#!/usr/bin/env bash
# check-patch-hygiene.sh — a patch series is a record, and records rot.
#
# TODO §14 Tier A, guards A3 and A4.
#
#   A3  every TESTED_TREE_MARKERS entry in build-openbios.sh names a file that
#       patches/TESTED-TREE.patch touches, a string that patch actually ADDS, and
#       — A3b — a string that is NOT already in the pristine upstream file.
#   A6  the RECORD and the BUILT divergence name the SAME files: every file in
#       patches/TESTED-TREE.patch is described by some patches/NN-*.patch, and
#       every file a numbered patch touches is in what actually gets applied.
#   A7  patches/00-CATALOG.md and the series describe the same patches: one row
#       each, a kind from the vocabulary the DOCUMENT defines, a scope column
#       recomputed from the patch's own files, and summary counts recomputed
#       from the rows.
#   A8  the NARRATIVE above those tables repeats none of their counts -- prose
#       says "all of them", the table says how many -- and names the commit
#       build-openbios.sh actually checks out. A7 guarded the tables; the five
#       stale numbers and the wrong SHA were all in the paragraphs above them.
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
# convention, it is correctness, and every patch is held to it.
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
# WHY A3b IS A SEPARATE QUESTION, learned the expensive way. A3 asked "does the
# patch add this string?" and `s" load-base"` passes: patch 01 adds exactly that
# line for x86. But the marker's semantics are PRESENT => APPLIED, and that string
# is in the pristine file three times already (the ppc, sparc32 and sparc64 arms).
# So a cold clone matched 1 of 8 markers and build-openbios.sh refused every build
# with "the revival patch is HALF applied". The lab never saw it because every
# working copy here has been patched since the day it was made; TODO §14's Tier B
# found it on the first cold checkout this lab has ever had.
#
# A3 was asking a true thing that was not the question. A3b asks the question:
# fetch the file at the pinned commit and require the marker to be ABSENT. That
# needs the network, so it SKIPS when the fetch fails rather than passing — an
# unchecked marker is an UNKNOWN, and this whole file exists because an unchecked
# marker was read as a checked one.
#
# WHY --numstat AND NOT A HAND-ROLLED PARSER. `git apply --numstat` is git's own
# diff reader; it validates structure without needing the target files and
# exits non-zero on a corrupt patch. Extract the shipped thing, never
# re-implement it: a private parser would drift and then prove something about
# itself.
#
# §0 proves the scanner on must-catch and must-not-catch shapes BEFORE it is
# aimed at a real file. It does NOT say how many here: this comment said "5 and
# 5" while §0's own summary line said "17 and 9", and both were typed by hand.
# The run counts them as they fire and prints the tally itself -- which is A8's
# rule applied to the file that enforces it.
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
    done < <(sed -n '/^TESTED_TREE_MARKERS=(/,/^)/p' "$build" | sed -n 's/^[[:space:]]*["'"'"']\(.*\)["'"'"']$/\1/p')
    if (( n == 0 )); then
        PROBLEMS+="no TESTED_TREE_MARKERS entries were extracted from $(basename "$build") — the array moved or changed shape, and this check is asserting nothing"$'\n'
    fi
    NMARK="$n"
}

# A3b: the marker must be ABSENT from the pinned upstream file. Sets A3B to the
# number checked, or leaves it empty when the network is unavailable.
A3B=""
NEWFILES=""
check_markers_pristine() {
    local build="$1" pin url line f pat body code n=0
    pin="$(sed -n 's/^OPENBIOS_PIN=\([0-9a-f]\{40\}\)$/\1/p' "$build" | head -1)"
    if [[ -z "$pin" ]]; then
        PROBLEMS+="A3b: no 40-character OPENBIOS_PIN in $(basename "$build"), so the pristine file cannot be identified — either the pin was removed or its shape changed"$'\n'
        return
    fi
    command -v curl >/dev/null || { note "A3b SKIPPED: curl is not installed — the markers are UNCHECKED against the pristine tree, which is an UNKNOWN and not a pass"; return; }
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        f="${line%%:*}"; pat="${line#*:}"
        url="https://raw.githubusercontent.com/openbios/openbios/$pin/$f"
        # A 404 is not a network failure, it is an ANSWER: the file does not
        # exist at the pin, so the marker cannot possibly be in it and the check
        # passes trivially. Distinguishing the two matters now that the markers
        # span the amd64 port, several of whose files the patch CREATES —
        # `curl -f` alone turns every one of those into a SKIP, and a SKIP that
        # is really a pass teaches the reader to ignore the SKIP that is really
        # an unknown.
        code="$(timeout 30 curl -sSL -o "$WORK/a3b.body" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
        if [[ "$code" == 404 ]]; then
            n=$((n + 1)); NEWFILES="$NEWFILES $f"; continue
        fi
        if [[ "$code" != 200 ]]; then
            note "A3b SKIPPED after $n marker(s): fetching $f at ${pin:0:7} returned '$code' — the rest are UNCHECKED against the pristine tree, which is an UNKNOWN and not a pass"
            return
        fi
        body="$(cat "$WORK/a3b.body")"
        n=$((n + 1))
        if grep -qF -- "$pat" <<<"$body"; then
            PROBLEMS+="marker '$f' looks for '$pat', which is ALREADY IN the pristine file at ${pin:0:7} — the marker means \"present => applied\", so it matches an unpatched tree and makes every cold clone read as half-applied"$'\n'
        fi
    done < <(sed -n '/^TESTED_TREE_MARKERS=(/,/^)/p' "$build" | sed -n 's/^[[:space:]]*["'"'"']\(.*\)["'"'"']$/\1/p')
    A3B="$n"
}

# A6: the RECORD and the BUILT divergence must name the same files.
#
# The lab keeps two artifacts describing one divergence: patches/NN-*.patch are
# READ (one annotated change each), patches/TESTED-TREE.patch is APPLIED. That
# is bug class #1 in CLAUDE.md — a record that outlives its subject — and the
# gap is invisible from either side on its own: the numbered patches all parse,
# the build all works, and nothing compares them.
#
# It found one on the day the split was introduced (2026-08-27):
# arch/amd64/boot.h was in the applied patch and in NO numbered patch, while
# arch/amd64/boot.c had been `#include`-ing it since Spike 1. The port was
# compiling against a file the record did not mention.
#
# Both directions are errors, and they are different errors. Built-but-unrecorded
# ships a change with no account of why. Recorded-but-unbuilt is worse: it is a
# document describing firmware nobody runs.
A6_BUILT=0; A6_REC=0
check_record_covers_build() {
    local lab="$1" tt="$1/patches/TESTED-TREE.patch"
    local built recorded only_built only_rec p
    if [[ ! -f "$tt" ]]; then
        PROBLEMS+="A6: patches/TESTED-TREE.patch is missing — it is the patch build-openbios.sh applies, so a clean checkout would build pristine upstream and the whole record would describe firmware nobody runs"$'\n'
        return
    fi
    built="$(touched_files "$tt")"
    recorded="$(for p in "$lab"/patches/[0-9][0-9]-*.patch; do [[ -f "$p" ]] && touched_files "$p"; done | sort -u)"
    A6_BUILT="$(printf '%s\n' "$built"    | grep -c . || true)"
    A6_REC="$(  printf '%s\n' "$recorded" | grep -c . || true)"
    only_built="$(comm -23 <(printf '%s\n' "$built") <(printf '%s\n' "$recorded"))"
    only_rec="$(  comm -13 <(printf '%s\n' "$built") <(printf '%s\n' "$recorded"))"
    [[ -z "$only_built" ]] \
        || PROBLEMS+="A6: built but named by NO numbered patch, so the change ships with no record of why it exists: $(tr '\n' ' ' <<<"$only_built")"$'\n'
    [[ -z "$only_rec" ]] \
        || PROBLEMS+="A6: recorded in a numbered patch but NOT in what is applied, so the record describes firmware nobody builds: $(tr '\n' ' ' <<<"$only_rec")"$'\n'
}

# A7: the CATALOG and the series must describe the same patches. (How many is
# not written here: see A8, and the reason it exists.)
#
# patches/00-CATALOG.md records the 2026-08-28 decision that none of this goes
# upstream, and sorts every patch by why it exists. That makes it a third record
# of one subject -- alongside the numbered patches and TESTED-TREE.patch -- and
# a record nothing checks is bug class #1 waiting to happen. A6 already binds
# the other two together; A7 binds this one to them.
#
# It checks four things, and only ONE of them is about the prose:
#
#   * the bijection: every NN-*.patch has exactly one row, every row names a
#     patch that exists. A patch added without a row is a divergence nobody
#     classified; a row left behind is a document describing a diff nobody has.
#   * the kind is drawn from the vocabulary THE DOCUMENT ITSELF defines. The
#     list is not hard-coded here: it is read out of the doc's own kind table,
#     and the three places kinds appear (that table, the rows, the summary) must
#     name the identical set. A checker carrying its own copy of the vocabulary
#     would drift from the doc and then prove something about itself.
#   * the scope column is RECOMPUTED from each patch's own file list and must
#     match. `arch-local` iff every touched path is under arch/, include/arch/,
#     or config/examples/<arch>_config.xml. This is the column a reader uses to
#     predict rebase pain at the next pin bump, and a hand-maintained answer to
#     "which files does this patch touch?" is a cached fact about a file that
#     changes.
#   * the summary counts are recomputed from the rows. "Don't write the test
#     count in prose" (CLAUDE.md) -- and this one earned it on the day it was
#     written: the hand-tallied table said 22 UPSTREAM-BUG and 9 PORT where the
#     rows say 20 and 10. Two numbers, wrong within an hour of being typed.
CAT_ROWS=0
patch_scope() { # patch_scope <patch> -> arch-local | shared
    if touched_files "$1" | grep -qvE '^arch/|^include/arch/|^config/examples/[a-z0-9_]+_config\.xml$'; then
        printf 'shared\n'
    else
        printf 'arch-local\n'
    fi
}
check_catalog() {
    local lab="$1" cat="$1/patches/00-CATALOG.md"
    local rows vocab used sums p base kind scope want n
    if [[ ! -f "$cat" ]]; then
        PROBLEMS+="A7: patches/00-CATALOG.md is missing — the series has no record of which divergences are deliberate and why none is sent upstream"$'\n'
        return
    fi
    # rows: | [`NN-name.patch`](NN-name.patch) | `KIND` | scope | text |
    rows="$(sed -n 's/^| \[`\([0-9][0-9]-[^`]*\.patch\)`\]([^)]*) | `\([A-Z-]*\)` | \([a-z-]*\) |.*/\1 \2 \3/p' "$cat")"
    CAT_ROWS="$(printf '%s\n' "$rows" | grep -c . || true)"
    if (( CAT_ROWS == 0 )); then
        PROBLEMS+="A7: no catalog rows parsed out of 00-CATALOG.md — the table moved or changed shape, and every check below it is asserting nothing"$'\n'
        return
    fi
    # the vocabulary the DOCUMENT defines, and the two places it is used again
    vocab="$(sed -n 's/^| `\([A-Z-]\+\)` | [a-z].*/\1/p' "$cat" | sort -u)"
    used="$( printf '%s\n' "$rows" | awk '{print $2}' | sort -u)"
    sums="$(sed -n 's/^| `\([A-Z-]\+\)` | \([0-9]\+\) |.*/\1/p' "$cat" | sort -u)"
    [[ "$vocab" == "$used" ]] \
        || PROBLEMS+="A7: the kinds the rows USE and the kinds the doc DEFINES are different sets — defined: $(tr '\n' ' ' <<<"$vocab")/ used: $(tr '\n' ' ' <<<"$used")"$'\n'
    [[ "$vocab" == "$sums" ]] \
        || PROBLEMS+="A7: the summary table and the kind table name different sets — a kind was added or renamed in one and not the other"$'\n'
    # bijection + per-row scope
    while read -r base kind scope; do
        [[ -z "$base" ]] && continue
        p="$lab/patches/$base"
        if [[ ! -f "$p" ]]; then
            PROBLEMS+="A7: 00-CATALOG.md has a row for $base, which is not in patches/ — the catalog describes a diff nobody has"$'\n'
            continue
        fi
        want="$(patch_scope "$p")"
        [[ "$scope" == "$want" ]] \
            || PROBLEMS+="A7: $base is catalogued '$scope' but its files make it '$want' — recomputed from the patch, which is the only thing that knows"$'\n'
    done <<<"$rows"
    for p in "$lab"/patches/[0-9][0-9]-*.patch; do
        [[ -f "$p" ]] || continue
        base="$(basename "$p")"
        n="$(printf '%s\n' "$rows" | awk -v b="$base" '$1 == b' | grep -c . || true)"
        (( n == 1 )) \
            || PROBLEMS+="A7: $base has $n rows in 00-CATALOG.md (want exactly 1) — an unclassified patch is a divergence nobody decided to carry"$'\n'
    done
    # the counts, recomputed -- BOTH summaries. The kind table drifted within an
    # hour of being typed; the scope table is the same shape and gets the same
    # treatment rather than waiting its turn.
    local nsum=0
    while read -r kind n; do
        [[ -z "$kind" ]] && continue
        nsum=$((nsum + 1))
        want="$(printf '%s\n' "$rows" | awk -v k="$kind" '$2 == k' | grep -c . || true)"
        (( n == want )) \
            || PROBLEMS+="A7: the summary says $n $kind row(s); there are $want — a count written in prose, drifting"$'\n'
    done < <(sed -n 's/^| `\([A-Z-]\+\)` | \([0-9]\+\) |.*/\1 \2/p' "$cat")
    while read -r sc n; do
        [[ -z "$sc" ]] && continue
        nsum=$((nsum + 1))
        want="$(printf '%s\n' "$rows" | awk -v k="$sc" '$3 == k' | grep -c . || true)"
        (( n == want )) \
            || PROBLEMS+="A7: the scope summary says $n $sc row(s); there are $want — the column that predicts a rebase conflict, counted wrong"$'\n'
    done < <(sed -n 's/^| \(shared\|arch-local\) | \([0-9]\+\) |.*/\1 \2/p' "$cat")
    (( nsum > 0 )) \
        || PROBLEMS+="A7: no summary counts parsed out of 00-CATALOG.md — the tables moved or changed shape, so nothing below is being counted at all"$'\n'
}

# A8: the NARRATIVE above the tables, which is where A7 was not looking.
#
# A7 recomputes every number in 00-CATALOG.md's two summary TABLES, and has done
# since the day the hand-tallied kind table drifted within an hour of being
# typed. It says of itself that "only ONE of [its four checks] is about the
# prose" -- and the one it means is those tables. The paragraphs ABOVE them were
# never read by anything.
#
# So they drifted, in exactly the way the tables were stopped from drifting.
# Measured 2026-08-30, with the checker green: the page opened "## The decision:
# all 41 are ours", said a pin bump "re-applies all 41", split them "22 of 41"
# shared against "The 19 arch-local rows", and closed on "what 'all 41 are ours'
# means" -- while its own summary tables, four inches lower and machine-checked,
# added up to 53. FIVE stale numbers on a page whose whole subject is numbers
# that go stale, and CI could not see one of them.
#
# THE FIX IS NOT TO CHECK THE PROSE'S ARITHMETIC. A second checked copy of a
# count is still a second copy; it merely fails loudly instead of quietly. The
# rule is the repo's own -- derive the fact, don't cache it -- so the narrative
# carries NO count, the summary tables are the single place counts live, and A8
# enforces the absence rather than the value. Prose says "all of them"; the
# table says how many.
#
# An absence rule cannot silently stop matching, which is why it is preferable
# to anchoring on sentences: a scan for a phrase that has been reworded goes
# green having read nothing, and that is the failure this file's §0 exists for.
#
# AND THE PIN, which is the other half. The catalog's first sentence names the
# commit every patch is a diff against -- and it named `6e563ee`, which is
# fcode-utils' pin. openbios' is `e5ac46d`. One wrong identity, in the single
# document whose job is to say what these diffs apply to, found the same day.
# It is read out of build-openbios.sh rather than kept here: a second copy of a
# SHA is a cache of the first.
#
# THE SENTENCE THAT NAMES IT SPANS TWO LINES ("...against the pinned commit\n
# `6e563ee`."), so the scan flattens the narrative before looking. A
# line-anchored regex standing in for a question about a SENTENCE is how
# check-harness-net.sh was wrong twice; it is not repeated here.
CAT_PIN=""
check_catalog_narrative() {
    local lab="$1" cat="$1/patches/00-CATALOG.md" build="$1/build-openbios.sh"
    local narr flat pin cpin hit
    [[ -f "$cat" ]] || return   # A7 already reported the absence
    if ! grep -q '^## The series' "$cat"; then
        PROBLEMS+="A8: 00-CATALOG.md has no '## The series' heading — that heading is where the narrative ends and the table begins, so nothing below can tell prose from rows"$'\n'
        return
    fi
    narr="$(sed '/^## The series/,$d' "$cat")"

    # (1) no count-shaped claim in the PROSE -- every line that is not a table
    # row, above the series table and below it alike. Each pattern is a SHAPE a
    # patch count takes in a sentence, not a phrase: "all 41", "22 of 41",
    # "41 patches", "19 arch-local rows", "the other 48", "23 bug fixes".
    #
    # It is scoped to non-`|` lines rather than to the narrative because the
    # first draft WAS narrative-only, and the paragraphs BELOW the summary
    # tables turned out to carry more stale numbers ("the other 48", "behind 23
    # bug fixes"). A rule aimed at the half of the document where the bug was
    # found is a rule that has already been outflanked once.
    #
    # AND IT IS FLATTENED, for the reason the pin check is. The line-based
    # version of this scan MISSED "behind 23 bug\nfixes" in the real file --
    # markdown wraps, so half these phrases straddle a line break. That is the
    # fourth time in this repo a line-anchored pattern has stood in for a
    # question about a sentence, and it was caught here only because the
    # document it was aimed at happened to contain the wrapped case.
    hit="$(grep -vE '^\|' "$cat" | tr '\n' ' ' \
        | grep -oE '\ball [0-9]+\b|\bother [0-9]+\b|[0-9]+ of [0-9]+|[0-9]+ patches\b|[0-9]+ [a-z-]* ?(fixes|rows)\b|[0-9]+ (`?(arch-local|shared)`? )?rows\b' || true)"
    if [[ -n "$hit" ]]; then
        PROBLEMS+="A8: 00-CATALOG.md's prose carries a count its summary tables already hold — $(tr '\n' '/' <<<"$hit" | sed 's:/$::') — and a count in prose is a cache that goes stale while the checked table stays right (five did, 2026-08-30). Say 'all of them' and let the table say how many"$'\n'
    fi

    # (2) the commit the patches are against, derived from the build.
    flat="$(printf '%s' "$narr" | tr '\n' ' ')"
    # grep -o, not a `.*`-anchored sed: on a flattened document a leading `.*`
    # is greedy and would silently read the LAST "pinned commit" in the file
    # rather than the first. Take the first match explicitly.
    cpin="$(grep -oE 'pinned commit[^`]*`[0-9a-f]{7,40}`' <<<"$flat" | head -1 | grep -oE '[0-9a-f]{7,40}')"
    pin=""
    [[ -f "$build" ]] && pin="$(sed -n 's/^OPENBIOS_PIN=\([0-9a-f]\{40\}\)$/\1/p' "$build" | head -1)"
    if [[ -z "$pin" ]]; then
        PROBLEMS+="A8: no OPENBIOS_PIN in $(basename "$build") — the catalog's base commit has nothing to be checked against, and an unchecked identity is what put fcode-utils' SHA in this document"$'\n'
    elif [[ -z "$cpin" ]]; then
        PROBLEMS+="A8: 00-CATALOG.md's narrative no longer names the pinned commit its patches are diffs against — the record and the tree it applies to are unbound"$'\n'
    elif [[ "$pin" != "$cpin"* ]]; then
        PROBLEMS+="A8: 00-CATALOG.md says the patches are against commit '$cpin'; build-openbios.sh checks out '${pin:0:7}' — the catalog is naming a different tree than the one every patch was made from"$'\n'
    else
        CAT_PIN="$cpin"
    fi
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
mk_build() { printf 'TESTED_TREE_MARKERS=(\n%s)\n' "$1" > "$2"; }
c_ok=0; c_bad=0; c_catch=0; c_clean=0
expect() {
    local want="$1" label="$2"
    if [[ "$want" == catch ]]; then
        c_catch=$((c_catch+1))
        if [[ -n "$PROBLEMS" ]]; then c_ok=$((c_ok+1)); else c_bad=$((c_bad+1)); note "§0 MISSED: $label"; fi
    else
        c_clean=$((c_clean+1))
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

# ── §0: A6's own controls ───────────────────────────────────────────────────
# A6 compares two file sets, and a set comparison that silently compares nothing
# is the all-PASS-proves-nothing shape: an empty `built` and an empty `recorded`
# agree perfectly. So it is aimed at four fixture labs — one that agrees, and one
# for each way they can disagree — before it is aimed at the real one.
mk_tt() { # mk_tt <lab> <file>...
    local lab="$1"; shift; local f
    mkdir -p "$lab/patches"
    : > "$lab/patches/TESTED-TREE.patch"
    for f in "$@"; do
        printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1,1 +1,2 @@\n ctx\n+x\n' \
            "$f" "$f" "$f" "$f" >> "$lab/patches/TESTED-TREE.patch"
    done
}
mk_tt "$WORK/lab-agree" src/a.c src/b.c
mk_patch "$WORK/lab-agree/patches/01-a.patch" 01 2 "src/a.c" "x"
mk_patch "$WORK/lab-agree/patches/02-b.patch" 02 2 "src/b.c" "x"
check_record_covers_build "$WORK/lab-agree"; expect clean "record and applied patch name the same files"

# the real 2026-08-27 defect: a file is built and no numbered patch mentions it
mk_tt "$WORK/lab-unrecorded" src/a.c src/b.c
mk_patch "$WORK/lab-unrecorded/patches/01-a.patch" 01 1 "src/a.c" "x"
check_record_covers_build "$WORK/lab-unrecorded"; expect catch "a file is BUILT but named by no numbered patch (the arch/amd64/boot.h shape)"

# the opposite: the record describes a change nothing applies
mk_tt "$WORK/lab-unbuilt" src/a.c
mk_patch "$WORK/lab-unbuilt/patches/01-a.patch" 01 2 "src/a.c" "x"
mk_patch "$WORK/lab-unbuilt/patches/02-b.patch" 02 2 "src/b.c" "x"
check_record_covers_build "$WORK/lab-unbuilt"; expect catch "a file is RECORDED but not in what is applied"

mkdir -p "$WORK/lab-nott/patches"
mk_patch "$WORK/lab-nott/patches/01-a.patch" 01 1 "src/a.c" "x"
check_record_covers_build "$WORK/lab-nott"; expect catch "patches/TESTED-TREE.patch is absent entirely"

# ── §0: A7's own controls ───────────────────────────────────────────────────
# The catalog is prose about diffs, and every column of it can be wrong while
# the file still renders perfectly. So the scanner is aimed at a coherent
# fixture and at one fixture per way the prose can drift from the patches,
# BEFORE it is aimed at the real 00-CATALOG.md.
#
# The scope rows matter most: `arch-local` vs `shared` is the column a reader
# uses to predict a rebase, it is derived from a file list that changes, and a
# wrong answer there looks exactly like a right one.
mk_cat_lab() { # mk_cat_lab <lab> <catalog-body>
    local lab="$1" body="$2"
    mkdir -p "$lab/patches"
    mk_patch "$lab/patches/01-a.patch" 01 2 "arch/x86/a.c" "x"   # -> arch-local
    mk_patch "$lab/patches/02-b.patch" 02 2 "libc/b.c"     "y"   # -> shared
    printf '%s' "$body" > "$lab/patches/00-CATALOG.md"
}
CAT_VOCAB='| `PORT` | a port |
| `FIXTURE` | a fixture |
'
CAT_SUMS='| `PORT` | 1 |
| `FIXTURE` | 1 |
'
mk_cat_lab "$WORK/cat-ok" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | arch-local | it is a port |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
$CAT_SUMS"
check_catalog "$WORK/cat-ok"; expect clean "a catalog whose rows, kinds, scopes and counts all agree with the patches"

mk_cat_lab "$WORK/cat-missing" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | arch-local | it is a port |
| \`PORT\` | 1 |
| \`FIXTURE\` | 0 |"
check_catalog "$WORK/cat-missing"; expect catch "a patch on disk with NO catalog row — an unclassified divergence"

mk_cat_lab "$WORK/cat-orphan" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | arch-local | it is a port |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
| [\`03-gone.patch\`](03-gone.patch) | \`PORT\` | shared | it is not there |
| \`PORT\` | 2 |
| \`FIXTURE\` | 1 |"
check_catalog "$WORK/cat-orphan"; expect catch "a catalog row naming a patch that does not exist"

mk_cat_lab "$WORK/cat-scope" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | shared | it only touches arch/x86 |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
$CAT_SUMS"
check_catalog "$WORK/cat-scope"; expect catch "a scope column that disagrees with the patch's own file list"

mk_cat_lab "$WORK/cat-count" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | arch-local | it is a port |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
| \`PORT\` | 2 |
| \`FIXTURE\` | 1 |"
check_catalog "$WORK/cat-count"; expect catch "a summary count written in prose and drifted from the rows"

mk_cat_lab "$WORK/cat-scopecount" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | arch-local | it is a port |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
$CAT_SUMS| shared | 2 |
| arch-local | 1 |"
check_catalog "$WORK/cat-scopecount"; expect catch "a SCOPE summary count drifted from the rows"

mk_cat_lab "$WORK/cat-scopeok" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`PORT\` | arch-local | it is a port |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
$CAT_SUMS| shared | 1 |
| arch-local | 1 |"
check_catalog "$WORK/cat-scopeok"; expect clean "a catalog carrying BOTH summaries, each agreeing with the rows"

mk_cat_lab "$WORK/cat-kind" "$CAT_VOCAB
| [\`01-a.patch\`](01-a.patch) | \`DIVERGENCE\` | arch-local | a kind the doc never defines |
| [\`02-b.patch\`](02-b.patch) | \`FIXTURE\` | shared | it is a fixture |
$CAT_SUMS"
check_catalog "$WORK/cat-kind"; expect catch "a row using a kind the document's own vocabulary does not define"

mkdir -p "$WORK/cat-none/patches"
mk_patch "$WORK/cat-none/patches/01-a.patch" 01 1 "arch/x86/a.c" "x"
check_catalog "$WORK/cat-none"; expect catch "no 00-CATALOG.md at all"

# The all-PASS-proves-nothing shape: if the table is reshaped so no row parses,
# every check above it silently has nothing to say.
mk_cat_lab "$WORK/cat-shape" "$CAT_VOCAB
* 01-a.patch -- PORT -- arch-local
* 02-b.patch -- FIXTURE -- shared
$CAT_SUMS"
check_catalog "$WORK/cat-shape"; expect catch "a reshaped table out of which no row parses — the scanner must say so, not pass"

# ── §0: A8's own controls ───────────────────────────────────────────────────
# A8 is an ABSENCE rule, and an absence rule has two ways to be useless: it can
# miss the shapes a count actually takes, and it can fire on the ordinary
# numbers a document about a patch series is full of (dates, patch numbers,
# ranges). Both directions are fixtured here.
mk_narr_lab() { # mk_narr_lab <lab> <narrative> <pin-line> [prose-AFTER-the-tables]
    local lab="$1" narr="$2" pinline="$3" tail="${4:-the taxonomy is left thin on purpose.}"
    mkdir -p "$lab/patches"
    mk_patch "$lab/patches/01-a.patch" 01 2 "arch/x86/a.c" "x"
    mk_patch "$lab/patches/02-b.patch" 02 2 "libc/b.c"     "y"
    printf '%s\n\n## The series\n\n%s\n| [`01-a.patch`](01-a.patch) | `PORT` | arch-local | it is a port |\n| [`02-b.patch`](02-b.patch) | `FIXTURE` | shared | it is a fixture |\n%s\n%s\n' \
        "$narr" "$CAT_VOCAB" "$CAT_SUMS" "$tail" > "$lab/patches/00-CATALOG.md"
    printf 'OPENBIOS_PIN=%s\n' "$pinline" > "$lab/build-openbios.sh"
}
GOODPIN=e5ac46dd24e6216c36aa80462af25457e7029440

NARR_OK='`patches/` holds one annotated diff per change against the pinned commit
`e5ac46d`.

## The decision (2026-08-28): all of them are ours

Upstream carries commits dated 2026-06-29. Every patch from patch 20 onward has
an `Arch-tested:` line, and the narrative for patches 12-34 lives in the README.
The `shared` rows below are where a rebase will land; the summary says how many.'

mk_narr_lab "$WORK/narr-ok" "$NARR_OK" "$GOODPIN"
check_catalog_narrative "$WORK/narr-ok"
expect clean "a narrative with dates, 'patch 20 onward' and a patch RANGE, carrying no count and the right pin"

mk_narr_lab "$WORK/narr-all" "${NARR_OK/all of them are ours/all 41 are ours}" "$GOODPIN"
check_catalog_narrative "$WORK/narr-all"
expect catch "'all 41 are ours' — the exact shape that drifted to 53 with CI green"

mk_narr_lab "$WORK/narr-of" "$NARR_OK
The **22 of 41** shared rows are where it hurts." "$GOODPIN"
check_catalog_narrative "$WORK/narr-of"
expect catch "'22 of 41' — a split written in prose beside a table that recomputes it"

mk_narr_lab "$WORK/narr-rows" "$NARR_OK
The 19 \`arch-local\` rows are nearly free to carry." "$GOODPIN"
check_catalog_narrative "$WORK/narr-rows"
expect catch "'The 19 arch-local rows' — a row count in prose"

mk_narr_lab "$WORK/narr-patches" "$NARR_OK
A pin bump means re-reading 41 patches." "$GOODPIN"
check_catalog_narrative "$WORK/narr-patches"
expect catch "'41 patches' — the same count wearing a different noun"

# The two shapes that outflanked the first draft: prose BELOW the summary
# tables, which a narrative-only scan never reads.
mk_narr_lab "$WORK/narr-tail-other" "$NARR_OK" "$GOODPIN" \
    "Only one is a divergence; the other 48 are things upstream would want."
check_catalog_narrative "$WORK/narr-tail-other"
expect catch "'the other 48' — a count in the prose BELOW the tables, where the first draft did not look"

mk_narr_lab "$WORK/narr-tail-fixes" "$NARR_OK" "$GOODPIN" \
    "Collapsing them would hide the divergence behind 23 bug fixes."
check_catalog_narrative "$WORK/narr-tail-fixes"
expect catch "'behind 23 bug fixes' — the same count as a different noun, also below the tables"

# THE WRAPPED CASE, which the line-based first draft missed in the real file:
# markdown wraps, so the count and its noun land on different lines.
mk_narr_lab "$WORK/narr-tail-wrap" "$NARR_OK" "$GOODPIN" \
    "Collapsing them would hide the only divergence behind 23 bug
fixes."
check_catalog_narrative "$WORK/narr-tail-wrap"
expect catch "a count SPLIT ACROSS A LINE BREAK ('23 bug\\nfixes') — the shape a line-anchored scan reads as clean"

mk_narr_lab "$WORK/narr-wrongpin" "${NARR_OK/e5ac46d/6e563ee}" "$GOODPIN"
check_catalog_narrative "$WORK/narr-wrongpin"
expect catch "the catalog naming fcode-utils' pin as the commit these diffs apply to — the real defect, 2026-08-30"

mk_narr_lab "$WORK/narr-nopin" "${NARR_OK/against the pinned commit
\`e5ac46d\`./against upstream.}" "$GOODPIN"
check_catalog_narrative "$WORK/narr-nopin"
expect catch "a catalog that names no base commit at all — the record unbound from the tree it applies to"

mk_narr_lab "$WORK/narr-nobuild" "$NARR_OK" "$GOODPIN"
rm -f "$WORK/narr-nobuild/build-openbios.sh"
check_catalog_narrative "$WORK/narr-nobuild"
expect catch "no OPENBIOS_PIN to check against — an unchecked identity is how the wrong SHA got in"

mk_narr_lab "$WORK/narr-noseries" "$NARR_OK" "$GOODPIN"
sed -i '/^## The series/d' "$WORK/narr-noseries/patches/00-CATALOG.md"
check_catalog_narrative "$WORK/narr-noseries"
expect catch "the heading that separates prose from rows is gone — the scan can no longer tell them apart"

# The two-line sentence, which is how the real file is written and how a
# line-anchored scan would go green having read nothing.
mk_narr_lab "$WORK/narr-split" "\`patches/\` holds one diff per change against the pinned commit
\`6e563ee\`.

## The decision: all of them are ours" "$GOODPIN"
check_catalog_narrative "$WORK/narr-split"
expect catch "a WRONG pin split across two lines — the shape a line-anchored regex misses"

(( c_bad == 0 )) \
    || fail "§0: $c_bad of $((c_ok + c_bad)) scanner controls behaved wrongly — nothing below its verdict means anything"
# The fixtures used the exemption too; clear what they recorded, or the report
# below names a temp file as a grandfathered patch.
EXEMPT_USED=""
note "§0 controls: $c_catch must-catch, $c_clean must-not-catch — all $c_ok behaved (counted as they ran; this line used to carry the tally by hand, which is the defect A8 exists for)"

# ---------------------------------------------------------------- the real files

LAB="${1:-}"
[[ -n "$LAB" && -d "$LAB/patches" ]] || fail "usage: check-patch-hygiene.sh <lab-dir>  (needs <lab-dir>/patches)"
BUILD="$LAB/build-openbios.sh"
[[ -f "$BUILD" ]] || fail "no build-openbios.sh in $LAB — A3 has nothing to read the markers from"

mapfile -t PATCHES < <(find "$LAB/patches" -maxdepth 1 -name '[0-9][0-9]-*.patch' | sort)
(( ${#PATCHES[@]} > 0 )) || fail "no NN-*.patch files in $LAB/patches — every check below would run over nothing"

PTT="$LAB/patches/TESTED-TREE.patch"
[[ -f "$PTT" ]] || fail "patches/TESTED-TREE.patch is missing — it is the patch build-openbios.sh applies, and the markers describe it"
check_markers "$BUILD" "$PTT"
check_markers_pristine "$BUILD"
check_record_covers_build "$LAB"
check_catalog "$LAB"
check_catalog_narrative "$LAB"

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
note "A3: $NMARK markers, each naming a file TESTED-TREE.patch touches and a string it adds"
if [[ -n "$A3B" ]]; then
    note "A3b: $A3B of them also checked against the PRISTINE file at the pinned commit, and absent from it"
    [[ -n "$NEWFILES" ]] && note "A3b: absent because the patch CREATES the file (404 at the pin, which is an answer and not a skip):$NEWFILES"
fi
note "A6: the record and the applied patch agree on all $A6_BUILT files"
note "A7: 00-CATALOG.md classifies all $CAT_ROWS patches — kinds, scopes and counts all recomputed from the patches themselves"
note "A8: its narrative carries no count of its own, and names commit ${CAT_PIN:-?} — read out of build-openbios.sh, not out of this checker"
note "A4: ${#PATCHES[@]} patches parse as unified diffs, subjects agree with filenames, series is 01..${#PATCHES[@]}"
if [[ -n "$EXEMPT_USED" ]]; then
    note "A4: no Subject: line on ${EXEMPT_USED% } — grandfathered BY NAME (the convention began at patch 11), printed here so the exemption cannot grow unnoticed"
fi
pass "the patch series is coherent with itself, with what is applied, and with the build: $NMARK markers describe strings the applied patch actually adds, and all ${#PATCHES[@]} patches read as unified diffs numbered 01..${#PATCHES[@]} with subjects that match their filenames, and the record and the applied TESTED-TREE.patch name the same $A6_BUILT files, and 00-CATALOG.md classifies all $CAT_ROWS of them with scopes and counts recomputed rather than read, its narrative repeating none of those counts and naming the pin the build actually checks out ($((c_catch + c_clean)) scanner self-controls fired first)"
