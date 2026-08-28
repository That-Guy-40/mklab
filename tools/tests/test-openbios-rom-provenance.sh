#!/usr/bin/env bash
# test-openbios-rom-provenance.sh — a ROM must not be able to answer for a payload
# that is not inside it.
#
# WHY. smoke-openbios.sh's `coreboot` track boots a ROM from OUTSIDE the tree under
# test. Until 2026-08-27 nothing related the two, and both consequences were
# observed rather than imagined: the track PASSED against an empty
# $OPENBIOS_WORKDIR, and on the development machine the ROM was two days older than
# the payload beside it, so every run reported on firmware predating the fixes it
# appeared to be testing. Nothing errored — the ROM boots and answers 7. It was a
# record outliving its subject.
#
# The three outcomes are graded differently and the grading is the point, so it is
# what gets asserted: a ROM built from another payload is UNKNOWN (77) because
# nothing is broken and a rebuild restores the answer; a sidecar that does not
# describe the ROM is a FAILURE (1) because the record and reality disagree, which
# outranks an honest failure.
#
# Synthetic files throughout: the question is whether the pairing logic is right,
# and a real 4 MB coreboot ROM would make every row slower without making one
# sharper. Own verdict helpers, so no subject supplies its own harness.
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
        printf 'FAIL: test-openbios-rom-provenance.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SUT="$ROOT/tools/openbios-rom-provenance.sh"
[[ -x "$SUT" ]] || fail "tools/openbios-rom-provenance.sh is missing or not executable"
WORK="$(mktemp -d)"
ROM="$WORK/coreboot.rom"; ELF="$WORK/openbios-builtin.elf"

problems=(); n=0
rc_of() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }
out_of() { "$@" 2>&1; }
row() { # row <want-rc> <label>  [uses $RC set by caller]
    n=$((n + 1))
    [[ "$RC" == "$1" ]] || problems+=("$2: expected rc=$1, got rc=$RC")
}

printf 'ROM-BYTES-v1\n' > "$ROM"
printf 'PAYLOAD-BYTES-v1\n' > "$ELF"

# ── the happy path, stamped then checked ────────────────────────────────────────
RC="$(rc_of "$SUT" --stamp "$ROM" "$ELF")";  row 0 "stamping succeeds"
[[ -f "$ROM.provenance" ]] || problems+=("stamping wrote no .provenance beside the ROM")
n=$((n + 1))
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 0 "a stamped ROM checks out against its own payload"

# ── the row the whole file exists for: the payload moved on ─────────────────────
# This is the two-day-stale ROM, reproduced. It must be UNKNOWN, never a pass.
printf 'PAYLOAD-BYTES-v2-rebuilt\n' > "$ELF"
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 77 "a ROM built from a DIFFERENT payload is UNKNOWN, not a pass"
msg="$(out_of "$SUT" --check "$ROM" "$ELF")"
grep -q 'DIFFERENT payload' <<<"$msg" || problems+=("the stale-payload message does not say what is wrong")
n=$((n + 1))

# ── the record disagreeing with the ROM is a FAILURE, not an unknown ────────────
printf 'PAYLOAD-BYTES-v1\n' > "$ELF"          # payload back to what was stamped
printf 'ROM-BYTES-v2-rebuilt\n' > "$ROM"      # ...but the ROM was replaced
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 1 "a sidecar describing a different ROM FAILS"
msg="$(out_of "$SUT" --check "$ROM" "$ELF")"
grep -q 'different ROM' <<<"$msg" || problems+=("the wrong-ROM message does not say what is wrong")
n=$((n + 1))

# ── the unknowns, each stated rather than passed ────────────────────────────────
printf 'ROM-BYTES-v1\n' > "$ROM"
rm -f "$ROM.provenance"
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 77 "an unstamped ROM is UNKNOWN (this is every pre-existing ROM)"
"$SUT" --stamp "$ROM" "$ELF" >/dev/null 2>&1
mv "$ELF" "$WORK/elsewhere"
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 77 "a missing payload is UNKNOWN — NOT a pass, which is what it used to be"
mv "$WORK/elsewhere" "$ELF"
RC="$(rc_of "$SUT" --check "$WORK/no-such.rom" "$ELF")"; row 77 "a missing ROM is UNKNOWN"

# ── a corrupt record is a failure: it looks like provenance and is not ──────────
"$SUT" --stamp "$ROM" "$ELF" >/dev/null 2>&1
sed -i 's/^payload-sha256: .*/payload-sha256: not-a-digest/' "$ROM.provenance"
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 1 "a truncated or hand-edited sidecar FAILS rather than being ignored"

# ── controls on the instrument itself ───────────────────────────────────────────
# Every row above compares a digest to a digest, so the whole file would pass if the
# comparison always succeeded. These two prove it can distinguish at all: identical
# inputs must agree, and a one-byte change must not.
"$SUT" --stamp "$ROM" "$ELF" >/dev/null 2>&1
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 0 "CONTROL: unchanged inputs still check out"
printf 'PAYLOAD-BYTES-v1x\n' > "$ELF"
RC="$(rc_of "$SUT" --check "$ROM" "$ELF")";  row 77 "CONTROL: a ONE-BYTE payload change is detected"

if (( ${#problems[@]} )); then
    printf '  - %s\n' "${problems[@]}" >&2
    fail "$(printf '%d' "${#problems[@]}") of $n provenance assertions failed — the coreboot track could report on firmware that is not in the ROM it boots"
fi
note "$n assertions: stamp/check round trip, a stale payload, a swapped ROM, three unknowns, a corrupt record, and two controls on the comparison itself"
pass "a coreboot ROM cannot answer for a payload that is not inside it: a ROM built from a different payload is UNKNOWN (77) and never a pass, a sidecar describing a different ROM is a FAILURE (1) because the record and reality disagree, a missing payload or sidecar is stated as an unknown rather than passed, and a one-byte change is detected ($n assertions)"
