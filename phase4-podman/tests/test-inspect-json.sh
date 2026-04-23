#!/usr/bin/env bash
# Test the `inspect [--json]` verb against real, ephemeral podman resources.
#
# Phase 4 mirrors Phase 3 in spirit (podman is the source of truth, no
# fake-state-dir trick), but adds two podman-specific dimensions:
#   - kind discrimination: containers AND pods both flow through inspect
#   - quadlet detection: a sidecar scan of $LAB_POD_STATE_DIR/*/quadlet-links/
#
# Coverage:
#   A) standalone container (no pod)
#   B) pod + container-in-pod
#   C) failure paths (no arg / unknown name)
#   D) stopped-container variant (reuses A's container at the very end)
#
# NOT covered in v0.1: the quadlet-managed branch.  cmd_inspect's quadlet
# scan walks $LAB_POD_STATE_DIR/<lab>/quadlet-links/ for a symlink named
# "<engine_name>.container" (or .pod).  Exercising the .managed=true branch
# would require fabricating that directory + symlink ourselves and pinning
# $LAB_STATE_DIR — leave for a follow-up that also covers `quadlet generate`.
# Until then, every assertion below expects .quadlet.managed == false.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_podman          # also covers `podman` presence + version >= 4.0
require_rootless_ready  # cmd_inspect calls require_rootless internally
require_cmd jq

# --- pick unique names + ports so parallel runs don't collide --------------
# Lab/svc split chosen so:
#   inspect lab-inspectest-<pid>-svc      → literal-name resolution
#   inspect inspectest-<pid>/svc          → lab/svc → lab-<lab>-<svc> rewrite
# Pod naming mirrors pod_name_for(): lab-<lab>-pod-<podname>.
SUFFIX="$$"
LAB_NAME="inspectest-${SUFFIX}"
SVC_NAME="svc"
CNAME="lab-${LAB_NAME}-${SVC_NAME}"

POD_BASE="ctf"
POD_NAME="lab-${LAB_NAME}-pod-${POD_BASE}"
ATTACKER_SVC="attacker"
ATTACKER_CNAME="lab-${LAB_NAME}-${ATTACKER_SVC}"

# Two distinct host ports, both bound to container :80.  Pick from the
# high ephemeral range and xor in $$ so parallel test runs almost never
# collide.  Add 1 for the pod's port so it can't equal HOST_PORT.
HOST_PORT=$((  40000 + (SUFFIX % 20000) ))
POD_PORT=$((  HOST_PORT + 1 ))

# --- guarantee cleanup BEFORE we touch podman ------------------------------
# A trap installed before any `podman run`/`podman pod create` covers the
# case where launch fails partway through (pull error, port collision,
# stale name, etc).  Pod removal cascades to its members.
# shellcheck disable=SC2064
trap "
    podman stop  '$CNAME'          >/dev/null 2>&1 || true
    podman rm -f '$CNAME'          >/dev/null 2>&1 || true
    podman stop  '$ATTACKER_CNAME' >/dev/null 2>&1 || true
    podman rm -f '$ATTACKER_CNAME' >/dev/null 2>&1 || true
    podman pod rm -f '$POD_NAME'   >/dev/null 2>&1 || true
" EXIT

# --- helper: poll until `podman inspect <name>` succeeds -------------------
# `podman run -d` returns once the container is created, but State.Running
# propagates async on slow systems.  Mirror Phase 3's poll cadence.
wait_for_running() {
    local name="$1" running=""
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        running="$(podman inspect -f '{{.State.Running}}' "$name" 2>/dev/null || true)"
        [[ "$running" == "true" ]] && return 0
        sleep 0.5
    done
    fail "$name never reached Running=true (got: ${running:-<empty>})"
}

# ===========================================================================
# A) STANDALONE CONTAINER
# ===========================================================================
note "launching standalone container: $CNAME (host port $HOST_PORT → 80)"
if ! podman run -d \
        --name "$CNAME" \
        --label "lab-create.tool=lab-podman" \
        --label "lab-create.lab=${LAB_NAME}" \
        --label "lab-create.svc=${SVC_NAME}" \
        -p "${HOST_PORT}:80" \
        docker.io/library/busybox:latest \
        sleep 3600 >/dev/null 2>&1; then
    skip "could not launch busybox container (network / image pull issue?)"
fi
wait_for_running "$CNAME"

# --- A.1: human form, literal name ----------------------------------------
note "inspect (human form, literal name)"
out="$("$LAB_PODMAN" inspect "$CNAME" 2>&1)"
for section in '[labels]' '[container]' '[state]' '[network]' '[userns]'; do
    case "$out" in
        *"$section"*) ;;
        *) fail "human form missing $section section; got:\n$out" ;;
    esac
done
case "$out" in
    *"lab            ${LAB_NAME}"*) ;;
    *) fail "human form: lab label ($LAB_NAME) not surfaced; got:\n$out" ;;
esac
case "$out" in
    *"svc            ${SVC_NAME}"*) ;;
    *) fail "human form: svc label ($SVC_NAME) not surfaced; got:\n$out" ;;
esac

# --- A.2: human form via lab/svc short form -------------------------------
# Same content; just exercises the _resolve_container_name rewrite branch.
note "inspect (human form, lab/svc form)"
out_short="$("$LAB_PODMAN" inspect "${LAB_NAME}/${SVC_NAME}" 2>&1)"
case "$out_short" in
    *"lab            ${LAB_NAME}"*) ;;
    *) fail "lab/svc form: lab label not surfaced; got:\n$out_short" ;;
esac
case "$out_short" in
    *"name           ${CNAME}"*) ;;
    *) fail "lab/svc form: name not resolved to ${CNAME}; got:\n$out_short" ;;
esac

# --- A.3: --json shape checks ---------------------------------------------
note "inspect --json (literal name)"
json="$("$LAB_PODMAN" inspect "$CNAME" --json)"
echo "$json" | jq -e '.schema_version == 1' >/dev/null \
    || fail "json: schema_version != 1"
[[ "$(jq -r '.kind' <<<"$json")" == "container" ]] \
    || fail "json: .kind != container (got: $(jq -r '.kind' <<<"$json"))"

note "schema spot-checks (labels)"
[[ "$(jq -r '.labels.lab'  <<<"$json")" == "$LAB_NAME" ]] \
    || fail "json: .labels.lab != $LAB_NAME"
[[ "$(jq -r '.labels.svc'  <<<"$json")" == "$SVC_NAME" ]] \
    || fail "json: .labels.svc != $SVC_NAME"
[[ "$(jq -r '.labels.tool' <<<"$json")" == "lab-podman" ]] \
    || fail "json: .labels.tool != lab-podman"

note "schema spot-checks (container)"
img="$(jq -r '.container.image' <<<"$json")"
# podman ImageName comes through fully-qualified ("docker.io/library/...");
# we accept any string that contains "busybox" rather than pin the exact
# registry/tag form, since podman 4.x and 5.x word it slightly differently.
case "$img" in
    *busybox*) ;;
    *) fail "json: .container.image lacks 'busybox': $img" ;;
esac
cid="$(jq -r '.container.id' <<<"$json")"
[[ ${#cid} -ge 12 ]] || fail "json: .container.id too short (${#cid} chars): $cid"

note "schema spot-checks (state — running)"
[[ "$(jq -r '.state.status'        <<<"$json")" == "running" ]] \
    || fail "json: .state.status != running"
[[ "$(jq -r '.state.running'       <<<"$json")" == "true" ]] \
    || fail "json: .state.running != true"
[[ "$(jq -r '.state.running | type' <<<"$json")" == "boolean" ]] \
    || fail "json: .state.running is not a boolean"
[[ "$(jq -r '.state.pid | type'    <<<"$json")" == "number" ]] \
    || fail "json: .state.pid is not a number while running"
pid="$(jq -r '.state.pid' <<<"$json")"
(( pid > 0 )) || fail "json: .state.pid ($pid) should be > 0 while running"
[[ "$(jq -r '.state.exit_code'     <<<"$json")" == "null" ]] \
    || fail "json: .state.exit_code should be null while running"
[[ "$(jq -r '.state.health'        <<<"$json")" == "null" ]] \
    || fail "json: .state.health should be null (no HEALTHCHECK in busybox); got: $(jq -r '.state.health' <<<"$json")"
[[ "$(jq -r '.state.restart_count' <<<"$json")" == "0" ]] \
    || fail "json: .state.restart_count != 0 (got: $(jq -r '.state.restart_count' <<<"$json"))"

note "schema spot-checks (network — ports)"
nports="$(jq -r '.network.ports | length' <<<"$json")"
(( nports >= 1 )) || fail "json: .network.ports has no entries (expected ≥1 for 80→${HOST_PORT})"
match="$(jq -r --argjson hp "$HOST_PORT" \
    '[.network.ports[] | select(.container_port == 80 and .host_port == $hp)] | length' <<<"$json")"
(( match >= 1 )) || fail "json: no .network.ports entry matches 80→${HOST_PORT}; got: $(jq -c '.network.ports' <<<"$json")"
[[ "$(jq -r '.network.ports[0].container_port | type' <<<"$json")" == "number" ]] \
    || fail "json: .network.ports[0].container_port is not a number"
[[ "$(jq -r '.network.ports[0].host_port      | type' <<<"$json")" == "number" ]] \
    || fail "json: .network.ports[0].host_port is not a number"

note "schema spot-checks (userns)"
# Rootless podman ALWAYS sets up a userns (UIDMap is non-empty), so the
# script's branch yields "auto" (or a keep-id name if the container was
# launched with --userns=keep-id).  We just require a non-empty string —
# the exact value depends on podman's mode.  Type must be string, never
# null/number.
[[ "$(jq -r '.userns | type' <<<"$json")" == "string" ]] \
    || fail "json: .userns is not a string (got type $(jq -r '.userns | type' <<<"$json"))"
un="$(jq -r '.userns' <<<"$json")"
[[ -n "$un" ]] || fail "json: .userns is empty"

note "schema spot-checks (pod / quadlet — both off for standalone)"
[[ "$(jq -r '.pod' <<<"$json")" == "null" ]] \
    || fail "json: .pod should be null for standalone container; got: $(jq -r '.pod' <<<"$json")"
[[ "$(jq -r '.quadlet.managed' <<<"$json")" == "false" ]] \
    || fail "json: .quadlet.managed should be false (no quadlet links fabricated); got: $(jq -r '.quadlet.managed' <<<"$json")"

# Sanity: the lab/svc form returns the same .container.id as the literal.
short_id="$(jq -r '.container.id' < <("$LAB_PODMAN" inspect "${LAB_NAME}/${SVC_NAME}" --json))"
[[ "$short_id" == "$cid" ]] \
    || fail "lab/svc form returned a different .container.id ($short_id) than literal ($cid)"

# ===========================================================================
# B) POD + CONTAINER-IN-POD
# ===========================================================================
# Pod naming follows pod_name_for():  lab-<lab>-pod-<podname>
# Container-in-pod follows container_name_for():  lab-<lab>-<svc>
note "creating pod: $POD_NAME (host port $POD_PORT → 80)"
if ! podman pod create \
        --name "$POD_NAME" \
        --label "lab-create.tool=lab-podman" \
        --label "lab-create.lab=${LAB_NAME}" \
        --label "lab-create.pod=${POD_BASE}" \
        -p "${POD_PORT}:80" >/dev/null 2>&1; then
    skip "could not create pod (port collision? podman networking down?)"
fi

note "launching attacker container in pod: $ATTACKER_CNAME"
if ! podman run -d \
        --pod "$POD_NAME" \
        --name "$ATTACKER_CNAME" \
        --label "lab-create.tool=lab-podman" \
        --label "lab-create.lab=${LAB_NAME}" \
        --label "lab-create.svc=${ATTACKER_SVC}" \
        --label "lab-create.pod=${POD_BASE}" \
        docker.io/library/busybox:latest \
        sleep 3600 >/dev/null 2>&1; then
    fail "could not launch attacker container in pod"
fi
wait_for_running "$ATTACKER_CNAME"

# --- B.1: lab/<podname> resolves to the POD, not a missing container ------
# This exercises the cmd_inspect three-candidate loop:
#   1) literal "inspectest-<pid>/ctf" — no such resource
#   2) _resolve_container_name → "lab-inspectest-<pid>-ctf" — also no such container
#   3) pod_name_for → "lab-inspectest-<pid>-pod-ctf" — HIT (pod kind)
note "inspect ${LAB_NAME}/${POD_BASE} → pod kind"
pod_json="$("$LAB_PODMAN" inspect "${LAB_NAME}/${POD_BASE}" --json)"
[[ "$(jq -r '.schema_version' <<<"$pod_json")" == "1" ]] \
    || fail "pod json: schema_version != 1"
[[ "$(jq -r '.kind' <<<"$pod_json")" == "pod" ]] \
    || fail "pod json: .kind != pod (got: $(jq -r '.kind' <<<"$pod_json"))"

# pod.num_containers should be 2 — attacker + the implicit infra container
# podman adds when the pod has port bindings (which ours does).
nctr="$(jq -r '.pod.num_containers' <<<"$pod_json")"
(( nctr == 2 )) || fail "pod json: .pod.num_containers should be 2 (attacker + infra), got: $nctr"

# .containers[] shape: id/name/state, length matches num_containers.
clen="$(jq -r '.containers | length' <<<"$pod_json")"
(( clen == 2 )) || fail "pod json: .containers length should be 2, got: $clen"
for f in id name state; do
    [[ "$(jq -r ".containers[0].$f | type" <<<"$pod_json")" == "string" ]] \
        || fail "pod json: .containers[0].$f is not a string"
done
# At least one of the listed containers should be our attacker.
attacker_seen="$(jq -r --arg n "$ATTACKER_CNAME" \
    '[.containers[] | select(.name == $n)] | length' <<<"$pod_json")"
(( attacker_seen >= 1 )) || fail "pod json: attacker $ATTACKER_CNAME not in .containers; got: $(jq -c '.containers' <<<"$pod_json")"

# Pod-level port bindings: 80 → POD_PORT.
pod_match="$(jq -r --argjson hp "$POD_PORT" \
    '[.network.ports[] | select(.container_port == 80 and .host_port == $hp)] | length' <<<"$pod_json")"
(( pod_match >= 1 )) || fail "pod json: no .network.ports entry matches 80→${POD_PORT}; got: $(jq -c '.network.ports' <<<"$pod_json")"

[[ "$(jq -r '.quadlet.managed' <<<"$pod_json")" == "false" ]] \
    || fail "pod json: .quadlet.managed should be false; got: $(jq -r '.quadlet.managed' <<<"$pod_json")"

# Quick sanity: human form has a [pod] section, not [container].
pod_human="$("$LAB_PODMAN" inspect "${LAB_NAME}/${POD_BASE}" 2>&1)"
case "$pod_human" in
    *'[pod]'*'[containers in pod]'*) ;;
    *) fail "pod human form missing [pod]/[containers in pod] sections; got:\n$pod_human" ;;
esac
case "$pod_human" in
    *'[container]'*) fail "pod human form should NOT contain [container] header; got:\n$pod_human" ;;
esac

# --- B.2: container-in-pod surfaces .pod (not null) and labels.pod --------
note "inspect ${LAB_NAME}/${ATTACKER_SVC} → container kind, .pod set"
att_json="$("$LAB_PODMAN" inspect "${LAB_NAME}/${ATTACKER_SVC}" --json)"
[[ "$(jq -r '.kind' <<<"$att_json")" == "container" ]] \
    || fail "attacker json: .kind != container (got: $(jq -r '.kind' <<<"$att_json"))"
attacker_pod_field="$(jq -r '.pod' <<<"$att_json")"
[[ "$attacker_pod_field" != "null" && -n "$attacker_pod_field" ]] \
    || fail "attacker json: .pod should be the pod name, not null/empty; got: $attacker_pod_field"
[[ "$(jq -r '.labels.pod' <<<"$att_json")" == "$POD_BASE" ]] \
    || fail "attacker json: .labels.pod != '$POD_BASE' (got: $(jq -r '.labels.pod' <<<"$att_json"))"

# ===========================================================================
# C) FAILURE PATHS
# ===========================================================================
note "failure path: inspect with no arg"
if "$LAB_PODMAN" inspect 2>/dev/null; then
    fail "inspect with no arg should exit non-zero"
fi
no_arg_err="$("$LAB_PODMAN" inspect 2>&1 || true)"
case "$no_arg_err" in
    *usage*) ;;
    *) fail "inspect with no arg: error should mention 'usage'; got: $no_arg_err" ;;
esac

note "failure path: inspect nonexistent name"
bogus="noexist-xyz-${SUFFIX}"
if "$LAB_PODMAN" inspect "$bogus" 2>/dev/null; then
    fail "inspect of unknown name should exit non-zero"
fi
err="$("$LAB_PODMAN" inspect "$bogus" 2>&1 || true)"
case "$err" in
    *"no container or pod matches"*) ;;
    *) fail "inspect of unknown name: error should mention 'no container or pod matches'; got: $err" ;;
esac

# ===========================================================================
# D) STOPPED-CONTAINER VARIANT  (reuses A's container — stop, re-inspect)
# ===========================================================================
# Re-uses $CNAME from (A).  We stop (don't rm) so the container stays in
# `exited` and inspect's flipped State branches fire.  Trap still cleans
# both states.
note "stopping $CNAME to test exited-state branches"
podman stop "$CNAME" >/dev/null 2>&1 || fail "could not stop $CNAME"
# State propagation can lag a tick on slow systems.
for _ in 1 2 3 4 5; do
    st="$(podman inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null || true)"
    case "$st" in
        exited|stopped|created|dead) break ;;
    esac
    sleep 0.3
done

note "stopped inspect --json"
json2="$("$LAB_PODMAN" inspect "$CNAME" --json)"
status2="$(jq -r '.state.status' <<<"$json2")"
# podman 4.x reports "exited"; allow "stopped" too in case a future bump
# changes the wording (per spec).
case "$status2" in
    exited|stopped|created|dead) ;;
    *) fail "json (stopped): .state.status should be exited|stopped|created|dead, got: $status2" ;;
esac
[[ "$(jq -r '.state.running' <<<"$json2")" == "false" ]] \
    || fail "json (stopped): .state.running != false"
[[ "$(jq -r '.state.exit_code | type' <<<"$json2")" == "number" ]] \
    || fail "json (stopped): .state.exit_code should be a number, got type $(jq -r '.state.exit_code | type' <<<"$json2")"
[[ "$(jq -r '.state.pid' <<<"$json2")" == "null" ]] \
    || fail "json (stopped): .state.pid should be null after stop, got: $(jq -r '.state.pid' <<<"$json2")"

pass "inspect [--json] OK"
