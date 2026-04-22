#!/usr/bin/env bash
# Quadlet: `generate` subcommand writes .container units to
# ~/.config/containers/systemd/ with the right sections.  Does NOT try to
# run systemctl — that's the host-integration test and adds too many
# preconditions (systemd --user, linger, etc.).

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman_quadlet
require_rootless_ready

LAB="quadlet-gen-$$"
CONFIG="$(mktemp --suffix=.toml)"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
UNIT="${UNIT_DIR}/lab-${LAB}-only.container"

cleanup() {
    rm -f "$CONFIG" "$UNIT"
    rmdir "${HOME}/.local/state/lab-create/podman/${LAB}/quadlet-links" 2>/dev/null || true
    rm -rf "${HOME}/.local/state/lab-create/podman/${LAB}" 2>/dev/null || true
}
trap cleanup EXIT

cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[service]]
name    = "only"
image   = "docker.io/library/nginx:alpine"
manager = "quadlet"
ports   = ["19999:80"]
EOF

note "generate"
"$LAB_PODMAN" generate --config "$CONFIG" >/dev/null || fail "generate failed"

[[ -r "$UNIT" ]] || fail "expected unit not created: $UNIT"
note "unit file created: $UNIT"

# Sanity-check section headers.
grep -q '^\[Container\]' "$UNIT" || fail "no [Container] section in unit"
grep -q '^\[Install\]' "$UNIT"   || fail "no [Install] section in unit"
grep -q "^Image=docker.io/library/nginx:alpine" "$UNIT" || fail "wrong Image= line"
grep -q "^PublishPort=19999:80" "$UNIT" || fail "no PublishPort= line"
grep -q "^Label=${LAB_LABEL_TOOL:-lab-create.tool=lab-podman}" "$UNIT" \
    || grep -q "^Label=lab-create.tool=lab-podman" "$UNIT" \
    || fail "no tool label"
note "unit content OK"

# Link should exist in state dir.
state_link="${HOME}/.local/state/lab-create/podman/${LAB}/quadlet-links/lab-${LAB}-only.container"
[[ -L "$state_link" ]] || fail "no state-dir link: $state_link"
note "state-dir link OK"

pass "quadlet generate writes correct unit file"
