#!/usr/bin/env bash
# REGRESSION (REVIEW-phase7.md P7-4, P7-5, and the `--force` item in §3).
#
# P7-4 — `start` printed PASS on the strength of a fork returning:
#
#     setsid firecracker --no-api --config-file … &
#     printf '%s\n' "$!" > pidfile
#     printf 'PASS: started %s (pid %s)…'
#
#   Measured against a VMM that refuses the config and exits 1: `PASS: started k1 (pid …)`,
#   rc 0, and fc.log saying `Error: Invalid JSON`. Then `stop` said `PASS: k1 was not
#   running`. Two PASSes, no VM. `cmd_stop` twenty lines below carries an in-code comment
#   about this exact mistake — *"Sending a signal is not stopping a VM; the first version of
#   this printed PASS on the strength of kill(2) returning 0"* — so the lesson was learned
#   on `stop` and never carried across to its sibling. Fix the liar first: an honest failure
#   is debuggable, a false success hides every bug behind it.
#
# P7-5 — one pidfile, three answers. The identity check (`is the process at that pid
# actually ours?`) lived only in `_kill_recorded`; `start` and `list` used a bare
# `-d /proc/$p`. Measured with an unrelated `sleep 600`'s pid in fc.pid:
#     list -> running    start -> refused "already running"    stop -> "was not running"
#
# §3 — `--force` was parsed, listed in USAGE for `stop` and `destroy`, RECOMMENDED BY
# `stop`'s own failure message, passed by the repo's only consumer (micro-cloud's cleanup),
# and thrown away by `: "$force" "$lab"`.
#
# ── THE STAND-IN IS THE RIGHT SEAM ────────────────────────────────────────────────────
# The question is "what does this tool report when the VMM does X?", and a real Firecracker
# cannot be made to die on demand, ignore SIGTERM on demand, or be replaced by an unrelated
# process on demand. A stand-in that keeps firecracker's argv answers exactly that. It
# proves nothing about booting — `examples/micro-cloud/tests/test-edge-on-the-fabric.sh`
# does that, with a real VMM.
#
# EVERYTHING IS KILLED BY PID. The stand-in's command line carries this test's scratch
# path, so a `pkill -f` on it would match any other process that mentions the same path.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd sha256sum

tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")   # NOT a second EXIT trap — see lib.sh
export LAB_STATE_DIR="$tmp/state"
K="$tmp/vmlinux"; R="$tmp/rootfs.ext4"
cp -- "$(command -v bash)" "$K" || skip "could not stage an ELF kernel fixture"
command -v mke2fs >/dev/null 2>&1 || skip "mke2fs not installed (e2fsprogs)"
command -v debugfs >/dev/null 2>&1 || skip "debugfs not installed (e2fsprogs)"
mkdir -p "$tmp/rfs/sbin" && cp -- /bin/true "$tmp/rfs/sbin/init"
truncate -s 16M "$R" && mke2fs -q -F -t ext4 -d "$tmp/rfs" "$R" >/dev/null 2>&1 \
    || skip "mke2fs could not build the rootfs fixture"
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] \
    || skip "/dev/kvm not read-write for uid $EUID — preflight's KVM gate refuses, so \`create\` cannot complete"

# ── the stand-in VMM ──────────────────────────────────────────────────────────────────
# Its behaviour is chosen per-invocation by env, so ONE fixture covers every scenario.
# It does NOT `exec`, so its own argv (which carries `--config-file <this instance>`) stays
# visible in /proc — that argv is what the tool's identity check reads.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/firecracker" <<'SHIM'
#!/usr/bin/env bash
[[ "$1" == "--version" ]] && { printf 'Firecracker %s\n' "${SHIM_VERSION:-v1.16.1}"; exit 0; }
case "${SHIM_MODE:-run}" in
    die)     printf 'Error: Invalid JSON: expected value at line 1 column 1\n' >&2; exit 1 ;;
    deaf)    trap '' TERM; while :; do sleep 0.2; done ;;   # ignores SIGTERM, dies on KILL
    *)       trap 'exit 0' TERM; while :; do sleep 0.2; done ;;
esac
SHIM
chmod +x "$tmp/bin/firecracker"
PATH="$tmp/bin:$PATH"; export PATH
[[ "$(command -v firecracker)" == "$tmp/bin/firecracker" ]] || fail "setup: the stand-in is not first on PATH"

n="p7lc$$"
reap() {   # by PID, resolved from the tool's own record — never a pattern
    local p; p="$(cat "$LAB_STATE_DIR/fc/$n/fc.pid" 2>/dev/null || true)"
    [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null
    return 0
}
on_exit 'reap'

run_fc "$tmp/create.out" create --name "$n" --kernel "$K" --rootfs "$R" \
    || { cat "$tmp/create.out" >&2; fail "setup: create refused a spec built from this test's own fixtures"; }

# ── 1. P7-4: the VMM refuses the config and dies ──────────────────────────────────────
SHIM_MODE=die run_fc "$tmp/die.out" start "$n" && rc=0 || rc=$?
(( rc != 0 )) \
    || fail "REGRESSION: 'start' reported success when firecracker exited immediately — PASS on the strength of a fork returning, not of a VM existing (P7-4)"
grep -q '^FAIL' "$tmp/die.out" \
    || fail "'start' failed but did not say FAIL; a non-zero exit with no verdict is a different bug. Got: $(cat "$tmp/die.out")"
grep -q 'Invalid JSON' "$tmp/die.out" \
    || fail "'start' failed without showing the console log — the operator is told it broke and not why. Got: $(cat "$tmp/die.out")"
[[ -e "$LAB_STATE_DIR/fc/$n/fc.pid" ]] \
    && fail "REGRESSION: 'start' left a pidfile behind for a VM that never ran — the next 'list' would read it"
note "P7-4: a VMM that dies immediately makes 'start' FAIL, print the console log, and leave no pidfile"

# ── 2. and the same call succeeds when the VMM really runs ────────────────────────────
# Without this, section 1 is satisfied by a 'start' that always fails.
run_fc "$tmp/ok.out" start "$n" || { cat "$tmp/ok.out" >&2; fail "control: 'start' failed against a VMM that stays up"; }
grep -q '^PASS: started' "$tmp/ok.out" || fail "control: 'start' succeeded without a PASS line"
grep -q 'confirmed running' "$tmp/ok.out" \
    || fail "'start' claims success without claiming it CHECKED — the message is the only thing distinguishing this from the old behaviour"
p="$(cat "$LAB_STATE_DIR/fc/$n/fc.pid")"
[[ "$p" =~ ^[0-9]+$ && -d "/proc/$p" ]] || fail "control: the recorded pid $p is not a live process"
run_fc "$tmp/l1.out" list; grep -qE "^$n +running" "$tmp/l1.out" \
    || fail "control: 'list' does not report the running instance; got: $(cat "$tmp/l1.out")"
note "control: against a VMM that stays up, 'start' passes and 'list' agrees"

# ── 3. §3: destroy refuses a running instance without --force ─────────────────────────
run_fc "$tmp/dn.out" destroy "$n" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'destroy' reaped a RUNNING instance with no --force and no warning"
grep -qi 'is running' "$tmp/dn.out" || fail "destroy refused but did not say the instance was running; got: $(cat "$tmp/dn.out")"
note "§3: destroy refuses a running instance unless --force is given"

# ── 4. P7-5: one pidfile, one answer ──────────────────────────────────────────────────
# A pid that is alive but is NOT this instance's VMM. The old code asked "is /proc/N a
# directory?", which is true of every process on the box.
run_fc "$tmp/s1.out" stop "$n" || { cat "$tmp/s1.out" >&2; fail "setup: could not stop the instance"; }
sleep 600 & foreign=$!
disown "$foreign" 2>/dev/null || true   # or bash prints its own "Killed" line after the verdict
on_exit 'kill -KILL "$foreign" 2>/dev/null || true'
printf '%s\n' "$foreign" > "$LAB_STATE_DIR/fc/$n/fc.pid"

run_fc "$tmp/l2.out" list
grep -qE "^$n +stopped" "$tmp/l2.out" \
    || fail "REGRESSION: 'list' reports an instance as running because SOMETHING is alive at the recorded pid — it is a \`sleep\`, not this VMM (P7-5). Got: $(cat "$tmp/l2.out")"
run_fc "$tmp/s2.out" stop "$n"
grep -q 'was not running' "$tmp/s2.out" \
    || fail "'stop' disagrees with 'list' about the same pidfile in the same instant (P7-5); got: $(cat "$tmp/s2.out")"
[[ -d "/proc/$foreign" ]] \
    || fail "REGRESSION: a lifecycle verb SIGNALLED an unrelated process because its pid was in our pidfile"
note "P7-5: list and stop agree that a foreign pid is not this instance, and the foreign process is untouched"

# ...and a pid that is a firecracker, but a DIFFERENT instance's. `grep -qa firecracker`
# alone cannot tell those apart; binding to this instance's config path can.
run_fc "$tmp/ok2.out" start "$n" || fail "setup: could not restart the instance"
mine="$(cat "$LAB_STATE_DIR/fc/$n/fc.pid")"
n2="${n}b"
run_fc "$tmp/c2.out" create --name "$n2" --kernel "$K" --rootfs "$R" \
    || { cat "$tmp/c2.out" >&2; fail "setup: could not create a second instance"; }
on_exit 'p="$(cat "$LAB_STATE_DIR/fc/$n2/fc.pid" 2>/dev/null || true)"; [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; true'
printf '%s\n' "$mine" > "$LAB_STATE_DIR/fc/$n2/fc.pid"     # $n's VMM, recorded against $n2
run_fc "$tmp/l3.out" list
grep -qE "^$n2 +stopped" "$tmp/l3.out" \
    || fail "REGRESSION: an instance is reported running on the strength of ANOTHER instance's firecracker — the identity check is not bound to this instance (P7-5). Got: $(cat "$tmp/l3.out")"
run_fc "$tmp/s3.out" stop "$n2"
[[ -d "/proc/$mine" ]] \
    || fail "REGRESSION: 'stop $n2' killed $n's VMM — a recycled pid running SOME firecracker was treated as ours"
grep -qE "^$n +running" <(run_fc "$tmp/l4.out" list; cat "$tmp/l4.out") \
    || fail "'$n' should still be running after stopping '$n2'; got: $(cat "$tmp/l4.out")"
note "P7-5: another instance's firecracker at the recorded pid is not mistaken for this one"

# ── 5. §3: --force actually escalates ─────────────────────────────────────────────────
run_fc "$tmp/dz.out" destroy "$n2" --force || fail "cleanup: destroy of the second instance failed"
run_fc "$tmp/s4.out" stop "$n" --force || { cat "$tmp/s4.out" >&2; fail "cleanup: could not stop $n"; }
run_fc "$tmp/dz2.out" destroy "$n" --force || fail "cleanup: destroy of $n failed"

# A VMM that ignores SIGTERM. Without --force this must FAIL and say to use it; WITH
# --force it must actually stop. The old code's message said "Use --force." about a flag
# it discarded.
n3="${n}c"
run_fc "$tmp/c3.out" create --name "$n3" --kernel "$K" --rootfs "$R" || fail "setup: create $n3 failed"
on_exit 'p="$(cat "$LAB_STATE_DIR/fc/$n3/fc.pid" 2>/dev/null || true)"; [[ "$p" =~ ^[0-9]+$ ]] && kill -KILL "$p" 2>/dev/null; true'
SHIM_MODE=deaf run_fc "$tmp/c3s.out" start "$n3" || { cat "$tmp/c3s.out" >&2; fail "setup: could not start the SIGTERM-deaf VMM"; }
deafpid="$(cat "$LAB_STATE_DIR/fc/$n3/fc.pid")"

run_fc "$tmp/nf.out" stop "$n3" && rc=0 || rc=$?
(( rc != 0 )) || fail "REGRESSION: 'stop' reported success for a VMM that ignored SIGTERM — signalling is not stopping"
grep -q -- '--force' "$tmp/nf.out" || fail "'stop' failed without pointing at --force; got: $(cat "$tmp/nf.out")"
[[ -d "/proc/$deafpid" ]] || fail "the SIGTERM-deaf fixture died on TERM — it is not testing what it claims"
note "a SIGTERM-deaf VMM makes plain 'stop' FAIL and name --force"

run_fc "$tmp/f.out" stop "$n3" --force || { cat "$tmp/f.out" >&2; fail "REGRESSION: 'stop --force' did not stop a SIGTERM-deaf VMM — --force is still the no-op it was (§3)"; }
grep -q 'escalating to SIGKILL' "$tmp/f.out" || fail "'stop --force' succeeded without escalating — did it stop, or did it just stop looking?"
[[ -d "/proc/$deafpid" ]] && fail "REGRESSION: 'stop --force' printed PASS while the VMM is still running"
note "§3: 'stop --force' escalates to SIGKILL and confirms the process is gone"

run_fc "$tmp/dz3.out" destroy "$n3" || fail "cleanup: destroy $n3 failed"
run_fc "$tmp/lend.out" list
grep -q "$n" "$tmp/lend.out" && fail "cleanup: instances survive the run"
note "every instance this test created is gone"

pass "start proves the VM is running, stop proves it is gone, --force does what USAGE says, and every pidfile reader asks about identity (P7-4, P7-5, §3)"
