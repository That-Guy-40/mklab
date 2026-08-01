#!/usr/bin/env bash
# Round-trip: pull alpine, run, exec, logs, destroy.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker

# Preflight: confirm the daemon can actually SIGNAL a container.  Such a host can
# run + exec fine but can never pass the destroy step.
#
# MEASURED CAUSE (2026-08-01): AppArmor mediates signals at BOTH ends.  The container
# runs under `docker-default`, whose stock template has no rule admitting a *confined*
# sender — so when dockerd is itself confined (snap docker runs as
# `snap.docker.dockerd`) the kernel denies the kill:
#
#   apparmor="DENIED" operation="signal" class="signal" profile="docker-default" \
#     requested_mask="receive" signal=kill peer="snap.docker.dockerd"
#
# Confirm on any host with:  journalctl -k | grep 'class="signal"'
# It is NOT seccomp: `--security-opt seccomp=unconfined` is still denied, while
# `--security-opt apparmor=unconfined` succeeds.  An UNCONFINED dockerd (the deb
# docker-ce package) is not mediated at all, so switching daemons resolves it.
#
# When this fires the probe is left behind on purpose — it is running and cannot be
# signalled, so neither `docker rm` nor `docker rm -f` can remove it.  Sweep it after
# fixing the host with tools/lab-sweep.sh.
_probe="probe-rad-preflight-$$"
docker run -d --name "$_probe" alpine:latest sleep 60 >/dev/null 2>&1 \
    || skip "cannot start containers (docker run failed)"
sleep 1  # Ensure the container process is fully running before testing kill.
if ! docker rm -f "$_probe" >/dev/null 2>&1; then
    docker rm "$_probe" >/dev/null 2>&1 || true
    skip "docker rm -f blocked: AppArmor denies docker-default receiving SIGKILL from a confined dockerd (journalctl -k | grep 'class=\"signal\"')"
fi

name="t-run-$$"
cname="lab-${name}"
trap 'cleanup_container "$cname"' EXIT

note "run alpine sleeping in detach mode"
"$LAB_DOCKER" run --name "$name" --image alpine:latest --detach \
    -- /bin/sh -c 'echo READY; sleep 60'

note "verify container exists with our labels"
docker inspect -f '{{.Config.Labels}}' "$cname" | grep -q 'lab-create.tool:lab-docker' \
    || fail "tool label missing"
docker inspect -f '{{.Config.Labels}}' "$cname" | grep -q 'lab-create.lab:adhoc' \
    || fail "adhoc label missing"

note "logs"
"$LAB_DOCKER" logs "$name" | grep -q READY \
    || fail "logs did not include the READY marker"

note "exec"
got="$("$LAB_DOCKER" exec "$name" -- /bin/sh -c 'echo HELLO')"
[[ "$got" == HELLO ]] || fail "exec did not return HELLO; got: $got"

note "list shows our container"
"$LAB_DOCKER" list 2>/dev/null | grep -q "$cname" \
    || fail "list did not show our container"

note "destroy --force"
"$LAB_DOCKER" destroy "$name" --force

docker ps -a --format '{{.Names}}' | grep -qx "$cname" \
    && fail "container still present after destroy"

pass "run + destroy round-trip OK"
