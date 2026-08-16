#!/usr/bin/env bash
# Regression (REVIEW-phase3.md §3): a literal environment value of "null" was silently
# dropped on the way to `docker run`.
#
# Finding 32 preserves compose's inherit-from-host semantics by marking such entries
# JSON null.  The consumer then tested the RENDERED TEXT — `[[ -n "$kk" && "$vv" != "null" ]]`
# — and `jq -r` prints a JSON null and the string "null" identically, so the two are
# indistinguishable at that seam.  A sentinel that collides with a legal value; the same
# shape as the jq `//` trap that could not tell `false` from absent.
#
# Asserted on the environment the CONTAINER actually got, not on the argv the driver
# built: the outcome is what the process sees.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd jq
require_toml_parser

lab="env$$"
cfg="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$cfg"; cleanup_lab "$lab"'

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[[service]]
name    = "w"
image   = "alpine:latest"
command = "sleep 300"

[service.environment]
A = "null"
B = "keep"
C = "false"
D = ""
EOF

"$LAB_DOCKER" up --config "$cfg" >/dev/null 2>&1 || fail "setup: 'up' failed"
cname="lab-${lab}-w"
await_line 15 "$cname" -- docker ps --format '{{.Names}}' || fail "setup: container never started"

env_of() {  # env_of KEY — the value the container actually received, or <unset>
    docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/,""); print; found=1} END{if(!found) print "<unset>"}'
}

[[ "$(env_of A)" == "null" ]] \
    || fail "REGRESSION: a literal env value of \"null\" was dropped — the container got A=$(env_of A). The inherit-from-host sentinel collides with a legal value at the text seam."
[[ "$(env_of B)" == "keep" ]] || fail "the control env var B did not survive: got $(env_of B)"
[[ "$(env_of C)" == "false" ]] || fail "an env value of \"false\" was dropped: got $(env_of C)"
[[ "$(env_of D)" == "" ]] || fail "an empty env value should still be SET (distinct from inherit): got $(env_of D)"
note "A=null, B=keep, C=false and an empty D all reach the container"

pass "a literal env value of \"null\" is set, not mistaken for the inherit-from-host sentinel (§3)"
