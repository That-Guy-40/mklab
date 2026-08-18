#!/usr/bin/env bash
# check-usage-is-data.sh <script>... — prove a tool's help text cannot run.
#
# Verdict: none of these scripts' usage text contains command substitution, and none of
# them writes to stderr when asked for `--help`.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE BUG THIS GENERALISES (phase 2, found 2026-08-18).
#
#   usage() { cat <<EOF
#     ...  NO ROOT. Start the `listen` VM first.
#   EOF
#   }
#
# The delimiter is unquoted — it HAS to be, because the text interpolates $LAB_PROG and
# $LAB_VERSION — so backticks inside it are command substitution. Bash ran `listen`,
# wrote `lab-vm.sh: line 3738: listen: command not found` to stderr, and substituted the
# empty result INTO THE HELP TEXT. Every reader of `--help` was told:
#
#     no host interface, NO ROOT. Start the  VM first.
#
# Documentation silently corrupted at the exact word naming which end to start. `--help`
# still exited 0. It is CLAUDE.md's opening rule pointed the other way round: there the
# live command was test data, here it was a piece of PROSE.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THERE ARE TWO SECTIONS, AND WHY §2 ALONE WOULD BE A LIAR.
#
# The obvious check — "`--help` must write nothing to stderr" — is a CHEAP CHECK STANDING
# IN FOR THE REAL ONE, and it passes while the class is wide open:
#
#     `listen`  → no such command → loud. Caught by §2.
#     `date`    → runs fine       → SILENT. §2 sees an empty stderr and says PASS,
#                                   while the help text has been rewritten by whatever
#                                   `date` printed.
#
# The dangerous case is the quiet one, and it is the one the cheap check cannot see. §0
# proves exactly this with a fixture (`$(pwd)` in a usage heredoc): §2 passes it, §1
# catches it. So the real question is asked directly —
#
#     §1  is there command substitution in a usage heredoc whose delimiter is unquoted?
#     §2  and, as the outcome check, does `--help` in fact run nothing?
#
# Neither subsumes the other: §1 cannot see a script that builds its help some other way,
# §2 cannot see a substitution that succeeds.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY §0 EXISTS, WHICH IS THE PART THAT MATTERS MOST.
#
# `tools/check-harness-net.sh`'s §1 was WRONG TWICE — each time a regex over a physical
# line standing in for a question about a command, each time printing a confident green ✓
# across six suites while twenty tests violated the rule. The lesson recorded there is
# that *a scan that matches nothing and a scan that is broken print the same green ✓*, and
# the durable fix was not a better regex: it was running the scanner over shapes it MUST
# catch and shapes it MUST NOT, on every run, before aiming it at anything real.
#
# So §0 does that here — 5 must-catch and 5 must-not-catch — and this script refuses to
# report on a single real file until all ten have behaved.
#
# ─────────────────────────────────────────────────────────────────────────────
# SCOPE, STATED SO THE GAP IS NOT MISTAKEN FOR COVERAGE.
#
# §1 looks at heredocs inside a function named usage/print_usage/show_usage/show_help.
# A heredoc that writes a CONFIG FILE legitimately interpolates and is deliberately out of
# scope. A script whose help is not a heredoc at all (phase 7 extracts a marker-delimited
# COMMENT block, which is structurally immune) gets `n/a` printed — not a silent pass,
# because "I could not check this" must never render as "this is fine".
set -uo pipefail

_VERDICT=0
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: check-usage-is-data.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

(( $# )) || fail "usage: check-usage-is-data.sh <script>..."
WORK="$(mktemp -d)"

# ── §1's scanner ───────────────────────────────────────────────────────────
#
# Prints one `<line>\t<text>` row per offending line. A heredoc opener is recognised by
# splitting on `<<`; `<<<` is a herestring and is skipped, `<<-` is the tab-stripping
# form and is the same heredoc otherwise. A QUOTED delimiter (`<<'EOF'` / `<<"EOF"`)
# disables every expansion in the body, so its contents are inert text by definition.
scan_usage_heredocs() {
    local f="$1"
    local inusage=0 delim="" quoted=0 lineno=0 line rest d body
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        # NOTE the absence of a `continue` here. `usage() { cat <<EOF` is ONE line, so the
        # line that opens the function is also the line that opens the heredoc — an early
        # `continue` skipped it and the scanner saw nothing, in every driver. §0 caught
        # that on the first run, which is the entire argument for §0.
        if (( ! inusage )); then
            case "$line" in
                usage\(\)*|print_usage\(\)*|show_usage\(\)*|show_help\(\)*|\
usage\ \(\)*|print_usage\ \(\)*|show_usage\ \(\)*|show_help\ \(\)*) inusage=1 ;;
                *) continue ;;
            esac
        fi
        if [[ -z "$delim" ]]; then
            [[ "$line" == "}" ]] && { inusage=0; continue; }
            [[ "$line" == *"<<"* ]] || continue
            rest="${line#*<<}"
            [[ "$rest" == "<"* ]] && continue          # <<< is a herestring, not a heredoc
            rest="${rest#-}"
            rest="${rest#"${rest%%[![:space:]]*}"}"    # ltrim
            case "$rest" in
                \"*) quoted=1; d="${rest#\"}"; d="${d%%\"*}" ;;
                \'*) quoted=1; d="${rest#\'}"; d="${d%%\'*}" ;;
                *)   quoted=0; d="${rest%%[^A-Za-z0-9_]*}" ;;
            esac
            [[ -n "$d" ]] && delim="$d"
            continue
        fi
        # inside a heredoc body
        body="${line#"${line%%[![:space:]]*}"}"
        if [[ "$body" == "$delim" ]]; then delim=""; inusage=0; continue; fi
        (( quoted )) && continue
        if [[ "$line" == *'`'* || "$line" == *'$('* ]]; then
            printf '%s\t%s\n' "$lineno" "$line"
        fi
    done < "$f"
}

has_usage_heredoc() {
    local f="$1" inusage=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ! inusage )); then
            case "$line" in
                usage\(\)*|print_usage\(\)*|show_usage\(\)*|show_help\(\)*|\
usage\ \(\)*|print_usage\ \(\)*|show_usage\ \(\)*|show_help\ \(\)*) inusage=1 ;;
                *) continue ;;
            esac
        fi
        [[ "$line" == "}" ]] && { inusage=0; continue; }
        [[ "$line" == *"<<"* && "${line#*<<}" != "<"* ]] && return 0
    done < "$f"
    return 1
}

# ── §0 — THE SCANNER'S OWN CONTROLS, BEFORE IT IS AIMED AT ANYTHING REAL ───
mk() { printf '%s\n' "$2" > "$WORK/$1.sh"; chmod +x "$WORK/$1.sh"; }

# --- 5 shapes §1 MUST catch -------------------------------------------------
mk catch1 '#!/usr/bin/env bash
P=x
usage() { cat <<EOF
$P — start the `zzz-nope` end first.
EOF
}
usage'
mk catch2 '#!/usr/bin/env bash
P=x
usage() { cat <<EOF
$P — built on $(pwd)
EOF
}
usage'
mk catch3 '#!/usr/bin/env bash
P=x
usage() { cat <<-EOF
	$P — the `zzz-nope` form, tab-stripped
	EOF
}
usage'
mk catch4 '#!/usr/bin/env bash
P=x
usage() { cat <<EOF
$P
  line one, innocent
  line two, innocent
  line three has a `zzz-nope`
EOF
}
usage'
mk catch5 '#!/usr/bin/env bash
P=x
show_help() { cat <<HELP
$P — a differently named help function with a `zzz-nope`
HELP
}
show_help'

# --- 5 shapes §1 MUST NOT catch ---------------------------------------------
mk safe1 "#!/usr/bin/env bash
usage() { cat <<'EOF'
a single-quoted delimiter makes \`this\` inert text
EOF
}
usage"
mk safe2 '#!/usr/bin/env bash
usage() { cat <<"EOF"
a double-quoted delimiter is inert too: `this`
EOF
}
usage'
mk safe3 '#!/usr/bin/env bash
P=x
write_config() { cat > /dev/null <<EOF
this heredoc is OUTSIDE usage() and legitimately interpolates $(id -u)
EOF
}
usage() { cat <<EOF
$P — clean help
EOF
}
usage'
mk safe4 '#!/usr/bin/env bash
P=x
V=1
usage() { cat <<EOF
$P $V — plain variables are not command substitution
EOF
}
usage'
mk safe5 '#!/usr/bin/env bash
P=x
usage() { grep -q x <<<"$P"; cat <<EOF
$P — a herestring is not a heredoc
EOF
}
usage'

ctl_fail=()
for c in catch1 catch2 catch3 catch4 catch5; do
    [[ -n "$(scan_usage_heredocs "$WORK/$c.sh")" ]] \
        || ctl_fail+=("§1 MISSED a must-catch shape: $c")
done
for s in safe1 safe2 safe3 safe4 safe5; do
    [[ -z "$(scan_usage_heredocs "$WORK/$s.sh")" ]] \
        || ctl_fail+=("§1 FIRED on a must-not-catch shape: $s ($(scan_usage_heredocs "$WORK/$s.sh" | head -1))")
done

# THE CONTROL THAT JUSTIFIES §1's EXISTENCE. `catch2` substitutes `$(pwd)`, which
# SUCCEEDS — so the stderr check passes it while its help text has been rewritten. If
# this ever stops being true, §1 could be dropped; until then, §2 alone is a liar.
c2_err="$(bash "$WORK/catch2.sh" 2>&1 >/dev/null || true)"
[[ -z "$c2_err" ]] \
    || ctl_fail+=("the §2-is-not-enough control did not hold: a succeeding substitution wrote to stderr after all (${c2_err})")
c2_out="$(bash "$WORK/catch2.sh" 2>/dev/null || true)"
[[ "$c2_out" != *'$(pwd)'* ]] \
    || ctl_fail+=("the §2-is-not-enough control did not hold: \$(pwd) was not substituted, so the fixture proves nothing")

# --- §2's own controls ------------------------------------------------------
mk noisy '#!/usr/bin/env bash
usage() { cat <<EOF
x — the `zzz-nope` that makes noise
EOF
}
case "${1:-}" in --help) usage; exit 0 ;; esac'
mk quiet '#!/usr/bin/env bash
usage() { cat <<EOF
x — clean
EOF
}
case "${1:-}" in --help) usage; exit 0 ;; esac'
[[ -n "$(bash "$WORK/noisy.sh" --help 2>&1 >/dev/null || true)" ]] \
    || ctl_fail+=("§2's positive control failed: a broken --help produced no stderr")
[[ -z "$(bash "$WORK/quiet.sh" --help 2>&1 >/dev/null || true)" ]] \
    || ctl_fail+=("§2's negative control failed: a clean --help wrote to stderr anyway")

if (( ${#ctl_fail[@]} )); then
    printf '  %s\n' "${ctl_fail[@]}" >&2
    fail "the checker's own controls did not behave — nothing below can be trusted, so nothing below was run"
fi
note "§0 controls: 5 must-catch, 5 must-not-catch, 2 for the stderr check, and the fixture proving stderr alone is not enough — all 13 behaved"

# ── §1 + §2 — the real files ───────────────────────────────────────────────
problems=() checked=0 struct_na=()
for f in "$@"; do
    [[ -r "$f" ]] || { problems+=("$f: not readable"); continue; }
    checked=$((checked + 1))

    if has_usage_heredoc "$f"; then
        hits="$(scan_usage_heredocs "$f")"
        if [[ -n "$hits" ]]; then
            while IFS=$'\t' read -r ln txt; do
                problems+=("$f:$ln — command substitution in an UNQUOTED usage heredoc; it will RUN: ${txt#"${txt%%[![:space:]]*}"}")
            done <<<"$hits"
        fi
    else
        # Not a pass and not a failure: this script's help is not a heredoc at all.
        struct_na+=("$f")
    fi

    err="$(bash "$f" --help 2>&1 >/dev/null || true)"
    rc=0; bash "$f" --help >/dev/null 2>&1 || rc=$?
    if (( rc != 0 )); then
        problems+=("$f: --help exited $rc, so §2 could not be applied (an unchecked file is not a checked one)")
    elif [[ -n "$err" ]]; then
        problems+=("$f: --help wrote to stderr, which means something in its help text EXECUTED: ${err}")
    fi
done

(( checked )) || fail "no readable files were checked"
if (( ${#struct_na[@]} )); then
    note "§1 n/a for ${#struct_na[@]} file(s) — help is not built from a heredoc there (checked by §2 only): ${struct_na[*]}"
fi

if (( ${#problems[@]} )); then
    printf '  %s\n' "${problems[@]}" >&2
    fail "${#problems[@]} usage-text defect(s) — help text that runs is not documentation, it is a program nobody reviewed"
fi

pass "$checked script(s): no command substitution in any usage heredoc, and --help runs nothing (13 self-controls fired first)"
