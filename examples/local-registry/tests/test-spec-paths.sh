#!/usr/bin/env bash
# test-spec-paths.sh — the spec's absolute volume paths must name THIS checkout.
#
# WHY (TODO 15.7, applied before it can happen again). podman needs absolute host paths for
# a bind mount, so `local-registry.toml` carries two of them — which makes them a cached
# fact about a machine sitting in a tracked file. The sibling spec that did the same thing
# named `/home/user/mklab/…` from the day it was written: absolute, and nobody's home
# directory on any machine. Nothing noticed for months, because the only question ever
# asked of that path was whether it began with a slash.
#
# So the expected value is DERIVED from where this test is standing, and compared. Needs
# no podman, no network and no registry: this is the half of the lab that can always be
# checked, which is exactly why it is separated from the round trip.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$LAB_DIR/registry-lab.sh"
SPEC="$LAB_DIR/local-registry.toml"
[[ -x "$DRIVER" ]] || fail "missing the lab driver: $DRIVER"
[[ -r "$SPEC"   ]] || fail "missing the spec: $SPEC"

# The driver is the one that knows what the paths must be; asking it (rather than
# re-deriving them here) is the repo's "extract the shipped thing, never re-implement it".
mapfile -t want < <("$DRIVER" paths)
(( ${#want[@]} == 2 )) \
    || fail "registry-lab.sh paths printed ${#want[@]} line(s), expected 2 — the driver and this test disagree about what a volume line looks like, so nothing below is checking the spec"

for w in "${want[@]}"; do
    grep -qF -- "$w" "$SPEC" \
        || fail "REGRESSION: local-registry.toml does not contain the volume line this checkout needs:
      want: $w
    An absolute path that exists on no machine passes an 'is it absolute?' check, which is
    how the zfsbootmenu spec carried /home/user/… unnoticed (TODO 15.7)."
done
note "both volume lines name this checkout, derived from the driver's own location"

# …and the driver must actually refuse a spec that does not match, or the check above is
# a statement about a file nobody consults. Run it against a copy with one path mangled.
tmp="$(mktemp -d)"; on_exit 'rm -rf "$tmp"'
cp -a "$LAB_DIR/." "$tmp/lab" 2>/dev/null || fail "could not copy the lab for the control"
sed -i 's#/certs:ro,Z#/certs-WRONG:ro,Z#' "$tmp/lab/local-registry.toml"
if ( cd "$tmp/lab" && ./registry-lab.sh spec-check ) >/dev/null 2>&1; then
    fail "CONTROL DID NOT FIRE: spec-check accepted a spec whose volume path had been changed — it is not comparing anything"
fi
note "control: a mangled volume path is refused by spec-check"

# The loopback bind is a security decision, not a default, so it is asserted rather than
# left to whoever edits the file next: an unauthenticated registry on 0.0.0.0 is a
# write-anything artifact store for the whole network.
grep -qE '^\s*ports\s*=\s*\["127\.0\.0\.1:' "$SPEC" \
    || fail "REGRESSION: the registry is no longer bound to 127.0.0.1. It has no authentication — the loopback bind is the only reason that is acceptable, and this lab documents it as such"
note "the registry is bound to loopback, which is what makes 'no auth' defensible here"

pass "local-registry.toml names this checkout in both volume mounts (derived from the driver, not re-implemented), spec-check refuses a path that does not match, and the registry stays bound to 127.0.0.1"
