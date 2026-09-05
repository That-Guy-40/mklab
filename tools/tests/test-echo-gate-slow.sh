#!/usr/bin/env bash
# test-echo-gate-slow.sh — the echo-gate must not DUPLICATE a byte whose echo is
# merely SLOW (as opposed to dropped). Host-only: no QEMU, no root, no network.
#
# THE BUG THIS GUARDS (measured 2026-09-05, examples/openbios-the-rival-that-
# shipped tlv-primitives on ppc). drive-pty-repl.py's --echo-gate resends a byte
# it has not seen echoed within --echo-timeout, on the theory that a non-echo
# means the no-flow-control console dropped it. But it cannot tell a DROP from a
# SLOW echo: ppc under TCG echoes the first byte of a command typed right after a
# heavy `evaluate` only once it has flushed that evaluate's output, past the 2 s
# default. The resend then duplicates a byte the console DID accept -- `load
# cd:\S0CHK.FTH;1` arrived as `lload` -- and the drive spiralled to its timeout.
#
# The fixture slow-echo-console.py echoes every byte (dropping NOTHING) but holds
# the first one BUSY seconds. So a grace SHORTER than BUSY resends -> duplicates;
# a grace LONGER than BUSY does not. PASS requires BOTH: the duplicate must
# reproduce at the default grace (else the fixture proves nothing), and the
# larger grace must deliver the word intact.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/../drive-pty-repl.py"
CONSOLE="$HERE/slow-echo-console.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/echo-slow.XXXXXX")"
WORD='load-base'            # the real word that got mangled; inert as data
BUSY=3                      # the console's first-byte echo latency
skip() { printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
# shellcheck disable=SC2154
trap 'rc=$?; rm -rf -- "$TMP"; [[ $rc == 0 || $rc == 77 || $rc == 1 ]] || \
      printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT
command -v python3 >/dev/null 2>&1 || skip "python3 not available"
[[ -f "$DRIVER"  ]] || fail "missing driver: $DRIVER"
[[ -f "$CONSOLE" ]] || fail "missing fixture: $CONSOLE"
# drive <log> <extra driver args...> -> the console's reported line ("GOT:...")
drive() {
    local log="$1"; shift
    SLOW_ECHO_BUSY="$BUSY" python3 "$DRIVER" "$log" --timeout 40 --echo-gate "$@" \
        --expect 'READY' --send "$WORD" --send '\r' --expect 'GOT:' \
        -- python3 "$CONSOLE" >/dev/null 2>&1
    sed -n 's/.*GOT:\([^\r]*\).*/\1/p' "$log" | tail -1
}
# (1) default grace (2 s) < BUSY (3 s): the first byte's echo is late, the gate
#     resends, the console accepts both -> the accepted line is CORRUPTED.
GOT_DEFAULT="$(drive "$TMP/default.log")"
[[ "$GOT_DEFAULT" != "$WORD" ]] \
    || fail "the fixture did not reproduce the bug: at the 2 s default grace the console still received '$WORD' intact — a slow echo (BUSY=${BUSY}s) should have made the gate resend and duplicate a byte, so this control proves nothing"
note "default 2 s grace vs ${BUSY}s echo -> console received '${GOT_DEFAULT:-<no line>}' (corrupted, as expected)"
# (2) a grace LONGER than BUSY: the gate waits for the real echo, never resends,
#     the word arrives intact.
GOT_FIXED="$(drive "$TMP/fixed.log" --echo-timeout 8)"
[[ "$GOT_FIXED" == "$WORD" ]] \
    || fail "with --echo-timeout 8 (> BUSY ${BUSY}s) the console received '${GOT_FIXED:-<no line>}', not '$WORD' — the larger acknowledgment grace did not stop the duplicate"
note "--echo-timeout 8 vs ${BUSY}s echo -> console received '$GOT_FIXED' (intact)"
pass "the echo-gate duplicates a SLOW-echoed byte at the 2 s default ('${GOT_DEFAULT}') and delivers it intact once the grace exceeds the echo latency ('$GOT_FIXED') — the fix ppc drives apply as --echo-timeout 8"
