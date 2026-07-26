#!/usr/bin/env bash
# run-habitat.sh [sparc32|ppc] [--bare] — an interactive 0 > prompt, ofdiag resident.
#
# Ctrl-A X quits QEMU. Pass --bare to boot WITHOUT the vocabulary, which is how
# you see what the machine looks like before this lab touches it.
set -u
TRACK_ARG="sparc32"; BARE=""
for a in "$@"; do
    case "$a" in
        sparc32|ppc) TRACK_ARG="$a" ;;
        --bare)      BARE=yes ;;
        *) echo "usage: $0 [sparc32|ppc] [--bare]"; exit 1 ;;
    esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${HABITAT_WORKDIR:-$HOME/ofhabitat-lab}"
# shellcheck source=lib-habitat.sh
. "$HERE/lib-habitat.sh"
habitat_track "$TRACK_ARG" || { echo "usage: $0 [sparc32|ppc] [--bare]"; exit 1; }

command -v "$QEMU" >/dev/null || { echo "SKIP: $QEMU not installed"; exit 77; }

PROM=()
if [ -z "$BARE" ]; then
    MIN="$WORKDIR/ofdiag.min.fth"
    [ -f "$MIN" ] || { echo "no $MIN — run ./stage-dsl.sh"; exit 77; }
    PROM=(-prom-env "use-nvramrc?=true" -prom-env "nvramrc=$(cat "$MIN")")
fi
MEDIA=(); [ "$HAS_FS" = yes ] && [ -f "$WORKDIR/dsl.iso" ] && MEDIA=("${MEDIA_ARGS[@]}")

# pad to the column the rest of the list uses (the per-track target varies in width)
EG="$(printf '%-34s' "\" $T_OPENFAIL\" diag-open")"
cat <<EOF
Track: $TRACK_ARG — $MACHINE
Prompt is '0 > ' (the STACK DEPTH, not 'ok'), and the base is HEX.
${BARE:+Booting BARE — no vocabulary.}${BARE:+
}Try:
  why-no-boot                       diagnose every boot-device entry in turn
  ${EG}one target, one verdict
  printenv                          the config variables (authentically $([ "$TRACK_ARG" = ppc ] && echo Apple || echo Sun))
  dev / ls                          walk the device tree
  devalias                          NOTE: prints nothing — use 'dev /aliases .properties'
  see why-no-boot                   the firmware decompiles the word you just loaded
Ctrl-A X quits.

EOF
exec "$QEMU" "${QARGS[@]}" "${PROM[@]}" "${MEDIA[@]}"
