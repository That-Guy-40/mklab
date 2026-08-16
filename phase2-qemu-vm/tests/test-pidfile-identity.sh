#!/usr/bin/env bash
# Regression (REVIEW-phase2.md, P2-2): a recorded PID is not an identity, and `stop`/
# `destroy` must not signal a process merely because it inherited the number.
#
# THE BUG. `_running_at` asked only "is /proc/$pid a directory". `qemu.pid` outlives the
# QEMU it names whenever that QEMU did not exit cleanly — SIGKILLed (which `cmd_stop`
# itself sends after its 30s timeout), OOM-killed, or lost to a host crash, since
# `-pidfile -daemonize` removes the file only on a clean exit. Once the kernel recycles
# that number, `vm_running` returns a FALSE POSITIVE and `stop`/`destroy` send SIGTERM →
# SIGKILL to whatever now holds it. For a from-chroot/tap VM those verbs run under sudo,
# so the unrelated victim is killed AS ROOT.
#
# Measured 2026-08-15, before the fix:
#     $ sleep 600 &                          # pid 866882, argv literally "sleep 600"
#     $ echo 866882 > .../vms/ghost/qemu.pid
#     $ lab-vm.sh stop ghost --force
#     [info] killing ghost (pid 866882)
#     [info] ghost stopped                   # …and the sleep was gone
#
# This is CLAUDE.md's bug class #1 — a record that outlives the thing it describes — so the
# fix is that file's rule: DERIVE identity from the live process rather than trusting the
# cached number. `_pid_owns` reads /proc/PID/cmdline and requires both `qemu-system` and
# this VM's own pidfile path, which `build_qemu_argv` always puts on the command line.
#
# THE VICTIM IN THIS TEST IS A `sleep` THIS TEST STARTED, and every kill below is by a PID
# captured from `$!` — never by pattern (CLAUDE.md: a pattern matches the workload you are
# trying to protect).
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

work="$(mktemp -d)"
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"
VICTIMS=()
_reap() {
    local p
    for p in "${VICTIMS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    rm -rf -- "$work"
}
on_exit '_reap'

mkvm() {  # mkvm <name> — a VM dir the driver will recognise
    local n="$1" d="$work/state/vms/$1"
    mkdir -p "$d"
    printf 'name = "%s"\narch = "x86_64"\n' "$n" > "$d/manifest.toml"
    printf '%s' "$d"
}
# innocent <pidfile> — start a live NON-qemu process, record it for teardown, and write
# its pid into <pidfile>.  Sets $INNOCENT_PID; deliberately NOT called via `$( )`.
#
# TWO REASONS IT RETURNS THROUGH A GLOBAL, both measured while writing this test:
#   • a command substitution waits for every process holding the pipe's write end, so a
#     BACKGROUNDED child started inside one hangs until it exits — `v="$(innocent …)"`
#     blocked for the full 600s of the sleep it had just started;
#   • `$( )` is a SUBSHELL, so `VICTIMS+=` there updates a copy the EXIT-trap teardown
#     never sees, and the sleeps leak. (Same shape as micro-cloud's 2026-08 defect, where
#     cleanup bookkeeping done in a subshell left three live guests behind.)
innocent() {
    local pf="$1"
    sleep 600 >/dev/null 2>&1 & INNOCENT_PID=$!
    VICTIMS+=("$INNOCENT_PID")
    # let it exec, so /proc shows `sleep 600` rather than the still-forking shell
    local i; for i in $(seq 1 10); do
        [[ "$(tr '\0' ' ' < "/proc/$INNOCENT_PID/cmdline" 2>/dev/null)" == sleep* ]] && break
        sleep 0.2
    done
    printf '%s' "$INNOCENT_PID" > "$pf"
}

# ── 1. POSITIVE: an impostor pidfile must not get anything killed ────────────────────────
d="$(mkvm ghost)"
innocent "$d/qemu.pid"; v="$INNOCENT_PID"
[[ "$(tr '\0' ' ' < "/proc/$v/cmdline")" == sleep* ]] \
    || fail "setup: the innocent process is not the plain \`sleep\` this test expects, so the impostor case is not being exercised"
kill -0 "$v" 2>/dev/null || fail "setup: the innocent process was not alive before the test began"

out="$(bash "$LAB_VM" stop ghost --force 2>&1)" || true
sleep 0.5
kill -0 "$v" 2>/dev/null \
    || fail "REGRESSION: 'stop ghost --force' KILLED an unrelated process (pid $v, argv 'sleep 600') because its number happened to be in ghost's qemu.pid. For a from-chroot/tap VM this runs under sudo and reaps the victim as root (REVIEW-phase2.md P2-2). Output: $(tr '\n' ' ' <<<"$out")"
grep -q 'not running' <<<"$out" \
    || fail "'stop' did not report ghost as not-running for a stale pidfile; it said: $(tr '\n' ' ' <<<"$out")"
note "an impostor pidfile makes 'stop' report not-running, and the unrelated process survives  ✓"

# ── 2. CONTROL: a genuine QEMU is still seen, listed and stoppable ───────────────────────
# Without this the fix could be "never report anything as running", which passes §1 while
# making `stop` useless. `list` is used on purpose: it reaches _running_at through the
# `"$store"/*/` glob, whose TRAILING SLASH would otherwise be spliced into the marker path
# and make every genuinely-running VM read "stopped". Measured: removing that guard turns
# this row from `running` into `stopped`.
d2="$(mkvm realvm)"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    qemu-system-x86_64 -display none -daemonize -pidfile "$d2/qemu.pid" -S -m 64 2>/dev/null \
        || skip "qemu-system-x86_64 is present but would not start here"
    sleep 0.5
    real="$(cat "$d2/qemu.pid" 2>/dev/null || true)"
    [[ "$real" =~ ^[0-9]+$ ]] || fail "setup: qemu did not write a numeric pidfile"
    VICTIMS+=("$real")
    kind="a real daemonized qemu-system-x86_64"
else
    # No qemu here. The property under test is whether the identity predicate accepts THIS
    # VM's QEMU, and what it reads is the argv — so a process carrying the same argv shape
    # exercises the predicate faithfully. Named as a stand-in rather than claimed as QEMU:
    # §3 separately pins the launcher to that argv, so the pair still covers the real path.
    bash -c 'exec -a "qemu-system-x86_64 -pidfile '"$d2"'/qemu.pid" sleep 600' >/dev/null 2>&1 & real=$!
    VICTIMS+=("$real")
    sleep 0.4
    printf '%s' "$real" > "$d2/qemu.pid"
    kind="a STAND-IN carrying qemu's argv shape (qemu-system-x86_64 not installed)"
fi

listing="$(bash "$LAB_VM" list 2>/dev/null || true)"
grep -qE '^realvm .*running' <<<"$listing" \
    || fail "CONTROL FAILED: a genuinely running VM ($kind, pid $real) is reported as stopped by 'list'. Either the identity check refuses its own QEMU — making 'stop' unable to stop anything — or the trailing slash from list's \"\$store\"/*/ glob got spliced into the marker path. Listing: $(tr '\n' ' ' <<<"$listing")"
note "control: $kind is reported running by 'list' (so the glob's trailing slash is handled)  ✓"

out2="$(bash "$LAB_VM" stop realvm --force 2>&1)" || true
sleep 0.6
kill -0 "$real" 2>/dev/null \
    && fail "CONTROL FAILED: 'stop realvm --force' did NOT stop the running VM (pid $real) — the identity check is refusing this VM's own process. Output: $(tr '\n' ' ' <<<"$out2")"
note "control: the same VM is actually stopped by 'stop --force', so the guard refuses only impostors  ✓"

# ── 3. CONTROL: the launcher still puts the marker on the command line ───────────────────
# The predicate matches this VM's pidfile path in the argv. If build_qemu_argv ever stopped
# passing `-pidfile <vmdir>/qemu.pid`, every VM would read "stopped" — a silent, total
# breakage of stop/destroy/list. Pinned here because §2's runtime evidence may come from a
# stand-in on a host without qemu.
grep -q -- '-pidfile "\$(vm_pidfile "\$name")"' "$LAB_VM" \
    || fail "build_qemu_argv no longer passes -pidfile \"\$(vm_pidfile \"\$name\")\", so the per-VM path the identity check matches on is no longer guaranteed to be in QEMU's argv — every VM would read as stopped"
note "control: build_qemu_argv still passes -pidfile with the per-VM path the check matches  ✓"

# ── 4. the swtpm reaper has the same gap, and the same fix ───────────────────────────────
d3="$(mkvm tpmvm)"
innocent "$d3/swtpm.pid"; v3="$INNOCENT_PID"
bash -c "source '$LAB_VM'; stop_swtpm tpmvm" >/dev/null 2>&1 || true
sleep 0.4
kill -0 "$v3" 2>/dev/null \
    || fail "REGRESSION: stop_swtpm SIGTERMed an unrelated process (pid $v3) whose number was in swtpm.pid — 'kill -0' proves a PID is alive, not whose it is"
note "an impostor swtpm.pid is not signalled either  ✓"

# ── 5. NEGATIVE CONTROL: re-inject the pre-fix check and watch it kill ───────────────────
# A copy of the driver with _running_at's identity line removed. If this does NOT kill the
# innocent process, then §1 is not measuring the defect and would have passed against the
# original bug.
pre="$work/lab-vm-prefix.sh"
sed 's|^    _pid_owns "\$pid" "qemu-system" "\$pf"$|    return 0|' "$LAB_VM" > "$pre"
grep -q '^    return 0$' "$pre" \
    || fail "the negative control could not re-inject the pre-fix check, so it proves nothing (the _running_at line must have changed shape)"
bash -n "$pre" || fail "the re-injected pre-fix driver does not parse"

d4="$(mkvm ghost2)"
innocent "$d4/qemu.pid"; v4="$INNOCENT_PID"
bash "$pre" stop ghost2 --force >/dev/null 2>&1 || true
sleep 0.6
kill -0 "$v4" 2>/dev/null \
    && fail "the pre-fix driver did NOT kill the impostor's process, so §1 above is not measuring the defect — this test would pass against the original bug"
note "negative control: the pre-fix check kills the unrelated process, so §1 is measuring the real defect  ✓"

pass "a recorded PID is checked for identity before it is trusted or signalled: an impostor qemu.pid/swtpm.pid gets nothing killed and reports not-running, while a genuine QEMU is still listed running and stopped normally (with the pre-fix check re-injected, the same call reaps an unrelated process)"
