#!/usr/bin/env bash
# Shared helpers for metal-as-a-service tests (repo convention; mirrors bmc-toolkit).
# autotools exit codes: 0 = pass, 77 = skip, anything else = fail.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd -- "$TEST_DIR/.." && pwd)"
MAAS="$LAB_DIR/maas-lab.sh"
MOCK_BMC="$TEST_DIR/mock-bmc.sh"
readonly TEST_DIR LAB_DIR MAAS MOCK_BMC

# _VERDICT guards the EXIT net below: a test that already printed FAIL must not also be
# told "no verdict was printed", or the net becomes noise a reader learns to skip past.
_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }
need() { local c; for c in "$@"; do have "$c" || skip "missing required command: $c"; done; }

# ── the ONE EXIT trap, and the only place cleanup belongs ───────────────────────────
#
# Belt-and-suspenders (CLAUDE.md): if a test dies early — a `die` inside maas-lab.sh
# slipping past the assertions — this prints a FAIL verdict, so output is never
# silently blank with a bare rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT
# trap per shell, so a test writing `trap 'cleanup_sandboxes' EXIT` silently REPLACES
# this net and the verdict line disappears. That is not hypothetical: on 2026-08-06,
# 23 of this lab's 36 tests did exactly that and had no net at all, while 11 more
# re-inlined it and printed the FAIL line twice on a genuine failure. Register
# cleanup instead:
#
#     on_exit 'rm -rf "$SANDBOX"'      # evaluated at exit, so it may name a later var
#
# `tests/test-harness-net.sh` fails if any test installs its own EXIT trap, and proves
# the net fires when a test dies and stays quiet when it does not.
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }

_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
    cleanup_sandboxes
    if [[ -n "${_SIGNALLED:-}" ]]; then
        printf 'FAIL: test was TERMINATED FROM OUTSIDE by SIG%s — the run was cut short, so nothing above is a result about the code under test\n' "$_SIGNALLED" >&2
    elif (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# ── being KILLED is not the same as FAILING, and the net could not tell you which ────────
# Bash does not run an EXIT trap for an untrapped fatal signal. So a run stopped from
# outside — a CI job timeout, a harness deadline, Ctrl-C, an OOM reaper, a closed terminal —
# produced a log that simply STOPS: no verdict, no reason, and a reader left hunting inside
# a test that never got the chance to fail. Measured 2026-08-19: a SIGTERM to the process
# group mid-suite printed bash's bare `Terminated` and nothing else, and the truncated log
# was read for a day as an intermittent defect in the test it happened to interrupt.
#
# Trapping the three signals converts that silence into a sentence. The handler records
# WHICH signal and re-exits with the conventional 128+N, so the EXIT trap runs normally.
#
# WHAT THIS DOES *NOT* FIX, because the first draft of this comment claimed it did and the
# control in tools/check-harness-net.sh §7 caught the claim: teardown was never lost. A
# killed run already executed its registered cleanup — measured against the pre-change lib,
# which printed its cleanup and no verdict. The whole of what changes here is that the run
# now SAYS it was killed. That is worth having on its own, and it is all that is claimed.
#
# `_VERDICT` is left alone on purpose: this is a verdict, but a verdict about the RUN rather
# than about the code, and _on_exit prints it as such.
_SIGNALLED=""
_on_signal() { _SIGNALLED="$1"; exit $(( 128 + $2 )); }
trap '_on_signal TERM 15' TERM
trap '_on_signal INT 2'   INT
trap '_on_signal HUP 1'   HUP

# Every test runs against a throwaway state dir and the mock BMC, so the whole
# state machine drives with zero libvirt / vbmcd / root. Call once per test.
maas_env() {
    SANDBOX="$(mktemp -d)"
    export MAAS_STATE="$SANDBOX/maas"
    export MAAS_BMC="$MOCK_BMC"
    export MOCK_BMC_LOG="$SANDBOX/bmc-calls.log"
    : > "$MOCK_BMC_LOG"
    # cleaned by the caller's trap; record it for teardown
    _SANDBOXES+=("$SANDBOX")
}
_SANDBOXES=()
cleanup_sandboxes() { local s; for s in "${_SANDBOXES[@]:-}"; do [[ -n "$s" ]] && rm -rf "$s"; done; }

# Run maas-lab.sh; capture rc without tripping the EXIT trap (subshell contains any die).
m() { ( "$MAAS" "$@" ); }

# Deploy-driver test rig (increment 3): point --driver at tests/mock.sh, set up a
# signed-image store with a real snakeoil trust root, and use a short health timeout.
maas_env_drivers() {
    export MAAS_DRIVER_DIR="$TEST_DIR"           # so `--driver mock` -> tests/mock.sh
    export MAAS_IMAGES_DIR="$SANDBOX/images"
    export MAAS_HEALTH_TIMEOUT=3
    mkdir -p "$MAAS_IMAGES_DIR/trust"
    "$LAB_DIR/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
        || skip "verify-lib gen-keys failed (openssl missing?)"
}
# make_image <name> [tamper] — a signed payload for <name>; `tamper` flips a byte
# AFTER signing so verification must fail.
make_image() {
    local img="$1" dir; dir="$MAAS_IMAGES_DIR/$img"; mkdir -p "$dir"
    printf 'PAYLOAD-%s-%s\n' "$img" "${2:-clean}" > "$dir/payload.img"
    "$LAB_DIR/drivers/verify-lib.sh" sign "$dir/payload.img" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null 2>&1 \
        || fail "signing image '$img' failed"
    [[ "${2:-}" == tamper ]] && printf 'X' | dd of="$dir/payload.img" bs=1 seek=1 conv=notrunc >/dev/null 2>&1
    return 0
}

# Read a node's registry field (image, driver, previous_image, …) from the sandbox.
_show() { cat "$MAAS_STATE/$1/$2" 2>/dev/null; }

# Assert a node is in an expected state.
assert_state() {  # assert_state <node> <expected>
    local got; got="$("$MAAS" state "$1" 2>/dev/null)"
    [[ "$got" == "$2" ]] || fail "REGRESSION: node '$1' state expected '$2' but got '${got:-<none>}'"
}
