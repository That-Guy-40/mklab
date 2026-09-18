#!/usr/bin/env bash
# uki-edit.sh — produce a rescue UKI with a new kernel command line, WITHOUT a
# chroot, a USB stick, or blind GRUB-over-serial editing (UKI workbench Spike
# 8-basic — the persisted, host-side cousin of the in-firmware Spike 6/7 edits).
#
# The in-firmware edits (Spikes 6/7) are in-RAM and one-shot, and Spike 6 is
# bounded by the .cmdline section's raw slack. This tool is the PORTABLE, PERSISTED
# deliverable a UEFI x86 box actually uses: it rewrites a UKI's .cmdline — GROWING
# it past that slack — and emits a fresh, valid UKI to drop on the ESP, a change
# that survives reboots. It is unsigned (a non-secure-boot rescue box); re-signing
# is Spike 8-full's bridge to the attestation strand.
#
# HOW, and why not `objcopy --update-section`: that command leaves the section's
# VirtualSize header unchanged while overwriting the raw bytes, so a grown cmdline
# silently overflows the slot and the PE the firmware reads is broken (measured).
# So uki-edit REBUILDS with `ukify` instead — it extracts .linux/.initrd/.osrel
# from the input and rebuilds with the new --cmdline, so ukify lays out a correct
# PE and sizes .cmdline to fit. The output is then VALIDATED (its .cmdline reads
# back exactly, under a foreign objcopy) before it is written — a re-emit that does
# not validate is refused, never left on disk broken.
#
# Refuses BY NAME, writing NO output, like the readers/editors:
#   uki-edit| NOT-PE        the input is not a PE/COFF image
#   uki-edit| NO-CMDLINE    the input has no .cmdline section (not a UKI to edit)
#   uki-edit| NO-LINUX      the input has no .linux section (nothing to rebuild)
#   uki-edit| REEMIT-BROKEN the rebuilt UKI failed its own read-back check
#
# Usage: uki-edit.sh <in.efi> <out.efi> <new-cmdline>
#    or: uki-edit.sh <in.efi> <out.efi> @<file>     (cmdline read from <file>)
set -u

die()  { echo "uki-edit| $1"; exit 1; }
need() { command -v "$1" >/dev/null || { echo "uki-edit: missing $1 ($2)" >&2; exit 3; }; }

IN="${1:-}"; OUT="${2:-}"; CMD_ARG="${3:-}"
[[ -n "$IN" && -n "$OUT" && $# -ge 3 ]] || { echo "usage: uki-edit.sh <in.efi> <out.efi> <new-cmdline|@file>" >&2; exit 2; }
[[ -r "$IN" ]] || { echo "uki-edit: cannot read input $IN" >&2; exit 2; }

need objdump binutils; need objcopy binutils; need ukify systemd-ukify
STUB="${UKI_STUB:-/usr/lib/systemd/boot/efi/linuxx64.efi.stub}"
[[ -r "$STUB" ]] || { echo "uki-edit: missing EFI stub $STUB (set UKI_STUB=, install systemd-boot-efi)" >&2; exit 3; }

# the new command line: a literal, or @file
if [[ "$CMD_ARG" == @* ]]; then
  CF="${CMD_ARG#@}"; [[ -r "$CF" ]] || { echo "uki-edit: cannot read cmdline file $CF" >&2; exit 2; }
  NEWCMD="$(cat "$CF")"
else
  NEWCMD="$CMD_ARG"
fi
[[ -n "$NEWCMD" ]] || { echo "uki-edit: refusing an EMPTY command line" >&2; exit 2; }

# ── validate the input BEFORE touching anything ──────────────────────────────
objdump -f "$IN" 2>/dev/null | grep -q 'pei-' || die NOT-PE
HDRS="$(objdump -h "$IN" 2>/dev/null)" || die NOT-PE
grep -qE '[[:space:]]\.cmdline[[:space:]]' <<<"$HDRS" || die NO-CMDLINE
grep -qE '[[:space:]]\.linux[[:space:]]'   <<<"$HDRS" || die NO-LINUX

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
OLDLEN="$(objcopy -O binary --only-section=.cmdline "$IN" /dev/stdout 2>/dev/null | tr -d '\000' | wc -c)"

# ── extract the parts to preserve, rebuild with the new cmdline ──────────────
UARGS=( --stub="$STUB" --cmdline="$NEWCMD" --output="$WORK/out.efi" )
objcopy -O binary --only-section=.linux "$IN" "$WORK/linux" 2>/dev/null && UARGS+=( --linux="$WORK/linux" )
[[ -s "$WORK/linux" ]] || die NO-LINUX
if objcopy -O binary --only-section=.initrd "$IN" "$WORK/initrd" 2>/dev/null && [[ -s "$WORK/initrd" ]]; then
  UARGS+=( --initrd="$WORK/initrd" )
fi
if objcopy -O binary --only-section=.osrel "$IN" "$WORK/osrel" 2>/dev/null && [[ -s "$WORK/osrel" ]]; then
  UARGS+=( --os-release=@"$WORK/osrel" )
fi
ukify build "${UARGS[@]}" >"$WORK/ukify.log" 2>&1 || { echo "uki-edit: ukify failed:" >&2; tail -3 "$WORK/ukify.log" >&2; die REEMIT-BROKEN; }
[[ -s "$WORK/out.efi" ]] || die REEMIT-BROKEN

# ── VALIDATE the re-emit before it is written: still a PE, and .cmdline reads
#    back EXACTLY the new line (a foreign objcopy, not our own claim) ──────────
objdump -f "$WORK/out.efi" 2>/dev/null | grep -q 'pei-' || die REEMIT-BROKEN
GOT="$(objcopy -O binary --only-section=.cmdline "$WORK/out.efi" /dev/stdout 2>/dev/null | tr -d '\000')"
[[ "$GOT" == "$NEWCMD" ]] || die REEMIT-BROKEN

cp "$WORK/out.efi" "$OUT"
NEWLEN="$(printf '%s' "$NEWCMD" | wc -c)"
echo "uki-edit: $IN -> $OUT  .cmdline $OLDLEN -> $NEWLEN bytes (rescue image, persists across reboots; unsigned)"
