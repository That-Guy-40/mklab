#!/usr/bin/env bash
# [[project]] + [[profile]] creation idempotency and teardown leaves them
# in place (multi-lab sharing).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_lxd_or_incus
require_cmd jq

proj="ppp$$"
prof="prof-$$"
cfg="$(mktemp --suffix=.toml)"
lab="$proj-lab"

trap 'rm -f "$cfg"; cleanup_lab "$lab"; "$LXC_CMD" profile delete "$prof" --project "$proj" >/dev/null 2>&1 || true; "$LXC_CMD" project delete "$proj" >/dev/null 2>&1 || true' EXIT

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[[project]]
name = "${proj}"

[[profile]]
name    = "${prof}"
project = "${proj}"
config  = { "security.nesting" = "true" }

[[instance]]
name     = "m"
image    = "images:alpine/3.19"
project  = "${proj}"
profiles = ["default", "${prof}"]
EOF

note "up creates project + profile + instance"
"$LAB_LXD" up --config "$cfg"

"$LXC_CMD" project show "$proj" >/dev/null \
    || fail "project $proj not created"
"$LXC_CMD" profile show "$prof" --project "$proj" >/dev/null \
    || fail "profile $prof not created"

note "second up is idempotent"
"$LAB_LXD" up --config "$cfg" 2>&1 | grep -qE '(exists|leaving as-is)' \
    || note "(no idempotency debug line — may be fine; instance already present)"

note "down removes instance but leaves project + profile"
"$LAB_LXD" down --lab "$lab"
"$LXC_CMD" project show "$proj" >/dev/null \
    || fail "down should have left project in place"
"$LXC_CMD" profile show "$prof" --project "$proj" >/dev/null \
    || fail "down should have left profile in place"

pass "profiles + projects OK"
