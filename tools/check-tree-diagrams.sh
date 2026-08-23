#!/usr/bin/env bash
# check-tree-diagrams.sh — a filename in an ASCII tree is a promise. Keep it.
#
# WHY (TODO A.5). Four files the micro-cloud docs listed had never existed, and the checkers
# were green the whole time: all four were named in **ASCII tree diagrams inside code
# fences**. `link_check.py` validates markdown LINKS, and a filename in a tree is no more a
# link than a filename in a sentence. The honest fix at the time was to move the absent ones
# out of the tree and into prose beneath it — correct, but not checkable, which is why A.5
# asks for this: MICRO_CLOUD_LAB_PLAN.md §16 q6's *"what else in this document describes
# something that does not exist?"*, made mechanical.
#
# WHAT COUNTS AS A PROMISE. An entry in a tree that is not:
#   * gitignored (build output — `images/` is a real directory this repo declines to track,
#     and calling it a broken promise would be a lie about a lab that works);
#   * a glob (`RUNBOOK-*.md` promises "at least one", and is checked as that);
#   * a placeholder (`<name>/`, `{a,b}`), an annotation arrow, or a comment.
#
# Own verdict helpers on purpose. §0 proves the extractor on must-catch/must-not-catch
# shapes BEFORE it reads a real document — CLAUDE.md, "The control is where the bugs are".
set -uo pipefail

REPO="${REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" || { echo "FAIL: cannot cd to repo root" >&2; exit 1; }
_V=0
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip() { _V=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    (( rc != 0 && rc != 77 )) && (( _V == 0 )) && \
        printf 'FAIL: check-tree-diagrams.sh exited early (rc=%d) — no verdict\n' "$rc" >&2
    return 0
}
trap _on_exit EXIT
command -v git >/dev/null 2>&1 || skip "git not available"
WORK="$(mktemp -d)"

# tree_entries <file> — prints one bare entry name per tree line found in a fenced block.
tree_entries() {
    # Per FENCED BLOCK, split into segments on blank lines, and consider only the segments
    # that actually contain a branch glyph. One fence can hold several trees (PLAN-PXEBOOT.md
    # §7 holds two), and the earlier running-reset version emitted a "root" for every fenced
    # block in the repo -- so its count of skipped blocks read 4632, which is every code
    # fence rather than every tree. A number that large is its own tell.
    awk '
        /^[[:space:]]*```/ {
            if (infence) { flush(); infence = 0 } else { infence = 1; n = 0 }
            next
        }
        infence { buf[n++] = $0; next }
        END { if (infence) flush() }

        function flush(   i, seg, segn, has, root, line, j) {
            segn = 0; has = 0
            for (i = 0; i < n; i++) {
                if (buf[i] !~ /[^[:space:]]/) {          # blank line ends a segment
                    if (has) emit_segment(seg, segn)
                    segn = 0; has = 0; delete seg
                    continue
                }
                seg[segn++] = buf[i]
                if (buf[i] ~ /[├└]──/) has = 1
            }
            if (has) emit_segment(seg, segn)
            n = 0
        }
        function emit_segment(seg, segn,   i, root, line) {
            root = ""
            for (i = 0; i < segn; i++) {
                if (seg[i] !~ /[├└│]/) {                 # the first non-glyph line is the root
                    root = seg[i]
                    sub(/^[[:space:]]+/, "", root); sub(/[[:space:]].*$/, "", root)
                    break
                }
            }
            print "ROOT\t" root
            for (i = 0; i < segn; i++) {
                line = seg[i]
                if (line !~ /[├└]──/) continue
                # AN ENTRY MARKED ABSENT IS NOT A BROKEN PROMISE -- it is the fix. A.5 closed
                # its own finding by annotating unbuilt files (`NOT BUILT`), and a checker
                # that reported those would punish the remedy it exists to encourage.
                if (line ~ /NOT BUILT|not built|not yet|NOT YET|\(later\)|planned|PLANNED|TODO|⚠/) continue
                sub(/^.*[├└]──[[:space:]]*/, "", line)
                sub(/[[:space:]].*$/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (line == "") continue
                if (line ~ /^[←#`*]/) continue
                # A FILE TREE, NOT A FLOWCHART: box diagrams use the same corner glyph, so an
                # entry has to look like a filename -- plausible characters, and either an
                # extension or a trailing slash.
                if (line !~ /^[A-Za-z0-9._*+-]+\/?$/) continue
                if (line !~ /\./ && line !~ /\/$/) continue
                print "ENTRY\t" line
            }
        }
    ' "$1"
}

promise_kept() {
    local base="$1" entry="$2"
    local name="${entry%/}"
    # placeholders and metasyntax promise nothing
    case "$name" in *'<'*|*'>'*|*'{'*|*'}'*|*'$'*|'...'|'…') return 0 ;; esac
    # build output the repo deliberately does not track
    if git check-ignore -q "$base/$name" 2>/dev/null; then return 0; fi
    # a glob promises "at least one"
    if [[ "$name" == *'*'* ]]; then
        local -a hits
        shopt -s nullglob
        # The directive has to sit immediately above THE ASSIGNMENT: it attaches to the next
        # COMMAND, and `local -a hits; shopt …; hits=(…)` is three commands on one line, so
        # a directive above the first one never reached the third. Same lesson as
        # examples/metal-as-a-service/tests/test-e2e-reaps-sink.sh, relearned here.
        # shellcheck disable=SC2206  # $name IS the glob (`RUNBOOK-*.md`); quoting it would
        # ask for a file literally named with an asterisk.
        hits=("$base"/$name)
        shopt -u nullglob
        (( ${#hits[@]} > 0 )) && return 0
        mapfile -t hits < <(find "$base" -maxdepth 2 -name "$name" 2>/dev/null | head -1)
        (( ${#hits[@]} > 0 )); return
    fi
    # …otherwise: does anything by that name exist at or under the document's directory?
    [[ -e "$base/$name" ]] && return 0
    find "$base" -maxdepth 3 -name "$name" -print -quit 2>/dev/null | grep -q . && return 0
    return 1
}

# ── §0 — controls, before a real document is read ───────────────────────────────────────
FIX="$WORK/fixture.md"
mkdir -p "$WORK/lab/tests" "$WORK/lab/flowchart-below"; : > "$WORK/lab/real.sh"; : > "$WORK/lab/RUNBOOK-one.md"
cat > "$WORK/lab/fixture.md" <<'FIXTURE'
```
lab/
├── real.sh                   this exists
├── tests/                    so does this
├── RUNBOOK-*.md              a glob, one match on disk
├── GONE.md                   promised, never written
├── ALSO-GONE.md              named as absent — ⚠ NOT BUILT
├── <name>.toml               a placeholder
├── images/                   build output
└── flowchart-below/          (the next block is NOT a file tree)
```

```
  node A ─────┬──────────────► node B
              └──────────────► node C
```
FIXTURE
cp "$WORK/lab/fixture.md" "$FIX"
mapfile -t _got < <(tree_entries "$WORK/lab/fixture.md" | sed -n 's/^ENTRY\t//p')
_missing=()
for e in "${_got[@]}"; do promise_kept "$WORK/lab" "$e" || _missing+=("$e"); done
_c0=0
printf '%s\n' "${_missing[@]}" | grep -qx "GONE.md" || { echo "  ✗ CONTROL FAILED: the missing file was not caught" >&2; _c0=1; }
for must_not in real.sh tests/ 'RUNBOOK-*.md' '<name>.toml' 'node' '──────────────►' 'ALSO-GONE.md'; do
    if printf '%s\n' "${_missing[@]}" | grep -qxF "$must_not"; then
        echo "  ✗ CONTROL FAILED (must NOT catch): $must_not" >&2; _c0=1
    fi
done
(( _c0 == 0 )) || fail "the extractor's controls did not hold; it is not aimed at anything real until they do"
note "controls: a promised-but-absent entry is caught; a real file, a real directory, a glob with a match and a placeholder are not"

# ── §1 — every tracked document ─────────────────────────────────────────────────────────
EXPLICIT=""
if (( $# )); then DOCS=("$@"); EXPLICIT=1; else mapfile -t DOCS < <(git ls-files '*.md'); fi
problems=(); n_entries=0; n_trees=0; n_skipped=0; skipped_roots=()
for d in "${DOCS[@]}"; do
    seen_tree=0
    base=""; in_repo=0
    while IFS= read -r rec; do
        case "$rec" in
            ROOT*)
                root="${rec#ROOT$'\t'}"; root="${root%/}"
                in_repo=0; base=""
                # Resolve the root against the repo, then against the document's directory.
                # THE DOCUMENT'S OWN DIRECTORY FIRST. examples/pxe-boot-mechanics/tools/README.md
                # roots its tree at `tools/`, meaning ITS tools -- and resolving repo-first
                # matched the repo's top-level tools/, reporting six files as missing from a
                # directory they were never claimed to be in.
                if [[ -n "$root" && -d "$(dirname "$d")/$root" ]]; then base="$(dirname "$d")/$root"; in_repo=1
                elif [[ "$root" == "." || "$root" == "$(basename "$(dirname "$d")")" ]]; then
                    # The document lives IN the directory its tree is rooted at --
                    # examples/pxe-boot-mechanics/tools/README.md roots at `tools/`. This
                    # clause must beat the repo-root fallback, or that root matches the
                    # repo's own top-level tools/ and six files are reported missing from a
                    # directory nobody claimed they were in.
                    base="$(dirname "$d")"; in_repo=1
                elif [[ -n "$root" && -d "$REPO/$root" ]]; then base="$REPO/$root"; in_repo=1
                fi
                # NAME WHAT WAS NOT CHECKED. A block whose root is `/srv/tftp/`, a phase
                # label, or ASCII art describes something that is not this repo -- correctly
                # skipped, but silence about it would make "every entry exists" sound like
                # it covered every tree. It did not, and the count says so.
                if (( ! in_repo )) && [[ -n "$root" ]]; then
                    n_skipped=$((n_skipped+1))
                    [[ "$root" =~ ^[A-Za-z0-9._/-]+$ ]] && skipped_roots+=("$d: $root")
                fi ;;
            ENTRY*)
                (( in_repo )) || continue
                e="${rec#ENTRY$'\t'}"
                seen_tree=1; n_entries=$((n_entries+1))
                promise_kept "$base" "$e" \
                    || problems+=("$d: the tree rooted at '$root' lists '$e', which does not exist")
                ;;
        esac
    done < <(tree_entries "$d")
    (( seen_tree )) && n_trees=$((n_trees+1))
done
# The vacuous-pass guard belongs to the WHOLE-CORPUS run only. Given explicit files, "this
# document has no tree" is an answer, not an emptiness to be alarmed about -- and the first
# time the tool was pointed at one file it reported FAIL for having nothing to do.
if (( n_entries == 0 )); then
    if (( ${#EXPLICIT} )); then
        pass "the ${#DOCS[@]} document(s) named on the command line contain no ASCII tree entries to check"
    fi
    fail "no tree entries found in ${#DOCS[@]} document(s) — a whole-corpus run finding none means the scan is broken, not that the repo has no trees"
fi

if (( ${#problems[@]} )); then
    fail "$(printf '%d tree entr(ies) name something that does not exist:' "${#problems[@]}"
            printf '\n  - %s' "${problems[@]}"
            printf '\n\nA filename in a tree diagram is a promise a reader will try to open. If it is not built yet, name it BELOW the tree as absent (as examples/micro-cloud/README.md does) rather than listing it as something you could open.')"
fi
if (( n_skipped )); then
    note "$n_skipped tree block(s) NOT checked — their root is not a directory in this repo (a served filesystem, an initramfs layout, a phase label, ASCII art). Examples: $(printf '%s; ' "${skipped_roots[@]:0:3}")"
fi
pass "every one of the $n_entries entries in the ASCII trees of ${#DOCS[@]} documents ($n_trees carry one) names something that exists ($n_skipped further block(s) declined, named above) — build output the repo declines to track is excused by git check-ignore, a glob is checked as 'at least one', and placeholders promise nothing"
