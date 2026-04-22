#!/usr/bin/env bash
# End-to-end container path: up → list → exec → down.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_lxd_or_incus
require_cmd jq

lab="clc$$"
cfg="$(mktemp --suffix=.toml)"
trap 'rm -f "$cfg"; cleanup_lab "$lab"' EXIT

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[[instance]]
name  = "a"
type  = "container"
image = "images:alpine/3.19"
EOF

note "up"
"$LAB_LXD" up --config "$cfg"

note "list --lab shows the instance"
"$LAB_LXD" list --lab "$lab" 2>&1 | grep -q "lab-${lab}-a" \
    || fail "list did not show lab-${lab}-a"

note "exec returns alpine banner"
out="$("$LAB_LXD" exec "${lab}/a" -- cat /etc/os-release 2>&1)"
grep -qi 'alpine' <<<"$out" \
    || fail "exec did not return alpine banner; got: $out"

note "status <lab> succeeds"
"$LAB_LXD" status "$lab" >/dev/null \
    || fail "status <lab> failed"

note "down"
"$LAB_LXD" down --lab "$lab"

"$LXC_CMD" info "lab-${lab}-a" >/dev/null 2>&1 \
    && fail "down did not remove instance" || true

pass "container lifecycle OK"
