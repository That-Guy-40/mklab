#!/usr/bin/env bash
# build-rom.sh — build a MEASURED coreboot ROM (q35, TPM 2.0 over TIS, measured boot,
# TCG 2.0-format log) carrying one of two payloads, into its own isolated objdir:
#
#   build-rom.sh linux      payload = the TPM-capable capture kernel + initramfs
#   build-rom.sh openbios   payload = OpenBIOS (amd64, obj-amd64/openbios-builtin.elf32)
#
# THE PREREQUISITE, MEASURED RATHER THAN ASSUMED. Plan §12(2) / review F4 named it as
# "a coreboot build with CONFIG_VBOOT + a TPM". What an EVENT LOG actually needs is
# measured boot, not verified boot: TPM2 + TPM_MEASURED_BOOT (which selects only the
# vboot LIBRARY) + TPM_LOG_TPM2 (the TCG PC Client format dsl/eventlog.fth already
# reads). qemu-q35 selects MEMORY_MAPPED_TPM (TIS at 0xfed40000) — the i440fx board
# the lab's other ROMs use does not, so these are q35. ONE MORE THING, MEASURED:
# coreboot does NOT publish this TPM 2.0-format log through the ACPI TPM2 table —
# src/acpi/acpi.c points the table's log area at CBMEM_ID_TCPA_TCG_LOG (the TPM
# 1.2-format id) and creates an EMPTY one when absent, so a Linux payload's
# /sys/kernel/security/tpm0/binary_bios_measurements reads 0 bytes while the real
# log sits in cbmem under CBMEM_ID_TPM2_TCG_LOG. The capture initramfs therefore
# carries coreboot's own static `cbmem` and reads that entry directly (which needs
# iomem=relaxed on the kernel command line — see capture-init.sh).
#
# ISOLATION: .config-bench-<leg> + build-bench-<leg>/, so the lab's other ROMs
# (.config, .config-ofw, .config-openbios*) and their objdirs are untouched — the
# same discipline as build-coreboot-openbios.sh.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../../../.." && pwd)"
CB="${COREBOOT_DIR:-$HOME/linuxboot-lab/coreboot}"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
die() { printf 'build-rom: %s\n' "$*" >&2; exit 1; }
LEG="${1:-}"; [[ "$LEG" == linux || "$LEG" == openbios ]] || die "usage: $0 linux|openbios"
[[ -d "$CB/src" ]] || die "no coreboot tree at $CB (COREBOOT_DIR=)"
DOTCONFIG=".config-bench-$LEG"; OBJDIR="build-bench-$LEG"

KERNEL="${CAPTURE_KERNEL:-$HOME/.cache/mklab-kernel/vmlinuz}"
INITRD="${BENCH_INITRD:-$HERE/capture-initramfs.cpio.gz}"
OBELF="$WORKDIR/openbios/obj-amd64/openbios-builtin.elf32"
case "$LEG" in
  linux)
    [[ -r "$KERNEL" ]] || die "no readable TPM-capable kernel at $KERNEL"
    # Always rebuilt: the initramfs must carry coreboot's static `cbmem` (the guest reads
    # the TPM 2.0-format log out of cbmem with it — see capture-init.sh), and a stale
    # one built before cbmem existed would boot fine and then read 0 bytes.
    CBMEM="${CAPTURE_CBMEM:-$CB/util/cbmem/cbmem}"
    [[ -x "$CBMEM" ]] || die "no static cbmem at $CBMEM — build it: make -C $CB/util/cbmem LDFLAGS=-static"
    file -b "$CBMEM" | grep -q 'statically linked' || die "$CBMEM is not statically linked — an initramfs needs a static one"
    "$REPO/examples/metal-as-a-service/build-probe-initramfs.sh" \
      --init "$HERE/../edk2-swtpm/capture-init.sh" --busybox /usr/bin/busybox --out "$INITRD" \
      --add "$CBMEM:/bin/cbmem" >/dev/null 2>&1 \
      || die "building the capture initramfs failed"
    # SIZE, MEASURED. A 16 MiB ROM leaves a 16,596,480-byte slot; the 15 MiB kernel plus
    # a gzip initramfs carrying cbmem came to 16,632,490 — 36 KB over — and cbfstool's
    # LZMA cannot shrink an already-compressed bzImage ("LzmaEnc_Encode failed 9"). A
    # 32 MiB ROM is not the way out: cbfstool SIGABRTs (Error 134) building one for
    # x86 in this tree. So the initramfs is re-packed as xz (the kernel unpacks xz
    # initramfs natively), which recovers far more than the shortfall.
    command -v xz >/dev/null || die "xz is required to re-pack the initramfs"
    INITRD_XZ="${INITRD%.gz}.xz"
    zcat "$INITRD" | xz -9 --check=crc32 > "$INITRD_XZ" || die "re-packing the initramfs as xz failed"
    INITRD="$INITRD_XZ"
    PAYLOAD_KEYS="CONFIG_PAYLOAD_LINUX=y
CONFIG_PAYLOAD_FILE=\"$KERNEL\"
CONFIG_LINUX_INITRD=\"$INITRD\"
CONFIG_LINUX_COMMAND_LINE=\"console=ttyS0,115200 loglevel=5 iomem=relaxed\"" ;;
    # iomem=relaxed: the guest reads coreboot's TPM 2.0-format log straight out of
    # cbmem with `cbmem -r` (see capture-init.sh), and Ubuntu's CONFIG_STRICT_DEVMEM
    # refuses /dev/mem reads of RAM without it.
  openbios)
    [[ -f "$OBELF" ]] || die "no amd64 OpenBIOS payload at $OBELF — run ./build-openbios.sh amd64 first"
    PAYLOAD_KEYS="CONFIG_PAYLOAD_ELF=y
CONFIG_PAYLOAD_FILE=\"$OBELF\"" ;;
esac

echo "==> measured coreboot ROM, leg=$LEG: $CB/$DOTCONFIG + $OBJDIR/"
cat > "$CB/$DOTCONFIG" <<CFG
CONFIG_VENDOR_EMULATION=y
CONFIG_BOARD_EMULATION_QEMU_X86_Q35=y
CONFIG_COREBOOT_ROMSIZE_KB_${BENCH_ROMSIZE_KB:-16384}=y
CONFIG_TPM2=y
CONFIG_TPM_MEASURED_BOOT=y
CONFIG_TPM_LOG_TPM2=y
CONFIG_COMPRESSED_PAYLOAD_LZMA=y
CONFIG_CONSOLE_SERIAL=y
$PAYLOAD_KEYS
CFG
make -C "$CB" DOTCONFIG="$DOTCONFIG" obj="$OBJDIR" olddefconfig >/dev/null 2>&1 || die "olddefconfig failed"
# refuse a config where the measured-boot keys did not survive olddefconfig
for k in CONFIG_TPM2=y CONFIG_TPM_MEASURED_BOOT=y CONFIG_TPM_LOG_TPM2=y CONFIG_BOARD_EMULATION_QEMU_X86_Q35=y; do
  grep -qx "$k" "$CB/$DOTCONFIG" || die "$k did not survive olddefconfig — the measured-boot prerequisite is not satisfiable in this tree as written; see $CB/$DOTCONFIG"
done
make -C "$CB" DOTCONFIG="$DOTCONFIG" obj="$OBJDIR" -j"$(nproc)" >"$CB/$OBJDIR.build.log" 2>&1 \
  || die "build failed — see $CB/$OBJDIR.build.log (tail: $(tail -3 "$CB/$OBJDIR.build.log" | tr '\n' '|'))"
ROM="$CB/$OBJDIR/coreboot.rom"
[[ -s "$ROM" ]] || die "no coreboot.rom produced"
echo "==> $ROM ($(stat -c%s "$ROM") bytes); commit $(git -C "$CB" rev-parse --short HEAD 2>/dev/null || echo unknown)"
"$CB/$OBJDIR/cbfstool" "$ROM" print 2>/dev/null | grep -E 'payload|bootblock|romstage|ramstage' | head -5
