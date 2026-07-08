#!/usr/bin/env bash
# Regression: `create --config <malformed.toml>` must exit NON-zero.
#
# The bug: specs_from_config ran the TOML parser inside a `< <(…)` process
# substitution; its `die` was swallowed (set -e is suppressed in that context)
# and an empty-input jq downstream returned 0, so `create` exited 0 on a broken
# config — a silent no-op that fools any script/CI treating exit code as truth.
#
# shellcheck disable=SC1090,SC2034
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq
command -v tomlq >/dev/null 2>&1 \
    || command -v dasel >/dev/null 2>&1 \
    || { command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah; } \
    || skip "no TOML parser (tomlq/dasel/mikefarah-yq)"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"

printf 'this is not = valid TOML [[[\n' > "$work/bad.toml"

# `if cmd; then` catches the non-zero exit without set -e killing the test.
if out="$("$LAB_VM" create --config "$work/bad.toml" 2>&1)"; then
    fail "REGRESSION: create with malformed TOML exited 0 (silent no-op): $out"
fi
note "malformed config exits non-zero"

grep -qi 'parse' <<<"$out" \
    || fail "expected a parse-error message, got: $out"
note "error message names the parse failure"

# A well-formed config must get PAST the parser (it will fail later for lack of
# qemu/etc, but NOT with a parse error) — proves we didn't just break all configs.
printf '[[vm]]\nname = "ok1"\nbackend = "disk-image"\n' > "$work/good.toml"
out="$("$LAB_VM" create --config "$work/good.toml" 2>&1 || true)"
if grep -qi 'failed to parse' <<<"$out"; then
    fail "a well-formed config was rejected as a parse failure: $out"
fi
note "well-formed config parses (proceeds past the parser)"

pass "malformed --config exits non-zero with a parse error; valid config still parses"
