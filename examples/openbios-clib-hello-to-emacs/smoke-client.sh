#!/usr/bin/env bash
# smoke-client.sh [ppc] — one verdict that the OpenBIOS client interface runs
# our C client. ppc is the track that works today: the STOCK qemu-system-ppc
# firmware already wires the client interface, so our cross-compiled `hello`
# is loaded from a CD, entered via `boot`, and answers over the console.
#
#   ppc: build (if needed) hello-ppc → a plain ISO9660 CD → boot cd:\HELLO.;1
#        → expect "Hello world!" (proof the firmware serviced the client's
#        `write` through the IEEE 1275 client interface).
#
# (x86 gets its own verdict once the firmware is revived — Phase 3.)
# Exit: 0 PASS / 1 FAIL / 77 SKIP.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_CLIENTS_WORKDIR:-$HOME/openbios-clients-lab}"
FLAVOR="${1:-ppc}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
trap 'rc=$?; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: test exited early (rc=$rc)"' EXIT

case "$FLAVOR" in
  ppc)
    command -v python3          >/dev/null || skip "python3 not installed"
    command -v qemu-system-ppc  >/dev/null || skip "qemu-system-ppc not installed"
    command -v genisoimage      >/dev/null || skip "genisoimage not installed"

    CLIENT="$WORKDIR/hello-ppc"
    if [[ ! -f "$CLIENT" ]]; then
        note "no $CLIENT yet — building it"
        ( cd "$HERE" && ./build-client.sh ppc hello ) >/dev/null 2>&1 \
            || skip "could not build hello-ppc (need podman + the client build box)"
    fi
    [[ -f "$CLIENT" ]] || fail "hello-ppc missing after build"

    # Plain ISO9660 (NO RockRidge — it crashes OpenBIOS's dir); the ".;1"
    # version suffix on the name is mandatory at the prompt.
    ISO="$WORKDIR/hello-ppc.iso"; STAGE="$WORKDIR/.isoroot-ppc"
    rm -rf "$STAGE" "$ISO"; mkdir -p "$STAGE"; cp "$CLIENT" "$STAGE/HELLO"
    genisoimage -quiet -o "$ISO" -V CLIENT "$STAGE" || fail "genisoimage failed"

    LOG="$WORKDIR/smoke-client-ppc.log"; rm -f "$LOG"
    note "booting stock qemu-system-ppc + our client CD, driving boot cd:\\HELLO.;1 → $LOG"
    # ppc console input needs a real terminal, not a socket → the pty driver.
    python3 "$REPO/tools/drive-pty-repl.py" "$LOG" --timeout 90 \
        --expect "0 > " \
        --send 'boot cd:\\HELLO.;1\r' --expect "Hello world!" \
        -- qemu-system-ppc -M mac99 -m 256 -cdrom "$ISO" -nographic -vga none
    RC=$?
    [[ $RC -eq 0 ]] || fail "client did not answer at the prompt (rc=$RC) — see $LOG"
    grep -aq "Hello world!" "$LOG" || fail "REGRESSION: firmware entered the client but no console output — client interface write() path broke"
    pass "OpenBIOS-ppc loaded our C client and serviced its write() over the IEEE 1275 client interface (Hello world!)" ;;

  x86)
    skip "x86 client track needs the firmware revival (Phase 3) — see PLAN.md / patches/00-x86-cif-plant.patch" ;;
  *) echo "usage: $0 [ppc|x86]" >&2; exit 1 ;;
esac
