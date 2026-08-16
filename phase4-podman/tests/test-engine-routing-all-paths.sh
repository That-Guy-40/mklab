#!/usr/bin/env bash
# Regression (REVIEW-phase4.md P4-4): cross-phase `engine =` routing was honoured by ONE
# of THREE execution paths.
#
# Phase 4's headline cross-phase feature is that one topology can span engines: a service
# carrying `engine = "docker"` belongs to Phase 3, and Phase 4 must leave it alone. The
# plain-services loop did that. The POD loop and the QUADLET loop never read `engine` at
# all — so a user following the documented cross-phase workflow got the docker-owned
# service started TWICE, once by each tool, with the podman copy silently attached to
# podman's network instead of the one its author chose.
#
# The fix moves the filter to where the service is SELECTED rather than into one
# consumer, so a fourth path cannot reintroduce it. This test therefore checks all three
# paths against the same spec, and the plain path is the control that proves the routing
# was always understood.
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq podman
podman info >/dev/null 2>&1 || skip "podman not usable on this host"
if ! command -v tomlq >/dev/null 2>&1 && ! command -v dasel >/dev/null 2>&1 \
   && ! { command -v yq >/dev/null 2>&1 && printf 'a = 1\n' | yq -p toml -o json - >/dev/null 2>&1; }; then
    skip "no TOML parser (need tomlq, dasel, or a yq supporting -p toml)"
fi

tmp="$(mktemp -d)"
export LAB_STATE_DIR="$tmp/state"
export XDG_CONFIG_HOME="$tmp/xdg"
QUADLET_USER_DIR="$tmp/xdg/containers/systemd"
mkdir -p "$LAB_STATE_DIR" "$QUADLET_USER_DIR"
[[ "$QUADLET_USER_DIR" == "$tmp"/* ]] || fail "refusing to run: quadlet dir is not in the scratch tree"

labp="p4ep$$"   # plain
labd="p4ed$$"   # pod
labq="p4eq$$"   # quadlet
on_exit 'for l in "$labp" "$labd" "$labq"; do
             LAB_STATE_DIR="$tmp/state" "$LAB_PODMAN" down --lab "$l" >/dev/null 2>&1 || true
         done; rm -rf "$tmp"'

# `mine` is podman-owned; `theirs` belongs to Phase 3 and must be left alone everywhere.
# NOTE the shape avoided here: `[[ -n "$pod" ]] && printf …` as the LAST command of the
# group returns 1 when $pod is empty, which under `set -e` kills the test before a single
# assertion runs — with a blank terminal and a bare rc. That is the same `&&`-list trap
# REVIEW-phase3.md §3 recorded in `cmd_run`, committed here while writing a test for it.
write_cfg() {  # write_cfg <file> <lab> [pod]
    local f="$1" lab="$2" pod="${3:-}"
    {
        printf '[lab]\nname = "%s"\n\n' "$lab"
        if [[ -n "$pod" ]]; then printf '[[pod]]\nname = "%s"\n\n' "$pod"; fi
        printf '[[service]]\nname = "mine"\nimage = "alpine:latest"\ncommand = "sleep 300"\n'
        if [[ -n "$pod" ]]; then printf 'pod = "%s"\n' "$pod"; fi
        printf '\n[[service]]\nname = "theirs"\nengine = "docker"\nimage = "alpine:latest"\ncommand = "sleep 300"\n'
        if [[ -n "$pod" ]]; then printf 'pod = "%s"\n' "$pod"; fi
        printf '\n'
    } > "$f"
}

# ── control: the PLAIN path, which always honoured this ────────────────────────────
write_cfg "$tmp/plain.toml" "$labp"
out="$("$LAB_PODMAN" up --config "$tmp/plain.toml" 2>&1)" || fail "plain 'up' failed: $out"
await_line 20 "lab-${labp}-mine" -- podman ps --format '{{.Names}}' \
    || fail "control: the podman-owned service did not start on the plain path"
if has_line "lab-${labp}-theirs" -- podman ps -a --format '{{.Names}}'; then
    fail "control: the plain path started a docker-engine service — the routing this test relies on is itself broken"
fi
note "control: the plain path starts 'mine' and skips 'theirs' (it always did)"

# ── the POD path ───────────────────────────────────────────────────────────────────
write_cfg "$tmp/pod.toml" "$labd" "p"
out="$("$LAB_PODMAN" up --config "$tmp/pod.toml" 2>&1)" || fail "pod 'up' failed: $out"
await_line 20 "lab-${labd}-mine" -- podman ps --format '{{.Names}}' \
    || fail "the podman-owned service did not start on the pod path"
if has_line "lab-${labd}-theirs" -- podman ps -a --format '{{.Names}}'; then
    fail "REGRESSION: the POD path started 'theirs' (engine=docker) — the service is now running under BOTH engines, with the podman copy attached to podman's network instead of the one its author chose"
fi
note "pod path: 'theirs' (engine=docker) is left alone"

# ── the QUADLET path ───────────────────────────────────────────────────────────────
write_cfg "$tmp/quad.toml" "$labq"
out="$("$LAB_PODMAN" generate --config "$tmp/quad.toml" 2>&1)" || fail "'generate' failed: $out"
[[ -f "$QUADLET_USER_DIR/lab-${labq}-mine.container" ]] \
    || fail "the quadlet path did not write a unit for the podman-owned service"
[[ ! -e "$QUADLET_USER_DIR/lab-${labq}-theirs.container" ]] \
    || fail "REGRESSION: the QUADLET path wrote a unit for 'theirs' (engine=docker) — systemd would start a service this phase does not own"
note "quadlet path: no unit is written for a docker-engine service"

# ── the skip must be REPORTED, not silent ──────────────────────────────────────────
# A service quietly vanishing from a topology is its own defect: the operator has no way
# to tell "Phase 3 owns it" from "the tool lost it".
grep -qi 'engine' <<<"$out" \
    || fail "'generate' skipped a service without saying so — a silent omission is indistinguishable from a bug; got: $out"
note "the quadlet path reports what it skipped and why"

pass "engine routing is honoured by all three paths: plain, pod and quadlet (P4-4)"
