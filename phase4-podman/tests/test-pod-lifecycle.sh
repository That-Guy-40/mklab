#!/usr/bin/env bash
# Pod manager: 3 services share a pod; verify they see each other on localhost.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman
require_rootless_ready

LAB="pod-lifecycle-$$"
CONFIG="$(mktemp --suffix=.toml)"
trap 'rm -f "$CONFIG"; cleanup_lab "$LAB"' EXIT

cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[pod]]
name = "p"
publish = ["19998:80"]

[[service]]
name    = "a"
image   = "docker.io/library/nginx:alpine"
manager = "pod"
pod     = "p"

[[service]]
name    = "b"
image   = "docker.io/library/alpine:latest"
manager = "pod"
pod     = "p"
command = "sleep 300"
EOF

note "up (pod with 2 services)"
"$LAB_PODMAN" up --config "$CONFIG" >/dev/null || fail "up failed"

# Pod should exist with the expected name.
pod_name="lab-${LAB}-pod-p"
podman pod ls --format '{{.Name}}' | grep -qx "$pod_name" \
    || fail "expected pod '$pod_name' not found"
note "pod exists: $pod_name"

# Both services should be in it.
for svc in a b; do
    cname="lab-${LAB}-${svc}"
    podman ps --format '{{.Names}}' | grep -qx "$cname" \
        || fail "service '$svc' container '$cname' not running"
done
note "both services running"

# From inside 'b' (alpine), hit nginx on localhost (same pod, shared net).
note "b → localhost → a"
out="$("$LAB_PODMAN" exec "$LAB/b" -- wget -q -O- http://localhost/ 2>&1 || true)"
grep -qi 'nginx\|welcome' <<<"$out" \
    || fail "b couldn't reach a via localhost; got: $out"
note "pod networking OK"

note "down"
"$LAB_PODMAN" down --lab "$LAB" >/dev/null || fail "down failed"

podman pod ls --format '{{.Name}}' | grep -qx "$pod_name" \
    && fail "pod '$pod_name' still present after down"

pass "pod lifecycle OK"
