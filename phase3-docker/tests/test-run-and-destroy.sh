#!/usr/bin/env bash
# Round-trip: pull alpine, run, exec, logs, destroy.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker

# Preflight: confirm docker rm -f works on this host.  Hosts with AppArmor
# profiles that block SIGKILL delivery (permission denied) can run + exec
# fine but can never pass the destroy step.
_probe="probe-rad-preflight-$$"
docker run -d --name "$_probe" alpine:latest sleep 60 >/dev/null 2>&1 \
    || skip "cannot start containers (docker run failed)"
sleep 1  # Ensure the container process is fully running before testing kill.
if ! docker rm -f "$_probe" >/dev/null 2>&1; then
    docker rm "$_probe" >/dev/null 2>&1 || true
    skip "docker rm -f not functional on this host (AppArmor / seccomp restriction)"
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
