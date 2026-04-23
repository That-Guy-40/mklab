#!/usr/bin/env bash
# Test the `inspect [--json]` verb against a real, ephemeral LXD/Incus instance.
#
# Phase 5 mirrors Phase 3/4 in spirit (the engine — incus or lxd — is the
# source of truth, no fake-state-dir trick), but is the first phase where
# the tool runs against either of two binaries (incus or lxc).  We always
# bring instances up via `phase5-lxd/lab-lxd.sh up --config <toml>` rather
# than raw `lxc launch` so the lab-create.{tool,lab,svc} labels we assert
# against actually get set.
#
# Coverage:
#   A) running container: literal name AND lab/svc short form, both human
#      and --json modes; exhaustive JSON schema spot-checks (labels,
#      instance, image, state, network, devices, snapshots).
#   B) failure paths (no arg / unknown name).
#
# NOT covered in v0.1 (deferred to keep this test under ~10s):
#   - stopped-instance variant (would need a stop+poll cycle)
#   - VM (type=vm) variant (KVM-dependent on host; image is much heavier)
# Both rely on the same jq transform path that the Running container
# exercises here, so coverage is mostly redundant.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# require_lxd_or_incus also enforces the "default profile has root device"
# bootstrap requirement — see phase5-lxd/MANUAL_TESTING.md §0a.
require_lxd_or_incus
require_cmd jq

# --- pick unique names so parallel runs don't collide ---------------------
# Lab/svc split chosen so:
#   inspect lab-inspectest-<pid>-shell   → literal-name resolution
#   inspect inspectest-<pid>/shell       → lab/svc → lab-<lab>-<svc> rewrite
LAB_NAME="inspectest-$$"
SVC_NAME="shell"
INAME="lab-${LAB_NAME}-${SVC_NAME}"

WORK="$(mktemp -d)"
TOML="$WORK/inspect-test.toml"

cat > "$TOML" <<EOF
[lab]
name = "${LAB_NAME}"

[[instance]]
name  = "${SVC_NAME}"
type  = "container"
image = "images:alpine/latest"
EOF

# --- guarantee cleanup BEFORE we even try `up` ----------------------------
# A trap installed before `up` covers the case where launch fails partway
# through (image fetch error, stale name collision, etc).  `down --force`
# is idempotent — it returns 0 even if the lab doesn't exist yet.
# shellcheck disable=SC2064
trap "
    '$LAB_LXD' down --lab '$LAB_NAME' --force >/dev/null 2>&1 || true
    rm -rf '$WORK'
" EXIT

# ===========================================================================
# Bring the lab up.
# ===========================================================================
note "up: lab=$LAB_NAME image=images:alpine/latest"
"$LAB_LXD" up --config "$TOML" >/dev/null 2>&1 \
    || fail "up failed for lab $LAB_NAME (see: $LAB_LXD up --config $TOML)"

# `lab-lxd.sh up` calls `launch` then waits internally, but `state.network`
# in the JSON list output can lag a tick (eth0 needs DAD before its
# link-local appears).  Poll briefly for Status=Running.
note "waiting for instance to reach Running"
running=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    running="$("$LXC_CMD" list "$INAME" --all-projects --format=csv -c s 2>/dev/null \
                | head -n1 | tr -d '[:space:]')"
    [[ "$running" == "RUNNING" ]] && break
    sleep 0.5
done
[[ "$running" == "RUNNING" ]] \
    || fail "instance $INAME never reached RUNNING (got: $running)"

# ===========================================================================
# A) RUNNING CONTAINER — literal-name resolution, human form.
# ===========================================================================
note "inspect (human form, literal name)"
out="$("$LAB_LXD" inspect "$INAME" 2>&1)"

# Required section headers.  '[devices (expanded)]' is bracketed-with-paren
# so we glob with a wildcard inside to keep the case match readable.
for section in '[labels]' '[instance]' '[image]' '[state]' '[network]' '[devices (expanded)]'; do
    case "$out" in
        *"$section"*) ;;
        *) fail "human form missing $section section; got:\n$out" ;;
    esac
done
# Sanity: surfaces our labels.
case "$out" in
    *"lab            ${LAB_NAME}"*) ;;
    *) fail "human form: lab label ($LAB_NAME) not surfaced; got:\n$out" ;;
esac
case "$out" in
    *"svc            ${SVC_NAME}"*) ;;
    *) fail "human form: svc label ($SVC_NAME) not surfaced; got:\n$out" ;;
esac
case "$out" in
    *"tool           lab-lxd"*) ;;
    *) fail "human form: tool label not surfaced; got:\n$out" ;;
esac

# ===========================================================================
# A.2) RUNNING CONTAINER — lab/svc short form (rewrite branch).
# ===========================================================================
note "inspect (human form, lab/svc form)"
out_short="$("$LAB_LXD" inspect "${LAB_NAME}/${SVC_NAME}" 2>&1)"
case "$out_short" in
    *"name           ${INAME}"*) ;;
    *) fail "lab/svc form: name not resolved to ${INAME}; got:\n$out_short" ;;
esac

# ===========================================================================
# A.3) RUNNING CONTAINER — --json shape checks.
# ===========================================================================
note "inspect --json (literal name)"
json="$("$LAB_LXD" inspect "$INAME" --json)"

# The whole document must parse and carry schema_version=1.
echo "$json" | jq -e '.schema_version == 1' >/dev/null \
    || fail "json: schema_version != 1"

note "schema spot-checks (top-level)"
[[ "$(jq -r '.kind' <<<"$json")" == "instance" ]] \
    || fail "json: .kind != instance (got: $(jq -r '.kind' <<<"$json"))"
[[ "$(jq -r '.name' <<<"$json")" == "$INAME" ]] \
    || fail "json: .name != $INAME (got: $(jq -r '.name' <<<"$json"))"
engine="$(jq -r '.engine' <<<"$json")"
case "$engine" in
    incus|lxd) ;;
    *) fail "json: .engine should be 'incus' or 'lxd', got: $engine" ;;
esac

note "schema spot-checks (labels)"
[[ "$(jq -r '.labels.lab'  <<<"$json")" == "$LAB_NAME" ]] \
    || fail "json: .labels.lab != $LAB_NAME"
[[ "$(jq -r '.labels.svc'  <<<"$json")" == "$SVC_NAME" ]] \
    || fail "json: .labels.svc != $SVC_NAME"
[[ "$(jq -r '.labels.tool' <<<"$json")" == "lab-lxd" ]] \
    || fail "json: .labels.tool != lab-lxd"

note "schema spot-checks (instance)"
[[ "$(jq -r '.instance.type'    <<<"$json")" == "container" ]] \
    || fail "json: .instance.type != container"
[[ "$(jq -r '.instance.project' <<<"$json")" == "default" ]] \
    || fail "json: .instance.project != default (got: $(jq -r '.instance.project' <<<"$json"))"
# .instance.profiles must be an array containing "default" (we don't pass
# --profile, so the default profile is the only one attached).
in_profiles="$(jq -r '.instance.profiles | index("default")' <<<"$json")"
[[ "$in_profiles" != "null" ]] \
    || fail "json: .instance.profiles does not contain 'default'; got: $(jq -c '.instance.profiles' <<<"$json")"

note "schema spot-checks (image)"
[[ "$(jq -r '.image' <<<"$json")" != "null" ]] \
    || fail "json: .image should be non-null for an upstream Alpine launch"
# Phase 5 carries Alpine's image.os value verbatim from the simplestreams
# remote (capitalized "Alpine"), unlike LSB-style /etc/os-release "alpine".
[[ "$(jq -r '.image.os' <<<"$json")" == "Alpine" ]] \
    || fail "json: .image.os != 'Alpine' (got: $(jq -r '.image.os' <<<"$json"))"
# Don't pin .image.release — `images:alpine/latest` resolves to whatever
# Alpine considers the current stable.  Just check it's a string ("3.X").
[[ "$(jq -r '.image.release | type' <<<"$json")" == "string" ]] \
    || fail "json: .image.release is not a string; got type $(jq -r '.image.release | type' <<<"$json")"
img_rel="$(jq -r '.image.release' <<<"$json")"
[[ -n "$img_rel" && "$img_rel" != "null" ]] \
    || fail "json: .image.release is empty/null; got: $img_rel"

note "schema spot-checks (state — running)"
[[ "$(jq -r '.state.status' <<<"$json")" == "Running" ]] \
    || fail "json: .state.status != 'Running' (capitalized); got: $(jq -r '.state.status' <<<"$json")"
# .running must be a derived BOOLEAN, not a string.
[[ "$(jq -r '.state.running'        <<<"$json")" == "true" ]] \
    || fail "json: .state.running != true"
[[ "$(jq -r '.state.running | type' <<<"$json")" == "boolean" ]] \
    || fail "json: .state.running is not a boolean (got $(jq -r '.state.running | type' <<<"$json"))"
[[ "$(jq -r '.state.pid | type'    <<<"$json")" == "number" ]] \
    || fail "json: .state.pid is not a number while running"
pid="$(jq -r '.state.pid' <<<"$json")"
(( pid > 0 )) || fail "json: .state.pid ($pid) should be > 0 while running"
[[ "$(jq -r '.state.processes | type' <<<"$json")" == "number" ]] \
    || fail "json: .state.processes is not a number while running"
procs="$(jq -r '.state.processes' <<<"$json")"
(( procs > 0 )) || fail "json: .state.processes ($procs) should be > 0 while running"
# Memory: a running container always has SOME usage (init alone is enough).
mem_usage="$(jq -r '.state.memory.usage_bytes' <<<"$json")"
[[ "$(jq -r '.state.memory.usage_bytes | type' <<<"$json")" == "number" ]] \
    || fail "json: .state.memory.usage_bytes is not a number"
(( mem_usage > 0 )) \
    || fail "json: .state.memory.usage_bytes ($mem_usage) should be > 0 for a running container"

note "schema spot-checks (network)"
nifaces="$(jq -r '.network.interfaces | length' <<<"$json")"
(( nifaces >= 1 )) \
    || fail "json: .network.interfaces should have ≥1 entry, got: $nifaces"
# eth0 is the conventional default-bridge nic name; an alpine container
# brought up via the default profile always has it.
eth0_seen="$(jq -r '[.network.interfaces[] | select(.name == "eth0")] | length' <<<"$json")"
(( eth0_seen >= 1 )) \
    || fail "json: .network.interfaces lacks an 'eth0' entry; got: $(jq -c '[.network.interfaces[].name]' <<<"$json")"
# At minimum, eth0 carries an ipv6 link-local (fe80::/10) — it's assigned
# the moment the link comes up, well before any DHCP/SLAAC happens.
eth0_naddrs="$(jq -r '[.network.interfaces[] | select(.name == "eth0") | .addresses[]] | length' <<<"$json")"
(( eth0_naddrs >= 1 )) \
    || fail "json: eth0 has 0 addresses (expected ≥1, e.g. ipv6 link-local); got: $(jq -c '.network.interfaces' <<<"$json")"

note "schema spot-checks (devices — expanded)"
# Default profile attaches a `root` (disk) and `eth0` (nic) device.  Both
# come through .expanded_devices because we don't override them.
[[ "$(jq -r '.devices.root' <<<"$json")" != "null" ]] \
    || fail "json: .devices.root missing (expected from default profile)"
[[ "$(jq -r '.devices.eth0' <<<"$json")" != "null" ]] \
    || fail "json: .devices.eth0 missing (expected from default profile)"

note "schema spot-checks (snapshots)"
nsnaps="$(jq -r '.snapshots | length' <<<"$json")"
(( nsnaps == 0 )) \
    || fail "json: .snapshots should be empty (we didn't snapshot), got: $(jq -c '.snapshots' <<<"$json")"

# Sanity: lab/svc form returns the same .name as the literal form.
short_name="$(jq -r '.name' < <("$LAB_LXD" inspect "${LAB_NAME}/${SVC_NAME}" --json))"
[[ "$short_name" == "$INAME" ]] \
    || fail "lab/svc form returned a different .name ($short_name) than literal ($INAME)"

# ===========================================================================
# B) FAILURE PATHS
# ===========================================================================
note "failure path: inspect with no arg"
if "$LAB_LXD" inspect 2>/dev/null; then
    fail "inspect with no arg should exit non-zero"
fi
no_arg_err="$("$LAB_LXD" inspect 2>&1 || true)"
case "$no_arg_err" in
    *usage*) ;;
    *) fail "inspect with no arg: error should mention 'usage'; got: $no_arg_err" ;;
esac

note "failure path: inspect nonexistent name"
bogus="noexist-xyz-$$"
if "$LAB_LXD" inspect "$bogus" 2>/dev/null; then
    fail "inspect of unknown name should exit non-zero"
fi
err="$("$LAB_LXD" inspect "$bogus" 2>&1 || true)"
case "$err" in
    *"no instance matches"*) ;;
    *) fail "inspect of unknown name: error should mention 'no instance matches'; got: $err" ;;
esac

pass "inspect [--json] OK"
