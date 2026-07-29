#!/usr/bin/env bash
# build-golden-measured.sh — build the MEASURED golden whole-disk image: a
# UEFI-bootable ESP carrying a UKI (TPM-capable kernel + the measuring
# initramfs, measure-init.sh) for `deploy --driver image+measured`.
#
# WHY BUILD ONE AT ALL, when the plain `image` driver already has a golden Alpine
# raw that boots. Because that image cannot measure anything: Alpine's cloud
# images ship the **-virt kernel flavour, which has no TPM drivers at all** (no
# drivers/char/tpm in /lib/modules), and micro-linux's kernel has none either.
# Verified before this script existed, by inspecting both images. A "measured"
# deploy on a payload that cannot read a PCR would be theatre.
#
# So this image is assembled from parts whose measurement is PROVEN, not assumed:
#   kernel     micro-linux's own hand-built kernel (micro-linux/out/x86_64/kernel),
#              which now has BOTH halves compiled in: TCG_TPM/TCG_TIS/TCG_CRB=y so
#              it can read /sys/class/tpm/tpm0/pcr-sha256/, and VIRTIO_NET/E1000=y
#              so it can say what it read. This is the SAME kernel the deployer
#              ramdisk uses — one kernel, both jobs.
#
#              It was not always so. This image used to borrow AlmaLinux 9's netboot
#              vmlinuz, because the two kernels available had complementary gaps:
#              AlmaLinux had the TPM built in and its NIC drivers modular, while
#              micro-linux had the NICs built in and no TPM at all. A node that
#              measures perfectly and cannot report it is worth as little as one
#              that cannot measure, so this script used to lift
#              failover/net_failover/virtio_net out of the matching AlmaLinux initrd
#              and carry them in — a bridge between two half-kernels, with a version
#              guard because a module built for another kernel fails `insmod:
#              invalid module format` and lands the node right back at "no network
#              interface", one layer down and just as silent.
#
#              Building TCG_TPM=y into micro-linux (see micro-linux/mlbuild.sh, and
#              note =y is not a preference: an initramfs loads no modules, so a
#              modular TPM is indistinguishable from none) collapsed both halves
#              into one kernel and deleted the bridge entirely.
#   initramfs  measure-init.sh + busybox + a real openssl (busybox has no crypto,
#              and the quote must be signed ON the node that measured it)
#   boot       a UKI (kernel+initramfs+cmdline in ONE PE binary, via ukify) on an
#              ESP, booted by OVMF — **not** BIOS/syslinux, and that is the whole
#              point of this file's existence.
#
# WHY UEFI, PROVEN RATHER THAN ASSUMED. The first version of this script built a
# BIOS/syslinux disk, and measuring it showed the gate would have been theatre:
#
#   two DIFFERENT golden images (96 MB vs 160 MB)      -> PCR4 IDENTICAL
#   the same image with files swapped INSIDE the FAT   -> every PCR IDENTICAL
#
# SeaBIOS measures the boot-sector code (PCR4) and the partition table (PCR5) and
# nothing else: a completely different kernel and initramfs inside the filesystem
# measure the same. A PCR policy over that would bless any payload. Under OVMF
# with a UKI, the same experiment gives the opposite result — changing one byte of
# the kernel command line changes **PCR4 and PCR9**, because the firmware measures
# the binary it loads and the UKI *is* the payload. That is real measured boot,
# and it is why this image is UEFI-only.
#
# ROOTLESS AND LOOP-FREE. No mount, no losetup, no mknod: ukify links the UKI,
# mtools formats the ESP and copies the binary in. Everything here runs as an
# ordinary user.
#
#   build-golden-measured.sh [--out FILE] [--kernel FILE] [--md-url URL]
#                            [--trust DIR] [--size MB]
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"

OUT="${MAAS_ARTIFACTS:-$HOME/.cache/lab-create/maas}/golden-measured.raw"
KERNEL="${MAAS_MEASURED_KERNEL:-$HERE/../../micro-linux/out/x86_64/kernel}"
MD_URL="${MAAS_MD_URL:-}"
TRUST=""
SIZE_MB=64
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)    OUT="$2"; shift 2 ;;
        --kernel) KERNEL="$2"; shift 2 ;;
        --md-url) MD_URL="$2"; shift 2 ;;
        --trust)  TRUST="$2"; shift 2 ;;
        --size)   SIZE_MB="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "build-golden-measured: unknown option $1" >&2; exit 1 ;;
    esac
done
die() { echo "build-golden-measured: $*" >&2; exit 1; }

for t in mformat mcopy mmd ukify dd file cpio xzcat; do command -v "$t" >/dev/null || die "$t is required (mtools, systemd-ukify, file, cpio, xz-utils)"; done
[[ -f "$KERNEL" ]] || die "no kernel at $KERNEL — the AlmaLinux netboot vmlinuz is staged by
run-e2e-install.sh's preflight, or pass --kernel <a kernel with TPM support built in>"
STUB=""
for c in /usr/lib/systemd/boot/efi/linuxx64.efi.stub /usr/lib/systemd/boot/efi/linuxx64.elf.stub; do
    [[ -f "$c" ]] && { STUB="$c"; break; }
done
[[ -n "$STUB" ]] || die "the systemd EFI stub is not installed (systemd-boot-efi / systemd-ukify)"

TRUST="${TRUST:-$("$MAAS" _images-dir)/trust}"
[[ -f "$TRUST/ca.crt" ]] || die "no lab CA at $TRUST/ca.crt (drivers/verify-lib.sh gen-keys --dir $TRUST)"

# ── the attestation key ─────────────────────────────────────────────────────
# A DEDICATED leaf, not the payload-signing key: a key that ends up inside every
# copy of a golden image must not also be the key that signs what the fleet
# boots. Minted from the same CA so the control plane's existing verifier can
# check the quote with no new trust root.
AKDIR="$(dirname "$OUT")/attest"
if [[ ! -f "$AKDIR/codesign.key" ]]; then
    mkdir -p "$AKDIR"
    "$HERE/drivers/verify-lib.sh" gen-ak --ca-dir "$TRUST" --out "$AKDIR" \
        || die "could not mint the attestation key"
fi

# ── openssl, for signing on the node ────────────────────────────────────────
# busybox has no crypto, and the quote MUST be signed by the machine that
# measured it. Bundle the host's openssl and the libraries it actually needs.
SSL="$(command -v openssl)" || die "openssl not found on the host"
mapfile -t LIBS < <(ldd "$SSL" 2>/dev/null | sed -nE 's@.*=> (/[^ ]+).*@\1@p'; ldd "$SSL" 2>/dev/null | sed -nE 's@^\s*(/lib64/ld-linux[^ ]*).*@\1@p')
[[ ${#LIBS[@]} -gt 0 ]] || die "could not resolve openssl's libraries with ldd"

# ── the NIC drivers: built into the kernel, nothing to carry ────────────────
# There is deliberately no module handling here any more, and the reason is worth
# keeping. On 2026-07-29 this image measured 10 real PCRs, signed the quote on the
# node, and then could not deliver it:
#
#     udhcpc: SIOCGIFINDEX: No such device
#     MAAS-ATTEST: identity: mac= addr=none
#
# The kernel had no network interface at all. At that point the two kernels on hand
# each had exactly half of what a measured node needs:
#
#     AlmaLinux 9.8 netboot   TPM built in    NIC drivers modular
#     micro-linux 6.12.30     no TPM at all   NIC drivers built in
#
# so this script borrowed AlmaLinux's kernel and lifted failover/net_failover/
# virtio_net out of the matching netboot initrd, guarded by a kernel-version check
# (a module built for another kernel fails `insmod: invalid module format` and lands
# the node right back at "no network interface", one layer down and just as silent).
#
# micro-linux now builds TCG_TPM/TCG_TIS/TCG_CRB=y alongside VIRTIO_NET/E1000=y, so
# one kernel does both jobs and the bridge is gone: no MODSRC, no version guard, no
# nic-load-order, no insmod. If a future kernel makes NICs modular again, the symptom
# to recognise is the SIOCGIFINDEX line above — measure-init.sh still distinguishes
# "no interface exists" from "an interface exists but got no lease", which is the
# diagnosis that made this findable in the first place.

# ── the initramfs ───────────────────────────────────────────────────────────
INITRAMFS="$(dirname "$OUT")/measure-initramfs.cpio.gz"
add_args=(--add "$SSL:/usr/bin/openssl")
for l in "${LIBS[@]}"; do add_args+=(--add "$l:$l"); done
add_args+=(--add "$AKDIR/codesign.crt:/etc/attest/codesign.crt")
add_args+=(--add "$AKDIR/codesign.key:/etc/attest/codesign.key")
add_args+=(--add "$TRUST/ca.crt:/etc/attest/ca.crt")
"$HERE/build-probe-initramfs.sh" --init "$HERE/measure-init.sh" --out "$INITRAMFS" \
    "${add_args[@]}" >/dev/null 2>&1 || die "building the measuring initramfs failed"
echo "  - measuring initramfs: $INITRAMFS ($(du -h "$INITRAMFS" | cut -f1), openssl + AK bundled)" >&2

# ── the disk: an ESP carrying one UKI ───────────────────────────────────────
# The cmdline is baked INTO the UKI, which is exactly why this works: the
# firmware measures the whole binary, so the command line cannot be edited
# without changing PCR4. ip=dhcp for the same reason the deployer needs it (the
# ramdisk talks to the control plane itself); identity is NOT here — the image is
# generic and the node identifies itself by MAC (see measure-init.sh).
CMDLINE="console=ttyS0 ip=dhcp${MD_URL:+ maas.md=$MD_URL}"
UKI="$(dirname "$OUT")/measured-uki.efi"
ukify build --linux "$KERNEL" --initrd "$INITRAMFS" --cmdline "$CMDLINE" \
    --stub "$STUB" --output "$UKI" >/dev/null 2>&1 \
    || die "ukify could not build the UKI"
echo "  - UKI: $UKI ($(du -h "$UKI" | cut -f1)) — kernel+initramfs+cmdline, measured as ONE binary" >&2

# A whole-disk ESP: no partition table needed for OVMF's removable-media path,
# which looks for /EFI/BOOT/BOOTX64.EFI on a FAT volume. Fewer moving parts than
# a partitioned disk, and every byte here is fillable with mtools as an ordinary
# user — no mount, no losetup, no root.
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=1M count="$SIZE_MB" status=none || die "could not create $OUT"
mformat -i "$OUT" -F -v MEASURED :: 2>/dev/null || die "mformat could not create the ESP filesystem"
mmd -i "$OUT" ::/EFI ::/EFI/BOOT 2>/dev/null || die "could not create /EFI/BOOT in the ESP"
mcopy -i "$OUT" "$UKI" ::/EFI/BOOT/BOOTX64.EFI || die "mcopy: the UKI"

# ── prove it before calling it built ────────────────────────────────────────
# The same rule the initramfs builder learned: listing what you packed is not
# proof. A golden image that does not boot is worse than none, because the
# deploy succeeds and the node comes up dead.
mdir -i "$OUT" :: >/dev/null 2>&1 || die "the filesystem in the built image is not readable"
mdir -i "$OUT" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1 \
    || die "the built image has no /EFI/BOOT/BOOTX64.EFI — OVMF's removable-media path would find nothing to boot"
# The UKI must be a PE binary, or the firmware loads nothing and measures nothing.
head -c 2 "$UKI" | grep -q 'MZ' || die "the UKI is not a PE/COFF binary (no MZ header)"
# ...and openssl really is inside the initramfs. Listing what was passed to the
# builder is not proof it landed — the rule this check was written for, when the
# payload here was the NIC modules; the kernel now carries those, but the principle
# outlives them and openssl is the remaining binary the node cannot do without.
# busybox has no crypto, so an initramfs missing it produces a node that measures
# 10 real PCRs and cannot sign a single one of them.
zcat "$INITRAMFS" 2>/dev/null | cpio -t 2>/dev/null | grep -q 'usr/bin/openssl' \
    || die "the built initramfs does not contain usr/bin/openssl — the measured node
would read its PCRs and then have no way to sign the quote"

echo "built measured golden image: $OUT ($(du -h "$OUT" | cut -f1))" >&2
echo "verified: ESP filesystem + /EFI/BOOT/BOOTX64.EFI + PE header on the UKI + openssl in the initramfs" >&2
echo "  attestation key: $AKDIR (baked into the image — NOT a trust anchor; see measure-init.sh)" >&2
