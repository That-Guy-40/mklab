#!/usr/bin/env bash
# Verdict: a failed setup phase stops the live driver, instead of being logged and passed.
#
# THE INCIDENT. run-e2e.sh's `run()` invoked each phase and never looked at its exit
# status. Phase 3 failed outright —
#
#     qemu-img: /var/lib/libvirt/images/node1.qcow2: Failed to get "write" lock
#     create-fleet: create-node node1 failed
#
# — so no domain was recreated, no console instrumented, no BMC verified, nothing
# enrolled. Phases 4 through 10 ran anyway. Phase 4 then failed too ("cannot 'manage'
# from state 'manageable'"), was also ignored, and the run ended blaming a health gate
# eight phases downstream of the actual defect. Two of the three failed live runs were
# read wrong the first time because of this.
#
# The distinction the script now draws, and what this test pins:
#
#   run()       SETUP. Must succeed; everything after depends on it. Failure aborts,
#               naming the step, and does NOT paraphrase the tool's own error.
#   run_soft()  the things UNDER TEST (deploy, apply, watch). Their failure IS the
#               result — we want the state, the apply report and the verdict, not an
#               abort. Deliberately non-fatal, and that has to stay deliberate.
#
# SAFETY: pure text plus one throwaway bash subprocess whose "failing tool" is
# `false`. Nothing here names a destructive command, and nothing touches the fleet.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
maas_env
E2E="$LAB_DIR/run-e2e.sh"
[[ -f "$E2E" ]] || fail "run-e2e.sh is missing"

# ── 1. run() checks the exit status at all ─────────────────────────────────
sed -n '/^run()  {/,/^}/p' "$E2E" > "$SANDBOX/run.sh"
[[ -s "$SANDBOX/run.sh" ]] || fail "could not extract run() from run-e2e.sh — renamed?"
# Syntactic smoke only — §2/§3 below prove the BEHAVIOUR. Kept because a run() that
# never mentions $? at all is worth naming directly.
grep -qE 'rc=\$\?|if ! "\$@"|"\$@".*\|\| *die|return 1' "$SANDBOX/run.sh" \
    || fail "REGRESSION: run() does not act on the phase's exit status. A setup phase that fails would be logged and stepped over, and the run would report a different failure many phases later — which is exactly how three live runs were misread"
note "run() acts on the exit status of the phase it runs  ✓"

# ── 2. exercise the SHIPPED run(): a failing phase aborts ──────────────────
# Built from the real file, not a paraphrase of it.
harness() {  # harness <fn> <cmd...> ; echoes rc, writes output to $SANDBOX/out
    local fn="$1"; shift
    { printf 'DRY=0\nLOG="%s/harness.log"\n: > "$LOG"\n' "$SANDBOX"
      printf 'die() { printf "FAIL: %%s\\n" "$*" >&2; exit 1; }\n'
      printf 'info() { printf "   %%s\\n" "$*" >&2; }\n'
      sed -n "/^$fn() {*/,/^}/p" "$E2E"
      printf '%s "$@"\n' "$fn"
      printf 'printf "REACHED-THE-NEXT-PHASE\\n" >&2\n'
    } > "$SANDBOX/h.sh"
    ( bash "$SANDBOX/h.sh" "$@" ) >"$SANDBOX/out" 2>&1
    printf '%s' $?
}

rc="$(harness run false)"
[[ "$rc" != 0 ]] \
    || fail "REGRESSION: run() returned success for a phase that failed — every later phase would run on top of a broken one"
grep -q 'REACHED-THE-NEXT-PHASE' "$SANDBOX/out" \
    && fail "REGRESSION: execution continued past a failed setup phase. That is the defect: phase 3 once failed completely and phases 4-10 ran anyway, each reporting its own confusing error"
grep -q 'FAIL:' "$SANDBOX/out" \
    || fail "run() aborted but printed no FAIL verdict — a silent abort is indistinguishable from a broken harness"
note "a failing setup phase aborts the run, with a verdict, before the next phase  ✓"

# ── 3. the positive control: a succeeding phase does NOT abort ─────────────
# Without this, §2 would also pass on a run() that aborts unconditionally.
rc="$(harness run true)"
[[ "$rc" == 0 ]] || fail "run() failed a phase that SUCCEEDED (rc=$rc) — the whole script would be unusable"
grep -q 'REACHED-THE-NEXT-PHASE' "$SANDBOX/out" \
    || fail "run() did not continue past a phase that succeeded"
note "a succeeding phase continues normally  ✓"

# ── 4. run_soft is deliberately NOT fatal, and says so ─────────────────────
# The deploy failing is a result to report, not an obstacle. If someone "fixes" this by
# making everything fatal, a failed deploy would abort before `apply` gets to say HELD
# and before the verdict is computed — losing the most informative output there is.
rc="$(harness run_soft false)"
[[ "$rc" == 0 ]] \
    || fail "REGRESSION: run_soft aborted on failure. The deploy and apply phases ARE the experiment; aborting on them throws away the state, the apply report and the verdict"
grep -q 'REACHED-THE-NEXT-PHASE' "$SANDBOX/out" \
    || fail "REGRESSION: run_soft did not continue past a failed step"
grep -qi 'failed' "$SANDBOX/out" \
    || fail "run_soft swallowed the failure silently — non-fatal must still be VISIBLE, or a failed deploy reads as a successful one"
note "run_soft continues past a failure, but says out loud that it happened  ✓"

# ── 5. the setup phases actually use run(), not run_soft ───────────────────
# The distinction is only worth anything if the load-bearing phases are on the fatal
# side of it. create-fleet.sh's `up` is the one that failed and was stepped over.
grep -qE '^run "\$HERE/create-fleet\.sh" up' "$E2E" \
    || fail "REGRESSION: 'create-fleet.sh up' is no longer a fatal phase — it is THE step whose silent failure caused this test to exist"
grep -qE '^run "\$HERE/netboot-chain\.sh" install' "$E2E" \
    || fail "REGRESSION: 'netboot-chain.sh install' is no longer a fatal phase — without it every node boots the wrong payload"
note "the load-bearing setup phases are on the fatal side of the line  ✓"

# ── 6. --dry-run must not write to the real log ────────────────────────────
# It used to `tee -a` while skipping the truncation, so a dry run appended a ghost run
# to the last real one. A log with two interleaved runs is worse than no log.
before="$(wc -c < "$LAB_DIR/e2e-run.log" 2>/dev/null || echo 0)"
( cd "$LAB_DIR" && ./run-e2e.sh --dry-run ) >/dev/null 2>&1
after="$(wc -c < "$LAB_DIR/e2e-run.log" 2>/dev/null || echo 0)"
[[ "$before" == "$after" ]] \
    || fail "REGRESSION: --dry-run wrote to the real run log ($before -> $after bytes). It appends a ghost run to the last real one, and the next person reading a failure reads two runs interleaved"
note "--dry-run leaves the real run log byte-for-byte alone  ✓"

# ── 7. a run that never STARTS must not destroy the last run's log ─────────
# The log used to be truncated before preflight, so a run refused at the sudo gate — or
# at any preflight check — wiped the record of the last run that actually finished. (Done
# to a passing run's log while testing a preflight check, which is how it was found.)
# Same class as §6: the record of a completed run wrecked by a run that never started.
LOGF="$SANDBOX/keepme.log"
printf 'A COMPLETED RUN LIVED HERE\n' > "$LOGF"
sum_before="$(cksum < "$LOGF")"
# THIS LINE RUNS THE REAL run-e2e.sh, and that used to be safe only because the preflight
# happens to refuse before phase 1 — a test whose hermeticity depended on the order of
# checks *inside the script under test*. Measured harmless, but "harmless today" is a
# cached fact: move one check above the images-dir gate and this test would `sudo` its
# way through phase 1 and rebuild the operator's fleet.
#
# Made structural 2026-08-06. Every tool that can touch the host is replaced on PATH by
# a shim that records the attempt and refuses, so the run CANNOT reach the fleet however
# the checks are ordered. The shim log then becomes the assertion: preflight only ever
# invokes `sudo -n true` (its last gate), so anything else in that log means a check
# moved — reported here, by name, instead of discovered on a wrecked fleet.
#
# `command -v virsh` in preflight is satisfied by the shim, so the run still reaches the
# refusal this section is about rather than dying earlier for a different reason.
#
# AND THE ORIGINAL BELIEF WAS WRONG, which is why this mattered. The note said the run
# was stopped by `MAAS_IMAGES_DIR=$SANDBOX/nope`. It is not: preflight's payload gate
# resolves catalog paths against $REPO_ROOT, never against MAAS_IMAGES_DIR, so a bogus
# images dir does not trip it at all. The run reached preflight's LAST item — `sudo -n
# true` — and was stopped only by sudo being unprimed. run-e2e.sh's own refusal tells
# the operator to fix exactly that ("Run 'sudo -v' first"), so anyone who followed that
# advice and then ran the suite would have had this test rebuild their fleet. Measured
# 2026-08-06 by watching which gate actually fired.
SHIM="$SANDBOX/shim"; mkdir -p "$SHIM"
: > "$SANDBOX/shim.log"
for _c in virsh vbmc ipmitool qemu-img virt-install sudo; do
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s %%s\\n" "%s" "$*" >> "%s/shim.log"\n' "$_c" "$SANDBOX"
      printf 'exit 1\n'
    } > "$SHIM/$_c"
    chmod +x "$SHIM/$_c"
done
e2e_out="$( cd "$LAB_DIR" \
    && PATH="$SHIM:$PATH" E2E_LOG="$LOGF" MAAS_IMAGES_DIR="$SANDBOX/nope" MAAS_STATE="$SANDBOX/state" \
       ./run-e2e.sh 2>&1 )" && e2e_rc=0 || e2e_rc=$?

(( e2e_rc != 0 )) \
    || fail "REGRESSION: the real run-e2e.sh SUCCEEDED with a nonexistent images dir — it no longer refuses in preflight, and this section's whole premise (that it stops before touching anything) is gone"
# Only preflight's own sudo gate may appear. Anything else means a check moved and the
# run got as far as trying to change the host; the shims made that attempt inert.
_stray="$(grep -vE '^sudo -n true ?$' "$SANDBOX/shim.log" 2>/dev/null || true)"
[[ -z "$_stray" ]] \
    || fail "REGRESSION: run-e2e.sh tried to touch the host before refusing — a preflight check moved, and only the PATH shims stopped this test from rebuilding the operator's fleet. Attempted: ${_stray//$'\n'/ | }"
grep -q '== preflight ==' <<<"$e2e_out" \
    || fail "the run did not even reach preflight, so its refusal proves nothing about the preflight ordering this section pins. Output: ${e2e_out//$'\n'/ | }"
grep -q '== \[1/10\]' <<<"$e2e_out" \
    && fail "REGRESSION: the run entered phase 1 before refusing. Phase 1 is 'PXE network + HTTP docroot (sudo)' — on a host without these shims it would have reconfigured libvirt networking"
note "the real run-e2e.sh refuses inside preflight, and cannot reach the host: only 'sudo -n true' was attempted  ✓"
[[ "$(cksum < "$LOGF")" == "$sum_before" ]] \
    || fail "REGRESSION: a run that refused during preflight replaced the previous run's log. The last thing that actually finished is the thing you most want to read after a failed start — and the failed start had nothing of its own to say"
note "a run refused in preflight leaves the previous log byte-for-byte alone  ✓"

# The control: commit_log must actually replace it, or "never truncates" would pass §7
# while leaving every run appended to the last one — the ghost-log bug by another route.
cat > "$SANDBOX/commit.sh" <<EOS
DRY=0
REAL_LOG="$LOGF"
SCRATCH_LOG="$SANDBOX/scratch.log"
printf 'THIS RUN\n' > "\$SCRATCH_LOG"
EOS
sed -n '/^commit_log() {/,/^}/p' "$E2E" >> "$SANDBOX/commit.sh"
printf 'commit_log
' >> "$SANDBOX/commit.sh"
[[ "$(grep -c . "$SANDBOX/commit.sh")" -gt 4 ]] || fail "could not extract commit_log() from run-e2e.sh — renamed?"
bash "$SANDBOX/commit.sh" >/dev/null 2>&1
grep -q 'THIS RUN' "$LOGF" \
    || fail "commit_log did not replace the log with this run's output — a run that starts must own the log, or every run appends to the last one"
grep -q 'A COMPLETED RUN LIVED HERE' "$LOGF" \
    && fail "commit_log left the PREVIOUS run's content in place. Two runs interleaved in one file is the exact confusion §6 exists to prevent"
note "control: once the run commits, the log is replaced with this run's own output  ✓"

pass "a failed SETUP phase aborts the live driver with a verdict; the phases under test stay deliberately non-fatal but visible; and --dry-run never touches the run log"
