#!/usr/bin/env bash
# check-track-list.sh — the names a lab's scripts dispatch on, and the names its docs type.
#
# TODO §14 Tier A, guards A2 and A5.
#
#   A2  every `case` arm of a dispatching script appears in that script's own
#       `usage: $0 [a|b|c]` line and vice versa, and every arm is documented in
#       its usage() heredoc.
#   A5  every `<script>.sh <word>` invocation typed in the lab's Markdown names
#       a real arm of that script.
#
# WHY A5 IS NOT check-doc-verbs.sh's JOB. Pointed at this lab, that tool reports
# "0 distinct commands across 2 documents" and is right to: it deliberately
# passes over `$ `-prefixed console transcripts, which is how this lab writes
# every example. Wiring it in here would be a green tick over nothing. This asks
# a narrower question it can answer exactly: not "does the command work" but
# "is that a name the script has".
#
# WHAT IT DELIBERATELY DOES NOT DO: run anything. A track name that exists but is
# broken is smoke-openbios.sh's problem, and it says so per track. This is the
# drift guard — the one that catches a renamed arm leaving three documents behind.
#
# §0 proves the scanner on 5 must-catch and 5 must-not-catch shapes BEFORE it is
# aimed at a real file, because a scan that matches nothing and a scan that is
# broken print the same green tick.
#
# Usage: check-track-list.sh <lab-dir>
set -uo pipefail

_VERDICT=0
note() { printf '  - %s\n' "$*" >&2; }
fail() { _VERDICT=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _VERDICT=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
skip() { _VERDICT=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: check-track-list.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
for sig in TERM INT HUP; do
    # shellcheck disable=SC2064  # $sig must expand now, at trap-install time
    trap "printf 'FAIL: check-track-list.sh killed by SIG%s\n' $sig >&2; exit $((128 + $(kill -l "$sig"))) " "$sig"
done

# ---------------------------------------------------------------- extraction

# arms_of <script> — the case-arm names of the dispatch that carries the
# `usage: $0 [...]` line, one per line. Multi-name arms (`a|b)`) are split.
#
# Anchored on the `*)` usage line and its INDENT, then scanning back to the
# ENCLOSING `case` — counting `esac` on the way up, because a nested `case`
# inside an arm must not end the scan. smoke-openbios.sh has two of those and
# the first version of this stopped at the first of them, finding 2 arms out of
# 19 and reporting the other 17 as missing.
#
# The §0 fixture for that shape passed anyway, for the wrong reason: it wrote
# the nested `case` on the ARM'S OWN LINE (`alpha) case "$X" in`), where there
# is no bare `case` line to stop at. A fixture that does not reproduce the real
# shape is a fixture that proves nothing — so it now writes the nested `case`
# on its own line, which is how the real script writes it.
#
# Indent still does the other half: it keeps the nested arms themselves
# (`inner)`, `other)`) from being read as top-level ones.
arms_of() {
    local f="$1"
    awk '
        /usage: \$0 \[/ && /^[[:space:]]*\*\)/ { star = NR; match($0, /^[[:space:]]*/); ind = RLENGTH; exit }
        { lines[NR] = $0 }
        END {
            if (!star) exit 0
            depth = 0
            for (i = star - 1; i >= 1; i--) {
                if (lines[i] ~ /^[[:space:]]*esac([[:space:]]|$)/) { depth++; continue }
                if (lines[i] ~ /^[[:space:]]*case[[:space:]]/) {
                    if (depth > 0) { depth--; continue }
                    break
                }
                if (match(lines[i], /^[[:space:]]*/) && RLENGTH != ind) continue
                if (lines[i] !~ /^[[:space:]]*[A-Za-z0-9|_.-]+\)/) continue
                s = lines[i]
                sub(/^[[:space:]]*/, "", s)
                sub(/\).*/, "", s)
                n = split(s, parts, "|")
                for (j = 1; j <= n; j++) print parts[j]
            }
        }
    ' "$f" | sort -u
}

# usage_list_of <script> — the names inside `usage: $0 [a|b|c]`.
usage_list_of() {
    sed -n 's/.*usage: \$0 \[\([^]]*\)\].*/\1/p' "$1" | head -1 | tr '|' '\n' | sed '/^$/d' | sort -u
}

# heredoc_of <script> — the usage() heredoc text, for the "is it documented" check.
heredoc_of() {
    sed -n '/^usage() {/,/^}/p' "$1"
}

# doc_invocations <script-basename> <doc...> — the token typed immediately after
# the script name, once per occurrence. ONLY the first token: docs say
# "run ./build-openbios.sh amd64 and x86 first", and `and` is prose, not a name.
doc_invocations() {
    local base="$1"; shift
    grep -hoE "(\./)?${base}[[:space:]]+[^[:space:]\`]+" "$@" 2>/dev/null \
        | sed -E "s#(\./)?${base}[[:space:]]+##" \
        | grep -E '^[a-z0-9][a-z0-9-]*$' \
        | sort -u
}

# check_pair <script> <doc...> — appends failures to $PROBLEMS, one per line.
PROBLEMS=""
check_pair() {
    local f="$1"; shift
    local base; base="$(basename "$f")"
    local arms usage a
    arms="$(arms_of "$f")"
    usage="$(usage_list_of "$f")"

    if [[ -z "$arms" ]]; then
        PROBLEMS+="$base: no case arms extracted at all — the dispatch moved, or this scanner cannot see it; either way it is asserting nothing"$'\n'
        return
    fi
    if [[ -z "$usage" ]]; then
        PROBLEMS+="$base: no 'usage: \$0 [...]' line found, so there is nothing to compare the arms against"$'\n'
        return
    fi
    while read -r a; do
        [[ -z "$a" ]] && continue
        grep -qxF "$a" <<<"$usage" \
            || PROBLEMS+="$base: '$a' is a case arm but is NOT in its own usage list — a track nobody can discover from --help"$'\n'
    done <<<"$arms"
    while read -r a; do
        [[ -z "$a" ]] && continue
        grep -qxF "$a" <<<"$arms" \
            || PROBLEMS+="$base: '$a' is offered by the usage list but has NO case arm — typing it prints the usage line again"$'\n'
    done <<<"$usage"

    local hd; hd="$(heredoc_of "$f")"
    if [[ -n "$hd" ]]; then
        while read -r a; do
            [[ -z "$a" ]] && continue
            grep -qF "$a" <<<"$hd" \
                || PROBLEMS+="$base: '$a' is a case arm that its usage() heredoc never mentions — --help does not describe it"$'\n'
        done <<<"$arms"
    fi

    if [[ $# -gt 0 ]]; then
        local d
        while read -r d; do
            [[ -z "$d" ]] && continue
            grep -qxF "$d" <<<"$arms" \
                || PROBLEMS+="$base: the docs type '$base $d', which is not one of its arms — a renamed track left a document behind"$'\n'
        done < <(doc_invocations "$base" "$@")
    fi
}

# ---------------------------------------------------------------- §0 controls

WORK="$(mktemp -d)"
mk_script() {   # mk_script <path> <usage-list> <arms-block>
    { printf '#!/usr/bin/env bash\nusage() {\n  cat <<%s\n' "'U'"
      printf 'demo [TRACK]\n  %s\n' "$2"
      printf 'U\n}\ncase "$T" in\n%s  *) echo "usage: $0 [%s]" >&2; exit 1 ;;\nesac\n' "$3" "$2"
    } > "$1"
}
c_ok=0; c_bad=0
expect() {  # expect <catch|clean> <label>
    local want="$1" label="$2"
    if [[ "$want" == catch ]]; then
        if [[ -n "$PROBLEMS" ]]; then c_ok=$((c_ok+1)); else c_bad=$((c_bad+1)); note "§0 MISSED: $label"; fi
    else
        if [[ -z "$PROBLEMS" ]]; then c_ok=$((c_ok+1)); else c_bad=$((c_bad+1)); note "§0 FALSE POSITIVE: $label -> $PROBLEMS"; fi
    fi
    PROBLEMS=""
}

# must-not-catch 1: a clean pair
mk_script "$WORK/s1.sh" "alpha|beta" "  alpha) : ;;
  beta) : ;;
"
printf 'run `./s1.sh alpha` then `./s1.sh beta`.\n' > "$WORK/d1.md"
check_pair "$WORK/s1.sh" "$WORK/d1.md"; expect clean "clean script+doc pair"

# must-not-catch 2: a multi-name arm
mk_script "$WORK/s2.sh" "alpha|beta" "  alpha|beta) : ;;
"
check_pair "$WORK/s2.sh"; expect clean "multi-name arm a|b) splits"

# must-not-catch 3: a NESTED case inside an arm, ON ITS OWN LINE — which is how
# smoke-openbios.sh writes both of its nested dispatches, and the shape the
# first version of this fixture failed to reproduce.
mk_script "$WORK/s3.sh" "alpha|beta" "  alpha)
    case \"\$X\" in
      inner) : ;;
      other) : ;;
    esac
    ;;
  beta) : ;;
"
check_pair "$WORK/s3.sh"; expect clean "nested case is not read as arms"

# must-not-catch 4 and 5: docs that mention the script with a flag, or bare
mk_script "$WORK/s4.sh" "alpha" "  alpha) : ;;
"
printf 'see `./s4.sh --help`, or just `s4.sh` on its own.\n' > "$WORK/d4.md"
check_pair "$WORK/s4.sh" "$WORK/d4.md"; expect clean "docs with --help and a bare mention"
printf 'run `./s4.sh alpha` and then check the log.\n' > "$WORK/d5.md"
check_pair "$WORK/s4.sh" "$WORK/d5.md"; expect clean "first token only, prose after it ignored"

# must-catch 1: an arm missing from the usage list
mk_script "$WORK/b1.sh" "alpha" "  alpha) : ;;
  gamma) : ;;
"
check_pair "$WORK/b1.sh"; expect catch "arm absent from the usage list"

# must-catch 2: a usage name with no arm
mk_script "$WORK/b2.sh" "alpha|delta" "  alpha) : ;;
"
check_pair "$WORK/b2.sh"; expect catch "usage name with no case arm"

# must-catch 3: an arm the heredoc never mentions
{ printf '#!/usr/bin/env bash\nusage() {\n  cat <<%s\ndemo [TRACK]\n  alpha\nU\n}\ncase "$T" in\n  alpha) : ;;\n  zeta) : ;;\n  *) echo "usage: $0 [alpha|zeta]" >&2; exit 1 ;;\nesac\n' "'U'"; } > "$WORK/b3.sh"
check_pair "$WORK/b3.sh"; expect catch "arm undocumented in the usage heredoc"

# must-catch 4: a doc naming a track that is not an arm
mk_script "$WORK/b4.sh" "alpha" "  alpha) : ;;
"
printf 'run `./b4.sh alpha` and `./b4.sh renamed`.\n' > "$WORK/db4.md"
check_pair "$WORK/b4.sh" "$WORK/db4.md"; expect catch "doc names a track that is not an arm"

# must-catch 5: a dispatch the scanner cannot see
printf '#!/usr/bin/env bash\nusage() { :; }\ncase "$T" in\n  *) echo "usage: $0 [alpha]" >&2; exit 1 ;;\nesac\n' > "$WORK/b5.sh"
check_pair "$WORK/b5.sh"; expect catch "no arms extracted at all"

(( c_bad == 0 )) \
    || fail "§0: $c_bad of $((c_ok + c_bad)) scanner controls behaved wrongly — the scanner is not attached to what it claims to check, so nothing below its verdict means anything"
note "§0 controls: 5 must-catch, 5 must-not-catch — all $c_ok behaved"

# ---------------------------------------------------------------- the real files

LAB="${1:-}"
[[ -n "$LAB" && -d "$LAB" ]] || fail "usage: check-track-list.sh <lab-dir>"
mapfile -t DOCS < <(find "$LAB" -maxdepth 1 -name '*.md' | sort)
(( ${#DOCS[@]} > 0 )) || fail "no Markdown in $LAB — A5 would pass over an empty document set"

n_scripts=0
for f in "$LAB"/*.sh; do
    grep -q 'usage: \$0 \[' "$f" || continue
    n_scripts=$((n_scripts + 1))
    check_pair "$f" "${DOCS[@]}"
done
(( n_scripts > 0 )) || fail "no dispatching script found in $LAB — every check above ran over nothing"

if [[ -n "$PROBLEMS" ]]; then
    while read -r p; do [[ -n "$p" ]] && note "$p"; done <<<"$PROBLEMS"
    fail "$(grep -c . <<<"$PROBLEMS") track-name mismatch(es) across $n_scripts script(s) and ${#DOCS[@]} document(s) — see the lines above"
fi

total=0
for f in "$LAB"/*.sh; do
    grep -q 'usage: \$0 \[' "$f" || continue
    n=$(arms_of "$f" | grep -c .)
    total=$((total + n))
    note "$(basename "$f"): $n arms, all in its usage list and its --help text"
done
pass "$total dispatch names across $n_scripts script(s) agree with their own usage lists and --help text, and every '<script> <name>' typed in ${#DOCS[@]} document(s) names a real one (10 scanner self-controls fired first)"
