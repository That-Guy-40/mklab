#!/usr/bin/env bash
# build-bootparams-fixture.sh — the x86 setup image the `bootparams` track reads.
#
# Derived at run time, never cached (the repo's rule): the first 64 KiB of a REAL
# bzImage — its real-mode "zero page" (struct boot_params + setup_header) and the
# version string, which is all dsl/bootparams.fth reads. The full kernel is tens
# of MiB and will not fit in the firmware's load window; the setup prefix is
# ~20 KiB and carries every field, and `file`(1) decodes the prefix exactly as it
# decodes the whole image (it only touches the header and follows the version
# pointer). So `file` stays a faithful oracle of the exact bytes the reader walks.
#
# The SUBJECT is a real, foreign-authored kernel — not something we mint — so the
# builder LOCATES one rather than building it (a kernel build is far too heavy for
# a fixture). Order: $BZIMAGE if set, then a small list of paths this host is
# known to carry, then any readable /boot/vmlinuz-*. It fails by name if none is
# found, and the track turns that into a SKIP.
#
# Usage: build-bootparams-fixture.sh <out.setup>
set -eu
OUT="${1:?usage: build-bootparams-fixture.sh <out.setup>}"

is_bzimage() { [[ -r "$1" ]] && file -b "$1" 2>/dev/null | grep -q 'Linux kernel x86 boot executable bzImage'; }

SRC=""
CANDS=(
  "${BZIMAGE:-}"
  /media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/x86_64/build/linux-6.12.30/arch/x86/boot/bzImage
  /media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/riscv64/uroot-src/pkg/boot/bzimage/testdata/bzImage
)
for c in "${CANDS[@]}"; do [[ -n "$c" ]] && is_bzimage "$c" && { SRC="$c"; break; }; done
if [[ -z "$SRC" ]]; then
  for k in /boot/vmlinuz-*; do is_bzimage "$k" && { SRC="$k"; break; }; done
fi
[[ -n "$SRC" ]] || { echo "no readable bzImage found (set BZIMAGE=/path/to/bzImage) — the reader's subject" >&2; exit 1; }

# the real-mode setup + version string live well within 64 KiB; take that prefix.
dd if="$SRC" of="$OUT" bs=1024 count=64 2>/dev/null
[[ -s "$OUT" ]] || { echo "dd produced no setup image at $OUT" >&2; exit 1; }
# prove the prefix is still a bzImage the oracle can read (and thus grade), and
# that the version pointer resolves inside it — else the prefix was too short.
is_bzimage "$OUT" || { echo "the 64 KiB prefix of $SRC does not decode as a bzImage — cannot grade" >&2; exit 1; }
file -b "$OUT" | grep -q 'version ' || { echo "the setup prefix carries no version string — the version pointer left the prefix" >&2; exit 1; }
echo "source: $SRC" >&2
