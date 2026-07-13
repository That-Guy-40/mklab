#!/usr/bin/env bash
# test-scripts-shellcheck.sh — the lab's shell scripts must pass shellcheck.
# Host-safe: static lint only.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

require_cmd shellcheck

scripts=("$LAB_DIR/be.sh" "$LAB_DIR/install-zfs-root.sh")
for s in "${scripts[@]}"; do
    [[ -r "$s" ]] || fail "expected script missing: $s"
    if shellcheck -x "$s"; then
        note "shellcheck clean: ${s##*/}"
    else
        fail "shellcheck reported issues in ${s##*/}"
    fi
done

pass "all lab shell scripts pass shellcheck"
