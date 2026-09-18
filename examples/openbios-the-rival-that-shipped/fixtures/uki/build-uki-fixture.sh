#!/usr/bin/env bash
# build-uki-fixture.sh — a small but FAITHFUL UKI for the `uki` track (Spike 2).
#
# Derived at run time, never cached (the repo's rule). Unlike fixtures/pe/ (which
# uses the stub as a stand-in kernel), this UKI's .linux is the real-mode setup of
# a REAL bzImage, so every section grades by what it TRULY is:
#   .linux    a real x86 kernel setup — ?bootparams ACCEPTS it, file(1) names it
#   .uname    the kernel version ukify detected FROM .linux (so .uname == .linux)
#   .initrd   the newc cpio from fixtures/cpio/ — cpio.fth walks it
#   .cmdline  the string
#   .osrel    an os-release stanza
#
# THE SIZE TRICK, and why it is honest: a full bzImage is tens of MiB and will not
# fit the firmware's load window, but ukify detects the version and writes .uname
# from the setup header alone, and ?bootparams reads only the setup header — both
# live in the first 64 KiB. So .linux is the bzImage's 64 KiB setup prefix: small,
# loadable, and a real kernel header that file(1)/?bootparams both accept.
#
# Usage: build-uki-fixture.sh <out.efi>
set -eu
OUT="${1:?usage: build-uki-fixture.sh <out.efi>}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v ukify   >/dev/null || { echo "ukify not installed (systemd-ukify) — the UKI builder/oracle" >&2; exit 1; }
command -v objcopy >/dev/null || { echo "objcopy not installed (binutils)" >&2; exit 1; }
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
[[ -f "$STUB" ]] || { echo "missing $STUB (systemd-boot-efi) — the EFI stub" >&2; exit 1; }

is_bzimage() { [[ -r "$1" ]] && file -b "$1" 2>/dev/null | grep -q 'Linux kernel x86 boot executable bzImage'; }
SRC=""
for c in "${BZIMAGE:-}" \
  /media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/x86_64/build/linux-6.12.30/arch/x86/boot/bzImage \
  /media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/riscv64/uroot-src/pkg/boot/bzimage/testdata/bzImage ; do
  [[ -n "$c" ]] && is_bzimage "$c" && { SRC="$c"; break; }
done
[[ -z "$SRC" ]] && for k in /boot/vmlinuz-*; do is_bzimage "$k" && { SRC="$k"; break; }; done
[[ -n "$SRC" ]] || { echo "no readable bzImage found (set BZIMAGE=/path/to/bzImage) — the .linux subject" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# the .linux: the bzImage's 64 KiB real-mode setup prefix (carries the setup
# header + version string; ?bootparams and ukify's version-detect both read it).
dd if="$SRC" of="$TMP/linux.setup" bs=1024 count=64 2>/dev/null
is_bzimage "$TMP/linux.setup" || { echo "the 64 KiB prefix of $SRC does not decode as a bzImage" >&2; exit 1; }
# the .initrd: the cpio track's OWN archive, so the handoff is graded against cpio -itv
bash "$HERE/../cpio/build-cpio-fixture.sh" "$TMP/initrd.cpio"
printf 'root=/dev/sda1 ro quiet\n'      > "$TMP/cmdline.txt"
printf 'PRETTY_NAME="Lab UKI"\nID=lab\n' > "$TMP/osrel.txt"

# ukify prints harmless notes on stderr; rc + objdump readability are the gate.
ukify build \
  --linux="$TMP/linux.setup" --stub="$STUB" \
  --initrd="$TMP/initrd.cpio" \
  --cmdline="@$TMP/cmdline.txt" --os-release="@$TMP/osrel.txt" \
  --output="$OUT" >/dev/null 2>&1
[[ -s "$OUT" ]] || { echo "ukify produced no UKI at $OUT" >&2; exit 1; }
objdump -h "$OUT" >/dev/null 2>&1 || { echo "objdump cannot read $OUT as a PE" >&2; exit 1; }
# prove the faithful sections are present, else the grade below has nothing to check.
for s in .linux .initrd .cmdline .osrel .uname; do
  objdump -h "$OUT" | grep -qE "[[:space:]]${s}[[:space:]]" || { echo "the UKI is missing the ${s} section — ukify did not add it" >&2; exit 1; }
done
echo "source .linux: $SRC (64 KiB setup prefix)" >&2
