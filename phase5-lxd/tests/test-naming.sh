#!/usr/bin/env bash
# Instance naming: lab-<lab>-<svc> for topology entries; lab-<name> for
# ad-hoc `run` without --lab.  Label keys all live under user.lab-create.*.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_lxd_or_incus
require_cmd jq

lab="n$$"
cfg="$(mktemp --suffix=.toml)"
trap 'rm -f "$cfg"; cleanup_lab "$lab"' EXIT

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[[instance]]
name = "alpha"
image = "images:alpine/3.19"
EOF

note "up → instance should be named lab-${lab}-alpha"
"$LAB_LXD" up --config "$cfg"

iname="lab-${lab}-alpha"
"$LXC_CMD" info "$iname" >/dev/null \
    || fail "expected instance $iname not found"

note "verifying user.lab-create.* labels"
t="$("$LXC_CMD" config get "$iname" user.lab-create.tool)"
l="$("$LXC_CMD" config get "$iname" user.lab-create.lab)"
s="$("$LXC_CMD" config get "$iname" user.lab-create.svc)"

[[ "$t" == "lab-lxd" ]] || fail "user.lab-create.tool expected 'lab-lxd', got '$t'"
[[ "$l" == "$lab"    ]] || fail "user.lab-create.lab expected '$lab', got '$l'"
[[ "$s" == "alpha"   ]] || fail "user.lab-create.svc expected 'alpha', got '$s'"

note "label round-trip OK"

cleanup_lab "$lab"

"$LXC_CMD" info "$iname" >/dev/null 2>&1 \
    && fail "down did not remove $iname" || true

pass "naming + labels OK"
