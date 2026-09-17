#!/usr/bin/env bash
# build-pe-fixture.sh — author the UKI (a PE/COFF .efi) the `pe` track reads.
#
# Derived at run time, never cached (the repo's rule): a REAL Unified Kernel
# Image built with the host's own `ukify` (systemd's UKI builder — the UKI
# workbench plan's oracle), so the same `objdump -h` that lists its sections is a
# faithful oracle of the exact bytes dsl/pe.fth walks, and `ukify` is an
# independent author from the reader. The subject is genuinely a UKI: the systemd
# EFI stub with named PE sections glued on —
#
#   .linux    the (stand-in) kernel — here the stub itself; ukify wants a PE
#   .initrd   the newc cpio from fixtures/cpio/ — so pe-find hands it to cpio.fth
#   .cmdline  "root=/dev/sda1 ro quiet\n"  — pe-find hands it to `type`
#   .osrel    an os-release stanza
#   .sbat/.sdmagic/.reloc/.text/.rodata/.data  the stub's own sections
#
# The .initrd being the very archive the `cpio` track walks is the point: the
# `pe` track reads .initrd OUT of the PE and walks it as cpio, which is the UKI
# workbench's Spike 2 handoff (UKI_WORKBENCH_LAB_PLAN.md §Spike 2) end to end.
#
# Usage: build-pe-fixture.sh <out.efi>
set -eu
OUT="${1:?usage: build-pe-fixture.sh <out.efi>}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

command -v ukify   >/dev/null || { echo "ukify not installed (systemd-ukify) — the UKI builder/oracle" >&2; exit 1; }
command -v objcopy >/dev/null || { echo "objcopy not installed (binutils)" >&2; exit 1; }

# The systemd EFI stub — the real PE this UKI is built around. Path is stable on
# Debian/Ubuntu; fail by name if it moved rather than build a non-UKI.
STUB=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
[[ -f "$STUB" ]] || { echo "missing $STUB (systemd-boot-efi) — the PE the UKI is built around" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# the .initrd is the cpio track's OWN archive, so the handoff is graded against
# the same `cpio -itv` oracle the cpio track uses.
bash "$HERE/../cpio/build-cpio-fixture.sh" "$TMP/initrd.cpio"
printf 'root=/dev/sda1 ro quiet\n'          > "$TMP/cmdline.txt"
printf 'PRETTY_NAME="Lab UKI"\nID=lab\n'     > "$TMP/osrel.txt"

# ukify emits harmless autodetect warnings on stderr (the stub carries no Linux
# version string); rc and the output file are the gate, never a stderr grep.
ukify build \
  --linux="$STUB" --stub="$STUB" \
  --initrd="$TMP/initrd.cpio" \
  --cmdline="@$TMP/cmdline.txt" \
  --os-release="@$TMP/osrel.txt" \
  --output="$OUT" >/dev/null 2>&1
[[ -s "$OUT" ]] || { echo "ukify produced no UKI at $OUT" >&2; exit 1; }
# prove it is a PE the oracle can read (and thus grade), not merely non-empty.
objdump -h "$OUT" >/dev/null 2>&1 || { echo "objdump cannot read $OUT as a PE — the fixture is not a UKI" >&2; exit 1; }
