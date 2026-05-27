#!/usr/bin/env bash
# Bring up a 3-service topology, verify, tear down. Hits Phase 3's
# headline exit criterion.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd jq curl

# Preflight: confirm containers can be force-removed on this host.  The
# teardown path uses docker rm -f; hosts with AppArmor profiles that block
# SIGKILL delivery (permission denied) will fail at the "verify nothing left"
# assertion rather than an infra issue, so skip early.
_probe="probe-topo-preflight-$$"
docker run -d --name "$_probe" alpine:latest sleep 60 >/dev/null 2>&1 \
    || skip "cannot start containers (docker run failed)"
sleep 1  # Ensure the container process is fully running before testing kill.
if ! docker rm -f "$_probe" >/dev/null 2>&1; then
    docker rm "$_probe" >/dev/null 2>&1 || true
    skip "docker rm -f not functional on this host (AppArmor / seccomp restriction)"
fi

# Need a TOML parser.
if ! command -v tomlq >/dev/null 2>&1 \
   && ! command -v dasel >/dev/null 2>&1 \
   && ! ( command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -qi mikefarah ); then
    skip "no TOML parser (need yq/tomlq/dasel)"
fi

# Build a self-contained 3-svc topology to avoid depending on examples/
# being present at exactly the right relative path.
cfg="$(mktemp --suffix=.toml)"
lab="ttd$$"
trap 'rm -f "$cfg"; cleanup_lab "$lab"' EXIT

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[network.front]
driver = "bridge"

[[service]]
name     = "web"
image    = "nginx:alpine"
networks = ["front"]
ports    = ["18099:80"]

[[service]]
name     = "client"
image    = "alpine:latest"
networks = ["front"]
command  = "sleep 60"

[[service]]
name     = "client2"
image    = "alpine:latest"
networks = ["front"]
command  = "sleep 60"
EOF

note "up"
"$LAB_DOCKER" up --config "$cfg"

note "verify network"
docker network ls --filter "label=lab-create.lab=${lab}" -q | grep -q . \
    || fail "topology network not created"

note "verify 3 containers"
n="$(docker ps -aq --filter "label=lab-create.lab=${lab}" | wc -l)"
[[ "$n" -eq 3 ]] || fail "expected 3 containers, found $n"

note "list --lab"
"$LAB_DOCKER" list --lab "$lab" >/dev/null

note "curl the web service (allow up to 10s for nginx to come up)"
got=""
for i in $(seq 1 10); do
    got="$(curl -s --max-time 2 http://localhost:18099/ 2>/dev/null || true)"
    [[ -n "$got" ]] && break
    sleep 1
done
grep -qi 'nginx' <<<"$got" || fail "web service did not respond with an nginx page"

note "exec into client"
"$LAB_DOCKER" exec "${lab}/client" -- /bin/sh -c 'echo HELLO' | grep -qx HELLO \
    || fail "exec into client did not return HELLO"

note "down"
"$LAB_DOCKER" down --lab "$lab"

note "verify nothing left"
n="$(docker ps -aq --filter "label=lab-create.lab=${lab}" | wc -l)"
[[ "$n" -eq 0 ]] || fail "containers still present after down"
n="$(docker network ls -q --filter "label=lab-create.lab=${lab}" | wc -l)"
[[ "$n" -eq 0 ]] || fail "networks still present after down"

pass "topology up/down round-trip OK"
