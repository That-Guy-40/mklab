#!/usr/bin/env bash
# Regression (Review: name validation): service/pod names from a TOML topology
# must be validated up front — they become quadlet unit *paths*, podman
# --name/--hostname, labels, and grep patterns. A name like "../evil" or one
# with shell metacharacters must be refused before anything is created.
#
# Drives the REAL cmd_up with the podman preflight stubbed out; no container is
# ever launched because validation fails first.
#
# shellcheck disable=SC1090,SC2317
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
require_cmd jq
command -v tomlq >/dev/null 2>&1 || skip "no tomlq (TOML parser) for toml_to_json"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export LAB_POD_STATE_DIR="$work/state"

source "$LAB_PODMAN"
# Stub the rootless/podman preflight so we reach the name-validation loop.
require_rootless()    { :; }
check_subuid_subgid() { :; }
require_podman()      { :; }
state_init()          { install -d "$work/state" 2>/dev/null || true; }
detect_rootless_network() { echo none; }
podman() { echo "PODMAN $*" >> "$work/podman-calls"; return 0; }

_reject() {   # _reject <bad-name> <label>
    local cfg="$work/c.toml"
    printf '[lab]\nname = "ok"\n\n[[service]]\nname = "%s"\nimage = "alpine"\n' "$1" > "$cfg"
    OPT_CONFIG="$cfg" OPT_LAB="" POS_ARGS=() EXTRA_ARGS=()
    local out; out="$( ( cmd_up ) 2>&1 || true )"
    grep -qi 'invalid service name' <<<"$out" \
        || fail "REGRESSION: bad service name ($2) not rejected — got: $out"
    [[ ! -e "$work/podman-calls" ]] \
        || fail "REGRESSION: podman was invoked before the name was validated ($2)"
    note "$2 rejected before any podman call"
}

_reject '../evil'   'path traversal'
_reject 'a;reboot'  'shell metacharacter'
_reject 'a b'       'embedded space'

# A clean name must NOT be rejected by the validator (it proceeds past it and
# fails later on the stubbed backend, but never with an "invalid name" error).
printf '[lab]\nname = "ok"\n\n[[service]]\nname = "web1"\nimage = "alpine"\n' > "$work/good.toml"
OPT_CONFIG="$work/good.toml" OPT_LAB="" POS_ARGS=() EXTRA_ARGS=()
out="$( ( cmd_up ) 2>&1 || true )"
grep -qi 'invalid service name' <<<"$out" && fail "a valid name 'web1' was wrongly rejected: $out"
note "valid name accepted"

pass "service names are validated up front; traversal/metachar/space refused pre-launch"
