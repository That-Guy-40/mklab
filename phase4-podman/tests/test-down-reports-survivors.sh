#!/usr/bin/env bash
# Regression (REVIEW-phase4.md P4-6): `down` reported `── lab 'x' torn down ──` and
# exited 0 while a network it had failed to remove was still present — AND it deleted
# the lab's state dir on the way out regardless.
#
# Phase 3 has the same false-success shape (P3-3), but Phase 4 adds the consequence
# that makes this worse than a cosmetic lie: the state dir holds the `spec.toml` copy
# that `export --format compose` reads. So a lab that was STILL RUNNING could no
# longer be exported, and the error blamed the user for not doing the thing they did:
#
#     no spec.toml for lab 'x' (was it brought up via 'up --config'?)
#
# That is the "record and reality disagree" rung — here with the record destroyed
# while its subject lives, which is the same defect class as a stale record, inverted.
#
# The trigger is ordinary, not adversarial: the lab network is a normal podman network
# anything can join, and podman refuses to remove a network that still has containers
# ("has associated containers with it ... network is being used", rc=2).
#
# shellcheck disable=SC1091
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_cmd jq podman
podman info >/dev/null 2>&1 || skip "podman not usable on this host"
# A TOML parser, asked as a capability rather than as a vendor banner.
if ! command -v tomlq >/dev/null 2>&1 && ! command -v dasel >/dev/null 2>&1 \
   && ! { command -v yq >/dev/null 2>&1 && printf 'a = 1\n' | yq -p toml -o json - >/dev/null 2>&1; }; then
    skip "no TOML parser (need tomlq, dasel, or a yq supporting -p toml)"
fi

tmp="$(mktemp -d)"
lab="p4dwn$$"
squatter="p4squat$$"
# The squatter must go before the lab, or `down` can never finish.
on_exit 'podman rm -f "$squatter" >/dev/null 2>&1 || true; \
         LAB_STATE_DIR="$tmp/state" "$LAB_PODMAN" down --lab "$lab" >/dev/null 2>&1 || true; \
         rm -rf "$tmp"'

export LAB_STATE_DIR="$tmp/state"

cfg="$tmp/lab.toml"
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

netname="lab-${lab}-net"
spec="$LAB_STATE_DIR/podman/$lab/spec.toml"

"$LAB_PODMAN" up --config "$cfg" >/dev/null 2>&1 || skip "'up' failed (podman/network problem, not a test failure)"
[[ -r "$spec" ]] || fail "setup: expected the spec copy at $spec"
podman network exists "$netname" 2>/dev/null || fail "setup: expected network $netname"

# ── control: nothing holding the network — `down` must succeed AND clean up ────────
out="$("$LAB_PODMAN" down --lab "$lab" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "control: a clean teardown must exit 0, got rc=$rc; output: $out"
grep -q "torn down" <<<"$out" || fail "control: a clean teardown must report success; got: $out"
podman network exists "$netname" 2>/dev/null \
    && fail "control: the network survived a teardown that reported success"
[[ ! -e "$spec" ]] \
    || fail "control: the state dir must be removed once the lab really is gone (it is the record of a thing that no longer exists)"
note "control: a clean teardown exits 0, removes the network, and clears the state dir"

# ── the finding: a foreign container holds the network open ───────────────────────
"$LAB_PODMAN" up --config "$cfg" >/dev/null 2>&1 || skip "second 'up' failed"
podman run -d --name "$squatter" --network "$netname" alpine:latest sleep 300 >/dev/null 2>&1 \
    || skip "could not start the squatter container (podman problem, not a test failure)"

out="$("$LAB_PODMAN" down --lab "$lab" 2>&1)" && rc=0 || rc=$?

podman network exists "$netname" 2>/dev/null \
    || skip "this podman removed a network that still had a container attached — the premise of the test does not hold here"

(( rc != 0 )) \
    || fail "REGRESSION: 'down' exited 0 while network '$netname' was still present — a false success outranks an honest failure"
grep -q "PARTIALLY torn down" <<<"$out" \
    || fail "REGRESSION: 'down' did not report a partial teardown; got: $out"
grep -q "network remains:   $netname" <<<"$out" \
    || fail "REGRESSION: 'down' did not NAME the network it failed to remove; got: $out"
grep -qE "^\[info\] ── lab '$lab' torn down ──" <<<"$out" \
    && fail "REGRESSION: 'down' still printed the success banner alongside the partial-teardown warning"
note "'down' refuses to call a partial teardown a success, and names the survivor"

# ── the Phase-4-specific half: the record must OUTLIVE nothing, but must not ───────
# ── predecease its subject either ─────────────────────────────────────────────────
[[ -r "$spec" ]] \
    || fail "REGRESSION: 'down' deleted the lab's spec.toml while the lab was still up — the record was discarded while its subject lives"
note "the spec copy survives a partial teardown"

# ...and the user-visible consequence the finding named: export still works.
exp="$("$LAB_PODMAN" export "$lab" --format compose 2>&1)" && erc=0 || erc=$?
(( erc == 0 )) \
    || fail "REGRESSION: a still-running lab could not be exported after a partial 'down': $exp"
grep -q 'services:' <<<"$exp" \
    || fail "export after a partial teardown produced no services block; got: $(head -3 <<<"$exp")"
grep -q "no spec.toml for lab" <<<"$exp" \
    && fail "REGRESSION: export blamed the user for not using 'up --config' on a lab that WAS brought up that way"
note "a still-running lab is still exportable after a partial teardown"

# ── and it recovers: once the holder is gone, the same command completes ──────────
podman rm -f "$squatter" >/dev/null 2>&1 || fail "could not remove the squatter container"
out="$("$LAB_PODMAN" down --lab "$lab" 2>&1)" && rc=0 || rc=$?
(( rc == 0 )) || fail "after the holder was removed, 'down' should succeed; rc=$rc, output: $out"
grep -q "torn down" <<<"$out" || fail "recovery run did not report success; got: $out"
podman network exists "$netname" 2>/dev/null \
    && fail "the network survived the recovery teardown"
[[ ! -e "$spec" ]] \
    || fail "the state dir survived a teardown that finally succeeded — the record must go when its subject does"
note "recovery: with the holder gone, 'down' completes, and only then is the record cleared"

pass "'down' ground-truths the teardown, names survivors, and keeps the spec while the lab lives (P4-6)"
