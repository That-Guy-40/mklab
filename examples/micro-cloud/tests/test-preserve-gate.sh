#!/usr/bin/env bash
# §9.5's break-it row: RESTORE FROM A CHANGED ARTIFACT MUST REFUSE BY NAME.
#
# This is the assertion the whole of `preserve.sh` exists to be able to make, and it is
# the MAAS lesson made mechanical. Fourteen defects came out of that lab while its suite
# stayed green, and the largest class was one shape: a record that outlived the thing it
# described. A `disk.raw.sha256` describing a re-staged image. A `pcrs.expected` captured
# from a build that had been wiped. A served `vmlinuz` whose `file -b` string was
# IDENTICAL to the kernel rebuilt over it — only the sha differed. Every one was readable
# and none errored; they were merely false, and each surfaced far downstream.
#
# So the property under test is not "preserve.sh can hash a file". It is:
#
#   a restore that would import bytes the derivation does not describe DOES NOT HAPPEN,
#   says which artifact, and prints both digests.
#
# ── WHY THIS TEST NEEDS NO ENGINE AND NO ROOT ───────────────────────────────────────────
# `lab-chroot.sh export-tarball` takes `<name|path>`, so a plain directory of plain files
# is a legitimate subject. The gate is a property of the manifest-to-bytes relationship
# and does not care what produced the bytes — which means this row runs everywhere,
# including CI, instead of skipping on the machines least likely to have podman.
# The live round trip through a real engine is the sibling test.
#
# ── THE THREE OUTCOMES, AND WHY ALL THREE ARE ASSERTED ──────────────────────────────────
# "I could not look" is not "it matches" and it is not "it changed" either. An UNKNOWN
# that renders as a pass is how an open question gets retired; an UNKNOWN that renders as
# CHANGED sends someone hunting a corruption that never happened. Both are wrong, and only
# checking one of the three would leave the other free to collapse into it.
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PRESERVE="$LAB_DIR/preserve.sh"
[[ -x "$PRESERVE" ]] || fail "preserve.sh is missing or not executable at $PRESERVE"
need tar sha256sum

WORK="$(mktemp -d)"; on_exit 'rm -rf -- "$WORK"'
TREE="$WORK/tree"; BK="$WORK/bk"
mkdir -p "$TREE/etc"
printf 'GATE-MARKER-8b21\n' > "$TREE/etc/marker"

# ── save ────────────────────────────────────────────────────────────────────────────────
out="$(bash "$PRESERVE" save --tier portable --out "$BK" "chroot:$TREE" 2>&1)"; rc=$?
(( rc == 0 )) || fail "save failed (rc=$rc): $out"
MAN="$BK/derivation.toml"
[[ -r "$MAN" ]] || fail "save reported success and wrote no $MAN — that is the liar case"

# The manifest must actually bind the artifact to a digest. A [[artifact]] block with no
# sha256 would sail through every check below, because there would be nothing to compare.
grep -q '^\[\[artifact\]\]' "$MAN" || fail "the manifest lists no [[artifact]] block"
want="$(sed -n 's/^sha256 *= *"\(.*\)"$/\1/p' "$MAN" | head -1)"
[[ ${#want} -eq 64 ]] || fail "the manifest's sha256 is not a 64-char digest (got '${want}')"
art="$(sed -n 's/^file *= *"\(.*\)"$/\1/p' "$MAN" | head -1)"
[[ -s "$BK/$art" ]] || fail "the manifest names a file '$art' that is not in $BK"
note "artifact $art, sha256 ${want:0:16}…"

# ── 1. THE POSITIVE CONTROL ─────────────────────────────────────────────────────────────
# Without this, every assertion below could be satisfied by a `verify` that always
# refuses — an all-FAIL checker and a working one are indistinguishable from the failing
# rows alone.
out="$(bash "$PRESERVE" verify "$BK" 2>&1)"; rc=$?
(( rc == 0 )) || fail "verify refused an UNTOUCHED backup (rc=$rc) — the gate fires on everything and proves nothing: $out"
grep -q 'OK: every artifact matches' <<<"$out" || fail "verify exited 0 without saying the artifacts match: $out"

# A clean restore of a chroot unit has no automatic import path (phase 1 creates from
# debootstrap, not from a tarball), so it must report rc=2 and NAME that — distinct from
# the rc=1 the gate returns below. If both came back 1, assertion 2 would prove nothing.
out="$(bash "$PRESERVE" restore --dry-run "$BK" 2>&1)"; rc=$?
(( rc == 2 )) || fail "a CLEAN restore with no import path should exit 2 (some units unhandled), got rc=$rc: $out"
grep -q 'no import path' <<<"$out" || fail "the clean restore did not name the units it could not import: $out"

# ── 2. THE BREAK-IT ROW ─────────────────────────────────────────────────────────────────
# One byte. Not a truncation, not a rewrite — the smallest change a stale record can hide
# behind, and the one a size check or an `ls` would miss.
cp -- "$BK/$art" "$WORK/good.tar.gz"
printf 'X' >> "$BK/$art"

out="$(bash "$PRESERVE" verify "$BK" 2>&1)"; rc=$?
(( rc == 1 )) || fail "REGRESSION: verify did not refuse a CHANGED artifact (rc=$rc, expected 1): $out"
# ROW-SCOPED ON PURPOSE. A bare `grep CHANGED` also matches verify's own summary line
# ("0 CHANGED"), so it is true whether or not any artifact changed — the exact shape that
# once made `"unknown" not in out` match a preflight's `0 UNKNOWN` total. Anchor on the
# per-artifact row.
grep -qE '^[[:space:]]+CHANGED[[:space:]]' <<<"$out" \
    || fail "REGRESSION: verify refused without a CHANGED row naming the artifact: $out"
grep -qF -- "$art" <<<"$out" || fail "REGRESSION: the refusal does not NAME the artifact that changed — 'checksum failed' sends you looking: $out"
grep -qF -- "$want" <<<"$out" \
    || fail "REGRESSION: the refusal does not print the EXPECTED digest, so nobody can tell which half moved: $out"
got="$(sha256sum -- "$BK/$art")"; got="${got%% *}"
grep -qF -- "$got" <<<"$out" \
    || fail "REGRESSION: the refusal does not print the ACTUAL digest ($got): $out"
[[ "$got" != "$want" ]] || fail "the test's own premise is broken: appending a byte did not change the digest"

# ── 3. REFUSE BEFORE THE IRREVERSIBLE STEP ──────────────────────────────────────────────
# A gate that fires after the import is a post-mortem. Asserted as an OUTCOME — the
# restore issued nothing — rather than by reading the order of calls in the source.
out="$(bash "$PRESERVE" restore --dry-run "$BK" 2>&1)"; rc=$?
(( rc == 1 )) || fail "REGRESSION: restore proceeded past a CHANGED artifact (rc=$rc, expected 1): $out"
grep -q 'restore REFUSED' <<<"$out" || fail "restore stopped without saying it was refused: $out"
! grep -q 'would issue' <<<"$out" \
    || fail "REGRESSION: restore planned an import ANYWAY after the gate refused — the gate runs too late: $out"
! grep -q 'no import path' <<<"$out" \
    || fail "restore reached its per-unit walk after the gate refused; it should not have got that far: $out"

# ── 4. UNKNOWN IS A VERDICT, DISTINCT FROM BOTH ─────────────────────────────────────────
cp -- "$WORK/good.tar.gz" "$BK/$art"          # back to the state the manifest describes
mv -- "$BK/$art" "$WORK/moved-away.tar.gz"    # …and now it cannot be looked at
out="$(bash "$PRESERVE" verify "$BK" 2>&1)"; rc=$?
(( rc == 3 )) || fail "REGRESSION: an unreadable artifact did not come back UNKNOWN (rc=$rc, expected 3): $out"
grep -qE '^[[:space:]]+UNKNOWN[[:space:]]' <<<"$out" \
    || fail "REGRESSION: an unreadable artifact got no UNKNOWN row: $out"
! grep -qE '^[[:space:]]+CHANGED[[:space:]]' <<<"$out" \
    || fail "REGRESSION: an artifact nobody could read was reported as CHANGED — 'I could not look' is not 'it changed': $out"

# …and restore must refuse on UNKNOWN too. An unchecked artifact is not a verified one,
# and importing it would be exactly the silent step §9.5 exists to prevent.
out="$(bash "$PRESERVE" restore --dry-run "$BK" 2>&1)"; rc=$?
(( rc == 1 )) || fail "REGRESSION: restore proceeded on an UNKNOWN artifact (rc=$rc, expected 1): $out"

# ── 5. THE FINAL CONTROL: put it back, and the gate must fall silent ────────────────────
mv -- "$WORK/moved-away.tar.gz" "$BK/$art"
out="$(bash "$PRESERVE" verify "$BK" 2>&1)"; rc=$?
(( rc == 0 )) || fail "verify did not go quiet once the artifact was restored (rc=$rc) — the gate is sticky: $out"

pass "a changed artifact is refused BY NAME with both digests, restore stops BEFORE importing, and unreadable is UNKNOWN — not CHANGED and not a pass"
