#!/usr/bin/env bash
# Minimal end-to-end: plain manager, alpine image, exec something, tear down.
# Confirms that the happy path works on an otherwise cold host.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman
require_rootless_ready

LAB="smoke-$$"
CONFIG="$(mktemp --suffix=.toml)"
trap 'rm -f "$CONFIG"; cleanup_lab "$LAB"' EXIT

cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[service]]
name    = "alpine"
image   = "docker.io/library/alpine:latest"
manager = "plain"
command = "sleep 300"
EOF

note "up"
"$LAB_PODMAN" up --config "$CONFIG" >/dev/null || fail "up failed"

note "exec"
out="$("$LAB_PODMAN" exec "$LAB/alpine" -- cat /etc/os-release 2>&1)" || fail "exec failed"
grep -q 'Alpine Linux' <<<"$out" || fail "/etc/os-release not from Alpine? got: $out"

note "list --lab"
"$LAB_PODMAN" list --lab "$LAB" >/dev/null || fail "list failed"

note "down"
"$LAB_PODMAN" down --lab "$LAB" >/dev/null || fail "down failed"

# Verify teardown.
cname="lab-${LAB}-alpine"
podman ps -a --format '{{.Names}}' | grep -qx "$cname" \
    && fail "$cname still present after down"

pass "rootless plain-mode end-to-end OK"
