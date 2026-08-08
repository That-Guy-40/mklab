#!/usr/bin/env bash
# Minimal end-to-end: plain manager, alpine image, exec something, tear down.
# Confirms that the happy path works on an otherwise cold host.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman
require_rootless_ready
require_oci_runtime          # environment vs lab: skip, don't fail, on a broken runtime

LAB="smoke-$$"
CONFIG="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$CONFIG"; cleanup_lab "$LAB"'

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
await_absent 20 "$cname" -- podman ps -a --format '{{.Names}}' \
    || fail "$cname still present 20s after down"

pass "rootless plain-mode end-to-end OK"
