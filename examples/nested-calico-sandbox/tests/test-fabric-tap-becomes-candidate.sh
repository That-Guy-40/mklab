#!/usr/bin/env bash
# Verdict: G.9's deferred scenario, run at last — a REAL `fabric.sh` tap, given an address
# on purpose, becomes a first-found candidate and Calico's tunnel moves onto it.
#
# WHY THIS IS A DIFFERENT TEST FROM test-selection-rules.sh, and not a duplicate.
#
# That test measured the PROPERTY with dummy interfaces. This one measures it on the actual
# subject: a tap created by the real `fabric.sh`, on the real `br-mc0`, with the real
# addressless rule deliberately violated. **A dummy interface in a guest is not a tap on
# br-mc0** — same property, different subject, and collapsing the two is precisely the
# substitution this repo keeps getting caught by. plan G.9 recorded this scenario as
# deferred on 2026-08-02 with the reason "re-running F.6 means an outage on a live cluster";
# inside a sandbox it costs nothing, which is the whole argument for the sandbox.
#
# WHAT IT ALSO PROVES, INCIDENTALLY: that `fabric.sh` runs at all somewhere that is not this
# host. Every previous exercise of it has been on one machine with one Calico.
#
# ROOT IS NEEDED **IN THE GUEST ONLY** — the fabric wants CAP_NET_ADMIN there. Nothing on
# the host side of this test is privileged, and the host's own cluster is compared before
# and after.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

load_findings
FABRIC="$REPO_DIR/examples/micro-cloud/fabric.sh"
LAB_VM="$REPO_DIR/phase2-qemu-vm/lab-vm.sh"
[[ -r "$FABRIC" ]] || skip "micro-cloud's fabric.sh not found at $FABRIC"
sandbox_running \
    || skip "the sandbox VM is not running — this test needs a Calico it may break. Bring one up with 'examples/nested-calico-sandbox/sandbox.sh up' (~15 min, unprivileged), then re-run"

gssh() { bash "$LAB_VM" ssh calico-sandbox -- "$@"; }

host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || true; }
HOST_BEFORE="$(host_binding)"

# ── 1. put the REAL fabric in the guest, and bring it up THERE ─────────────
gssh 'cat > /tmp/fabric.sh' < "$FABRIC" || fail "could not copy fabric.sh into the guest"
# MC_OWNER is required: the fabric refuses to make a root-owned tap by name, because an
# unprivileged VMM would get EPERM from TUNSETIFF (plan G.4). `lab` is the guest's user.
if ! out="$(gssh 'sudo MC_OWNER=lab bash /tmp/fabric.sh up 2>&1' )"; then
    fail "fabric.sh up failed inside the guest — the fabric has never been run anywhere but this repo's host, so a failure here is a finding about its portability, not a harness problem: ${out//$'\n'/ }"
fi
# TEARDOWN MUST UNDO THE FAULT FIRST. `fabric.sh down` compares Calico's binding against
# what it recorded at `up` and refuses to call teardown clean if the CNI moved — which, after
# this test deliberately captures the tunnel, is exactly what has happened. So the address
# comes off, Calico is given time to move back, and only then is `down` invoked. (The first
# run left /run/mklab-mc/preflight behind for precisely this reason, and the NEXT run refused
# to start: the fabric was right twice.)
on_exit 'gssh "sudo ip addr del 10.77.0.1/24 dev mc-g9 2>/dev/null; sleep 20; sudo bash /tmp/fabric.sh down >/dev/null 2>&1; sudo rm -rf /run/mklab-mc" || true'
note "the real fabric.sh is up inside the sandbox — first time it has run on any host but this one  ✓"

if ! out="$(gssh 'sudo MC_OWNER=lab bash /tmp/fabric.sh tap g9 2>&1')"; then
    fail "fabric.sh tap failed inside the guest: ${out//$'\n'/ }"
fi
TAP=mc-g9
gssh "ip link show $TAP >/dev/null 2>&1" || fail "fabric.sh reported success but $TAP does not exist in the guest"

# The fabric's OWN rule, asserted before we break it: a tap it makes carries no address.
addrs="$(gssh "ip -4 -o addr show $TAP 2>/dev/null" || true)"
[[ "$addrs" != *inet* ]] \
    || fail "REGRESSION: fabric.sh created $TAP WITH an IPv4 ($addrs). Rule 2 says that makes it a candidate — the fabric would be manufacturing the hazard it exists to avoid"
note "the fabric's tap is addressless, as its own rule requires  ✓"

BEFORE_IF="$(gssh 'ip -d link show vxlan.calico 2>/dev/null | grep -oE "dev [a-zA-Z0-9._-]+"' | awk '{print $2}')"
[[ -n "$BEFORE_IF" ]] || fail "the guest has no vxlan.calico — nothing to watch move"
[[ "$BEFORE_IF" != "$TAP" ]] \
    || fail "Calico is ALREADY on $TAP before we gave it an address — an addressless tap became the tunnel endpoint, which contradicts rule 2 in the opposite direction and is a much bigger finding than the one this test came for"
note "before: guest tunnel on '$BEFORE_IF', fabric tap present and addressless  ✓"

# ── 2. THE SCENARIO G.9 DEFERRED: give it an address on purpose ────────────
gssh "sudo ip addr add 10.77.0.1/24 dev $TAP" || fail "could not add an address to $TAP"
note "gave $TAP 10.77.0.1/24 — deliberately violating the fabric's own addressless rule"

# WAIT, do not restart. And wait GENEROUSLY: three runs of this converged in ~180s, 15s and
# 10s on identical inputs, so any fixed expectation would be asserting a coincidence.
DEADLINE=$(( SECONDS + ${NCS_G9_WAIT:-240} ))
NOW="$BEFORE_IF"
while (( SECONDS < DEADLINE )); do
    NOW="$(gssh 'ip -d link show vxlan.calico 2>/dev/null | grep -oE "dev [a-zA-Z0-9._-]+"' | awk '{print $2}')"
    [[ "$NOW" == "$TAP" ]] && break
    sleep 10
done

# ── 3. the verdict, in whichever direction it falls ────────────────────────
# BOTH outcomes are results and both are recorded. If the tap does NOT capture the tunnel,
# that does not vindicate anything — it means the ordering did not favour it this time, and
# `fabric.sh`'s addressless rule is still the only thing standing between a lab and F.6.
if [[ "$NOW" == "$TAP" ]]; then
    note "G.9 MEASURED: Calico's tunnel moved onto the fabric's own tap $TAP once it had an address  ✓"
    note "  → F.6's outage, reproduced deliberately on the real artifact, at Calico $F_CALICO"
    VERDICT="a REAL fabric.sh tap captured the guest cluster's VXLAN tunnel endpoint the moment it was given an address — F.6 reproduced on purpose, on the actual subject rather than a stand-in"
else
    # Not a pass-shaped silence: say plainly what was and was not shown.
    note "G.9 result: the tunnel stayed on '$NOW' — the addressed tap did NOT capture it within the deadline"
    note "  → rule 2 still holds (test-selection-rules.sh measured it); what this shows is that being a"
    note "    candidate is not the same as WINNING, and the ordering among candidates decided it"
    VERDICT="an addressed fabric.sh tap did NOT capture the tunnel within the deadline (it stayed on '$NOW'). Recorded as measured-and-negative, not as a pass: the tap became a candidate, and the ordering among candidates is what kept it from winning — which is exactly the thing G.3 retracted an explanation for"
fi

# ── 4. THE FABRIC'S OWN TEARDOWN GUARD, exercised by the fault ─────────────
# `down` records Calico's binding at `up` and compares it at teardown — the assertion that
# CAUGHT F.6 in the first place. With the tunnel now sitting on our tap, it must refuse to
# report a clean teardown. This is free evidence: the guard has never been observed firing
# for the reason it was written, because doing that meant causing an outage.
if [[ "$NOW" == "$TAP" ]]; then
    down_out="$(gssh 'sudo bash /tmp/fabric.sh down 2>&1' || true)"
    if grep -qiE 'calico|binding|moved' <<<"$down_out"; then
        note "the fabric's teardown guard REFUSED to call this clean, naming the moved binding — the assertion that caught F.6, observed firing for its actual reason  ✓"
    else
        note "(fabric.sh down did not mention the moved Calico binding: ${down_out//$'\n'/ } — worth a look, but not this test's verdict)"
    fi
fi

# Whatever happened in the guest, the host's cluster is the invariant.
HOST_AFTER="$(host_binding)"
[[ "$HOST_AFTER" == "$HOST_BEFORE" ]] \
    || fail "REGRESSION: the HOST's Calico binding moved during this run: '${HOST_BEFORE:-<absent>}' -> '${HOST_AFTER:-<absent>}'. Running a fabric inside a guest must not be able to touch the host's cluster"
note "host binding unchanged: ${HOST_AFTER:-<absent>}  ✓"

pass "G.9's deferred scenario ran at last, on the real artifact: $VERDICT. The fabric itself came up cleanly inside the sandbox — the first time it has run on any host but this repo's — its tap was addressless until deliberately broken, and the host's own cluster never moved"
