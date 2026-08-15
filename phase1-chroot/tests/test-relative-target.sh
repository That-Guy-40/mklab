#!/usr/bin/env bash
# Regression (REVIEW-phase1.md §3): a RELATIVE `target` must not make every write_files
# entry fail its own jail check.
#
# THE BUG. `apply_write_files` jails each entry with
#
#     dest="$(realpath -m "$target/$path")"      # always ABSOLUTE
#     [[ "$dest" == "$target/"* ]]               # compared to a possibly RELATIVE prefix
#
# so with `target = "rel/tree"` the comparison could never match and every entry was refused
# with "escapes chroot root" — a jail check firing on exactly the thing it exists to permit.
# It failed CLOSED, so it was a rejected valid config rather than a hole; but the rest of the
# driver (the manifest, `_safe_rm_rf`, path-mode lookups) also assumes an absolute target,
# and that assumption was undocumented and unenforced, which is how it survived.
#
# THE FIX is `spec_absolutize_target`, applied once in `create_one` right after
# `validate_spec` — one chokepoint rather than the seven `spec_get "$spec" target` sites,
# for the same reason as UNMANAGED_NAME: a call site added later is then correct by default.
#
# WHAT THIS TEST GUARDS MOST CAREFULLY. The fix changes what a SECURITY check compares
# against, so §3 below re-runs the traversal case in both shapes. A "fix" that made
# `/../escapee.txt` land outside the tree would be far worse than the bug.
#
# Runs unprivileged: writing into a tree this test owns needs no root.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq realpath

work="$(mktemp -d)"
on_exit 'rm -rf -- "$work"'
source "$LAB_CHROOT"          # the real driver, via its sourced-not-run guard

# wf <target> <path> — run the real apply_write_files with the fix applied, capturing the
# `die`. Never piped: `set -o pipefail` is on, and a subshell that dies inside a pipeline
# takes the whole test with it (CLAUDE.md).
wf() {
    local t="$1" p="$2" spec fixed
    spec="$(jq -nc --arg t "$t" --arg p "$p" '{target:$t, write_files:[{path:$p, content:"x"}]}')"
    fixed="$(spec_absolutize_target "$spec")"
    ( apply_write_files "$fixed" "$(spec_get "$fixed" target)" ) 2>&1 || true
}
# wf_raw — the PRE-FIX path: the spec's target used verbatim, no absolutization.
wf_raw() {
    local t="$1" p="$2" spec
    spec="$(jq -nc --arg t "$t" --arg p "$p" '{target:$t, write_files:[{path:$p, content:"x"}]}')"
    ( apply_write_files "$spec" "$(spec_get "$spec" target)" ) 2>&1 || true
}

cd "$work" || fail "setup: could not cd to $work"
mkdir -p rel/tree

# ── 1. POSITIVE: a relative target writes the file ───────────────────────────────────────
out="$(wf "rel/tree" "/hello.txt")"
[[ -f "$work/rel/tree/hello.txt" ]] \
    || fail "REGRESSION: a relative target refused a legitimate write_files entry — the jail check is comparing an absolute realpath against a relative prefix again (REVIEW-phase1.md §3). Got: $(tr '\n' ' ' <<<"$out")"
note "a relative target writes its write_files entries  ✓"

# and the normalization is visible in the spec, not just in the effect
spec="$(jq -nc '{target:"rel/tree"}')"
abs="$(spec_get "$(spec_absolutize_target "$spec")" target)"
[[ "$abs" == /* ]] \
    || fail "spec_absolutize_target left the target relative: '$abs'"
[[ "$abs" == "$work/rel/tree" ]] \
    || fail "spec_absolutize_target resolved to '$abs', expected '$work/rel/tree'"
note "the spec's target is rewritten to an absolute path ($abs)  ✓"

# ── 2. NEGATIVE CONTROL: the pre-fix path still refuses ──────────────────────────────────
# Without this, §1 would pass on any driver where write_files happened to work at all.
rm -f "$work/rel/tree/hello.txt"
out_raw="$(wf_raw "rel/tree" "/hello.txt")"
[[ ! -f "$work/rel/tree/hello.txt" ]] \
    || fail "the pre-fix path (no absolutization) WROTE the file, so §1 is not measuring the defect — this test would pass against the original bug"
grep -q 'escapes chroot root' <<<"$out_raw" \
    || fail "the pre-fix path failed for some reason other than the jail check, so §1 is not measuring the defect. Got: $(tr '\n' ' ' <<<"$out_raw")"
note "negative control: without absolutization the same entry is still refused as 'escapes chroot root'  ✓"

# ── 3. SECURITY CONTROL: the traversal jail still holds, both shapes ─────────────────────
# This is the assertion that matters. Normalizing the target changed what the jail compares
# against; a fix that let `/../escapee.txt` out would be worse than the bug it replaced.
for t in "rel/tree" "$work/rel/tree"; do
    out_t="$(wf "$t" "/../escapee.txt")"
    grep -q 'escapes chroot root' <<<"$out_t" \
        || fail "REGRESSION: path traversal '/../escapee.txt' was NOT refused with target='$t' — absolutizing the target weakened the write_files jail (Finding 1: traversal → host write as root). Got: $(tr '\n' ' ' <<<"$out_t")"
done
escaped="$(find "$work" -name 'escapee.txt' 2>/dev/null)"
[[ -z "$escaped" ]] \
    || fail "REGRESSION: a write_files entry escaped the chroot root and landed at: $escaped"
note "traversal is still refused for both relative and absolute targets, and nothing escaped  ✓"

# ── 4. CONTROL: an already-absolute target is unchanged, and still works ─────────────────
same="$(spec_get "$(spec_absolutize_target "$(jq -nc --arg t "$work/rel/tree" '{target:$t}')")" target)"
[[ "$same" == "$work/rel/tree" ]] \
    || fail "spec_absolutize_target mangled an already-absolute target: '$same'"
out_abs="$(wf "$work/rel/tree" "/abs-ok.txt")"
[[ -f "$work/rel/tree/abs-ok.txt" ]] \
    || fail "an absolute target stopped working after the change. Got: $(tr '\n' ' ' <<<"$out_abs")"
note "control: an absolute target is passed through unchanged and still writes  ✓"

pass "a relative target is normalized to absolute once in create_one, so write_files entries land instead of being refused by their own jail — while path traversal stays refused for relative and absolute targets alike"
