#!/usr/bin/env bash
# Regression (REVIEW-phase3.md P3-3): `down` used to print
# `── lab 'x' torn down ──` and exit 0 while a network it had FAILED to remove was
# still present.  Both removals discard their exit status, and nothing between them
# and the banner ever asked whether anything actually went away.
#
# This is the record-and-reality rung reported as success — the class CLAUDE.md ranks
# above an honest failure, because each leaked network keeps a subnet from Docker's
# finite address pool and the next failure surfaces far from the cause.
#
# The trigger is ordinary, not adversarial: the lab network is a normal Docker network,
# so any container a student starts on it holds it open.
#
# shellcheck disable=SC1090
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker
require_cmd jq
require_toml_parser

lab="dwn$$"
squatter="p3squatter$$"
cfg="$(mktemp --suffix=.toml)"
# Cleanup order matters: the squatter must go before the lab, or `down` can't finish.
on_exit 'rm -f "$cfg"; docker rm -f "$squatter" >/dev/null 2>&1 || true; cleanup_lab "$lab"'

cat > "$cfg" <<EOF
[lab]
name = "${lab}"

[network.net]
driver = "bridge"

[[service]]
name     = "web"
image    = "alpine:latest"
networks = ["net"]
command  = "sleep 300"
EOF

"$LAB_DOCKER" up --config "$cfg" >/dev/null 2>&1 || fail "setup: 'up' failed"
netname="lab-${lab}-net"
docker network inspect "$netname" >/dev/null 2>&1 || fail "setup: expected network $netname to exist"

# ── the control: with nothing holding the network, `down` must succeed and say so ──
out="$("$LAB_DOCKER" down --lab "$lab" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "control: a clean teardown must exit 0, got rc=$rc; output: $out"
grep -q "torn down" <<<"$out" || fail "control: a clean teardown must report success; got: $out"
docker network inspect "$netname" >/dev/null 2>&1 \
    && fail "control: the network survived a teardown that reported success"
note "control: a clean teardown exits 0, says 'torn down', and really removes the network"

# ── the finding: a foreign container holds the network open ────────────────────────
"$LAB_DOCKER" up --config "$cfg" >/dev/null 2>&1 || fail "setup: second 'up' failed"
docker run -d --name "$squatter" --network "$netname" alpine:latest sleep 300 >/dev/null \
    || skip "could not start the squatter container (daemon problem, not a test failure)"

out="$("$LAB_DOCKER" down --lab "$lab" 2>&1)" && rc=0 || rc=$?

still_there=0
docker network inspect "$netname" >/dev/null 2>&1 && still_there=1
(( still_there == 1 )) \
    || skip "this daemon removed a network that still had a container attached — the premise of the test does not hold here"

(( rc != 0 )) \
    || fail "REGRESSION: 'down' exited 0 while network '$netname' was still present — a false success outranks an honest failure"
grep -q "PARTIALLY torn down" <<<"$out" \
    || fail "REGRESSION: 'down' did not report a partial teardown; got: $out"
grep -q "network remains:   $netname" <<<"$out" \
    || fail "REGRESSION: 'down' did not NAME the network it failed to remove; got: $out"
# A count cannot say WHICH resource survived, so the name is the point.
grep -qE "^\[info\] ── lab '$lab' torn down ──" <<<"$out" \
    && fail "REGRESSION: 'down' still printed the success banner alongside the partial-teardown warning"
note "'down' refuses to call a partial teardown a success, and names the survivor"

# ── and it recovers: once the holder is gone, the same command completes ───────────
docker rm -f "$squatter" >/dev/null 2>&1 || fail "could not remove the squatter container"
out="$("$LAB_DOCKER" down --lab "$lab" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "after the holder was removed, 'down' should succeed; rc=$rc, output: $out"
grep -q "torn down" <<<"$out" || fail "recovery run did not report success; got: $out"
docker network inspect "$netname" >/dev/null 2>&1 \
    && fail "the network survived the recovery teardown"
note "recovery: with the holder gone, the same 'down' completes and reports success"

pass "'down' ground-truths the teardown and names what survived (P3-3)"
