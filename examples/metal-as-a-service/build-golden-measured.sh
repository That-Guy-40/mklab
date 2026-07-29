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
#   kernel     the AlmaLinux 9 netboot vmlinuz (~/netboot/vmlinuz) — TPM support
#              built IN (a busybox init read PCR0 straight out of
#              /sys/class/tpm/tpm0/pcr-sha256/ under swtpm). NOTE this is NOT the
#              kernel the deployer ramdisk uses: that one is micro-linux's, which
#              has no TPM at all. They are different kernels with complementary
#              gaps, and this comment used to claim they were the same one.
#   NIC drvs   failover/net_failover/virtio_net, lifted from the matching AlmaLinux
#              netboot initrd — this kernel keeps them modular and expects dracut,
#              so without them the node measures perfectly and cannot report it
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
KERNEL="${MAAS_MEASURED_KERNEL:-$HOME/netboot/vmlinuz}"
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

# ── the NIC drivers, without which the quote never leaves the machine ───────
# FOUND LIVE 2026-07-29. This image measured 10 real PCRs, signed the quote on the
# node, and then could not deliver it:
#
#     udhcpc: SIOCGIFINDEX: No such device
#     MAAS-ATTEST: identity: mac= addr=none
#
# The kernel had no network interface at all — it registers every network protocol
# family and not one NIC driver. AlmaLinux keeps them as MODULES for dracut to load,
# and this initramfs is busybox with no modules in it. The two kernels available here
# each have exactly half of what a measured node needs:
#
#     AlmaLinux 9.8 netboot   TPM built in   NIC drivers modular    <- this one
#     micro-linux 6.12.30     no TPM at all  NIC drivers built in
#
# So the TPM decides the kernel (a payload that cannot read a PCR measures nothing —
# see the header), and the modules have to be carried in. They come out of the same
# AlmaLinux netboot initrd the install driver already uses, which is where the
# matching build of them lives.
#
# THE VERSION CHECK IS NOT OPTIONAL. A module built for a different kernel fails with
# `insmod: invalid module format` inside a busybox initramfs, which lands the node
# right back at "no network interface" — the same silent symptom, one layer down. So
# the kernel's own version string is read out of the bzImage and compared.
MODSRC="${MAAS_MEASURED_MODULES:-$HOME/netboot/initrd.img}"
# failover <- net_failover <- virtio_net, per the initrd's own modules.dep. virtio_pci
# and virtio are NOT modules here (they are built in, which is why virtio_blk works).
NIC_MODULES=(kernel/net/core/failover.ko.xz
             kernel/drivers/net/net_failover.ko.xz
             kernel/drivers/net/virtio_net.ko.xz)
MODDIR="$(dirname "$OUT")/nic-modules"
rm -rf "$MODDIR"; mkdir -p "$MODDIR"

kver="$(file -b "$KERNEL" 2>/dev/null | sed -nE 's/.*version ([^ ]+) .*/\1/p')"
[[ -n "$kver" ]] || die "could not read a version string out of $KERNEL — refusing to guess
which kernel modules belong with it (a mismatch fails as 'invalid module format' at boot,
and the node then has no network with no useful message)."

[[ -f "$MODSRC" ]] || die "no module source at $MODSRC.
The measured image's kernel ($kver) needs virtio_net, which AlmaLinux ships as a module.
Point MAAS_MEASURED_MODULES= at the matching netboot initrd, or stage it:
  run-e2e-install.sh's preflight fetches the AlmaLinux netboot pair."

modwork="$(mktemp -d)"
trap 'rm -rf "$modwork"' EXIT
( cd "$modwork" && { zstd -dc "$MODSRC" 2>/dev/null || xzcat "$MODSRC" 2>/dev/null \
    || zcat "$MODSRC" 2>/dev/null || cat "$MODSRC"; } | cpio -idm --no-absolute-filenames 2>/dev/null )
modroot="$(find "$modwork" -type d -name "$kver" -path '*modules*' 2>/dev/null | head -1)"
[[ -n "$modroot" ]] || die "$MODSRC carries no modules for kernel $kver.
Available: $(find "$modwork" -maxdepth 4 -type d -path '*lib/modules/*' -printf '%f ' 2>/dev/null || echo none)
A module built for another kernel would fail 'insmod: invalid module format' and the node
would have no network — the exact failure this check exists to prevent."

mod_files=()
for rel in "${NIC_MODULES[@]}"; do
    src="$modroot/$rel"
    [[ -f "$src" ]] || die "$MODSRC has no $rel for kernel $kver — the measured node could not bring up its NIC"
    base="$(basename "$rel" .xz)"
    if [[ "$rel" == *.xz ]]; then
        xzcat "$src" > "$MODDIR/$base" || die "could not decompress $src"
    else
        cp "$src" "$MODDIR/$base"
    fi
    mod_files+=("$base")
done
echo "  - NIC modules for $kver: ${mod_files[*]} (from $MODSRC)" >&2

# ── the initramfs ───────────────────────────────────────────────────────────
INITRAMFS="$(dirname "$OUT")/measure-initramfs.cpio.gz"
add_args=(--add "$SSL:/usr/bin/openssl")
# Load order matters and is encoded in the filenames' order here; measure-init.sh
# insmods /lib/modules/nic/* in the order listed in nic-load-order.
for m in "${mod_files[@]}"; do add_args+=(--add "$MODDIR/$m:/lib/modules/nic/$m"); done
printf '%s\n' "${mod_files[@]}" > "$MODDIR/nic-load-order"
add_args+=(--add "$MODDIR/nic-load-order:/lib/modules/nic-load-order")
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
# ...and the NIC modules really are inside the initramfs. Listing what was passed to
# the builder is not proof it landed (the same rule the builder itself learned), and
# the failure mode is a node that measures correctly and cannot deliver a word of it.
for m in "${mod_files[@]}"; do
    zcat "$INITRAMFS" 2>/dev/null | cpio -t 2>/dev/null | grep -q "lib/modules/nic/$m" \
        || die "the built initramfs does not contain lib/modules/nic/$m — the measured node
would come up with no network interface and park with its quote undelivered"
done

echo "built measured golden image: $OUT ($(du -h "$OUT" | cut -f1))" >&2
echo "verified: ESP filesystem + /EFI/BOOT/BOOTX64.EFI + PE header on the UKI + ${#mod_files[@]} NIC modules in the initramfs" >&2
echo "  attestation key: $AKDIR (baked into the image — NOT a trust anchor; see measure-init.sh)" >&2
