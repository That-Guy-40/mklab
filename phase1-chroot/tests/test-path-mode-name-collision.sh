#!/usr/bin/env bash
# Regression (REVIEW-phase1.md, P1-1): a path-mode verb must not bind to a manifest that
# merely shares its target's BASENAME.
#
# THE BUG. `resolve_target_and_manager`, given an absolute path with no manifest whose
# `target` matches, synthesized the chroot name from the path's basename. `manifest_path`
# maps a bare NAME, so every downstream `read_manifest_field "$name"` / `remove_manifest
# "$name"` then bound to whatever UNRELATED managed chroot happened to share that basename:
#
#     lab-chroot.sh destroy /somewhere/else/shared --force
#       → tears down /somewhere/else/shared            (correct)
#       → then deletes the managed `shared`'s manifest (wrong)
#       → tree survives on disk with no record, invisible to `list` — ORPHANED
#
# Two more symptoms from the same root cause, both exercised below: `inspect` on an
# unrelated directory printed the managed chroot's `backend` and `lab`, and a colliding
# manifest's `rootless=true` flipped destroy's `EUID==0` gate for a path that is not that
# rootless tree.
#
# WHY THIS RUNS UNPRIVILEGED, AND WITHOUT BUILDING A CHROOT. The defect lives entirely in
# name resolution, so the fixture is a manifest plus two empty directories — and the
# manifest is written by the driver's OWN `write_manifest`, not hand-rolled, so it cannot
# drift from the real schema. The privilege-gate symptom is actually SHARPEST as an
# ordinary user, because that is who the flipped gate would have let through.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq

work="$(mktemp -d)"
on_exit 'rm -rf -- "$work"'
export LAB_STATE_DIR="$work/state" LAB_CACHE_DIR="$work/cache"

real="$work/real/shared"          # a MANAGED chroot named `shared`
other="$work/elsewhere/shared"    # an unrelated directory with the same basename
mkdir -p "$real" "$other"
echo "keep-me" > "$real/sentinel"

# The managed chroot's manifest, written by the real writer. `rootless = "true"` is the
# field whose misreading flips destroy's root gate, so it is part of the fixture.
( source "$LAB_CHROOT"
  write_manifest shared "$real" host-copy "" "" amd64 none SECRETLAB
  printf 'rootless   = "true"\n' >> "$(manifest_path shared)" )
manifest="$LAB_STATE_DIR/chroots/shared.toml"
[[ -f "$manifest" ]] || fail "setup: the managed chroot's manifest was not written to $manifest"
# Captured, never piped: `grep -q` closes the pipe on its first match, `list` dies of
# SIGPIPE, and under `pipefail` the PIPELINE status is 141 — so `| grep -q … || fail` fails
# on a successful list. (CLAUDE.md: never pipe a command whose exit status is the gate.)
listing="$(bash "$LAB_CHROOT" list 2>/dev/null || true)"
grep -q '^shared ' <<<"$listing" \
    || fail "setup: 'list' does not show the managed chroot, so this test cannot detect it being orphaned"

# ── 1. inspect on an unrelated path must not report the managed chroot's metadata ────────
j="$(bash "$LAB_CHROOT" inspect "$other" --json 2>/dev/null)" \
    || fail "setup: 'inspect $other --json' failed outright"
[[ "$(jq -r '.manifest.backend' <<<"$j")" != "host-copy" ]] \
    || fail "REGRESSION: 'inspect' on an unrelated directory reported the MANAGED chroot's backend=host-copy — it bound to a manifest by basename (REVIEW-phase1.md P1-1)"
[[ "$(jq -r '.manifest.lab' <<<"$j")" != "SECRETLAB" ]] \
    || fail "REGRESSION: 'inspect' on an unrelated directory leaked the managed chroot's lab name SECRETLAB"
note "inspect on an unrelated path reports no manifest fields — no basename binding  ✓"

# ── 2. destroy must not act on the colliding manifest ────────────────────────────────────
# As an ordinary user the symptom is the flipped privilege gate: the colliding manifest says
# rootless=true, so pre-fix destroy skipped `EUID==0` and went ahead. As root the gate is
# open anyway, and the symptom is the manifest deletion asserted in §3. Both are real
# outcomes of the same defect, so the test asserts whichever one applies rather than skipping.
d_out="$(bash "$LAB_CHROOT" destroy "$other" --force 2>&1)" && d_rc=0 || d_rc=$?
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    (( d_rc != 0 )) \
        || fail "REGRESSION: 'destroy' on an unrelated path SUCCEEDED as a non-root user — it read rootless=true from the managed chroot's manifest, which it matched by basename, and skipped the EUID==0 gate. Output: $(tr '\n' ' ' <<<"$d_out")"
    grep -q 'requires root' <<<"$d_out" \
        || fail "'destroy' refused for some reason other than the root gate, so this assertion is not measuring the collision. Got: $(tr '\n' ' ' <<<"$d_out")"
    note "destroy of an unrelated path is refused as non-root — the colliding rootless=true did not flip the gate  ✓"
else
    note "running as root: the privilege-gate symptom cannot arise; §3 carries the assertion"
fi

# ── 3. the managed chroot must still exist ───────────────────────────────────────────────
[[ -f "$manifest" ]] \
    || fail "REGRESSION: 'destroy $other' deleted the MANAGED chroot's manifest — the managed tree at $real is now orphaned on disk and invisible to 'list' (REVIEW-phase1.md P1-1)"
listing="$(bash "$LAB_CHROOT" list 2>/dev/null || true)"
grep -q '^shared ' <<<"$listing" \
    || fail "REGRESSION: the managed chroot vanished from 'list' after destroying an unrelated path"
[[ -f "$real/sentinel" ]] \
    || fail "REGRESSION: 'destroy' on the unrelated path removed the MANAGED chroot's tree"
note "the managed chroot survives: manifest on disk, listed, tree intact  ✓"

# ── 4. CONTROL: legitimate manifest reads still work ─────────────────────────────────────
# Without this, §1 would also pass if the sentinel guard had broken read_manifest_field for
# EVERY name — a resolver that can never find a manifest would satisfy every assertion above
# while making the tool useless.
jm="$(bash "$LAB_CHROOT" inspect shared --json 2>/dev/null)" \
    || fail "'inspect shared --json' failed — the sentinel guard broke lookups by real name"
[[ "$(jq -r '.manifest.backend' <<<"$jm")" == "host-copy" ]] \
    || fail "CONTROL FAILED: inspecting the managed chroot BY NAME no longer reports its backend — read_manifest_field is refusing legitimate names, which would make assertion 1 pass for the wrong reason"
[[ "$(jq -r '.manifest.lab' <<<"$jm")" == "SECRETLAB" ]] \
    || fail "CONTROL FAILED: inspecting the managed chroot by name no longer reports its lab"
note "control: lookups by a real name still resolve, so the guard refuses only the sentinel  ✓"

# ── 5. NEGATIVE CONTROL: re-inject the basename synthesis and watch it orphan ─────────────
# A copy of the driver with ONLY the pre-fix resolver line restored. If this does not
# reproduce the orphaning, then everything above is passing for some other reason.
pre="$work/lab-chroot-prefix.sh"
sed 's|printf .%s\\t%s\\t%s\\n. "\$UNMANAGED_NAME" "\$arg" "none"|printf "%s\\t%s\\t%s\\n" "${arg##*/}" "$arg" "none"|' \
    "$LAB_CHROOT" > "$pre"
grep -q 'arg##\*/' "$pre" \
    || fail "the negative control could not re-inject the pre-fix basename synthesis, so it proves nothing (the resolver line must have changed shape)"
bash -n "$pre" || fail "the re-injected pre-fix driver does not parse"

mkdir -p "$other"
p_out="$(bash "$pre" destroy "$other" --force 2>&1)" && p_rc=0 || p_rc=$?
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    (( p_rc == 0 )) \
        || fail "the pre-fix driver did NOT sail past the root gate as a non-root user, so §2 above is not measuring the defect. Got (rc=$p_rc): $(tr '\n' ' ' <<<"$p_out")"
fi
[[ ! -f "$manifest" ]] \
    || fail "the pre-fix driver did NOT delete the managed chroot's manifest, so §3 above is not measuring the defect — this test would pass against the original bug"
[[ -f "$real/sentinel" ]] \
    || fail "the negative control destroyed the wrong tree entirely — the fixture is wrong, not the driver"
note "negative control: the pre-fix resolver orphans the managed chroot (manifest gone, tree left) — the assertions above are measuring the real defect  ✓"

pass "path-mode verbs no longer bind to a manifest by basename: destroy/inspect on an unrelated path leave the managed chroot's manifest, tree and privilege gate alone, while lookups by a real name still resolve (with the pre-fix resolver re-injected, the same destroy orphans it)"
