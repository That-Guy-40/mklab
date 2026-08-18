#!/usr/bin/env bash
# TODO A.3 (lxd/incus sibling of phase3's and phase4's test-start-verb.sh).
#
# `up` here is create-if-absent too — against an existing instance it logs
# "instance '<n>' exists (…); leaving as-is" and returns 0 — so until 2026-08-17 a
# stopped instance was a state no verb in this driver could repair, and phase 6's
# `apply` HELD it rather than reach around to `incus start` (two owners on one
# lifecycle is the stale-record bug this repo keeps finding).
#
# WHAT THIS FILE PROVES AND WHAT IT DOES NOT — stated, because the difference matters.
#
# The refusal and target-resolution paths below run anywhere an engine answers:
# they are read-only (`list`), touch no network, and create nothing.  The FULL
# lifecycle — launch, stop, start, read the state back — is gated behind
# LAB_LXD_LIVE=1 and SKIPs otherwise.  That is not shyness: the development host
# runs a live Calico cluster whose VXLAN binding has been captured by a lab bridge
# before (MICRO_CLOUD_LAB_PLAN Appendix F.6), and launching an instance here
# manufactures exactly that hazard.  The docker and podman siblings do run the
# whole lifecycle, including the control, because their engines are safe to drive.
#
# So on this host the gated half is an UNKNOWN and says so, rather than a pass.

set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq
require_lxd_or_incus

LAB="startverb-$$"

# ── always: `start` does not create, and it resolves the target correctly ──────
# A BARE name resolves to `lab-<name>`; the lab/service form to `lab-<lab>-<svc>`.
# Getting that wrong is not cosmetic — phase 6 issues `<lab>/<service>`, and a
# driver that resolved it differently would refuse, or worse address, the wrong
# instance.  Both forms are asserted through the refusal, which names what it
# looked for.
out="$("$LAB_LXD" start "$LAB/nosuch" 2>&1)" && fail "start invented an instance that was never declared"
grep -q 'no such instance' <<<"$out" \
    || fail "wrong refusal for an absent instance: $out"
grep -q "lab-${LAB}-nosuch" <<<"$out" \
    || fail "the lab/service target did not resolve to lab-<lab>-<svc>: $out"
note "start refuses an instance that does not exist, and names what it looked for"

out="$("$LAB_LXD" start "nosuchbare" 2>&1)" && fail "start invented a bare-named instance"
grep -q 'lab-nosuchbare' <<<"$out" || fail "a bare target did not resolve to lab-<name>: $out"
note "both target forms resolve the way phase 6 and the other two drivers expect"

out="$("$LAB_LXD" start 2>&1)" && fail "start with no target should refuse"
grep -q 'usage:' <<<"$out" || fail "no usage line for a missing target: $out"

# ── gated: the whole lifecycle, on a host where launching is acceptable ────────
[[ "${LAB_LXD_LIVE:-}" == "1" ]] || skip "the launch/stop/start lifecycle needs LAB_LXD_LIVE=1 — this host runs a live Calico cluster and creating an instance manufactures the bridge-capture hazard of Appendix F.6; the refusal and resolution paths above DID run"

CONFIG="$(mktemp --suffix=.toml)"
on_exit 'rm -f "$CONFIG"; cleanup_lab "$LAB"'
cat > "$CONFIG" <<EOF
[lab]
name = "$LAB"

[[instance]]
name   = "web"
engine = "lxd"
image  = "images:alpine/edge"
EOF

iname="lab-${LAB}-web"
_status() { "$LXC_CMD" list --format=json 2>/dev/null | jq -r --arg n "$iname" 'first(.[] | select(.name==$n) | .status) // empty'; }

"$LAB_LXD" up --config "$CONFIG" >/dev/null || fail "up failed"
[[ "$(_status)" == "Running" ]] || fail "the fixture never came up, so nothing below would mean anything"

note "stopping it the way an operator or a crash would"
"$LXC_CMD" stop "$iname" >/dev/null 2>&1 || fail "could not stop the fixture"
[[ "$(_status)" == "Stopped" ]] || fail "the fixture did not actually stop (status: $(_status))"

"$LAB_LXD" up --config "$CONFIG" >/dev/null 2>&1
[[ "$(_status)" == "Stopped" ]] \
    || fail "REGRESSION: \`up\` now starts an existing instance — if deliberate, phase 6's held_for_want_of_a_verb and TODO A.3 are both stale and must be updated with it"
note "confirmed: up left the stopped instance alone (that is the gap)"

out="$("$LAB_LXD" start "$LAB/web" 2>&1)" || fail "start failed: $out"
grep -q '^PASS: started' <<<"$out" || fail "start did not report a PASS verdict: $out"
[[ "$(_status)" == "Running" ]] || fail "start reported success but the instance is not running"
note "start brought it back, and the state was read back from the engine"

out="$("$LAB_LXD" start "$LAB/web" 2>&1)" || fail "start on a running instance failed: $out"
grep -q 'already running' <<<"$out" || fail "expected an already-running verdict, got: $out"

pass "start runs an existing instance, is idempotent, does not create, and resolves both target forms"
