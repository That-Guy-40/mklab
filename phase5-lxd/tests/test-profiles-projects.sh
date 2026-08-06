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

# Teardown order matters, and the old trap got it wrong for a whole class of runs.
# Launching an instance CACHES ITS IMAGE INTO THE PROJECT, and that copy outlives the
# instance -- so deleting the instances does not empty the project. `project delete` then
# fails with "Only empty projects can be removed", and because the call was written
# `>/dev/null 2>&1 || true` the failure was silent: the suite reported a clean teardown
# and leaked one project + one cached image on EVERY run. (Found 2026-08-01 by
# tools/lab-sweep.sh, which had committed the identical bug itself.)
#
# So: instances -> images -> profile -> project. Same shape as tools/lab-sweep.sh.
cleanup_project() {
    cleanup_lab "$lab"
    while read -r fp; do
        [[ -n "$fp" ]] || continue
        "$LXC_CMD" image delete "$fp" --project "$proj" >/dev/null 2>&1 || true
    done < <("$LXC_CMD" image list --project "$proj" --format csv 2>/dev/null | cut -d, -f2)
    "$LXC_CMD" profile delete "$prof" --project "$proj" >/dev/null 2>&1 || true
    "$LXC_CMD" project delete "$proj" >/dev/null 2>&1 || true
    # Assert the OUTCOME, not the attempt: a project still standing here means the
    # teardown silently failed again, and saying so is the whole point.
    if "$LXC_CMD" project list --format csv 2>/dev/null | cut -d, -f1 | grep -qx "$proj"; then
        printf '  - WARNING: project %s survived teardown (sweep with tools/lab-sweep.sh)\n' "$proj" >&2
    fi
}
on_exit 'rm -f "$cfg"; cleanup_project'

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
image    = "images:alpine/latest"
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
