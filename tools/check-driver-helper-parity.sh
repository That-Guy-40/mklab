#!/usr/bin/env bash
# check-driver-helper-parity.sh — a helper duplicated across the phase drivers must stay
# byte-identical, or "duplicated inline" quietly becomes "drifted".
#
# WHY (TODO 15.11). Every phase driver is SELF-CONTAINED on purpose — `lab-podman.sh:23`
# says so in as many words ("Self-contained per the per-phase rule: helpers are duplicated
# inline"), and CLAUDE.md opens with it. So when `volumes`/`image`/`kernel` needed
# @LAB_DIR@ / @REPO@ / @NETBOOT@ expansion in four drivers, the answer was NOT a shared
# library: that would make the first driver in this repo unable to be copied out on its
# own, which is a bigger change than the one being made and belongs to whoever decides to
# make it deliberately.
#
# BUT DUPLICATION WITHOUT A CHECK IS JUST DEFERRED DRIFT. This repo's own history is the
# argument: three near-identical `toml_to_json` bodies already exist, and nobody could have
# told you which two were the same (podman and lxd) without hashing them. So the rule is
# duplicate-and-bind: the copies are compared here on every run, and a run where they
# differ names the drivers and the line.
#
# WHAT IS COMPARED, and what deliberately is not. Only `_expand_spec_paths`, whose whole
# purpose is to behave identically everywhere. `_toml_to_json_raw` is NOT compared: the
# parsers genuinely differ (phase 3 carries a python3/tomllib branch the others lack), and
# demanding parity there would force a false uniformity — a checker that punishes a real
# difference teaches people to delete the difference.
#
# Own verdict helpers on purpose: it must not source a suite's lib.sh.
set -uo pipefail

REPO="${REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO" || { echo "FAIL: cannot cd to repo root" >&2; exit 1; }

_V=0
pass() { _V=1; printf 'PASS: %s\n' "$*" >&2; exit 0; }
fail() { _V=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '  - %s\n' "$*" >&2; }
WORK=""
_on_exit() {
    local rc=$?
    [[ -n "$WORK" ]] && rm -rf -- "$WORK"
    if (( rc != 0 && rc != 77 )) && (( _V == 0 )); then
        printf 'FAIL: check-driver-helper-parity.sh exited early (rc=%d) — no verdict printed\n' "$rc" >&2
    fi
}
trap _on_exit EXIT
WORK="$(mktemp -d)"

# extract <file> <fn> → the function body, or nothing
extract() { sed -n "/^$2() {/,/^}/p" "$1"; }

# ── §0. THE EXTRACTOR PROVES ITSELF FIRST ───────────────────────────────────────────────
# A parity check whose extractor returns empty for every file reports perfect agreement —
# the loudest possible way to prove nothing. So it is aimed at fixtures before real files.
printf 'x() {\n  echo a\n}\n_expand_spec_paths() {\n  echo SAME\n}\ny() {\n  echo b\n}\n' > "$WORK/a.sh"
printf '_expand_spec_paths() {\n  echo SAME\n}\n' > "$WORK/b.sh"
printf '_expand_spec_paths() {\n  echo DIFFERENT\n}\n' > "$WORK/c.sh"
printf 'nothing_here() {\n  echo x\n}\n' > "$WORK/d.sh"
c_ok=0; c_bad=0
[[ "$(extract "$WORK/a.sh" _expand_spec_paths)" == "$(extract "$WORK/b.sh" _expand_spec_paths)" ]] \
    && c_ok=$((c_ok+1)) || { c_bad=$((c_bad+1)); printf '  ✗ CONTROL: two identical copies compared UNEQUAL\n' >&2; }
[[ "$(extract "$WORK/a.sh" _expand_spec_paths)" != "$(extract "$WORK/c.sh" _expand_spec_paths)" ]] \
    && c_ok=$((c_ok+1)) || { c_bad=$((c_bad+1)); printf '  ✗ CONTROL: a CHANGED copy compared equal — the comparison is not looking at the body\n' >&2; }
[[ -n "$(extract "$WORK/a.sh" _expand_spec_paths)" ]] \
    && c_ok=$((c_ok+1)) || { c_bad=$((c_bad+1)); printf '  ✗ CONTROL: the extractor found nothing in a file that has the function\n' >&2; }
[[ -z "$(extract "$WORK/d.sh" _expand_spec_paths)" ]] \
    && c_ok=$((c_ok+1)) || { c_bad=$((c_bad+1)); printf '  ✗ CONTROL: the extractor invented a body for a file without the function\n' >&2; }
(( c_bad == 0 )) || fail "§0: $c_bad of 4 extractor controls behaved wrongly — an empty extraction and perfect agreement print the same thing"
note "§0: 4 extractor controls behaved (identical, changed, present, absent)"

# ── §1. the drivers ─────────────────────────────────────────────────────────────────────
FN="_expand_spec_paths"
mapfile -t DRIVERS < <(git ls-files 'phase*/lab-*.sh')
(( ${#DRIVERS[@]} >= 4 )) \
    || fail "only ${#DRIVERS[@]} phase driver(s) found — the enumeration collapsed, and a parity check over one file always agrees with itself"

have=(); missing=()
for d in "${DRIVERS[@]}"; do
    if [[ -n "$(extract "$d" "$FN")" ]]; then have+=("$d"); else missing+=("$d"); fi
done
(( ${#have[@]} > 0 )) || fail "no driver defines $FN — either it was renamed everywhere, or this check has been asserting nothing"

ref="${have[0]}"; ref_body="$(extract "$ref" "$FN")"
bad=""
for d in "${have[@]:1}"; do
    [[ "$(extract "$d" "$FN")" == "$ref_body" ]] \
        || bad+="    $d differs from $ref"$'\n'
done
if [[ -n "$bad" ]]; then
    printf '%s' "$bad" >&2
    fail "$FN has drifted between drivers. It is duplicated inline BY DESIGN (the per-phase
  self-containment rule), which is only safe while the copies are identical — so a
  difference here is not a style question, it is two drivers resolving @LAB_DIR@ two ways.
  Copy the reference body from $ref."
fi
note "$FN is byte-identical in ${#have[@]} driver(s): $(printf '%s ' "${have[@]##*/}")"

# A driver that reads a config but has NO copy is the other failure: its specs would be
# handed a literal @LAB_DIR@. Named rather than assumed away — phase 1 and 7 do not parse
# path-bearing specs the same way, so they are listed, not failed.
if (( ${#missing[@]} )); then
    note "no copy (and none needed unless they grow path-bearing specs): $(printf '%s ' "${missing[@]##*/}")"
fi

pass "$FN is byte-identical across ${#have[@]} phase drivers — duplicated inline per the self-containment rule and CHECKED rather than hoped, with the parsers around it left free to differ (phase 3 carries a python3/tomllib branch the others do not); 4 extractor controls fired first"
