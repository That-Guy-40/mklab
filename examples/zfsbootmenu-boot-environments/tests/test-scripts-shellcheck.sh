#!/usr/bin/env bash
# test-scripts-shellcheck.sh — the lab's shell scripts must pass shellcheck.
# Host-safe: static lint only.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

require_cmd shellcheck

# The lab's own scripts, linted strictly (no exclusions).
scripts=("$LAB_DIR/be.sh" "$LAB_DIR/install-zfs-root.sh")
for s in "${scripts[@]}"; do
    [[ -r "$s" ]] || fail "expected script missing: $s"
    if shellcheck -x "$s"; then
        note "shellcheck clean: ${s##*/}"
    else
        fail "shellcheck reported issues in ${s##*/}"
    fi
done

# The TEST scripts too — the verdict below says "all lab shell scripts", and
# with seven files under tests/ that claim was only true of two of them.
#
# Linted at the repo's CI settings rather than bare: --severity=warning drops
# info-level style notes that vary by shellcheck version, and the three excluded
# codes are this repo's documented-intentional warnings (see .github/workflows/
# ci.yml). Concretely, lib.sh's `readonly X="$(...)"` is SC2155 by design, and
# test-docs-drift.sh's single-quoted sed pattern is SC2016 on purpose.
shopt -s nullglob
tests=("$TEST_DIR"/*.sh)
shopt -u nullglob
[[ ${#tests[@]} -ge 4 ]] || fail "expected several test scripts under $TEST_DIR, found ${#tests[@]}"
for s in "${tests[@]}"; do
    if shellcheck -x --severity=warning -e SC2064,SC2155,SC2034 "$s"; then
        note "shellcheck clean: tests/${s##*/}"
    else
        fail "shellcheck reported issues in tests/${s##*/}"
    fi
done

pass "all ${#scripts[@]} lab scripts and ${#tests[@]} test scripts pass shellcheck"
