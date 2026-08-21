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
# (`run --name <NEW-NAME> --tarball FILE`) and watching it die at the last inch:
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

# TODO A.4's ground truth, read from the ORIGINAL container while it still exists, and
# from the ENGINE rather than from the spec that asked for it.
#
# This line exists because its absence let a control walk straight through. The first
# version of the A.4 section below compared the revived container's argv against the argv
# it had just read out of the MANIFEST — a comparison of the record with itself.
# Sabotaging preserve.sh to record `["sleep","999"]` for a container running `sleep 600`
# produced a manifest that was wrong, a revival that faithfully replayed the wrong value,
# and a green PASS. The property is not "the replay matches the record"; it is "the record
# matches what was preserved", and only the original can answer that.
ORIG_ARGV="$(podman inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "lab-${LAB}-keeper" 2>/dev/null || true)"
[[ -n "$ORIG_ARGV" ]] \
    || fail "could not read the original container's argv — there is nothing to compare a restore against"
note "original argv (ground truth): $ORIG_ARGV"

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

# ── TODO A.4: the INTENT survives too, and the proof is a container that RUNS ───────────
# Above proves the loss. This proves what closed it. The image still has no config — that
# is `export`, and nothing here can change it — so the argv has to come from the manifest,
# which means the manifest has to have it. Assert the OUTCOME (a container in state
# `running`, executing the original's argv), not the mechanism (a field being present):
# a `command = [...]` row could be there and still be the wrong argv, or unusable.
grep -qE '^command +=' "$MAN"     || fail "REGRESSION: the derivation records no 'command' — TODO A.4 put it there so a restore stops handing back an image nothing can start"
grep -qE '^entrypoint +=' "$MAN"  || fail "REGRESSION: the derivation records no 'entrypoint'"
grep -qE '^argv_source +=' "$MAN" || fail "REGRESSION: the derivation records no 'argv_source' — the value is only replayable if we know HOW it was derived"
note "manifest argv: $(sed -n 's/^entrypoint *= *//p' "$MAN" | head -1) + $(sed -n 's/^command *= *//p' "$MAN" | head -1) (source: $(sed -n 's/^argv_source *= *"\(.*\)"$/\1/p' "$MAN" | head -1))"

# The advice line is meant to be PASTED, so its placeholder must look like one. It read
# `--name NEW` until 2026-08-20, which is a legal container name: pasting it verbatim
# silently created a container called `lab-NEW` and reported success. `<NEW-NAME>` is a
# shell redirection, so the same paste dies with a syntax error before podman is reached —
# an honest failure instead of a false one. Asserted on the real output, not on the source.
case "$out" in
    *'--name NEW '*|*'--name NEW"'*)
        fail "REGRESSION: the restore advice offers a bare '--name NEW' — that is a VALID container name, so a reader who pastes the line gets a container called lab-NEW and no warning. Use a placeholder that cannot be pasted by accident." ;;
esac
case "$out" in
    *'--name <NEW-NAME>'*) ;;
    *) fail "REGRESSION: the restore advice no longer carries a visible <NEW-NAME> placeholder — output was:\n$out" ;;
esac

case "$out" in
    *'Start it with the argv this backup recorded:'*) ;;
    *) fail "REGRESSION: restore did not offer the recorded argv — it fell back to the '<cmd>' placeholder that TODO A.4 removed. Output was:\n$out" ;;
esac

# Take the argv from the DERIVATION rather than from the string restore printed: parsing
# the advice line back would test this test's own regex against its own prose. The
# manifest's `command`/`entrypoint` rows are TOML arrays that are also valid JSON, on
# purpose, so jq reads them directly.
_ep="$(sed -n 's/^entrypoint *= *//p' "$MAN" | head -1)"
_cmd="$(sed -n 's/^command *= *//p'    "$MAN" | head -1)"
mapfile -t RESTORED_ARGV < <(jq -r --argjson ep "${_ep:-[]}" --argjson cmd "${_cmd:-[]}" -n '($ep + $cmd)[]')
(( ${#RESTORED_ARGV[@]} > 0 ))     || fail "REGRESSION: the recorded argv is empty for a container created with command = \"sleep 600\" — the driver reported nothing, or the manifest lost it"

RNAME="${LAB}-revived"
on_exit 'podman rm -f "lab-${LAB}-revived" >/dev/null 2>&1 || true'
out2="$(bash "$TOOL" run --name "$RNAME" --image "$TAG" --detach -- "${RESTORED_ARGV[@]}" 2>&1)"; rc=$?
(( rc == 0 )) || fail "REGRESSION: the argv the derivation recorded does not start the restored image (rc=$rc): $out2"

# `run` returning 0 is the engine accepting the request, not the container running — the
# same distinction REVIEW-phase7.md P7-4 was written about. Read the state back.
state=""
for _i in 1 2 3 4 5 6 7 8 9 10; do
    state="$(podman inspect -f '{{.State.Status}}' "lab-${LAB}-revived" 2>/dev/null || true)"
    [[ "$state" == "running" ]] && break
    sleep 0.5
done
[[ "$state" == "running" ]]     || fail "REGRESSION: the restored image started with the recorded argv and is not running (state: ${state:-<none>}) — an unstartable restore reported as success is the liar case"

# …and it is running THE ORIGINAL'S argv. Compared against $ORIG_ARGV — captured from the
# original container above — and NOT against what the manifest said, which would compare
# the record with itself and pass over a manifest that recorded the wrong thing.
got_argv="$(podman inspect -f '{{range .Config.Cmd}}{{.}} {{end}}' "lab-${LAB}-revived" 2>/dev/null || true)"
[[ "$got_argv" == "$ORIG_ARGV" ]] \
    || fail "REGRESSION: the revived container does not run the ORIGINAL's argv — it runs '$got_argv' where the container this backup describes ran '$ORIG_ARGV'"

# The same comparison against the record itself, so a mismatch says WHICH half moved: a
# manifest that disagrees with the original is a bad RECORDING; a revival that disagrees
# with the manifest is a bad REPLAY. One message each, rather than one that covers both
# and identifies neither.
[[ "${RESTORED_ARGV[*]} " == "$ORIG_ARGV" ]] \
    || fail "REGRESSION: the DERIVATION recorded the wrong argv — it says '${RESTORED_ARGV[*]}' for a container that ran '$ORIG_ARGV'"

note "revived from the derivation's own argv: ${RESTORED_ARGV[*]}"

pass "a marker written into a LIVE container survived export → derivation → destroy → restore; the restore named the image config it could not bring back AND replayed the argv it recorded into a container that is RUNNING it"
