#!/usr/bin/env bash
# The usage text is DATA. It must not run.
#
# THE BUG THIS GUARDS (found 2026-08-18, while building examples/micro-cloud/preserve.sh):
#
#   usage() { cat <<EOF
#     ...  NO ROOT. Start the `listen` VM first.
#   EOF
#   }
#
# The heredoc delimiter is UNQUOTED — it has to be, because the text interpolates
# $LAB_PROG and $LAB_VERSION — so backticks inside it are command substitution. Bash ran
# `listen`, printed
#
#     lab-vm.sh: line 3738: listen: command not found
#
# on stderr, and then substituted the (empty) output INTO THE HELP TEXT, so every reader
# of `lab-vm.sh --help` was told:
#
#     no host interface, NO ROOT. Start the  VM first.
#
# — documentation silently corrupted at the exact word that says which end to start.
# Nothing failed. `--help` still exited 0, the surrounding text was intact, and the error
# went to stderr where a `--help | less` never shows it.
#
# It is also the repo's oldest rule pointed the other way round: CLAUDE.md opens with
# "never let test/sample data execute as a live command", written after a `$(reboot)` in a
# double-quoted printf rebooted the machine. Here the live command was a piece of PROSE,
# and `listen` is harmless only by luck — the same heredoc would have run anything.
#
# THE ASSERTIONS ARE OUTCOMES, NOT THE MECHANISM. Grepping the source for a backtick would
# pass the moment someone used `$(…)` instead, and would fail on a backtick inside a
# single-quoted string that never runs. So: invoke the thing, and look at what came out.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

out="$(bash "$LAB_VM" --help 2>/dev/null)" || fail "lab-vm.sh --help exited non-zero"
err="$(bash "$LAB_VM" --help 2>&1 >/dev/null)"

# 1. Nothing in the help text may execute. A shell diagnostic on stderr is the visible
#    half of the substitution; the corrupted text below is the half that matters.
[[ -z "$err" ]] || fail "REGRESSION: lab-vm.sh --help wrote to stderr, which means its usage heredoc EXECUTED something: ${err}"

# 2. The word that got eaten is back. This is the outcome: `listen` names one of the two
#    ends of --peer-link, and without it the sentence tells you to start "the  VM".
grep -q "Start the 'listen' VM" <<<"$out" \
    || fail "REGRESSION: the --peer-link help no longer names the 'listen' end — the heredoc ate it again (grep for: Start the ... VM)"

# 3. Both ends are still documented, so a fix that deleted the sentence would not pass.
grep -q -- '--peer-link {listen|connect}:PORT' <<<"$out" \
    || fail "the --peer-link usage line is gone or reworded; this test guards the text that carried the bug"

# 4. THE NEGATIVE CONTROL, run rather than reasoned. A copy of the real usage function
#    with a backticked word must FAIL assertion 1 — otherwise assertion 1 could be
#    matching an always-empty stderr and proving nothing.
ctl="$(mktemp -d)"; on_exit 'rm -rf -- "$ctl"'
cat > "$ctl/victim.sh" <<'SCRIPT'
#!/usr/bin/env bash
LAB_PROG=victim
usage() { cat <<EOF
$LAB_PROG — a stand-in for lab-vm.sh's usage()
  --peer-link {listen|connect}:PORT   Start the `zzz-no-such-command-anywhere` VM first.
EOF
}
usage
SCRIPT
ctl_err="$(bash "$ctl/victim.sh" 2>&1 >/dev/null || true)"
ctl_out="$(bash "$ctl/victim.sh" 2>/dev/null || true)"
[[ -n "$ctl_err" ]] \
    || fail "the control did not bite: a backticked word in an unquoted heredoc produced no stderr, so assertion 1 cannot be trusted"
grep -q 'Start the  VM first' <<<"$ctl_out" \
    || fail "the control did not bite: the backticked word was not substituted away, so assertion 2 cannot be trusted"

note "control fired: ${ctl_err##*: }"
pass "lab-vm.sh --help executes nothing and still names the 'listen' end of --peer-link (control confirmed both assertions can fail)"
