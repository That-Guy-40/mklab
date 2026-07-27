#!/usr/bin/env bash
# test-be-guardrails.sh — exercise the code paths BE_DRYRUN=1 SKIPS.
#
# test-be-logic.sh proves the dry-run command PLAN is right. But be.sh guards
# its one irreversible operation behind `if [[ "${BE_DRYRUN:-0}" != 1 ]]`:
#
#     cmd_destroy() {
#         if [[ "${BE_DRYRUN:-0}" != 1 ]]; then
#             bootfs="$("$ZPOOL" get -H -o value bootfs "$pool")"
#             [[ "$bootfs" == "$root/$name" ]] \
#                 && die "refusing to destroy the active BE ..."
#         fi
#
# so a dry-run test can never reach it. The refusal to destroy the BE you are
# currently booted from is the single most important behaviour in this tool, and
# it was completely untested.
#
# be.sh already ships the seam for this: $ZFS and $ZPOOL name the binaries, and
# its header says "(for stubbing in tests)". Nothing used it. This does.
#
# SAFETY: the stubs below are inert — they append their argv to a log and print
# canned values, nothing more. be.sh is pointed at them EXPLICITLY via $ZFS and
# $ZPOOL (no PATH games), so a real `zfs destroy` cannot be reached from here
# even if the guardrail were broken. That is deliberate: a test for a
# destructive-operation guard must not be able to perform the destruction.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

BE="$LAB_DIR/be.sh"
[[ -x "$BE" ]] || fail "be.sh not found or not executable at $BE"

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' RETURN 2>/dev/null || true
cleanup() { rm -rf "$STUB_DIR"; }

# Re-arm the verdict trap so it also cleans up.
# shellcheck disable=SC2154
trap 'rc=$?; cleanup; [[ $rc == 0 || $rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$rc" >&2' EXIT

cat >"$STUB_DIR/zpool" <<'STUB'
#!/usr/bin/env bash
# inert zpool stub: log the call, answer bootfs queries from $STUB_BOOTFS
printf 'zpool %s\n' "$*" >>"$STUB_LOG"
if [[ "$1" == get && "$*" == *bootfs* ]]; then printf '%s\n' "${STUB_BOOTFS:-}"; fi
if [[ "$1" == list && "$*" == *bootfs* ]]; then printf '%s\n' "${STUB_BOOTFS:-}"; fi
exit 0
STUB
cat >"$STUB_DIR/zfs" <<'STUB'
#!/usr/bin/env bash
# inert zfs stub: log the call and succeed. It never touches a pool.
printf 'zfs %s\n' "$*" >>"$STUB_LOG"
exit 0
STUB
chmod +x "$STUB_DIR/zpool" "$STUB_DIR/zfs"

export ZFS="$STUB_DIR/zfs" ZPOOL="$STUB_DIR/zpool"
export STUB_LOG="$STUB_DIR/calls.log"
unset BE_DRYRUN                       # the whole point: NOT dry-run

# run_be <bootfs-value> -- <be.sh args...>   → sets $out/$rc/$log
run_be() {
    local bootfs="$1"; shift; [[ "${1:-}" == -- ]] && shift
    : >"$STUB_LOG"
    out="$(STUB_BOOTFS="$bootfs" "$BE" "$@" 2>&1)" && rc=0 || rc=$?
    log="$(cat "$STUB_LOG")"
}

# ── 1. the guardrail: destroying the ACTIVE BE must be refused ───────────────
run_be "rpool/ROOT/default" -- --pool rpool destroy default
[[ $rc -ne 0 ]] \
    || fail "REGRESSION: destroying the ACTIVE boot environment was ALLOWED — this is the one operation that can leave a machine unbootable"
grep -Fq "refusing to destroy the active BE" <<<"$out" \
    || fail "REGRESSION: destroy of the active BE failed, but not with the guardrail's message (got: ${out//$'\n'/ })"
# The decisive assertion: it must not merely complain, it must NOT HAVE RUN.
grep -q 'zfs destroy' <<<"$log" \
    && fail "REGRESSION: be.sh printed the refusal AND issued 'zfs destroy' anyway — the guard does not short-circuit"
note "destroy of the active BE: refused, and no zfs destroy was issued  ✓"

# ── 2. …but a NON-active BE is destroyed for real ────────────────────────────
# Without this, the test above would also pass on a be.sh that refuses every
# destroy — proving the guard is selective, not blanket.
run_be "rpool/ROOT/default" -- --pool rpool destroy spare
[[ $rc -eq 0 ]] \
    || fail "destroying a NON-active BE was refused (rc=$rc): the guardrail is too broad (got: ${out//$'\n'/ })"
grep -Fq 'zfs destroy -r rpool/ROOT/spare' <<<"$log" \
    || fail "destroy of a non-active BE did not issue 'zfs destroy -r rpool/ROOT/spare' (log: ${log//$'\n'/ })"
note "destroy of a non-active BE: proceeds — the guard is selective, not blanket  ✓"

# ── 3. create with no -e resolves the source from the REAL bootfs ────────────
# Dry-run fakes this with BE_ACTIVE:-default, so the live branch is untested.
run_be "rpool/ROOT/prod" -- --pool rpool create trial
[[ $rc -eq 0 ]] || fail "create with no -e failed against a live bootfs (got: ${out//$'\n'/ })"
grep -Fq 'zfs snapshot rpool/ROOT/prod@' <<<"$log" \
    || fail "REGRESSION: create sourced the wrong BE — bootfs said rpool/ROOT/prod (log: ${log//$'\n'/ })"
grep -Fq 'rpool/ROOT/trial' <<<"$log" \
    || fail "create did not clone into rpool/ROOT/trial (log: ${log//$'\n'/ })"
note "create with no -e: sources whatever bootfs actually points at  ✓"

# ── 4. a bootfs OUTSIDE the BE container is rejected, not guessed at ─────────
run_be "tank/somewhere/else" -- --pool rpool create trial
[[ $rc -ne 0 ]] \
    || fail "REGRESSION: create accepted a bootfs outside the BE container instead of refusing"
grep -Fq "is not under" <<<"$out" \
    || fail "create rejected an out-of-container bootfs but not with the explaining message (got: ${out//$'\n'/ })"
grep -q 'zfs snapshot' <<<"$log" \
    && fail "REGRESSION: be.sh snapshotted something before rejecting an out-of-container bootfs"
note "a bootfs outside <pool>/ROOT is refused before anything is snapshotted  ✓"

# ── 5. pool auto-resolution, the path --pool bypasses ────────────────────────
run_be "tank/ROOT/default" -- activate default     # no --pool, no ZBM_POOL
[[ $rc -eq 0 ]] || fail "activate could not auto-resolve the pool from bootfs (got: ${out//$'\n'/ })"
grep -Fq 'zpool set bootfs=tank/ROOT/default tank' <<<"$log" \
    || fail "REGRESSION: pool auto-resolution picked the wrong pool — expected tank from bootfs tank/ROOT/default (log: ${log//$'\n'/ })"
note "with no --pool, the pool is derived from the active bootfs  ✓"

# ── 6. …and when no pool has a bootfs at all, it fails cleanly ───────────────
run_be "" -- activate default
[[ $rc -ne 0 ]] \
    || fail "REGRESSION: be.sh proceeded with no bootfs set anywhere instead of failing"
grep -Fq "bootfs" <<<"$out" \
    || fail "failed with no bootfs, but the message does not mention bootfs (got: ${out//$'\n'/ })"
note "no bootfs anywhere: a clean, explaining failure rather than a wrong guess  ✓"

pass "be.sh's live-path guardrails hold: the active BE cannot be destroyed, and pool/source resolution refuses to guess"
