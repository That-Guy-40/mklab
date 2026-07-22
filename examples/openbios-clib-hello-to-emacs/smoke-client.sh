#!/usr/bin/env bash
# smoke-client.sh [ppc|x86] [program] — one verdict that the OpenBIOS client
# interface runs our C client. program defaults to "hello" (see clib/*.c for
# the ladder: hello, memtest, …). ppc is the track that works today: the STOCK
# qemu-system-ppc firmware already wires the client interface, so our
# cross-compiled client is loaded from a CD, entered via `boot`, and reports
# over the console — every line a firmware `write` service call.
#
#   ppc: build (if needed) <program>-ppc → a plain ISO9660 CD → boot cd:\NAME.;1
#        → expect the program's success marker.
#
# (x86 gets its own verdict once the firmware is revived — Phase 3.)
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
FLAVOR="${1:-ppc}"
PROG="${2:-hello}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

# Per-program success marker + how long to allow (memtest hammers RAM under TCG).
case "$PROG" in
  hello)   MARKER="Hello world!"; WHAT="answered Hello world!";           TMO=90 ;;
  memtest) MARKER="memtest: PASS"; WHAT="ran the RAM tester to a clean PASS"; TMO=140 ;;
  *)       MARKER="EXIT"; WHAT="ran and exited via the client interface";  TMO=90 ;;
esac

case "$FLAVOR" in
  ppc)
    command -v python3          >/dev/null || skip "python3 not installed"
    command -v qemu-system-ppc  >/dev/null || skip "qemu-system-ppc not installed"
    command -v genisoimage      >/dev/null || skip "genisoimage not installed"
    [[ -f "$HERE/clib/$PROG.c" ]] || skip "no such client program: clib/$PROG.c"

    CLIENT="$WORKDIR/$PROG-ppc"
    if [[ ! -f "$CLIENT" ]]; then
        note "no $CLIENT yet — building it"
        ( cd "$HERE" && ./build-client.sh ppc "$PROG" ) >/dev/null 2>&1 \
            || skip "could not build $PROG-ppc (need podman + the client build box)"
    fi
    [[ -f "$CLIENT" ]] || fail "$PROG-ppc missing after build"

    # Plain ISO9660 (NO RockRidge — it crashes OpenBIOS's dir); the ".;1"
    # version suffix on the name is mandatory at the prompt.
    NAME="$(echo "$PROG" | tr '[:lower:]' '[:upper:]')"
    ISO="$WORKDIR/$PROG-ppc.iso"; STAGE="$WORKDIR/.isoroot-$PROG"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/$NAME"
    genisoimage -quiet -o "$ISO" -V CLIENT "$STAGE" || fail "genisoimage failed"

    LOG="$WORKDIR/smoke-client-ppc-$PROG.log"; rm -f "$LOG"
    note "booting stock qemu-system-ppc + our $PROG CD, driving boot cd:\\$NAME.;1 → $LOG"
    # ppc console input needs a real terminal, not a socket → the pty driver.
    python3 "$REPO/tools/drive-pty-repl.py" "$LOG" --timeout "$TMO" \
        --expect "0 > " \
        --send "boot cd:\\\\$NAME.;1\r" --expect "$MARKER" \
        -- qemu-system-ppc -M mac99 -m 256 -cdrom "$ISO" -nographic -vga none
    RC=$?
    # A program that entered but reported its OWN failure (e.g. memtest: FAIL)
    # is a real, specific defect — surface it, don't just time out.
    if grep -aq "memtest: FAIL" "$LOG"; then
        fail "REGRESSION: memtest reported memory errors on emulated RAM — clib claim/verify path broke (see $LOG)"
    fi
    [[ $RC -eq 0 ]] || fail "$PROG did not reach its success marker '$MARKER' (rc=$RC) — see $LOG"
    grep -aq "$MARKER" "$LOG" || fail "REGRESSION: firmware entered $PROG but no '$MARKER' — client interface path broke"
    pass "OpenBIOS-ppc loaded our C client '$PROG' and it $WHAT over the IEEE 1275 client interface" ;;

  x86)
    skip "x86 client track needs the firmware revival (Phase 3) — see PLAN.md / patches/00-x86-cif-plant.patch" ;;
  *) echo "usage: $0 [ppc|x86] [program]" >&2; exit 1 ;;
esac
