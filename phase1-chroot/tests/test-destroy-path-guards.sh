#!/usr/bin/env bash
# `_safe_rm_rf`'s PATH-SANITY guards must actually bite — all four of them.
#
# WHY, when test-destroy-mount-guard.sh already covers _safe_rm_rf. It covers exactly one
# of the five refusals: the still-mounted one. The other four — empty, not absolute, `/`,
# and too shallow — have **never been observed failing**. An assertion never seen to fire
# is not known to work: it may be guarding a condition that cannot arise, or be dead code
# after a refactor, and either way it reads as protection that is not there.
#
# That matters more than usual here, because what these four stand between is
# `rm -rf -- "$path"` and a path read back out of a manifest. AUDIT.md F7 named exactly
# this: *"a hand-corrupted manifest with target = "/" would be catastrophic."*
#
# THE AUDIT ROW IS STALE, WHICH IS THE OTHER HALF OF THIS TEST'S JOB. F7 is listed as an
# open Low finding, and the guard has since been written (`_safe_rm_rf`, credited to
# "Finding 14") and wired into all three destroy paths. The recommendation was implemented
# and the record was not updated — this repo's bug class #1, aimed at its own audit. This
# test is the evidence for closing that row: it proves the guard exists, is reachable, and
# refuses each bad shape by name.
#
# NO ROOT, NO CHROOT, NOTHING DELETED. The function is sourced and called directly with
# paths that must be REFUSED, so a passing run performs no deletion at all. The one path
# it is allowed to accept is a throwaway directory this test created.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

tmp="$(mktemp -d)"
on_exit 'rm -rf "$tmp"'

# Source the tool for its functions. It must not run its CLI when sourced.
# shellcheck disable=SC1090
source "$LAB_CHROOT" >/dev/null 2>&1 || true
declare -F _safe_rm_rf >/dev/null \
    || fail "_safe_rm_rf is not defined after sourcing $LAB_CHROOT — the destroy guard AUDIT F7 asks for is absent or was renamed; three destroy paths call it, so this is not a test-only problem"
note "_safe_rm_rf is defined and reachable"

# refuses <label> <path> — the call MUST die. `die` is an exit, so it goes in a subshell
# (house rule) or the refusal takes this test with it.
refuses() {
    local label="$1" path="$2" out
    out="$( ( _safe_rm_rf "$path" ) 2>&1 )" && \
        fail "REGRESSION: _safe_rm_rf ACCEPTED $label ('$path') — it would have run 'rm -rf -- $path'"
    grep -qi 'refus\|too shallow\|not absolute\|is empty' <<<"$out" \
        || fail "_safe_rm_rf refused $label ('$path') but without saying why: ${out//$'\n'/ }"
    note "refuses $label — $(head -1 <<<"$out" | cut -c1-88)"
}

# ── the four guards that had never been watched bite ───────────────────────
refuses "an EMPTY path"        ""
refuses "a RELATIVE path"      "some/relative/dir"
refuses "the ROOT filesystem"  "/"
refuses "a TOO-SHALLOW path"   "/usr"

# A near-miss, so "too shallow" is a boundary and not an accident: /a/b is the documented
# minimum depth, and one component less must still be refused.
refuses "a two-component path" "/var"

# ── the positive control: it must still DELETE a legitimate tree ───────────
# Without this, every assertion above is satisfied by a _safe_rm_rf that refuses
# everything — a guard that never permits anything is not a guard, it is a broken destroy.
victim="$tmp/deep/enough/tree"
mkdir -p "$victim/sub" && : > "$victim/sub/file"
[[ -d "$victim" ]] || fail "could not build the positive-control tree"
( _safe_rm_rf "$victim" ) >/dev/null 2>&1 \
    || fail "_safe_rm_rf REFUSED a legitimate deep, unmounted, absolute path ('$victim') — it now refuses everything, so destroy is broken and the refusals above prove nothing"
[[ ! -e "$victim" ]] \
    || fail "_safe_rm_rf exited 0 on '$victim' but the tree is still there — it reported success without deleting"
note "positive control: a legitimate deep unmounted tree IS removed"

pass "_safe_rm_rf refuses empty, relative, '/', and too-shallow paths by name — and still deletes a legitimate tree (AUDIT F7's guard, with its four never-exercised refusals now observed firing)"
