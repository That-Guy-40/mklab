#!/usr/bin/env bash
# Verdict: run-e2e.sh reaps the one process it starts — by PID, and only that one.
#
# THE INCIDENT. The facts sink is backgrounded by run-e2e.sh and holds :8282 for the
# whole run. Three runs in a row ended on a timeout and left it behind; the next run's
# sink then failed to bind. The first time, that failure was SILENT — the script had
# backgrounded the server, so its exit status was invisible — and the blame landed on
# the probe two phases later. The second time the guard caught it, but the operator
# still had to go find and kill a process by hand.
#
# The script states elsewhere that it "does not kill processes it did not start", which
# is right and does not apply here: this one it DID start and it has the pid.
#
# What is under test is the SHIPPED text of the reap function, extracted from
# run-e2e.sh and sourced — not a copy of it. Two things must hold:
#
#   it kills what it started        a recorded PID goes away
#   and NOTHING else                an unrecorded process on the same command line
#                                   survives. This is the pkill footgun the repo has
#                                   already been bitten by: a pattern that matches the
#                                   sink's path also matches other tooling, and killing
#                                   by name once took out a QEMU VM and the agent's own
#                                   shell (CLAUDE.md).
#
# SAFETY: the victim processes are `sleep`. Nothing destructive is named anywhere here.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
maas_env
E2E="$LAB_DIR/run-e2e.sh"
[[ -f "$E2E" ]] || fail "run-e2e.sh is missing"

# ── 1. the trap is actually installed, and kills by PID ────────────────────
grep -q '^trap reap EXIT' "$E2E" \
    || fail "REGRESSION: run-e2e.sh no longer installs the EXIT trap — every run that ends on a timeout would again leave its facts sink holding :8282, and the next run would fail to bind"
grep -qE 'pkill|killall' "$E2E" \
    && fail "REGRESSION: run-e2e.sh kills by PATTERN. A pattern matching the sink's path also matches other tooling on this host; the repo has already lost a QEMU VM (and a shell) to exactly that. Kill by PID"
note "the EXIT trap is installed, and nothing kills by pattern  ✓"

# ── 2. extract the SHIPPED reap function and exercise it ───────────────────
# sed out of the real file: a test that re-implements the logic proves nothing about
# what ships.
FN="$SANDBOX/reap.sh"
sed -n '/^reap() {/,/^}/p' "$E2E" > "$FN"
[[ -s "$FN" ]] || fail "could not extract reap() from run-e2e.sh — has it been renamed?"
MD_PID=""
# A `# shellcheck disable` attaches to the next COMMAND, not the next LINE. This directive
# sat above `MD_PID=""; source "$FN" || fail …`, so it covered the assignment and never
# reached the `source` — measured 2026-08-21: stripping the directive entirely changed
# the output not at all, which is the definition of an inert suppression. (Rewording this
# very comment cost a round too: a line STARTING `# shellcheck` is parsed as a directive
# wherever it appears, so the prose broke the file it was explaining.) It is a
# smaller cousin of the defect in tools/check-harness-net.sh §1 (twice) and of
# CLAUDE.md's own rule: a thing aimed at a line is not a thing aimed at a command.
# shellcheck disable=SC1090   # $FN is sed'd out of run-e2e.sh at runtime; nothing to follow
source "$FN" || fail "the extracted reap() does not parse"

sleep 30 & VICTIM=$!            # the "sink": recorded, must die
sleep 30 & BYSTANDER=$!         # same command line, NOT recorded: must survive
MD_PID="$VICTIM"
( reap ) >/dev/null 2>&1
sleep 0.4

kill -0 "$VICTIM" 2>/dev/null \
    && { kill "$VICTIM" "$BYSTANDER" 2>/dev/null
         fail "REGRESSION: reap() did not kill the recorded PID — the sink would survive the run and hold :8282 against the next one"; }
note "the recorded PID is reaped  ✓"

kill -0 "$BYSTANDER" 2>/dev/null \
    || fail "REGRESSION: reap() killed a process it did not start, one that merely shares a command line with the sink. That is the pattern-matching failure mode by another route, and it is how a lab loses a VM"
note "an identical process that was NOT recorded survives — it reaps by PID, not by name  ✓"
kill "$BYSTANDER" 2>/dev/null

# ── 3. an empty MD_PID reaps nothing (the die-before-start path) ───────────
# The sink-failed-to-bind branch sets MD_PID="" precisely so the trap does not fire on
# a dead or never-owned pid. If reap() ignored that, a `kill ""` would be harmless —
# but a reap() that treated empty as "kill whatever" would not be.
sleep 30 & UNRELATED=$!
MD_PID=""
( reap ) >/dev/null 2>&1
sleep 0.2
kill -0 "$UNRELATED" 2>/dev/null \
    || fail "REGRESSION: reap() killed something with no PID recorded — with MD_PID empty it must do nothing at all"
note "with no PID recorded, reap() touches nothing  ✓"
kill "$UNRELATED" 2>/dev/null

# ── 4. the exit status survives the trap ───────────────────────────────────
# An EXIT trap that swallows a failure turns a failed run into a passing one, which is
# the worst possible outcome for a script whose entire job is to report a verdict.
cat > "$SANDBOX/rc.sh" <<'EOS'
MD_PID=""
EOS
sed -n '/^reap() {/,/^}/p' "$E2E" >> "$SANDBOX/rc.sh"
printf 'trap reap EXIT\nexit 3\n' >> "$SANDBOX/rc.sh"
( bash "$SANDBOX/rc.sh" ) >/dev/null 2>&1
rc=$?
[[ $rc -eq 3 ]] \
    || fail "REGRESSION: the EXIT trap changed the exit status (expected 3, got $rc) — a failed live run could report success"
note "the trap preserves the script's exit status  ✓"

pass "run-e2e.sh reaps its own facts sink by recorded PID on exit, leaves identically-named processes it did not start alone, does nothing when it owns no PID, and does not alter the run's verdict"
