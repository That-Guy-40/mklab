#!/usr/bin/env bash
# Pod manager: 3 services share a pod; verify they see each other on localhost.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman
require_rootless_ready
require_oci_runtime          # environment vs lab: skip, don't fail, on a broken runtime

LAB="pod-lifecycle-$$"
CONFIG="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$CONFIG"; cleanup_lab "$LAB"'

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
await_line 20 "$pod_name" -- podman pod ls --format '{{.Name}}' \
    || fail "expected pod '$pod_name' not found within 20s"
note "pod exists: $pod_name"

# Both services should be in it.
for svc in a b; do
    cname="lab-${LAB}-${svc}"
    await_line 20 "$cname" -- podman ps --format '{{.Names}}' \
        || fail "service '$svc' container '$cname' not running within 20s"
done
note "both services running"

# From inside 'b' (alpine), hit nginx on localhost (same pod, shared net).
# A container that is *running* is not yet a server that is *accepting*: the pod and
# both containers being listed (await_line above) does not mean nginx is LISTENING.
# So wait — bounded — for nginx to ANSWER, not merely for its container to exist. This
# was a readiness race: the old one-shot probe fired into the gap and got "Connection
# refused" (main red for ~2 days, DEFERRED.md D1). await_match captures-then-tests (no
# pipe → no SIGPIPE/pipefail inversion) and retries until nginx's page — which contains
# "nginx" (the stock nginx:alpine welcome page) — comes back.
note "b → localhost → a (waiting for nginx to answer)"
out="$(await_match 30 nginx -- "$LAB_PODMAN" exec "$LAB/b" -- wget -q -O- http://localhost/)" \
    || fail "b couldn't reach a via localhost within 30s; last: ${out:-<no output from wget>}"
note "pod networking OK"

note "down"
"$LAB_PODMAN" down --lab "$LAB" >/dev/null || fail "down failed"

# EVENTUAL ABSENCE — see await_absent's note in lib.sh: the old `&& fail` form turned a
# SIGPIPE into a PASS with the pod still running.
await_absent 20 "$pod_name" -- podman pod ls --format '{{.Name}}' \
    || fail "pod '$pod_name' still present 20s after down"

pass "pod lifecycle OK"
