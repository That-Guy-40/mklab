#!/usr/bin/env bash
# test-spec-paths.sh — the TRACKED spec must be portable, and rendering it must produce the
# paths this lab actually needs.
#
# WHY, AND THE PART THAT IS NOT THE OBVIOUS LESSON. podman needs absolute host paths for a
# bind mount. Five specs in this repo answer that by hard-coding one checkout's path — a
# cached fact about a machine in a tracked file, which is how TODO 15.7's sibling came to
# name `/home/user/…` (absolute, and nobody's home directory) for months without anyone
# noticing: the only question ever asked of it was whether it began with a slash.
#
# THE FIRST DRAFT OF THIS TEST MADE THE SAME TRADE. It hard-coded the path and derived the
# expected value to compare against — a real improvement, and still wrong. CI's checkout is
# /home/runner/work/mklab/mklab, so it failed there within the hour, correctly, on a design
# that could never have passed anywhere but one machine. **A value that is false everywhere
# except one machine is not rescued by checking it.** The spec now carries @LAB_DIR@ and the
# absolute paths exist only in a rendered copy nobody commits.
#
# Needs no podman, no network and no registry — this is the half that can always be checked,
# on any machine, which is exactly the property the first draft did not have.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$LAB_DIR/registry-lab.sh"
SPEC="$LAB_DIR/local-registry.toml"
[[ -x "$DRIVER" ]] || fail "missing the lab driver: $DRIVER"
[[ -r "$SPEC"   ]] || fail "missing the spec template: $SPEC"

# ── 1. the TRACKED template is portable ─────────────────────────────────────────────────
grep -qF '@LAB_DIR@' "$SPEC" \
    || fail "REGRESSION: local-registry.toml has no @LAB_DIR@ placeholder. Someone substituted a real path into the TRACKED file, which makes it true on one machine and false on every other — the 15.7 shape, and the reason this test exists"
abs="$(grep -nE '"(/[A-Za-z0-9._-]+)+/state/' "$SPEC" || true)"
[[ -z "$abs" ]] \
    || fail "REGRESSION: the TRACKED spec contains an absolute host path — $abs. That path is false on every machine but one, and no amount of checking rescues it; render it instead"
note "the tracked template is portable: @LAB_DIR@, no absolute host path"

# ── 2. rendering produces what this lab needs ───────────────────────────────────────────
# The driver owns both halves (what the paths are, and how they are substituted), so they
# are asked of it rather than re-implemented here — the repo's "extract the shipped thing".
mapfile -t want < <("$DRIVER" paths)
(( ${#want[@]} == 2 )) \
    || fail "registry-lab.sh paths printed ${#want[@]} line(s), expected 2 — the driver and this test disagree about what a volume line is, so nothing below is checking anything"
rendered="$("$DRIVER" render | tail -1)"
[[ -r "$rendered" ]] || fail "registry-lab.sh render did not produce a readable file (got '$rendered')"
for w in "${want[@]}"; do
    grep -qF -- "$w" "$rendered" \
        || fail "the rendered spec is missing the volume line this lab needs:
      want: $w
    The template's @LAB_DIR@ lines and the driver's idea of the paths have drifted apart,
    so the container would mount something other than this lab's state directory."
done
grep -qF '@LAB_DIR@' "$rendered" \
    && fail "the rendered spec still contains @LAB_DIR@ — the substitution did not happen, and podman would be handed a literal placeholder as a host path"
note "rendered: both volume lines name this lab, and no placeholder survives"

# ── 3. the controls: each half must be able to fail ─────────────────────────────────────
tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
cp -a "$LAB_DIR/." "$tmp/lab" 2>/dev/null || fail "could not copy the lab for the controls"
rm -rf "$tmp/lab/state"

# (a) a template with the placeholder already substituted — the 15.7 defect, re-injected
awk -v d="/somewhere/else" '{ gsub(/@LAB_DIR@/, d); print }' "$SPEC" > "$tmp/lab/local-registry.toml"
if ( cd "$tmp/lab" && ./registry-lab.sh spec-check ) >/dev/null 2>&1; then
    fail "CONTROL DID NOT FIRE: spec-check accepted a template whose @LAB_DIR@ had been replaced by a real absolute path — exactly the defect that shipped in the first draft"
fi
note "control: a template carrying a hard-coded absolute path is refused"

# (b) a template whose mount target drifted from what the driver expects
cp -a "$LAB_DIR/local-registry.toml" "$tmp/lab/local-registry.toml"
sed -i 's#/certs:ro,Z#/certs-WRONG:ro,Z#' "$tmp/lab/local-registry.toml"
if ( cd "$tmp/lab" && ./registry-lab.sh spec-check ) >/dev/null 2>&1; then
    fail "CONTROL DID NOT FIRE: spec-check accepted a spec whose volume line no longer matches the driver — the two would mount different things and nothing would say so"
fi
note "control: a drifted volume line is refused"

# ── 4. loopback is a security decision, so it is asserted ───────────────────────────────
grep -qE '^\s*ports\s*=\s*\["127\.0\.0\.1:' "$SPEC" \
    || fail "REGRESSION: the registry is no longer bound to 127.0.0.1. It has no authentication — the loopback bind is the only reason that is acceptable, and this lab says so in its README"
note "the registry is bound to loopback, which is what makes 'no auth' defensible here"

pass "the tracked spec is portable (@LAB_DIR@, no absolute host path), rendering it produces exactly the volume lines the driver asks for with no placeholder left, both halves were watched to fail on injected defects, and the registry stays bound to 127.0.0.1"
