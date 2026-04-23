#!/usr/bin/env bash
# Test the `inspect [--json]` verb against a real, ephemeral docker container.
#
# Phase 3 differs from Phases 1/2: docker is the source of truth, so we can't
# fabricate a "fake state dir" — the inspect command shells out to
# `docker inspect`. We spin up a short-lived busybox container with the
# lab-create.{tool,lab,svc} labels, exercise both human and --json modes,
# stop it to also exercise the exited-state JSON branches, then trap-clean
# unconditionally.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd jq

# --- pick a unique container name + a high host port unlikely to collide ----
# Using $$ + a fixed suffix keeps it deterministic per-run.  Lab/svc
# split into the literal name `lab-inspectest-<pid>-svc` so:
#   - `inspect lab-inspectest-<pid>-svc`        → literal-name resolution
#   - `inspect inspectest-<pid>/svc`            → lab/svc → `lab-<lab>-<svc>` rewrite
LAB_NAME="inspectest-$$"
SVC_NAME="svc"
CNAME="lab-${LAB_NAME}-${SVC_NAME}"
# Pick a host port from the high ephemeral range; xor in $$ so parallel
# test runs almost never collide.  busybox listens on 80 inside.
HOST_PORT=$(( 40000 + ($$ % 20000) ))

# --- guarantee cleanup BEFORE we even try to start the container ------------
# A trap installed before `docker run` covers the case where `run` fails
# partway through (image pull error, name collision, etc).
# shellcheck disable=SC2064
trap "docker stop '$CNAME' >/dev/null 2>&1 || true; docker rm -f '$CNAME' >/dev/null 2>&1 || true" EXIT

note "launching ephemeral container: $CNAME (host port $HOST_PORT → 80)"
# Use busybox httpd (ships in the base image, ~5MB, no extra apt/apk roundtrip).
# `httpd -f -p 80` keeps it foreground-bound to a real port so docker
# materializes a NetworkSettings.Ports entry — which is the single most
# important thing we're asserting against.
if ! docker run -d \
        --name "$CNAME" \
        --label "lab-create.tool=lab-docker" \
        --label "lab-create.lab=${LAB_NAME}" \
        --label "lab-create.svc=${SVC_NAME}" \
        -p "${HOST_PORT}:80" \
        busybox:latest \
        httpd -f -p 80 >/dev/null 2>&1; then
    skip "could not launch busybox container (network / image pull issue?)"
fi

# --- wait briefly for State.Running == true ---------------------------------
# busybox httpd starts in <100ms but docker's State propagation is async.
# Poll for up to ~5s.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    running="$(docker inspect -f '{{.State.Running}}' "$CNAME" 2>/dev/null || true)"
    [[ "$running" == "true" ]] && break
    sleep 0.5
done
[[ "$running" == "true" ]] || fail "container $CNAME never reached Running=true (got: $running)"

# === RUNNING VARIANT — literal-name resolution ==============================
note "running inspect (human form, literal name)"
out="$("$LAB_DOCKER" inspect "$CNAME" 2>&1)"

# All four section headers must be present.
for section in '[labels]' '[container]' '[state]' '[network]'; do
    case "$out" in
        *"$section"*) ;;
        *) fail "human form missing $section section; got:\n$out" ;;
    esac
done
# Sanity: our labels surfaced.
case "$out" in
    *"lab            ${LAB_NAME}"*) ;;
    *) fail "human form: lab label ($LAB_NAME) not surfaced; got:\n$out" ;;
esac
case "$out" in
    *"svc            ${SVC_NAME}"*) ;;
    *) fail "human form: svc label ($SVC_NAME) not surfaced; got:\n$out" ;;
esac
case "$out" in
    *"image          busybox:latest"*) ;;
    *) fail "human form: image not surfaced; got:\n$out" ;;
esac

# === RUNNING VARIANT — lab/svc resolution ===================================
# Mirrors the literal-name run, but uses the short `lab/svc` form so we
# also cover the `_resolve_container_name` rewrite branch.
note "running inspect (human form, lab/svc form)"
out_short="$("$LAB_DOCKER" inspect "${LAB_NAME}/${SVC_NAME}" 2>&1)"
case "$out_short" in
    *"image          busybox:latest"*) ;;
    *) fail "lab/svc form: image not surfaced; got:\n$out_short" ;;
esac

# === RUNNING VARIANT — --json ===============================================
note "running inspect --json (literal name)"
json="$("$LAB_DOCKER" inspect "$CNAME" --json)"
echo "$json" | jq -e '.schema_version == 1' >/dev/null \
    || fail "json: schema_version != 1"

note "schema spot-checks (labels)"
[[ "$(jq -r '.labels.lab'  <<<"$json")" == "$LAB_NAME" ]] \
    || fail "json: .labels.lab != $LAB_NAME"
[[ "$(jq -r '.labels.svc'  <<<"$json")" == "$SVC_NAME" ]] \
    || fail "json: .labels.svc != $SVC_NAME"
[[ "$(jq -r '.labels.tool' <<<"$json")" == "lab-docker" ]] \
    || fail "json: .labels.tool != lab-docker"
# _other should be an OBJECT regardless of contents (busybox carries no
# extra labels of its own, but nginx/alpine bases sometimes do — we only
# assert on type, not keys).
[[ "$(jq -r '.labels._other | type' <<<"$json")" == "object" ]] \
    || fail "json: .labels._other should be an object, got: $(jq -r '.labels._other | type' <<<"$json")"

note "schema spot-checks (container)"
[[ "$(jq -r '.container.image' <<<"$json")" == "busybox:latest" ]] \
    || fail "json: .container.image != busybox:latest"
cid="$(jq -r '.container.id' <<<"$json")"
# Docker container IDs are 64-char hex, but be lenient: ≥12 covers the
# short form too (and the script never truncates, so this should always
# be 64 — we're just guarding against a trim regression).
[[ ${#cid} -ge 12 ]] || fail "json: .container.id too short (${#cid} chars): $cid"

note "schema spot-checks (state — running)"
[[ "$(jq -r '.state.status' <<<"$json")" == "running" ]] \
    || fail "json: .state.status != running"
# .running must be a BOOLEAN, not the string "true".
[[ "$(jq -r '.state.running'        <<<"$json")" == "true" ]] \
    || fail "json: .state.running != true"
[[ "$(jq -r '.state.running | type' <<<"$json")" == "boolean" ]] \
    || fail "json: .state.running is not a boolean (got $(jq -r '.state.running | type' <<<"$json"))"
# pid must be a positive number while running.
[[ "$(jq -r '.state.pid | type' <<<"$json")" == "number" ]] \
    || fail "json: .state.pid is not a number while running"
pid="$(jq -r '.state.pid' <<<"$json")"
(( pid > 0 )) || fail "json: .state.pid ($pid) should be > 0 while running"
# exit_code is null while running (per the jq `if Running then null` branch).
[[ "$(jq -r '.state.exit_code' <<<"$json")" == "null" ]] \
    || fail "json: .state.exit_code should be null while running"
# No healthcheck defined → .state.health is null.
[[ "$(jq -r '.state.health'    <<<"$json")" == "null" ]] \
    || fail "json: .state.health should be null (no HEALTHCHECK in busybox)"

note "schema spot-checks (network — ports)"
# Must contain at least one entry mapping container_port=80 to our HOST_PORT.
# Docker emits BOTH a 0.0.0.0 and a :: (IPv6) entry on most setups; we
# assert at least one matches without forbidding the second.
nports="$(jq -r '.network.ports | length' <<<"$json")"
(( nports >= 1 )) || fail "json: .network.ports has no entries (expected ≥1 for 80→${HOST_PORT})"
match="$(jq -r --argjson hp "$HOST_PORT" \
    '[.network.ports[] | select(.container_port == 80 and .host_port == $hp)] | length' <<<"$json")"
(( match >= 1 )) || fail "json: no .network.ports entry matches container_port=80 host_port=${HOST_PORT}; got: $(jq -c '.network.ports' <<<"$json")"
# Each port entry should have container_port + host_port as numbers.
[[ "$(jq -r '.network.ports[0].container_port | type' <<<"$json")" == "number" ]] \
    || fail "json: .network.ports[0].container_port is not a number"
[[ "$(jq -r '.network.ports[0].host_port      | type' <<<"$json")" == "number" ]] \
    || fail "json: .network.ports[0].host_port is not a number"

note "schema spot-checks (network — networks + IPs)"
# Default `docker run` (no --network) attaches to the `bridge` network.
on_bridge="$(jq -r '.network.networks | index("bridge")' <<<"$json")"
[[ "$on_bridge" != "null" ]] \
    || fail "json: .network.networks does not include 'bridge'; got: $(jq -c '.network.networks' <<<"$json")"
br_ip="$(jq -r '.network.ip_addresses.bridge // ""' <<<"$json")"
[[ -n "$br_ip" ]] \
    || fail "json: .network.ip_addresses.bridge is empty (expected an IPv4)"
# Loose IPv4 shape check — four dot-separated numeric fields.
case "$br_ip" in
    *.*.*.*) ;;
    *) fail "json: .network.ip_addresses.bridge ($br_ip) does not look like IPv4" ;;
esac

# === STOPPED VARIANT ========================================================
# Stop (don't rm) so the container hangs around in `exited` state.  The JSON
# branches that depend on State.Running flip; this is the cheap way to
# exercise them.
note "stopping container to test exited-state branches"
docker stop "$CNAME" >/dev/null 2>&1 || fail "could not stop $CNAME"

# Re-poll briefly: docker stop returns when the container has exited, but
# State.Status sometimes lags by a tick on slow systems.
for _ in 1 2 3 4 5; do
    st="$(docker inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null || true)"
    case "$st" in
        exited|created|dead) break ;;
    esac
    sleep 0.3
done

note "stopped inspect --json"
json2="$("$LAB_DOCKER" inspect "$CNAME" --json)"

# `exited` is the normal post-stop status; `created` is the rarely-seen
# "docker GC'd quickly" path; both are valid.
status2="$(jq -r '.state.status' <<<"$json2")"
case "$status2" in
    exited|created|dead) ;;
    *) fail "json (stopped): .state.status should be exited|created|dead, got: $status2" ;;
esac
[[ "$(jq -r '.state.running' <<<"$json2")" == "false" ]] \
    || fail "json (stopped): .state.running != false"
# exit_code is now a NUMBER (the actual exit), not null.
[[ "$(jq -r '.state.exit_code | type' <<<"$json2")" == "number" ]] \
    || fail "json (stopped): .state.exit_code should be a number, got type $(jq -r '.state.exit_code | type' <<<"$json2")"
# pid flips back to null because `(if (.Pid // 0) > 0 then .Pid else null)`.
[[ "$(jq -r '.state.pid' <<<"$json2")" == "null" ]] \
    || fail "json (stopped): .state.pid should be null after stop, got: $(jq -r '.state.pid' <<<"$json2")"

# === FAILURE PATHS ==========================================================
note "failure path: inspect with no arg"
if "$LAB_DOCKER" inspect 2>/dev/null; then
    fail "inspect with no arg should exit non-zero"
fi

note "failure path: inspect nonexistent container"
if "$LAB_DOCKER" inspect "nonexistent-container-xyz-$$" 2>/dev/null; then
    fail "inspect of unknown container should exit non-zero"
fi
# And the error message should mention either 'no container' or 'matches'.
err="$("$LAB_DOCKER" inspect "nonexistent-container-xyz-$$" 2>&1 || true)"
case "$err" in
    *"no container"*|*"matches"*) ;;
    *) fail "inspect of unknown container: error should mention 'no container'/'matches'; got: $err" ;;
esac

pass "inspect [--json] OK"
