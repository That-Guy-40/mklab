#!/usr/bin/env bash
# check-patch-hygiene.sh — a patch series is a record, and records rot.
#
# TODO §14 Tier A, guards A3 and A4.
#
#   A3  every REVIVAL_MARKERS entry in build-openbios.sh names a file that
#       patches/01 touches AND a string that patch actually ADDS.
#   A4  every patches/NN-*.patch parses as a unified diff, and its
#       `Subject: [PATCH NN/M]` agrees with its own filename. Plus: the series
#       is numbered 01..N with no gaps and no duplicates.
#
# THE SUBJECT CONVENTION BEGAN AT PATCH 11 (2026-08-24). Patches 01-10 predate
# it: some are bare diffs, some open with a `#` comment header. They are exempt
# from the subject half BY NAME AND WITH A REASON, never by a date cutoff -- an
# exemption justified by "it is old" grows silently, which is the argument
# check-patch-scope.sh makes about its own five grandfathered patches. The
# exempt list is PRINTED on every run for the same reason.
#
# Only the subject half is exempt. Parsing as a unified diff is not a
# convention, it is correctness, and all thirty are held to it.
#
# WHY A3. build-openbios.sh decides "is patch 01 already applied?" by looking
# for eight marker strings rather than by `git apply --reverse --check`, and it
# is right to: a patch is a diff, which is a cache of a state, and a later patch
# editing the same region broke the reverse check while patch 01 was still fully
# in effect. But the marker array is then itself A CACHED DESCRIPTION OF A PATCH
# -- bug class #1 in CLAUDE.md -- and nothing checked it against the patch. A
# marker that patch 01 no longer adds makes the build say "not applied" and
# reapply, or say "half applied" and stop, for a tree that is fine.
#
# WHY --numstat AND NOT A HAND-ROLLED PARSER. `git apply --numstat` is git's own
# diff reader; it validates structure without needing the target files and
# exits non-zero on a corrupt patch. Extract the shipped thing, never
# re-implement it: a private parser would drift and then prove something about
# itself.
#
# §0 proves the scanner on 5 must-catch and 5 must-not-catch shapes BEFORE it is
# aimed at a real file.
#
# Usage: check-patch-hygiene.sh <lab-dir>
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
        printf 'FAIL: check-patch-hygiene.sh exited early (rc=%d) — no verdict was printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
for sig in TERM INT HUP; do
    # shellcheck disable=SC2064  # $sig must expand now, at trap-install time
    trap "printf 'FAIL: check-patch-hygiene.sh killed by SIG%s\n' $sig >&2; exit $((128 + $(kill -l "$sig")))" "$sig"
done

# Numbers exempt from the `Subject:` half. See the note above: by name, with a
# reason, and printed on every run.
SUBJECT_EXEMPT="01 02 03 04 05 06 07 08 09 10"
EXEMPT_USED=""

command -v git >/dev/null || skip "git is not installed — A4 uses git's own diff reader and will not hand-roll one"

PROBLEMS=""

# added_lines <patch> — the text of every ADDED line, '+' stripped. Header lines
# (+++ b/foo) are excluded: they name a file, they do not add a string.
added_lines() { grep -h '^+' "$1" | grep -v '^+++' | sed 's/^+//'; }
touched_files() { sed -n 's|^+++ b/||p' "$1" | sed 's/[[:space:]].*//' | sort -u; }

# check_markers <build-script> <patch01> — sets NMARK, appends to PROBLEMS.
#
# IT RETURNS ITS COUNT IN A GLOBAL, NOT ON STDOUT, and that is not a style
# choice. It was written to `echo "$n"` and called as NMARK="$(check_markers …)"
# — a COMMAND SUBSTITUTION, which is a SUBSHELL, so every `PROBLEMS+=` inside it
# was discarded on return. The §0 fixtures called it plainly and saw the
# problems; the real invocation wrapped it and did not. Both marker controls
# passed against a deliberately broken marker while §0 stayed green.
#
# A checker that reports its findings into a subshell is the liar this whole
# file exists to catch, and only an end-to-end control on the REAL corpus could
# see it: the fixtures exercised a different call shape from the one that ships.
NMARK=0
check_markers() {
    local build="$1" patch="$2" line f pat n=0
    local files added
    files="$(touched_files "$patch")"
    added="$(added_lines "$patch")"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        f="${line%%:*}"; pat="${line#*:}"
        n=$((n + 1))
        grep -qxF "$f" <<<"$files" \
            || { PROBLEMS+="marker '$f' names a file $(basename "$patch") does not touch — the marker array has drifted from the patch it describes"$'\n'; continue; }
        grep -qF -- "$pat" <<<"$added" \
            || PROBLEMS+="marker '$f' looks for a string $(basename "$patch") does not ADD: '$pat' — the build will read a correctly patched tree as unpatched"$'\n'
    done < <(sed -n '/^REVIVAL_MARKERS=(/,/^)/p' "$build" | sed -n 's/^[[:space:]]*["'"'"']\(.*\)["'"'"']$/\1/p')
    if (( n == 0 )); then
        PROBLEMS+="no REVIVAL_MARKERS entries were extracted from $(basename "$build") — the array moved or changed shape, and this check is asserting nothing"$'\n'
    fi
    NMARK="$n"
}

# check_patch <patch> — A4 for one file.
check_patch() {
    local p="$1" base num subj
    base="$(basename "$p")"
    num="${base%%-*}"
    [[ "$num" =~ ^[0-9]{2}$ ]] \
        || { PROBLEMS+="$base does not begin with a two-digit number, so it has no place in the series"$'\n'; return; }
    if ! git apply --numstat "$p" >/dev/null 2>&1; then
        PROBLEMS+="$base does not parse as a unified diff (git apply --numstat refused it) — a patch that cannot be read is a record of nothing"$'\n'
        return
    fi
    subj="$(sed -n 's/^Subject: \[PATCH \([0-9]\+\)\/[0-9]\+\].*/\1/p' "$p" | head -1)"
    if [[ -z "$subj" ]]; then
        if [[ " $SUBJECT_EXEMPT " == *" $num "* ]]; then
            EXEMPT_USED+="$num "
            return
        fi
        PROBLEMS+="$base has no 'Subject: [PATCH NN/M]' line — the series numbering lives only in the filename"$'\n'
        return
    fi
    [[ "$((10#$subj))" -eq "$((10#$num))" ]] \
        || PROBLEMS+="$base says 'Subject: [PATCH $subj/…]' — the filename and the subject disagree about which patch this is"$'\n'
}

# ---------------------------------------------------------------- §0 controls

WORK="$(mktemp -d)"
mk_patch() { # mk_patch <path> <subject-nn> <total> <file> <added-line>
    printf 'Subject: [PATCH %s/%s] demo\n\ndiff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,2 +1,3 @@\n ctx\n+%s\n ctx2\n' \
        "$2" "$3" "$4" "$4" "$4" "$4" "$5" > "$1"
}
mk_build() { printf 'REVIVAL_MARKERS=(\n%s)\n' "$1" > "$2"; }
c_ok=0; c_bad=0
expect() {
    local want="$1" label="$2"
    if [[ "$want" == catch ]]; then
        if [[ -n "$PROBLEMS" ]]; then c_ok=$((c_ok+1)); else c_bad=$((c_bad+1)); note "§0 MISSED: $label"; fi
    else
        if [[ -z "$PROBLEMS" ]]; then c_ok=$((c_ok+1)); else c_bad=$((c_bad+1)); note "§0 FALSE POSITIVE: $label -> $PROBLEMS"; fi
    fi
    PROBLEMS=""
}

mk_patch "$WORK/01-demo.patch" 01 2 "src/a.c" "hello world"
mk_build '    "src/a.c:hello world"
' "$WORK/build-ok.sh"
check_markers "$WORK/build-ok.sh" "$WORK/01-demo.patch"; expect clean "marker naming a file and a string the patch adds"
check_patch "$WORK/01-demo.patch"; expect clean "a well-formed patch whose subject matches its name"

mk_patch "$WORK/02-demo.patch" 2 2 "src/b.c" "x"
check_patch "$WORK/02-demo.patch"; expect clean "subject '2/2' against filename '02' (numeric, not textual)"

mk_build '    "src/a.c:hello world"
    "src/a.c:hello world"
' "$WORK/build-dup.sh"
check_markers "$WORK/build-dup.sh" "$WORK/01-demo.patch"; expect clean "a marker repeated is not an error"

# THE EXEMPTION ITSELF, both ways. A grandfather list that swallows everything
# is worse than none: it would pass a patch 29 with no subject just as quietly.
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1,2 @@\n a\n+b\n' > "$WORK/09-old.patch"
check_patch "$WORK/09-old.patch"; expect clean "an EXEMPT number with no Subject line"
cp "$WORK/09-old.patch" "$WORK/29-new.patch"
check_patch "$WORK/29-new.patch"; expect catch "a NON-exempt number with no Subject line"

printf 'Subject: [PATCH 01/1] demo\n\ndiff --git a/x b/x\nnew file mode 100644\n--- /dev/null\n+++ b/x\n@@ -0,0 +1 @@\n+only\n' > "$WORK/01-new.patch"
check_patch "$WORK/01-new.patch"; expect clean "a new-file patch (--- /dev/null) parses"

mk_build '    "src/ZZZ.c:hello world"
' "$WORK/build-badfile.sh"
check_markers "$WORK/build-badfile.sh" "$WORK/01-demo.patch"; expect catch "marker names a file the patch does not touch"

mk_build '    "src/a.c:goodbye world"
' "$WORK/build-badpat.sh"
check_markers "$WORK/build-badpat.sh" "$WORK/01-demo.patch"; expect catch "marker looks for a string the patch does not add"

# A marker matching a line the patch REMOVES, or one that is only context, is a
# marker that will never be found in the built tree.
printf 'Subject: [PATCH 01/1] demo\n\ndiff --git a/src/a.c b/src/a.c\n--- a/src/a.c\n+++ b/src/a.c\n@@ -1,2 +1,2 @@\n ctx\n-removed string\n+added string\n' > "$WORK/01-rm.patch"
mk_build '    "src/a.c:removed string"
' "$WORK/build-rm.sh"
check_markers "$WORK/build-rm.sh" "$WORK/01-rm.patch"; expect catch "marker matches a REMOVED line, not an added one"

mk_patch "$WORK/03-demo.patch" 07 9 "src/c.c" "y"
check_patch "$WORK/03-demo.patch"; expect catch "subject number disagrees with the filename"

printf 'Subject: [PATCH 04/9] demo\n\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,3 +1,9 @@\n a\n-b\n+c\n' > "$WORK/04-corrupt.patch"
check_patch "$WORK/04-corrupt.patch"; expect catch "hunk header line counts do not match the hunk"

(( c_bad == 0 )) \
    || fail "§0: $c_bad of $((c_ok + c_bad)) scanner controls behaved wrongly — nothing below its verdict means anything"
# The fixtures used the exemption too; clear what they recorded, or the report
# below names a temp file as a grandfathered patch.
EXEMPT_USED=""
note "§0 controls: 6 must-catch, 6 must-not-catch — all $c_ok behaved"

# ---------------------------------------------------------------- the real files

LAB="${1:-}"
[[ -n "$LAB" && -d "$LAB/patches" ]] || fail "usage: check-patch-hygiene.sh <lab-dir>  (needs <lab-dir>/patches)"
BUILD="$LAB/build-openbios.sh"
[[ -f "$BUILD" ]] || fail "no build-openbios.sh in $LAB — A3 has nothing to read the markers from"

mapfile -t PATCHES < <(find "$LAB/patches" -maxdepth 1 -name '[0-9][0-9]-*.patch' | sort)
(( ${#PATCHES[@]} > 0 )) || fail "no NN-*.patch files in $LAB/patches — every check below would run over nothing"

P01="$LAB/patches/01-x86-revival.patch"
[[ -f "$P01" ]] || fail "patches/01-x86-revival.patch is missing — it is the one patch build-openbios.sh applies, and the markers describe it"
check_markers "$BUILD" "$P01"

for p in "${PATCHES[@]}"; do check_patch "$p"; done

# The series itself: 01..N, no gaps, no duplicates. A gap is a deleted patch
# nobody renumbered; a duplicate is two people adding one on the same evening.
nums=(); for p in "${PATCHES[@]}"; do b="$(basename "$p")"; nums+=("$((10#${b%%-*}))"); done
mapfile -t sorted < <(printf '%s\n' "${nums[@]}" | sort -n)
for ((i = 0; i < ${#sorted[@]}; i++)); do
    want=$((i + 1))
    if [[ "${sorted[$i]}" -ne "$want" ]]; then
        PROBLEMS+="the series is not 01..${#sorted[@]}: expected $(printf '%02d' "$want") at position $want but found $(printf '%02d' "${sorted[$i]}") — a gap or a duplicate"$'\n'
        break
    fi
done

if [[ -n "$PROBLEMS" ]]; then
    while read -r p; do [[ -n "$p" ]] && note "$p"; done <<<"$PROBLEMS"
    fail "$(grep -c . <<<"$PROBLEMS") patch-hygiene problem(s) — see the lines above"
fi
note "A3: $NMARK revival markers, each naming a file patch 01 touches and a string it adds"
note "A4: ${#PATCHES[@]} patches parse as unified diffs, subjects agree with filenames, series is 01..${#PATCHES[@]}"
if [[ -n "$EXEMPT_USED" ]]; then
    note "A4: no Subject: line on ${EXEMPT_USED% } — grandfathered BY NAME (the convention began at patch 11), printed here so the exemption cannot grow unnoticed"
fi
pass "the patch series is coherent with itself and with the build: $NMARK markers describe strings patches/01 actually adds, and all ${#PATCHES[@]} patches read as unified diffs numbered 01..${#PATCHES[@]} with subjects that match their filenames (12 scanner self-controls fired first)"
