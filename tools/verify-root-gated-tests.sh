#!/usr/bin/env bash
# verify-root-gated-tests.sh — run the three tests that 11.3a could not verify by execution.
#
# WHY THIS EXISTS. PR #271 rewrote a pipe-gated assertion in each of these three. All three
# skip without root — on this box AND on the CI runner — so those three rewrites are the only
# ones in that change never watched running. An assertion nobody has seen execute is an
# UNKNOWN, not a pass, and this closes it the only way that counts: by running them.
#
# It writes everything to a report file under TMPDIR (never into the repo, where a root-owned
# artifact would sit in `git status` afterwards); nothing is printed but a summary.
# State goes to a throwaway directory, NOT your real ~/.local/state, so a root-run test
# cannot leave root-owned files where an unprivileged run would later trip over them.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run me with sudo: sudo bash $0"; exit 2; }

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${TMPDIR:-/tmp}/verify-root-gated-tests.$$.out"
STATE="$(mktemp -d /tmp/mklab-root-verify.XXXXXX)"
export LAB_STATE_DIR="$STATE/state" LAB_CACHE_DIR="$STATE/cache"

TESTS=(phase1-chroot/tests/test-nspawn-integration.sh
       phase1-chroot/tests/test-schroot-integration.sh
       phase4-podman/tests/test-rootful-up.sh)

: > "$REPORT"
summary=()
for t in "${TESTS[@]}"; do
    echo "=================== $t ===================" >> "$REPORT"
    out="$(cd "$REPO" && timeout 600 bash "$t" 2>&1)"; rc=$?
    printf '%s\n' "$out" >> "$REPORT"
    verdict="$(printf '%s' "$out" | grep -aoE '^(PASS|FAIL|SKIP):.*' | tail -1)"
    echo "--- rc=$rc  ${verdict:-<NO VERDICT LINE — that is itself a defect>}" >> "$REPORT"
    summary+=("$(printf '%-42s rc=%-3s %s' "$(basename "$t")" "$rc" "${verdict:0:70}")")
done

echo >> "$REPORT"
echo "state dir used: $STATE (remove it yourself if it survived)" >> "$REPORT"
printf '%s\n' "${summary[@]}"
echo
echo "full output: $REPORT"
