#!/usr/bin/env bash
# test-cli-contract.sh — every subcommand rejects a missing/!bad argument.
#
# test-be-logic.sh checks ONE guardrail (`create` with no NAME). be.sh has eight
# subcommands and seven of them have required arguments; an unvalidated one
# would build a dataset path with an empty component — `rpool/ROOT/` — and hand
# it to zfs. So assert the whole surface, not a sample.
#
# Everything here runs with BE_DRYRUN=1 and a fixed pool: no ZFS, no root, and
# no command is ever executed even in principle.
#
# THE SILENT-EXIT TRAP (CLAUDE.md): every one of these calls is expected to
# `die`, which is `exit`, not `return`. Calling one in a bare `if be.sh …; then`
# lets that exit blow past the `if` and kill this test before its later
# assertions run — so every invocation below is wrapped in a SUBSHELL.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

BE="$LAB_DIR/be.sh"
[[ -x "$BE" ]] || fail "be.sh not found or not executable at $BE"
export BE_DRYRUN=1 ZBM_POOL=rpool BE_SNAPSHOT_TAG=t BE_ACTIVE=default

# rejects <why> <args...> — the call must fail AND explain itself.
rejects() {
    local why="$1"; shift
    local out rc
    out="$( ( "$BE" "$@" ) 2>&1 )" && rc=0 || rc=$?
    [[ $rc -ne 0 ]] \
        || fail "REGRESSION: '$*' was ACCEPTED but should be refused ($why)"
    [[ -n "$out" ]] \
        || fail "REGRESSION: '$*' failed silently with no message — the reader cannot tell a refusal from a crash ($why)"
    printf '%s' "$out"
}

# accepts <args...> — the call must succeed (the positive control).
accepts() {
    ( "$BE" "$@" ) >/dev/null 2>&1 \
        || fail "'$*' should be a valid invocation but was rejected"
}

# ── required arguments, one subcommand at a time ─────────────────────────────
rejects "NAME is required"        create   >/dev/null
rejects "NAME is required"        activate >/dev/null
rejects "NAME is required"        destroy  >/dev/null
rejects "NAME is required"        snapshot >/dev/null
rejects "NAME is required"        cmdline  >/dev/null
rejects "OLD and NEW required"    rename       >/dev/null
rejects "OLD and NEW required"    rename only1 >/dev/null
rejects "NAME and TAG required"   rollback         >/dev/null
rejects "NAME and TAG required"   rollback nametag >/dev/null
note "all 7 argument-taking subcommands refuse a missing argument  ✓"

# The positive controls. Without these the block above would also pass on a
# be.sh that rejects EVERYTHING.
accepts create  newbe
accepts activate newbe
accepts destroy  newbe
accepts snapshot newbe tag
accepts rename   a b
accepts rollback newbe tag
accepts cmdline  newbe "quiet"
accepts list
note "…and all 8 subcommands accept a well-formed invocation  ✓"

# ── the dispatcher itself ────────────────────────────────────────────────────
out="$(rejects "not a subcommand" definitely-not-a-command)"
grep -Fq "unknown command" <<<"$out" \
    || fail "an unknown subcommand was refused, but not with 'unknown command' (got: ${out//$'\n'/ })"
note "an unknown subcommand is named as such  ✓"

out="$(rejects "not a global option" --definitely-not-an-option list)"
grep -Fq "unknown option" <<<"$out" \
    || fail "an unknown global option was refused, but not with 'unknown option' (got: ${out//$'\n'/ })"
note "an unknown global option is named as such  ✓"

out="$(rejects "not a create flag" create -Z bad)"
grep -Fq "unknown flag" <<<"$out" \
    || fail "an unknown create flag was refused, but not with 'unknown flag' (got: ${out//$'\n'/ })"
note "an unknown per-command flag is named as such  ✓"

# No subcommand at all: usage, and a NON-zero exit — a bare `be.sh` that exits 0
# would tell a calling script that something happened.
out="$( ( "$BE" ) 2>&1 )" && rc=0 || rc=$?
[[ $rc -ne 0 ]] || fail "REGRESSION: be.sh with no arguments exited 0 — a caller cannot distinguish that from success"
grep -Fq "Usage:" <<<"$out" || fail "be.sh with no arguments did not print usage (got: ${out//$'\n'/ })"
note "no arguments: usage, and a non-zero exit  ✓"

# --help is the one that must succeed.
out="$( ( "$BE" --help ) 2>&1 )" && rc=0 || rc=$?
[[ $rc -eq 0 ]] || fail "--help exited $rc; it is the one invocation that must succeed"
grep -Fq "Usage:" <<<"$out" || fail "--help printed no usage block"
note "--help succeeds and prints usage  ✓"

pass "be.sh's CLI contract holds: every subcommand validates its arguments, and every refusal explains itself"
