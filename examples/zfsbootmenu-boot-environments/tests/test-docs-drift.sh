#!/usr/bin/env bash
# test-docs-drift.sh — the docs and the code must not drift apart.
#
# Three specific ways this lab can rot silently:
#
#   1. A subcommand is added to the dispatcher and never documented — or is
#      documented and quietly removed, so the RUNBOOK teaches a command that no
#      longer exists.
#   2. `--help` prints `sed -n '2,45p' "$0"` — a HARDCODED line range. Grow the
#      header by one line and the usage block truncates, with no error and no
#      test to notice. This one is a booby trap, not a hypothetical.
#   3. An env knob is documented but never read (or read but never documented),
#      which makes the header a lie in the direction users cannot check.
#
# Pure text analysis: nothing is executed except `be.sh --help`.
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
arm_exit_trap

BE="$LAB_DIR/be.sh"
[[ -r "$BE" ]] || fail "be.sh not found at $BE"

# The subcommands the dispatcher actually implements, straight from the case
# arms in main() (lines like:  list)     cmd_list "$@" ;;).
mapfile -t IMPL < <(sed -n '/case "\$cmd" in/,/esac/p' "$BE" \
    | sed -nE 's/^[[:space:]]*([a-z]+)\).*cmd_[a-z]+.*/\1/p' | sort -u)
[[ ${#IMPL[@]} -ge 5 ]] \
    || fail "could not parse the subcommand list out of be.sh (found ${#IMPL[@]}) — this test's parser has drifted from the script"
note "dispatcher implements: ${IMPL[*]}"

# The usage block as a USER sees it — via --help, not by reading the file, so a
# truncating line range is caught rather than bypassed.
HELP="$( ( "$BE" --help ) 2>&1 )" || fail "be.sh --help failed"

# ── 1. every implemented subcommand is documented in --help ─────────────────
for c in "${IMPL[@]}"; do
    grep -qE "^#[[:space:]]+$c( |\[|$)" <<<"$HELP" \
        || fail "REGRESSION: subcommand '$c' is implemented but absent from --help. If it was just added, document it in the header block; if the header outgrew be.sh's hardcoded 'sed -n 2,45p', --help is TRUNCATING and every command past the cut is invisible"
done
note "all ${#IMPL[@]} implemented subcommands appear in --help  ✓"

# ── 2. …and --help documents nothing that does not exist ────────────────────
mapfile -t DOCD < <(sed -nE 's/^#[[:space:]]{3}([a-z]+)[[:space:]].*/\1/p' <<<"$HELP" | sort -u)
for c in "${DOCD[@]}"; do
    grep -qx -- "$c" <<<"$(printf '%s\n' "${IMPL[@]}")" \
        || fail "REGRESSION: --help documents '$c', which the dispatcher does not implement — the RUNBOOK would be teaching a command that dies with 'unknown command'"
done
note "--help documents no command that the dispatcher lacks  ✓"

# ── 3. --help must emit the WHOLE header, however it is implemented ─────────
# Mechanism-agnostic on purpose. The original --help was `sed -n '2,45p' "$0"`
# and the header had already outgrown 45, so the entire "Env knobs" section was
# invisible to users — six documented controls nobody could discover. Rather
# than assert the line number (which just moves the trap), compare --help
# against the leading comment block computed from the file.
HEADER="$(awk 'NR==1 {next} /^#/ {print; next} {exit}' "$BE")"
HEADER_LINES=$(wc -l <<<"$HEADER"); HELP_LINES=$(wc -l <<<"$HELP")
[[ $HELP_LINES -ge $HEADER_LINES ]] \
    || fail "REGRESSION: --help emits $HELP_LINES lines but be.sh's header comment is $HEADER_LINES — --help is TRUNCATING its own documentation. Do not just raise a line number; make it print the whole block"
LAST="$(tail -1 <<<"$HEADER")"
grep -Fqx -- "$LAST" <<<"$HELP" \
    || fail "REGRESSION: --help does not reach the last line of the header ('${LAST:0:50}') — it is cutting the tail off its own usage text"
note "--help emits the complete header block ($HEADER_LINES lines), not a fixed range  ✓"

# ── 4. documented env knobs are actually read ───────────────────────────────
for knob in ZBM_POOL ZBM_ROOT BE_SNAPSHOT_TAG BE_DRYRUN ZFS ZPOOL; do
    grep -Fq "$knob" <<<"$HELP" \
        || fail "env knob $knob is read by be.sh but not documented in --help"
    # read somewhere other than the header comment block
    sed "1,${HEADER_LINES}d" "$BE" | grep -Fq "$knob" \
        || fail "REGRESSION: --help documents the env knob $knob, but nothing outside the comment header ever reads it — the documentation promises a control that does not exist"
done
note "all 6 documented env knobs are genuinely read by the code  ✓"

# ── 5. every be.sh command the prose teaches actually exists ────────────────
# The RUNBOOKs and README are what a reader types. A command that only exists in
# prose is worse than an undocumented one.
# A line is an INVOCATION only if it starts with the program — optionally
# behind a `$ ` prompt, a `./`, or env assignments (`BE_DRYRUN=1 ./be.sh …`).
# Matching `be.sh <word>` anywhere instead sweeps up English: this lab's fenced
# blocks contain "PASS: be.sh emits the correct…" and "# (be.sh refuses to
# destroy the active…", which are output and commentary, not commands.
bad=0
while read -r c; do
    [[ -z "$c" || "$c" == -* ]] && continue
    grep -qx -- "$c" <<<"$(printf '%s\n' "${IMPL[@]}")" && continue
    note "prose teaches 'be.sh $c', which is not a subcommand"
    bad=1
done < <(grep -rhE '^[[:space:]]*(\$ )?([A-Za-z_][A-Za-z0-9_]*=[^ ]+ )*(\./)?be\.sh ' "$LAB_DIR"/*.md \
         | sed -E 's/^[[:space:]]*(\$ )?([A-Za-z_][A-Za-z0-9_]*=[^ ]+ )*(\.\/)?be\.sh +//' \
         | sed -E 's/^(--[a-z-]+ +[^ ]+ +|--[a-z-]+ +)*//' \
         | awk '{print $1}' | sort -u)
[[ $bad -eq 0 ]] \
    || fail "REGRESSION: the lab's prose teaches a be.sh subcommand that does not exist (listed above)"
note "every 'be.sh <cmd>' in the lab's Markdown resolves to a real subcommand  ✓"

pass "be.sh and its documentation agree: no undocumented commands, no phantom commands, no truncated --help, no fictional env knobs"
