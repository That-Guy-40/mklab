#!/usr/bin/env bash
# test-round-trip.sh — an image pushed to the lab registry comes back byte-identical, and
# a client that does not trust the shared root is REFUSED.
#
# THE SECOND HALF IS THE POINT. "podman push succeeded" is satisfied by a registry with
# `--tls-verify=false`, which is how most lab registries are actually run — and it is
# indistinguishable from a working chain until the day it matters. So this drives the
# driver's `demo`, which pushes twice: once with no CA (must fail with x509) and once with
# the shared root (must succeed). A run where the control did not fire is not a pass.
#
# PRECONDITIONS ARE UNKNOWNS, NOT FAILURES, and they are named. This needs podman, the
# registry image ALREADY PULLED (the test does not reach the network — a suite that fetches
# from Docker Hub fails for reasons that have nothing to do with the code), and the shared
# CA's private key, which is gitignored and therefore absent on any machine but the one
# that made it.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$LAB_DIR/registry-lab.sh"
[[ -x "$DRIVER" ]] || fail "missing the lab driver: $DRIVER"

require_cmd podman curl openssl
CA="$LAB_DIR/../lab-ca"
[[ -r "${LAB_CA_KEYDIR:-$CA/private}/lab-ca.key" ]] \
    || skip "no shared lab CA private key here — issuing the registry's TLS leaf needs it, and it is gitignored by design (examples/lab-ca/make-ca.sh creates one)"
podman image exists docker.io/library/registry:2 2>/dev/null \
    || skip "docker.io/library/registry:2 is not pulled locally — this test does not reach the network, so the image has to be staged first (podman pull docker.io/library/registry:2)"

# Was something already listening? Then leave it alone rather than fighting it: the port is
# the one shared piece of host state this lab touches.
port="${REGISTRY_HOSTPORT:-localhost:5000}"; port="${port##*:}"
started_here=0
if ! ( "$DRIVER" status ) >/dev/null 2>&1; then
    if ss -lnt 2>/dev/null | grep -qE "127\.0\.0\.1:${port}[[:space:]]"; then
        skip "127.0.0.1:$port is in use by something that is not this lab's registry — refusing to disturb it"
    fi
    ( "$DRIVER" certs ) >/dev/null 2>&1 || fail "could not issue the registry's TLS leaf from the shared CA"
    ( "$DRIVER" up )    >/dev/null 2>&1 || fail "could not start the registry through phase4-podman/lab-podman.sh"
    started_here=1
    on_exit '(( started_here == 1 )) && ( "$DRIVER" down ) >/dev/null 2>&1'
    note "started the registry for this test (and will stop it)"
else
    note "a registry was already up — using it, and leaving it running"
fi

out="$( "$DRIVER" demo 2>&1 )" && rc=0 || rc=$?
(( rc == 0 )) || fail "the push/pull round trip failed: $(tail -3 <<<"$out" | tr '\n' ' ')"

# Assert on what the run PROVED, not merely that it exited 0 — the control firing is the
# load-bearing half, and a demo that silently stopped running it would still exit 0.
grep -q 'CONTROL: pushing with NO CA' <<<"$out" \
    || fail "REGRESSION: the demo no longer runs the no-CA control. Without it, 'the push worked' is equally true of a registry nobody is verifying"
grep -q 'x509' <<<"$out" \
    || fail "REGRESSION: the CA-less push was not refused with a certificate error — TLS verification is not actually happening, and the chain to the shared root is decoration"
grep -q 'identical going in and coming out' <<<"$out" \
    || fail "the demo did not report a matching digest — the round trip is not being compared on the manifest digest"
digest="$(grep -oE 'sha256:[0-9a-f]{64}' <<<"$out" | head -1)"
[[ -n "$digest" ]] || fail "no manifest digest in the demo output, so nothing was compared"
note "control fired (x509 refusal) and the digest round-tripped: ${digest:0:23}…"

pass "an image pushed to the lab registry returns with the identical manifest digest, the TLS chain verifies against the SHARED lab root CA, and a client without that root is refused with x509 — the control that separates a real chain from --tls-verify=false"
