#!/usr/bin/env bash
# stage-dsl.sh — prepare the vocabulary for BOTH delivery doors.
#
# The two habitats accept a vocabulary through different doors, and neither
# accepts the other's (see DELIVERY.md), so staging produces two artifacts:
#
#   $WORKDIR/dsl.iso          ISO9660, 8.3 UPPERCASE — the SPARC door
#                             (`load cdrom:\OFDIAG.FTH` + `load-base load-size
#                             evaluate`). PPC cannot read it: no filesystem.
#   $WORKDIR/<name>.min.fth   the same source squeezed onto ONE line — the
#                             NVRAM door (`-prom-env nvramrc=...`), which is
#                             the only door that works on BOTH tracks.
#
# Three traps are handled here rather than left for the reader to trip:
#  1. 8.3 UPPERCASE. Same reason as the sister lab: the firmware's ISO9660
#     reader has no Rock Ridge, so `ofdiag.fth` must be staged as OFDIAG.FTH.
#  2. `device-end` is PREPENDED to every minified script. When nvramrc runs, a
#     device node is still active (measured: active-package != 0), so a bare `:`
#     compiles a package METHOD instead of a global word — the script appears to
#     work, prints its banner, and every word it defined is gone by the prompt.
#     This belongs to the delivery, not the vocabulary, so it lives here.
#  3. The one-line form CANNOT keep comments: `\` runs to end of line, and on a
#     single line that is the entire rest of the vocabulary. minify-fth.py
#     strips both comment forms and preserves string interiors.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${HABITAT_WORKDIR:-$HOME/ofhabitat-lab}"
STAGE="$WORKDIR/dsl-stage"
# packages/nvram.c:31 — DEF_SYSTEM_SIZE 0xc10, minus a 0x10 partition header.
# That 3072 bytes is shared by ALL config variables, not reserved for nvramrc.
NVRAM_BUDGET=3072

command -v genisoimage >/dev/null || { echo "SKIP: genisoimage not installed"; exit 77; }
mkdir -p "$WORKDIR"
rm -rf "$STAGE"; mkdir -p "$STAGE"

for f in "$HERE"/dsl/*.fth; do
    b="$(basename "$f")"; n="${b%.fth}"
    [ "${#n}" -le 8 ] || { echo "FAIL: '$b' is not 8.3 — the firmware's ISO9660 reader cannot open it"; exit 1; }
    cp "$f" "$STAGE/$(echo "$n" | tr '[:lower:]' '[:upper:]').FTH"

    # The NVRAM form. Fail loudly on overflow: a silently truncated nvramrc
    # would load a HALF vocabulary and report `ok`.
    min="$WORKDIR/$n.min.fth"
    { printf 'device-end '; python3 "$HERE/minify-fth.py" "$f"; } > "$min" 2>/dev/null \
        || { echo "FAIL: minify-fth.py failed on $b"; exit 1; }
    sz=$(wc -c < "$min")
    [ "$sz" -le "$NVRAM_BUDGET" ] \
        || { echo "FAIL: $n.min.fth is $sz bytes, over the $NVRAM_BUDGET-byte NVRAM config partition"; exit 1; }
    echo "  - $b -> $(basename "$min") ($sz bytes of $NVRAM_BUDGET) + $STAGE/$(echo "$n" | tr '[:lower:]' '[:upper:]').FTH"
done

genisoimage -quiet -o "$WORKDIR/dsl.iso" -V OFDSL "$STAGE" || { echo "FAIL: genisoimage"; exit 1; }
echo "staged $(ls "$STAGE" | tr '\n' ' ')-> $WORKDIR/dsl.iso"

# ── the autotrace script ─────────────────────────────────────────────────────
# patch + tracers + `trace-boot`, as ONE nvramrc line. Because nvramrc runs
# before probe-all, the call sites are rewritten before the firmware has probed
# anything — so the POWER-ON autoboot traces itself, with nothing typed.
AT="$WORKDIR/autotrace.min.fth"
{ printf 'device-end '
  python3 "$HERE/minify-fth.py" "$HERE/dsl/patch.fth" "$HERE/dsl/tracers.fth" || exit 1
  printf ' trace-boot'
} 2>/dev/null | tr -d '\n' > "$AT" || { echo "FAIL: building $AT"; exit 1; }
sz=$(wc -c < "$AT")
[ "$sz" -le "$NVRAM_BUDGET" ] \
    || { echo "FAIL: autotrace.min.fth is $sz bytes, over the $NVRAM_BUDGET-byte NVRAM config partition"; exit 1; }
echo "  - patch.fth + tracers.fth -> autotrace.min.fth ($sz bytes of $NVRAM_BUDGET, arms itself at power-on)"
