#!/usr/bin/env bash
# run-habitat.sh [sparc32|ppc] [--bare|--autotrace] — an interactive 0 > prompt.
#
# Ctrl-A X quits QEMU.
#   (default)    ofdiag resident in NVRAM — the diagnosis ladder
#   --bare       NO vocabulary: the machine as the firmware leaves it
#   --autotrace  patch + tracers instead, armed before probe-all, so the
#                power-on autoboot traces itself before you type anything
set -u
TRACK_ARG="sparc32"; BARE=""; MODE=ofdiag
for a in "$@"; do
    case "$a" in
        sparc32|ppc) TRACK_ARG="$a" ;;
        --bare)      BARE=yes ;;
        --autotrace) MODE=autotrace ;;
        *) echo "usage: $0 [sparc32|ppc] [--bare|--autotrace]"; exit 1 ;;
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
    case "$MODE" in
        ofdiag)    MIN="$WORKDIR/ofdiag.min.fth" ;;
        autotrace) MIN="$WORKDIR/autotrace.min.fth" ;;
    esac
    [ -f "$MIN" ] || { echo "no $MIN — run ./stage-dsl.sh"; exit 77; }
    PROM=(-prom-env "use-nvramrc?=true" -prom-env "nvramrc=$(cat "$MIN")")
fi
MEDIA=(); [ "$HAS_FS" = yes ] && [ -f "$WORKDIR/dsl.iso" ] && MEDIA=("${MEDIA_ARGS[@]}")

# The suggestion list depends on which vocabulary is actually resident —
# offering `why-no-boot` in autotrace mode would just print "undefined word".
EG="$(printf '%-34s' "\" $T_OPENFAIL\" diag-open")"
cat <<EOF
Track: $TRACK_ARG — $MACHINE
Prompt is '0 > ' (the STACK DEPTH, not 'ok'), and the base is HEX.
EOF
if [ -n "$BARE" ]; then
    cat <<EOF
Booting BARE — no vocabulary loaded. Try:
  dev / ls                          walk the device tree
  dev /aliases .properties          the real ones ('devalias' prints nothing)
  printenv                          config variables (authentically $([ "$TRACK_ARG" = ppc ] && echo Apple || echo Sun))
  see patch                         7.5.3.3, and it is EMPTY: ': patch ;'
EOF
elif [ "$MODE" = autotrace ]; then
    cat <<EOF
Loaded from NVRAM: patch + tracers, ARMED before probe-all.
Scroll up: the #T lines above the prompt are the POWER-ON autoboot tracing
itself, with nothing typed. Try:
  trace-sites u.                    how many call sites were rewritten (2)
  untrace                           put the firmware back, then boot again
  see \$load                         the rewritten body — t-open-dev in place of open-dev
  see patch                         our implementation, shadowing the stub
EOF
else
    cat <<EOF
Loaded from NVRAM: ofdiag. Try:
  why-no-boot                       diagnose every boot-device entry in turn
  ${EG}one target, one verdict
  printenv                          config variables (authentically $([ "$TRACK_ARG" = ppc ] && echo Apple || echo Sun))
  dev / ls                          walk the device tree
  see why-no-boot                   the firmware decompiles the word you just loaded
EOF
fi
echo "Ctrl-A X quits."
echo
exec "$QEMU" "${QARGS[@]}" "${PROM[@]}" "${MEDIA[@]}"
