#!/usr/bin/env bash
# TODO A.3: `up` is create-if-absent, NOT converge — against an existing container
# it logs "container exists (…); leaving as-is" and returns 0 — and until 2026-08-17
# this driver had no other verb that could run one.  A stopped container was a state
# nothing here could repair, which is why phase 6's `apply` HELD it (it will not
# reach around a driver to `podman start`: two owners on one lifecycle is the
# stale-record bug this repo keeps finding).
#
# The interesting assertion is not "start worked".  It is that `start` REPORTS
# FAILURE when the container does not stay running: `podman start` exiting 0 says
# the request was accepted, and a container whose entrypoint exits immediately is
# back to `exited` a moment later.  That is REVIEW-phase7.md P7-4 — `PASS: started`
# printed over a VM that never booted — carried across before it could recur here.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_podman
require_rootless_ready
require_oci_runtime

LAB="startverb-$$"
CONFIG="$(mktemp --suffix=.toml)"
DIES="lab-${LAB}-dies"
on_exit 'rm -f "$CONFIG"; cleanup_lab "$LAB"; podman rm -f "$DIES" >/dev/null 2>&1 || true'

cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[service]]
name    = "web"
engine  = "podman"
image   = "docker.io/library/alpine:latest"
manager = "plain"
command = "sleep 300"
EOF

cname="lab-${LAB}-web"

"$LAB_PODMAN" up --config "$CONFIG" >/dev/null || fail "up failed"
await_line 20 running -- podman inspect -f '{{.State.Status}}' "$cname" \
    || fail "the fixture never came up, so nothing below would mean anything"

# ── 1. the gap this verb closes ───────────────────────────────────────────────
note "stopping it the way an operator or a crash would"
podman stop -t 1 "$cname" >/dev/null 2>&1 || fail "could not stop the fixture"
[[ "$(podman inspect -f '{{.State.Status}}' "$cname")" == exited ]] \
    || fail "the fixture did not actually stop"

# `up` is create-if-absent: it must NOT be what fixes this, or the new verb is
# unnecessary and this test is asserting the wrong thing.
"$LAB_PODMAN" up --config "$CONFIG" >/dev/null 2>&1
[[ "$(podman inspect -f '{{.State.Status}}' "$cname")" == exited ]] \
    || fail "REGRESSION: \`up\` now starts an existing container — if that is deliberate, phase 6's held_for_want_of_a_verb and TODO A.3 are both stale and must be updated with it"
note "confirmed: up left the stopped container alone (that is the gap)"

out="$("$LAB_PODMAN" start "$LAB/web" 2>&1)" || fail "start failed: $out"
grep -q '^PASS: started' <<<"$out" || fail "start did not report a PASS verdict: $out"
[[ "$(podman inspect -f '{{.State.Status}}' "$cname")" == running ]] \
    || fail "start reported success but the container is not running"
note "start brought it back, and the state was read back from podman"

# ── 2. idempotent: a reconcile loop may issue it against an already-running row ─
out="$("$LAB_PODMAN" start "$LAB/web" 2>&1)" || fail "start on a running container failed: $out"
grep -q 'already running' <<<"$out" || fail "expected an already-running verdict, got: $out"

# ── 3. it does not create ──────────────────────────────────────────────────────
out="$("$LAB_PODMAN" start "$LAB/nosuch" 2>&1)" && fail "start invented a container that was never declared"
grep -q 'no such container' <<<"$out" || fail "wrong refusal for an absent container: $out"

# ── 4. THE CONTROL: the outcome is asserted, not the exit status ──────────────
# NOTE the `$LAB/dies` target form: a BARE name resolves to `lab-<name>`, so
# passing the container's real name would look for `lab-lab-…-dies` and refuse
# for the wrong reason.  Phase 6 passes `<lab>/<service>` for exactly this reason.
# A container whose command exits immediately: `podman start` returns 0 and the
# container is `exited` a moment later.  If this passes, the verdict above is
# being printed on the strength of rc alone and means nothing.
podman create --name "$DIES" docker.io/library/alpine:latest true >/dev/null 2>&1 \
    || fail "could not create the control container"
out="$("$LAB_PODMAN" start "$LAB/dies" 2>&1)" \
    && fail "REGRESSION: start reported success for a container that exited immediately — the verdict is coming from \`podman start\`'s exit status, not from the container's state"
grep -q 'REGRESSION:.*after start' <<<"$out" \
    || fail "the failure did not name what was wrong: $out"
note "control fired: a container that does not stay running is reported as a failure"

pass "start runs an existing container, is idempotent, does not create, and reports failure when the container does not stay up"
