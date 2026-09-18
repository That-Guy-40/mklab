#!/usr/bin/env bash
# build-cmdline-ptr-fixture.sh — the phys-0 boot_params dump the `cmdline-ptr`
# track (UKI Spike 7a) reads, edits, and grades against a foreign oracle.
#
# Derived at run time, never cached (the repo's rule). cmd_line_ptr is 0 on disk,
# so the fixture cannot BE a bzImage — it is guest physical memory captured from a
# REAL bootloader (QEMU's own -kernel loader) via capture-bootparams.py, dumped
# from address 0 so cmd_line_ptr is a direct offset into it. QEMU authored the
# pointer and the command-line buffer; we only pass the -append string, so the
# grade is against a foreign producer, not a round trip.
#
# It emits, into <outdir>:
#   CMDPTR.BIN      the dump, TRIMMED to cmd_line_ptr + ROOM so that BOTH bounds
#                   controls bite — CMDLINE-OOB (a write past the image end) and
#                   CMDLINE-TOO-BIG (a write past cmdline_size) need distinct sizes
#                   to be reachable, which requires ROOM < cmdline_size.
#   CMDLINE-PTR.FTH the rescue command line as a COMPILED word (no transient s" at
#                   the prompt) + the two control sizes, derived from the capture.
#   sentinel.txt    the exact -append string, for the track's read oracle.
#   rescue.txt      the exact rescue line, for the track's edit oracle.
#
# The builder VERIFIES what it emitted: the trimmed dump still decodes to the
# sentinel (the trim did not orphan the pointer), and the sizes are self-consistent.
#
# Usage: build-cmdline-ptr-fixture.sh <outdir> [<bzImage>]
set -eu
OUT="${1:?usage: build-cmdline-ptr-fixture.sh <outdir> [<bzImage>]}"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT"

# ── the subject: a REAL bzImage (its loader is the foreign oracle) ────────────
is_bzimage() { [[ -r "$1" ]] && file -b "$1" 2>/dev/null | grep -q 'Linux kernel x86 boot executable bzImage'; }
SRC="${2:-}"
if [[ -z "$SRC" ]]; then
  for c in "${BZIMAGE:-}" \
           /media/sqs/COLD_STORAGE/LAB_CREATE_V2/micro-linux/out/x86_64/build/linux-6.12.30/arch/x86/boot/bzImage; do
    [[ -n "$c" ]] && is_bzimage "$c" && { SRC="$c"; break; }
  done
fi
if [[ -z "$SRC" ]]; then
  for k in /boot/vmlinuz-*; do is_bzimage "$k" && { SRC="$k"; break; }; done
fi
[[ -n "$SRC" ]] || { echo "no readable bzImage found (set BZIMAGE=/path/to/bzImage) — the foreign loader" >&2; exit 77; }

# ── the strings: a realistic default, and the shorter rescue edit ─────────────
SENTINEL='root=/dev/vda1 ro quiet SENTINEL_CMDLINE_7=orig'
RESCUE='init=/bin/bash single'
ROOM=$((0x100))   # bytes carried past cmd_line_ptr: must exceed both strings and
                  # be LESS than cmdline_size, so an OOB size below cmdline_size exists

# ── capture a real boot_params from QEMU's loader, verified to hold SENTINEL ──
RAW="$OUT/capture.raw"
INFO="$(CMDPTR_INITRD="${CMDPTR_INITRD:-}" python3 "$HERE/capture-bootparams.py" "$SRC" "$SENTINEL" "$RAW" 40000)" \
  || { echo "capture-bootparams.py failed for $SRC — see stderr above" >&2; exit 1; }
BP_OFF=$(  printf '%s' "$INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin)["bp_off"])')
CMD_PTR=$( printf '%s' "$INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cmd_line_ptr"])')
CMD_SZ=$(  printf '%s' "$INFO" | python3 -c 'import json,sys;print(json.load(sys.stdin)["cmdline_size"])')

# ── size checks, before trimming: every bound must be satisfiable ─────────────
TRIM=$(( CMD_PTR + ROOM ))
[[ $(( BP_OFF + 0x264 )) -le $TRIM ]] || { echo "boot_params (0x$(printf %x "$BP_OFF")) + 0x264 does not fit in the trim to 0x$(printf %x "$TRIM") — unexpected QEMU layout" >&2; exit 1; }
[[ ${#SENTINEL} -lt $ROOM ]] || { echo "sentinel (${#SENTINEL} B) does not fit ROOM (0x$(printf %x "$ROOM"))" >&2; exit 1; }
[[ ${#RESCUE}  -lt $ROOM ]] || { echo "rescue (${#RESCUE} B) does not fit ROOM" >&2; exit 1; }
[[ ${#RESCUE}  -le $CMD_SZ ]] || { echo "rescue (${#RESCUE} B) exceeds cmdline_size (0x$(printf %x "$CMD_SZ"))" >&2; exit 1; }
OOB=$(( ROOM + 0x40 ))                       # ≥ ROOM (overruns the image) …
[[ $OOB -le $CMD_SZ ]] || { echo "cmdline_size (0x$(printf %x "$CMD_SZ")) too small: no OOB size below it exists (need ≥ 0x$(printf %x "$OOB"))" >&2; exit 1; }
TOOBIG=$(( CMD_SZ + 1 ))                      # … but TOOBIG is > cmdline_size

# ── trim the dump to cmd_line_ptr + ROOM (keeps the pointer a direct offset) ──
dd if="$RAW" of="$OUT/CMDPTR.BIN" bs=1 count="$TRIM" 2>/dev/null
rm -f "$RAW"
[[ -s "$OUT/CMDPTR.BIN" ]] || { echo "the trimmed dump was not produced" >&2; exit 1; }

# ── VERIFY the emitted fixture: the trim did not orphan cmd_line_ptr ──────────
GOT="$(python3 "$HERE/decode-cmdline.py" "$OUT/CMDPTR.BIN")" || { echo "decode-cmdline could not read the trimmed dump — the trim orphaned the pointer" >&2; exit 1; }
[[ "$GOT" == "$SENTINEL" ]] || { echo "the trimmed dump decodes to '$GOT', not the sentinel '$SENTINEL'" >&2; exit 1; }

# ── emit the generated Forth and the oracle text ─────────────────────────────
printf '%s' "$SENTINEL" > "$OUT/sentinel.txt"
printf '%s' "$RESCUE"   > "$OUT/rescue.txt"
{
  printf '%s\n' '\ CMDLINE-PTR.FTH — generated by build-cmdline-ptr-fixture.sh (do not edit).'
  printf '%s\n' '\ The rescue command line (compiled, so no transient s" is live at the prompt)'
  printf '%s\n' '\ and the two control sizes, derived from the captured cmdline_size / image.'
  printf '%s\n' 'hex'
  printf ': rescue-cmdline s" %s" ;\n' "$RESCUE"
  printf '%x constant cle-toobig    \\ > cmdline_size (0x%x) -> bp| CMDLINE-TOO-BIG\n' "$TOOBIG" "$CMD_SZ"
  printf '%x constant cle-oob        \\ <= cmdline_size but past the image -> bp| CMDLINE-OOB\n' "$OOB"
} > "$OUT/CMDLINE-PTR.FTH"

echo "source: $SRC  boot_params: 0x$(printf %x "$BP_OFF")  cmd_line_ptr: 0x$(printf %x "$CMD_PTR")  cmdline_size: 0x$(printf %x "$CMD_SZ")  trim: 0x$(printf %x "$TRIM")" >&2
