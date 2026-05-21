#!/usr/bin/env bash
# bash -n always; shellcheck when available.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

bash -n "$MLBUILD"          || fail "mlbuild.sh has a syntax error"
bash -n "$TEST_DIR/../init" || fail "init has a syntax error"
note "bash -n OK (mlbuild.sh, init)"

if have shellcheck; then
    shellcheck -S warning "$MLBUILD" || fail "shellcheck flagged mlbuild.sh"
    note "shellcheck -S warning clean"
else
    note "shellcheck not installed — lint skipped"
fi

pass "static analysis OK"
