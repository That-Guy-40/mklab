#!/usr/bin/env bash
# §14 slice 7's exercise, against a REAL engine: back up a lab, restore it, prove it is
# the same — and be precise about which half of "the same" survives tier 2.
#
# The sibling `test-preserve-gate.sh` proves the refusal, headless and everywhere. This one
# proves the thing worth refusing over actually works, and it needs a live rootless podman
# to do it: a fixture round-trips because the fixture says so.
#
# ── WHAT "PROVE IT IS THE SAME" MEANS HERE, AND WHY IT IS A MARKER ──────────────────────
# A marker file is written INTO THE RUNNING CONTAINER after it starts — not baked into the
# image, and not pre-written into a fixture the test hands to the exporter. Effects follow
# causes: the bytes exist because something ran, which is the only version of this that
# proves the export read the container's own filesystem rather than its image's.
# (metal-as-a-service shipped console fixtures written BEFORE the deploy for weeks; they
# proved the driver could grep a file the test had just written it.)
#
# ── AND THE HALF THAT DOES NOT SURVIVE, ASSERTED AS AN OUTCOME ──────────────────────────
# `podman export` writes the filesystem and NOT the OCI config, so the image `import`
# builds back has no CMD. This was found by trying the round trip the drivers advertise
# (`run --name NEW --tarball FILE`) and watching it die at the last inch:
#
#     Error: no command or entrypoint provided, and no CMD or ENTRYPOINT from image
#
# §9.5 says the portable tier "loses running state". It also loses the image's
# CONFIGURATION, and a restore that quietly produced an unstartable image while reporting
# success would be the liar case. So the loss is asserted in both directions below: the
# filesystem came back, and starting it still needs a command supplied.
set -uo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

PRESERVE="$LAB_DIR/preserve.sh"
TOOL="$REPO_DIR/phase4-podman/lab-podman.sh"
IMAGE="docker.io/library/busybox:latest"
LAB="mcpreservert"
MARKER="PRESERVE-ROUNDTRIP-4c9e"
TAG="mklab-restored-podman-${LAB}-keeper"

[[ -x "$PRESERVE" ]] || fail "preserve.sh is missing or not executable at $PRESERVE"
need podman tar sha256sum
podman image exists "$IMAGE" \
    || skip "no local $IMAGE — this test drives a real engine and will not pull over the network to do it"

WORK="$(mktemp -d)"; on_exit 'rm -rf -- "$WORK"'
export LAB_STATE_DIR="$WORK/state"
# Teardown through the phase tool's own lifecycle verb, and the image by the name we gave
# it — never a pattern. Registered BEFORE anything is created, so it runs however this ends.
on_exit 'bash "$TOOL" down --lab "$LAB" >/dev/null 2>&1 || true'
on_exit 'podman rmi -f "$TAG" >/dev/null 2>&1 || true'

cat > "$WORK/spec.toml" <<EOF
[lab]
name = "$LAB"

[[service]]
name = "keeper"
engine = "podman"
image = "$IMAGE"
manager = "plain"
command = "sleep 600"
EOF

# A leftover from an earlier run would make every assertion below meaningless.
podman ps -a --format '{{.Names}}' | grep -qx "lab-${LAB}-keeper" \
    && fail "a container from a previous run is still here (lab-${LAB}-keeper) — refusing to run over it"

out="$(bash "$TOOL" up --config "$WORK/spec.toml" 2>&1)"; rc=$?
(( rc == 0 )) || fail "could not bring the lab up (rc=$rc): $out"

# The marker goes in AFTER it is running. See the header.
podman exec "lab-${LAB}-keeper" sh -c "echo $MARKER > /etc/mklab-preserve-marker" \
    || fail "could not write the marker into the running container"

# ── save ────────────────────────────────────────────────────────────────────────────────
out="$(bash "$PRESERVE" save --tier portable --out "$WORK/bk" --spec "$WORK/spec.toml" "podman:$LAB/keeper" 2>&1)"; rc=$?
(( rc == 0 )) || fail "save failed against a live podman (rc=$rc): $out"
MAN="$WORK/bk/derivation.toml"
[[ -r "$MAN" ]] || fail "save wrote no manifest"

# The derivation must record what §9.5 asks of it, or it is a checksum file with ambitions.
for field in 'created' 'tier' 'tool_sha256' 'repo_commit'; do
    grep -qE "^${field} +=" "$MAN" || fail "the derivation records no '$field' — §9.5 asks for source, digests, tool versions and date"
done
grep -q '^\[spec\]' "$MAN"        || fail "--spec was given and no [spec] block was written"
grep -qE '^engine_version +=' "$MAN" || fail "the derivation records no engine version"
grep -qE '^driver_sha256 +=' "$MAN"  || fail "the derivation identifies the driver by no digest — a version string is not an identity"
note "manifest records: $(sed -n 's/^engine_version *= *"\(.*\)"$/\1/p' "$MAN" | head -1)"

out="$(bash "$PRESERVE" verify "$WORK/bk" 2>&1)"; rc=$?
(( rc == 0 )) || fail "verify refused a backup taken seconds earlier (rc=$rc): $out"

# ── destroy the original, then restore ──────────────────────────────────────────────────
# "Back up a lab, DESTROY it, restore it." Restoring beside a living original would not
# distinguish a working restore from a test reading the thing it never removed.
out="$(bash "$TOOL" down --lab "$LAB" 2>&1)"; rc=$?
(( rc == 0 )) || fail "could not tear the lab down (rc=$rc): $out"
! podman ps -a --format '{{.Names}}' | grep -qx "lab-${LAB}-keeper" \
    || fail "down reported success and the container is still there"

out="$(bash "$PRESERVE" restore "$WORK/bk" 2>&1)"; rc=$?
(( rc == 0 )) || fail "restore failed (rc=$rc): $out"
podman image exists "$TAG" || fail "restore reported success and no image '$TAG' exists — the liar case"

# ── prove it is the same: the marker survived ───────────────────────────────────────────
got="$(podman run --rm "$TAG" cat /etc/mklab-preserve-marker 2>&1)"; rc=$?
(( rc == 0 )) || fail "could not read the marker back out of the restored image: $got"
[[ "$got" == "$MARKER" ]] \
    || fail "REGRESSION: the restored filesystem is not the one that was preserved — expected '$MARKER', got '$got'"

# ── …and prove the half that did NOT survive, so the claim stays honest ─────────────────
if podman run --rm "$TAG" >/dev/null 2>&1; then
    fail "the restored image HAS a default command now — podman started carrying the OCI config through export/import, so preserve.sh should stop saying it does not (see its restore comment)"
fi
grep -q 'what came back, and what did NOT' <<<"$out" \
    || fail "restore did not tell the operator what it could not restore — an unstartable image reported as a clean success is the liar case"

pass "a marker written into a LIVE container survived export → derivation → destroy → restore, and the restore named the image config it could not bring back"
