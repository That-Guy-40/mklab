#!/usr/bin/env bash
# Verify that:
#   1. Containers go through the `lab-<lab>-<svc>` name format.
#   2. Labels use the lab-podman namespace (not lab-docker).
#   3. A second `up` on the same TOML is idempotent-ish.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman
require_rootless_ready
require_oci_runtime          # environment vs lab: skip, don't fail, on a broken runtime

LAB="naming-test-$$"
CONFIG="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$CONFIG"; cleanup_lab "$LAB"'

cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[service]]
name    = "only"
image   = "docker.io/library/alpine:latest"
manager = "plain"
command = "sleep 300"
EOF

note "bringing up lab '$LAB'"
"$LAB_PODMAN" up --config "$CONFIG" >/dev/null || fail "up failed"

# Container name format.
expected_name="lab-${LAB}-only"
await_line 20 "$expected_name" -- podman ps --format '{{.Names}}' \
    || fail "expected container '$expected_name' not found within 20s"
note "container name OK: $expected_name"

# Label scoping: container has lab-podman tool label, not lab-docker.
tool_label="$(podman inspect "$expected_name" --format '{{index .Config.Labels "lab-create.tool"}}')"
[[ "$tool_label" == "lab-podman" ]] \
    || fail "expected lab-create.tool=lab-podman; got '$tool_label'"
note "tool label OK: lab-podman"

# Second `up` should not explode.
note "second up (idempotency)"
"$LAB_PODMAN" up --config "$CONFIG" >/dev/null || fail "second up failed"

# List --lab filtering.
n="$("$LAB_PODMAN" list --lab "$LAB" 2>&1 | grep -c "$expected_name" || true)"
[[ "$n" -ge 1 ]] || fail "list --lab did not show the service"
note "list --lab OK"

pass "naming + labels + idempotency OK"
