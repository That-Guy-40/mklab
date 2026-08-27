#!/usr/bin/env bash
# test-openbios-archive-identity.sh — an archive must be able to prove what it is.
#
# WHY. tools/openbios-archive-tree.sh exists so the patched firmware tree can be
# recovered even if upstream vanishes. That makes it a RECORD, and this repo's
# most-repeated defect is a record that outlives its subject: a directory of
# tarballs whose names say when they were made and nothing about what they hold,
# so the day two of them disagree there is no way to tell which was the tree that
# was tested.
#
# The design answers that with a tree digest, and a digest is exactly the kind of
# thing that can be computed wrongly and still look fine -- an all-PASS verify is
# indistinguishable from a verify that compares a value to itself. So the rows
# that matter here are the ones where verification must FAIL: a corrupted archive,
# a manifest that has been edited, an archive with no manifest at all.
#
# Own verdict helpers: sourcing a suite's lib.sh would let a subject supply its
# own harness.
set -uo pipefail

_V=0
skip() { _V=1; printf 'SKIP: %s\n' "$*" >&2; exit 77; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: test-openbios-archive-identity.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$ROOT/tools/openbios-archive-tree.sh"
[[ -x "$SUT" ]] || fail "tools/openbios-archive-tree.sh is missing or not executable"
command -v tar >/dev/null 2>&1 || skip "tar is not installed"
WORK="$(mktemp -d)"

# A synthetic tree, not the real one: the question is whether the IDENTITY logic
# is right, and a 722-file tree would make every row slow without making any of
# them sharper.
TREE="$WORK/openbios"
mkdir -p "$TREE/arch/x86" "$TREE/forth"
echo 'int main(void){return 0;}' > "$TREE/arch/x86/openbios.c"
echo ': foo ." bar" ;'          > "$TREE/forth/bootstrap.fs"
echo 'MARKER'                    > "$TREE/Makefile.target"
OUT="$WORK/archives"

problems=(); n=0
# ROWS CAPTURE THE STATUS INTO $RC; THEY NEVER READ $? INSIDE A ROW. check()'s own
# first statement is an arithmetic assignment, which SETS $?, so `[[ "$?" != 0 ]]`
# passed as a condition here reads the increment and not the command under test.
# That is how the first draft of this file reported its two controls as failures
# while the tool was fine -- and it would equally have reported a broken verify as
# a pass. Caught by the controls, which is where the bugs are.
check() { n=$((n+1)); if eval "$2"; then :; else problems+=("$1"); fi; }
rc_of() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

# ── 1. it writes an archive and a manifest ──────────────────────────────────────
out="$("$SUT" --workdir "$TREE" --out "$OUT" 2>&1)"; rc=$?
check "archiving succeeds"                  '[[ "$rc" == 0 ]]'
TAR="$(find "$OUT" -maxdepth 1 -name '*.tar.*' | head -1)"
MAN="$(find "$OUT" -maxdepth 1 -name '*.manifest.txt' | head -1)"
check "an archive was written"              '[[ -f "$TAR" ]]'
check "a manifest was written beside it"    '[[ -f "$MAN" ]]'
check "the manifest carries a tree digest"  'grep -q "^tree-digest: [0-9a-f]\{64\}$" "$MAN"'
check "the manifest names the openbios pin" 'grep -q "^openbios-pin: [0-9a-f]\{40\}$" "$MAN"'
check "...and the patch that produced it"   'grep -q "^tested-tree-patch-sha256: [0-9a-f]\{64\}$" "$MAN"'
check "the filename carries the DATE"       '[[ "$(basename "$TAR")" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]'
check "...and the DIGEST"                   '[[ "$(basename "$TAR")" =~ -[0-9a-f]{12}\.tar\. ]]'
if (( ${#problems[@]} )); then printf '  - %s\n' "${problems[@]}" >&2; fail "the archiver did not produce a usable, identified archive"; fi

# ── 2. verify passes on an untouched archive ────────────────────────────────────
RC="$(rc_of "$SUT" --workdir "$TREE" --verify "$TAR")"
check "verify passes on an intact archive" '[[ "$RC" == 0 ]]'

# ── 3. dedup is by CONTENT, not by date ─────────────────────────────────────────
# NOT A FILE COUNT. Dedup produces the same date and the same digest, hence the
# same FILENAME -- so a run that re-archives simply overwrites in place and the
# count is identical either way. Measured: disabling the dedup check left this row
# green when it counted files. The instrument has to out-reach the defect, so the
# assertion is that the bytes on disk were not REWRITTEN.
before="$(find "$OUT" -name '*.tar.*' | wc -l)"
before_mt="$(stat -c '%y %s' "$TAR")"
"$SUT" --workdir "$TREE" --out "$OUT" >/dev/null 2>&1
after="$(find "$OUT" -name '*.tar.*' | wc -l)"
after_mt="$(stat -c '%y %s' "$TAR")"
check "an unchanged tree adds no new archive"    '[[ "$before" == "$after" ]]'
check "...and does not rewrite the existing one" '[[ "$before_mt" == "$after_mt" ]]'

# ── 4. the exclusions are real: build output must not move the digest ───────────
# This is the row that makes the archive comparable to a COLD reproduction. If
# obj-* or config-host.mak counted, a warm tree and a freshly built one would
# never agree and the digest would identify "what was last built" instead of
# "what the source is".
d1="$(sed -n 's/^tree-digest: //p' "$MAN")"
mkdir -p "$TREE/obj-x86"; echo 'build output' > "$TREE/obj-x86/openbios.dict"
echo 'generated' > "$TREE/config-host.mak"
"$SUT" --workdir "$TREE" --out "$OUT" >/dev/null 2>&1
after2="$(find "$OUT" -name '*.tar.*' | wc -l)"
check "obj-*/config-host.mak do not change the identity" '[[ "$after2" == "$after" ]]'

# ── 5. a REAL source change must produce a new archive ──────────────────────────
# Without this, row 4 is satisfied by a digest that never changes at all.
echo 'CHANGED' >> "$TREE/Makefile.target"
"$SUT" --workdir "$TREE" --out "$OUT" >/dev/null 2>&1
after3="$(find "$OUT" -name '*.tar.*' | wc -l)"
check "a changed source file DOES produce a new archive" '(( after3 == after2 + 1 ))'
d2="$(find "$OUT" -name '*.manifest.txt' -newer "$MAN" -exec sed -n 's/^tree-digest: //p' {} \; | head -1)"
check "...with a different digest"                       '[[ -n "$d2" && "$d1" != "$d2" ]]'

# ── 6. the controls: verification must FAIL when it should ──────────────────────
# An archive that verifies no matter what is a tarball with a reassuring script
# next to it.
cp "$TAR" "$WORK/corrupt.tar.zst" 2>/dev/null || cp "$TAR" "$WORK/corrupt.tar.gz"
CORRUPT="$(find "$WORK" -maxdepth 1 -name 'corrupt.tar.*' | head -1)"
cp "$MAN" "${CORRUPT%.tar.*}.manifest.txt"
tmpd="$WORK/x"; mkdir -p "$tmpd"; tar -xf "$CORRUPT" -C "$tmpd"
echo 'TAMPERED' >> "$tmpd/openbios/Makefile.target"
( cd "$tmpd" && tar --create --file "$CORRUPT" --sort=name openbios ) 2>/dev/null
RC="$(rc_of "$SUT" --workdir "$TREE" --verify "$CORRUPT")"
check "CONTROL: a tampered archive FAILS verification" '[[ "$RC" != 0 ]]'

rm -f "${CORRUPT%.tar.*}.manifest.txt"
RC="$(rc_of "$SUT" --workdir "$TREE" --verify "$CORRUPT")"
check "CONTROL: an archive with no manifest is refused" '[[ "$RC" != 0 ]]'

if (( ${#problems[@]} )); then
    printf '  - %s\n' "${problems[@]}" >&2
    fail "$(printf '%d' "${#problems[@]}") of $n archive-identity assertions failed"
fi
note "§1-5: $((n - 2)) assertions on writing, verifying, dedup-by-content and the exclusions"
note "§6 controls: a tampered archive and a manifest-less archive both refuse to verify  ✓"
pass "an archive identifies the tree it holds: it carries a content digest, the pin and the patch sha that produced it, and a date; dedup is by content so re-running is free; build output does not move the identity but a source change does; and verification FAILS on a tampered archive and on one with no manifest ($n assertions)"
