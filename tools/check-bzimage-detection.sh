#!/usr/bin/env bash
# check-bzimage-detection.sh — the regression guard for the bzImage-detection liar (#500).
#
# TWO THINGS, because fixing the pattern once is not enough — a fix with no control
# is one `file`-version bump from silently un-fixing (that is exactly how #500
# happened: six copies of `file … | grep 'Linux kernel x86 boot executable bzImage'`
# that stopped matching when file-5.46 inserted a comma, and nothing watched):
#
#   §1  CORRECTNESS — the shipped is_bzimage (tools/lib/bzimage.sh, the single
#       definition) matches BOTH the old wording (`…executable bzImage`) and the new
#       (`…executable, bzImage`) and rejects non-bzImages. The negative control is
#       the whole point: the OLD literal pattern must FAIL the new wording, so if
#       someone narrows the pattern back the guard bites.
#   §2  SINGLE SOURCE — no *.sh re-inlines the `file(1)`→bzImage detection; every
#       caller routes through tools/lib/bzimage.sh. Six copies was the bug's
#       blast radius; this refuses a seventh. Its scanner proves itself on a planted
#       copy before it is aimed at the tree.
#
# Own verdict helpers on purpose: a guard must not source the thing it guards beyond
# the one function under test. Exit 0 pass / 1 fail / 77 skip.
set -u
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/tools/lib/bzimage.sh"
SELF_REL="tools/check-bzimage-detection.sh"
pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
note() { echo "  - $*"; }

[[ -f "$LIB" ]] || fail "the single definition $LIB is missing — the dedupe (#500 follow-up) was reverted"

# ── §1: the pattern is correct, and its negative control bites ──────────────────
# Drive the SHIPPED is_bzimage by stubbing file(1) to emit a chosen type line, so
# this tests the function end to end (not a re-implementation of its regex).
# shellcheck source=tools/lib/bzimage.sh
. "$LIB"
WD="$(mktemp -d)"; trap 'rm -rf "$WD"' EXIT
SUBJ="$WD/subject"; : > "$SUBJ"      # a readable path; the stub decides what file(1) "says"
FILE_STUB=""
file() { printf '%s\n' "$FILE_STUB"; }   # deliberate shadow of file(1), for THIS shell's is_bzimage

MUSTCATCH=(
  "Linux kernel x86 boot executable bzImage, version 5.10.0"                  # OLD wording (pre-comma)
  "Linux kernel x86 boot executable, bzImage, version 6.12.30 (mklab@x), RO"  # NEW wording (file-5.46, the #500 trigger)
)
MUSTNOT=(
  "ELF 64-bit LSB pie executable, x86-64, version 1 (SYSV)"                   # an ELF, not a bzImage
  "ASCII text"                                                                # a text file
  "Linux kernel ARM boot executable zImage"                                  # ARM zImage, not x86 bzImage
  "DOS/MBR boot sector"                                                      # a raw boot sector
)
c0bad=0
for s in "${MUSTCATCH[@]}"; do FILE_STUB="$s"; is_bzimage "$SUBJ" || { echo "    §1 MISS (should catch): $s"; c0bad=$((c0bad+1)); }; done
for s in "${MUSTNOT[@]}";  do FILE_STUB="$s"; is_bzimage "$SUBJ" && { echo "    §1 FALSE (should reject): $s"; c0bad=$((c0bad+1)); }; done
[[ $c0bad -eq 0 ]] || fail "§1: $c0bad of $(( ${#MUSTCATCH[@]} + ${#MUSTNOT[@]} )) pattern controls behaved wrongly — is_bzimage does not track file(1)'s wording"
# the negative control: the OLD literal (no comma) MUST miss the NEW wording. If it
# matched, this guard could not tell the fixed pattern from the one #500 shipped.
if printf '%s\n' "${MUSTCATCH[1]}" | grep -q 'Linux kernel x86 boot executable bzImage'; then
  fail "§1 NEGATIVE CONTROL inert: the pre-#500 literal pattern still matches file-5.46's comma wording, so this guard cannot detect the regression it exists for"
fi
note "§1: is_bzimage catches ${#MUSTCATCH[@]} wordings (old + new), rejects ${#MUSTNOT[@]} non-bzImages; the pre-#500 literal misses the new wording (the control bites)"
unset -f file

# ── §2: single source — the scanner bites on a planted copy, then the tree is clean ─
# The detection idiom is a grep whose pattern is file(1)'s bzImage TYPE LINE
# (`Linux kernel … bzImage`) — distinct from merely naming a file "bzImage"
# (cpio listings, build-path greps), which this must NOT flag.
scan() { grep -rlnE 'Linux kernel.*bzImage' --include='*.sh' "$1" 2>/dev/null | sed "s|^$1/||;s|^\./||"; }
CTRL="$WD/ctrl"; mkdir -p "$CTRL/good" "$CTRL/bad"
printf '%s\n' '#!/usr/bin/env bash' 'echo hi' > "$CTRL/good/clean.sh"
printf '%s\n' '#!/usr/bin/env bash' "file -b x | grep -q 'Linux kernel x86 boot executable bzImage'" > "$CTRL/bad/reinlined.sh"
[[ -z "$(scan "$CTRL/good")" ]] || fail "§2 scanner control: flagged a clean fixture — it would false-positive on the tree"
[[ "$(scan "$CTRL/bad")" == "reinlined.sh" ]] || fail "§2 scanner control: did NOT flag a re-inlined copy — the single-source check is not attached to anything"
note "§2 scanner proven: clean fixture → 0, a re-inlined copy → flagged"

# the live assertion: in the repo, exactly ONE *.sh carries the detection idiom, and
# it is the shared definition. (This file is allow-listed: it carries the wordings as
# test fixtures, not as a detector.)
mapfile -t HITS < <(grep -rlnE 'Linux kernel.*bzImage' --include='*.sh' "$REPO" 2>/dev/null \
  | sed "s|^$REPO/||" | grep -vxF "$SELF_REL" | sort)
if [[ "${#HITS[@]}" -ne 1 || "${HITS[0]}" != "tools/lib/bzimage.sh" ]]; then
  fail "§2: the bzImage-detection idiom appears in ${#HITS[@]} script(s) outside this guard — expected exactly tools/lib/bzimage.sh. A re-inlined copy drifts the next time file(1) changes (the #500 liar). Offenders: ${HITS[*]}"
fi
note "§2: the detection lives in tools/lib/bzimage.sh alone; all six callers route through it"

# ── §3: a live cross-check, when a real bzImage is within reach (else UNKNOWN) ───
LIVE=""
for c in /boot/vmlinuz-* "$REPO"/micro-linux/out/x86_64/build/linux-*/arch/x86/boot/bzImage; do
  [[ -r "$c" ]] && file -b "$c" 2>/dev/null | grep -q bzImage && { LIVE="$c"; break; }
done
if [[ -n "$LIVE" ]]; then
  is_bzimage "$LIVE" || fail "§3: is_bzimage rejected a REAL bzImage ($LIVE) that file(1) calls one — the installed file(1)'s wording escaped the pattern"
  note "§3: is_bzimage accepts a real bzImage on this host ($(basename "$LIVE")) — pattern matches the installed file $(file --version 2>/dev/null | head -1)"
else
  note "§3: no real bzImage reachable here — the live cross-check is UNKNOWN (not failed); §1's stubbed wordings still proved the pattern"
fi

pass "bzImage detection is one definition (tools/lib/bzimage.sh), tolerant of file(1)'s old and new wording, with the pre-#500 literal as a biting negative control, and no *.sh re-inlines it (the scanner proved itself on a planted copy first) — the #500 liar cannot return silently"
