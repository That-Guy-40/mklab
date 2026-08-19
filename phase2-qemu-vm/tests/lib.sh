#!/usr/bin/env bash
# Shared helpers for phase2-qemu-vm tests.

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LAB_VM="${TEST_DIR}/../lab-vm.sh"

# _VERDICT guards the EXIT net below: a test that already printed FAIL must not also
# be told "no verdict was printed", or the net becomes noise a reader skips past.
_VERDICT=0
skip()  { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail()  { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass()  { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note()  { printf '  - %s\n' "$*" >&2; }

# ── the ONE EXIT trap, and the only place cleanup belongs ────────────────────────────
#
# Belt-and-suspenders (CLAUDE.md): if a test dies early — `set -e` tripping, or a `die`
# inside lab-vm.sh slipping past the assertions — this prints a FAIL verdict, so the
# terminal is never left blank with a bare non-zero rc.
#
# CLEANUP GOES THROUGH THIS TRAP, NEVER A SECOND `trap … EXIT`. Bash keeps ONE EXIT trap
# per shell, so a test writing its own silently REPLACES this net — measured across the
# repo on 2026-08-06, when 13 of 17 of these tests had no net at all. Register instead:
#
#     on_exit 'rm -rf "$tmp"'     # evaluated at exit, so it may name a later variable
#
# `tests/test-harness-net.sh` proves the net fires and refuses a test that installs an
# EXIT trap of its own.
_CLEANUPS=()
on_exit() { _CLEANUPS+=("$*"); }
_on_exit() {
    local rc=$? i
    # Registered cleanup can READ the exit status as $_EXIT_RC. Without it a teardown
    # that needs to know whether the run failed — keep the evidence, skip the tidy-up —
    # has to write its own `trap … EXIT`, which is the defect this block exists to stop.
    _EXIT_RC=$rc
    for (( i=${#_CLEANUPS[@]}-1; i>=0; i-- )); do eval "${_CLEANUPS[i]}" || true; done
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


require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || skip "missing required command: $c"
    done
}

cleanup_vm() {
    local name="$1"
    "$LAB_VM" destroy "$name" --force >/dev/null 2>&1 || true
}

wait_for_ssh() {
    # wait_for_ssh PORT TIMEOUT_SEC
    local port="$1" timeout="$2" elapsed=0
    while (( elapsed < timeout )); do
        if ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=2 -o BatchMode=yes -o PasswordAuthentication=no \
              lab@127.0.0.1 true 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

# fake_qemu_for <vmdir> — stand up a live process the driver will accept as THIS VM's
# QEMU, write its pid into <vmdir>/qemu.pid, and register its reaping.  Sets $FAKE_QEMU_PID.
#
# WHY THIS EXISTS. Tests used to fabricate "running" by writing the TEST'S OWN PID (`$$`)
# into qemu.pid, because `vm_running` only asked `[[ -d /proc/$pid ]]`. That shortcut was
# the P2-2 defect restated as a fixture: it asserted the MECHANISM ("some live pid is
# recorded") rather than the outcome ("this VM's QEMU is running"), so it kept passing for
# a shell that was never a plausible QEMU — and it stopped passing the moment the driver
# started checking identity, which is the direction CLAUDE.md warns costs a day.
#
# The driver now derives identity from /proc/PID/cmdline, so a faithful fixture is one
# whose argv looks like this VM's QEMU: `exec -a` sets argv[0] to a string carrying
# `qemu-system` and the VM's own pidfile path, which is exactly what `_pid_owns` reads.
#
# HONEST LABEL: this is a stand-in for QEMU's argv, not QEMU. It is what lets these tests
# run with no qemu, no KVM and no network. The real-QEMU evidence — that a genuinely
# daemonized qemu-system-x86_64 is accepted, listed and stopped — lives in
# tests/test-pidfile-identity.sh §2, which uses the real binary whenever it is installed.
fake_qemu_for() {
    local d="${1%/}" pf i
    pf="$d/qemu.pid"
    bash -c 'exec -a "qemu-system-x86_64 -pidfile '"$pf"'" sleep 900' >/dev/null 2>&1 &
    FAKE_QEMU_PID=$!
    # Registered immediately, and by PID: if an assertion below fails, the stand-in must
    # still be reaped (CLAUDE.md: kill by PID, never by pattern — a pattern carrying this
    # path would also match a real QEMU serving a real VM).
    on_exit "kill $FAKE_QEMU_PID 2>/dev/null"
    for i in $(seq 1 15); do
        [[ "$(tr '\0' ' ' < "/proc/$FAKE_QEMU_PID/cmdline" 2>/dev/null)" == qemu-system* ]] && break
        sleep 0.2
    done
    printf '%s\n' "$FAKE_QEMU_PID" > "$pf"
}
