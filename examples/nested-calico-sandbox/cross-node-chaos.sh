#!/usr/bin/env bash
# cross-node-chaos.sh — the CROSS-NODE half of the CNI break pass. Injects the two faults
# that need a peer to mean anything, and prints a machine-readable `CNI2-*` record the
# host-side harness grades on CLAUDE.md's ladder.
#
# ── THE TWO ROWS ONE NODE COULD NOT ASK, AND WHY ────────────────────────────────────────
#
# `cni-chaos.sh` says so in the open: on a single node the VXLAN tunnel carries no traffic,
# because there are no peers to reach through it. Two of its rows are therefore graded on a
# proxy, and it names them rather than letting them collect rungs they did not earn:
#
#   vxlan-deleted           graded on whether Calico REBUILDS the device — an UNKNOWN
#                           wearing a DEGRADED, because the dataplane could not move
#   chosen-address-removed  reproduces the F.6 MECHANISM (an address moves, Calico
#                           re-detects) with nobody on the other end to notice an outage
#
# Here there is a peer, and both become measurable:
#
#   tunnel-deleted-under-peer  the tunnel is deleted while it is carrying real pod-to-pod
#                              traffic, so the consequence is the dataplane itself
#   peer-address-moved         F.6 WITH A WITNESS: node 2's chosen address is moved out from
#                              under node 1 while node 1's pod is pinging node 2's pod. The
#                              one-node version can only show that Calico re-detects; here the
#                              questions are how long the traffic was down and what the
#                              cluster was claiming while it was
#
# ── WHY THIS DRIVER RUNS ON THE HOST AND NOT IN A GUEST ─────────────────────────────────
#
# Every other script in this lab runs inside the sandbox. This one cannot, and the reason is
# the second row: it MOVES AN ADDRESS ON THE WIRE. A driver on node 1 would have to reach
# node 2 over that same wire, so it would lose its remote hand at the exact instant the fault
# lands — the record would go quiet at the interesting moment and the run would look like a
# crash. `lab-vm.sh ssh` reaches each guest over its OWN slirp NIC, which no row here touches,
# so the management path is orthogonal to the fault domain. That is the same rule as
# "nothing here touches enp0s3" in the one-node matrix, one level up.
#
# ── THE F.6 ROW MOVES AN ADDRESS; IT DOES NOT OFFER A COMPETING ONE, AND THAT WAS MEASURED ─
#
# The obvious injector is the one the ONE-NODE matrix uses: create a decoy interface holding
# an address Calico will prefer, and watch the tunnel endpoint migrate onto it. It does not
# work here, and the reason is a fact about Calico worth having:
#
#   `first-found` and `cidr=` DO NOT ORDER THEIR CANDIDATES THE SAME WAY. Appendix O measured
#   first-found at v3.29.3 taking a freshly-created dummy — higher ifindex wins — in 20 s.
#   Measured on this pair 2026-08-15, with `cidr=` and a dummy holding a matching address at a
#   higher ifindex, Calico kept the wire address for 205 s, AND kept it through a full
#   calico-node restart. The competitor never wins while the incumbent still matches.
#
# So the fault is the move itself: node 2's wire address is deleted and a different one put in
# its place. That is more faithful anyway — F.6 was an address that STOPPED BEING WHERE THE
# PEERS THOUGHT IT WAS, not an address that gained a rival — and it lands every time.
#
# The new address is on the same wire, so once Calico notices, the peer can reach it again.
# The measurement is therefore not "is it permanently broken" but the two numbers the original
# incident was actually made of: HOW LONG the traffic was down, and how much of that time the
# cluster spent reporting perfect health.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
LAB_VM="$REPO/phase2-qemu-vm/lab-vm.sh"

N1=calico-n1
N2=calico-n2
NS=cnix
POD_A=pod-xa
POD_B=pod-xb
# The peer's address before and after the move. Both on the wire's own subnet: the point is
# that the address the peer is FOUND at changed, not that it became unroutable forever.
N2_IP="${X_N2_IP:-10.77.0.12}"
N2_ALT_IP="${X_N2_ALT_IP:-10.77.0.22}"
WIRE_PREFIX=24

# 240s for the same reason cni-chaos.sh uses 240 and not 150: findings.env records Calico
# convergence at 10-200s across runs, and a deadline below a spread this lab has already
# measured manufactures negative results out of impatience.
RECOVER_WAIT="${X_RECOVER_WAIT:-240}"
# How long a fault is given to heal ITSELF before the recovery verb is applied. Deliberately
# much shorter than RECOVER_WAIT: it is not a deadline anything fails on, it is the window
# that decides DEGRADED (healed alone) from HALTED/LIED (needed a hand).
SELFHEAL_WAIT="${X_SELFHEAL_WAIT:-90}"
POLL=5

say() { printf 'CNI2-%s\n' "$*"; }

# ssh stderr goes to a log rather than to the record: a stray "Warning: Permanently added…"
# in the middle of a snapshot would be parsed as an observable. But it is KEPT, and named on
# every failure — a silently swallowed ssh error looks exactly like a broken cluster, and this
# repo has spent real time on that confusion in both directions.
SSH_LOG="${TMPDIR:-/tmp}/cni2-ssh.$$.log"
: >"$SSH_LOG"
on1() { bash "$LAB_VM" ssh "$N1" -- "$1" 2>>"$SSH_LOG"; }
on2() { bash "$LAB_VM" ssh "$N2" -- "$1" 2>>"$SSH_LOG"; }

# ── the address move is persistent state, so its undo is registered BEFORE the move ─────
# Row 2 leaves node 2 living at an address nothing else in this lab expects: `sandbox.sh`
# names 10.77.0.12 in five places and `join2` pinned kubelet's --node-ip to it. A driver
# killed between the move and the restore would leave a pair that looks fine, mostly works,
# and refuses the next join for reasons pointing anywhere but here. Same reasoning as
# `restore_ipam` in cni-chaos.sh: the one fault that edits durable state gets its undo
# registered before the edit, not after it.
MOVED=no
WIRE_DEV2=""
restore_peer_address() {
    [[ "$MOVED" == no ]] && return 0
    on2 "sudo ip addr del $N2_ALT_IP/$WIRE_PREFIX dev $WIRE_DEV2" >/dev/null 2>&1
    on2 "sudo ip addr add $N2_IP/$WIRE_PREFIX dev $WIRE_DEV2" >/dev/null 2>&1
    MOVED=no
}
trap restore_peer_address EXIT

# ── observables ─────────────────────────────────────────────────────────────────────────
# One ssh, one instant — see guest-xprobe.sh. POD_B_IP is captured once, at setup, and every
# probe below pings that address: re-reading it each time would silently follow the pod if it
# were rescheduled, and a row that changes its own target mid-measurement is not measuring.
POD_B_IP=""
probe() { on1 "sudo bash /tmp/xprobe.sh $NS $POD_A ${POD_B_IP:-}"; }

kv() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<" $1"; }

# all_ready <probe-line> — does the CLUSTER claim every node is fine? The second half of the
# LIED rung: a broken dataplane matters differently depending on whether anything admitted it.
all_ready() {
    local r; r="$(kv "$1" ready)"
    # An UNREADABLE readiness field is not "everything is fine". Returning true here would
    # inflate the dishonesty window every time the API was merely slow, and the LIED rung
    # would then be reporting on this harness.
    [[ -z "$r" || "$r" == '?' || "$r" != *:True* ]] && return 1
    [[ "$r" == *:False* || "$r" == *:Unknown* ]] && return 1
    return 0
}

# ── THE WITNESS: A PACKET COUNT, NOT A SAMPLE ───────────────────────────────────────────
#
# The rung used to be decided by `MID` — one probe taken as fast as possible after the
# injection. That is a RACE, and it decides the row: the tunnel row's rebuild has been
# measured at 9s, 9s and **1s** across four runs, and a rebuild faster than the probe (a
# `kubectl exec` plus two pings, ~3-4s) would report `MID=OK`, grade the row ABSORBED, and
# read as "the CNI shrugged off having its overlay deleted". It caught the outage all four
# times; a row whose rung depends on winning a race is not measured, it is lucky.
#
# So a 1-packet-per-second ping runs inside pod-a for the whole fault window and the row is
# graded on PACKETS LOST. One lost packet is one second of dead cross-node traffic, which is
# also the number this entire increment exists to produce — measuring it at poll resolution
# and then quoting it to the second was never defensible.
#
# It is read BEFORE any recovery verb is applied, because the restore is itself a second move
# and its outage is not the one being graded.
WITNESS_SECS="${X_WITNESS_SECS:-90}"
WPID=""; WOUT=""; W_LOSS=unmeasured
start_witness() {
    WOUT="$(mktemp)"
    # Backgrounded on the HOST, not in the guest: `cmd &` through ssh leaves the channel open
    # and the call blocks anyway, and `nohup … &` remotely gives up the exit status and the
    # summary line. A host-side subshell keeps both.
    on1 "$K -n $NS exec $POD_A -- ping -c $WITNESS_SECS -i 1 -W 1 $POD_B_IP" >"$WOUT" 2>&1 &
    WPID=$!
}
read_witness() {
    W_LOSS=unmeasured
    [[ -z "$WPID" ]] && return 0
    wait "$WPID" 2>/dev/null
    local sent recv
    sent="$(sed -n 's/^\([0-9][0-9]*\) packets transmitted.*/\1/p' "$WOUT" | tail -1)"
    recv="$(sed -n 's/.*transmitted, \([0-9][0-9]*\) .*received.*/\1/p' "$WOUT" | tail -1)"
    # A WITNESS THAT NEVER RAN MUST NOT READ AS ZERO LOSS. `0/0` and "no packets were lost"
    # are the same number and opposite facts, and the grader refuses the former by name.
    if [[ -n "$sent" && -n "$recv" ]] && (( sent > 0 )); then
        W_LOSS="$(( sent - recv ))/$sent"
    fi
    rm -f "$WOUT"; WPID=""
}

# await_x <deadline> — wait for cross-node traffic to come back, and MEASURE THE DISHONESTY
# on the way. Sets X_SECS, X_OK and X_LIE (seconds spent broken while the cluster reported
# every node Ready). A timeout is a result, not an error.
#
# ⚠️ X_LIE IS A SAMPLED LOWER BOUND, and it must be read as one. It can only count intervals
# in which a probe actually observed the dataplane down, so an outage shorter than one
# iteration is invisible to it — measured 2026-08-15, the tunnel row reported `LIEWINDOW=0`
# in the same run whose packet witness counted FOUR lost seconds. The packet count is the
# outage; this is "at least this much of it went unadmitted".
#
# ⚠️ EACH SAMPLE IS CREDITED WITH THE WALL TIME IT ACTUALLY STANDS FOR, not with `POLL`.
# The first version added a flat `POLL` per broken sample, which is a measurement of the
# LOOP rather than of the outage: a probe costs a `kubectl exec` and two pings, so an
# iteration takes roughly POLL + 3-4s and the flat count under-reported the window by about a
# third (35s against a 55s outage in which every sample was broken AND every node read Ready
# — the honest answer there is 55). A number that is silently low is worse than no number,
# because it is the number that gets quoted.
X_SECS=0; X_OK=no; X_LIE=0
await_x() {
    local limit="$1" t0=$SECONDS t_iter s lie=0
    X_OK=no
    while (( SECONDS - t0 < limit )); do
        t_iter=$SECONDS
        s="$(probe)"
        if [[ "$(kv "$s" xpods)" == OK ]]; then X_OK=yes; break; fi
        sleep "$POLL"
        all_ready "$s" && lie=$((lie + SECONDS - t_iter))
    done
    X_SECS=$((SECONDS - t0)); X_LIE=$lie
}

# ── preflight ───────────────────────────────────────────────────────────────────────────
[[ -x "$LAB_VM" ]] || { say "FATAL no phase-2 driver at $LAB_VM"; exit 2; }
for vm in "$N1" "$N2"; do
    bash "$LAB_VM" ssh "$vm" -- 'true' >/dev/null 2>>"$SSH_LOG" \
        || { say "FATAL cannot ssh to $vm — bring the pair up with 'sandbox.sh up2 && sandbox.sh join2'. ssh stderr: $(tail -2 "$SSH_LOG" | tr '\n' ' ')"; exit 2; }
done

H1="$(on1 'hostname')"; H2="$(on2 'hostname')"
[[ -n "$H1" && -n "$H2" && "$H1" != "$H2" ]] \
    || { say "FATAL the two guests report hostnames '$H1' and '$H2' — pods cannot be pinned to distinct nodes by a name they share"; exit 2; }

# THE CLUSTER MUST ALREADY BE TWO NODES. Everything below is about what happens BETWEEN
# nodes; run against a single-node cluster it would inject faults, observe nothing, and grade
# a matrix that was never cross-node. An unmet precondition is UNKNOWN, never a pass.
NODES="$(on1 "sudo /snap/bin/microk8s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{\",\"}{end}'")"
n_nodes="$(tr ',' '\n' <<<"$NODES" | grep -c . || true)"
(( n_nodes >= 2 )) \
    || { say "FATAL the cluster has $n_nodes node(s) ($NODES) — 'sandbox.sh join2' has not been run, and every row here would measure a single node while claiming to measure two"; exit 2; }
AUTODETECT="$(on1 "sudo /snap/bin/microk8s kubectl get ds -n kube-system calico-node -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name==\"IP_AUTODETECTION_METHOD\")].value}'")"
say "TOPOLOGY nodes=$n_nodes leader=$H1 peer=$H2 autodetect=${AUTODETECT:-<unset>} peer_addr=$N2_IP moves_to=$N2_ALT_IP"

on1 'cat > /tmp/xprobe.sh' < "$HERE/guest-xprobe.sh" \
    || { say "FATAL could not copy guest-xprobe.sh into $N1"; exit 2; }

# ── setup: a workload that can only talk THROUGH THE OVERLAY ────────────────────────────
K="sudo /snap/bin/microk8s kubectl"
on1 "$K create namespace $NS" >/dev/null 2>&1
t0=$SECONDS
while (( SECONDS - t0 < 120 )); do
    [[ -n "$(on1 "$K -n $NS get configmap kube-root-ca.crt -o name 2>/dev/null")" ]] && break
    sleep 3
done
[[ -n "$(on1 "$K -n $NS get configmap kube-root-ca.crt -o name 2>/dev/null")" ]] \
    || { say "FATAL namespace-$NS-never-became-usable — a pod created now fails its serviceaccount mount, and the matrix would grade a dataplane that never existed"; exit 2; }

# PINNED BY nodeSelector, one pod per node. This is the entire premise: two pods on one node
# talk over a veth pair and a bridge, and no fault below would touch them. If the pins do not
# take, every row grades ABSORBED and the matrix reports on its own scheduling.
mkpod() {  # mkpod <name> <node>
    local p="$1" node="$2"
    if [[ -n "$(on1 "$K -n $NS get pod $p -o name 2>/dev/null")" ]]; then
        # Reuse only if USABLE, not merely present — the one-node matrix was fooled by exactly
        # this once: an earlier row had left the pods as live records of a dataplane that was
        # gone, and the setup declined to recreate them.
        local phase ip
        phase="$(on1 "$K -n $NS get pod $p -o jsonpath='{.status.phase}' 2>/dev/null")"
        ip="$(on1 "$K -n $NS get pod $p -o jsonpath='{.status.podIP}' 2>/dev/null")"
        [[ "$phase" == Running && -n "$ip" ]] && return 0
        on1 "$K -n $NS delete pod $p --grace-period=0 --force" >/dev/null 2>&1
    fi
    on1 "$K -n $NS run $p --image=busybox:1.36 --restart=Never --overrides='{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$node\"}}}' -- sleep 3600" >/dev/null 2>&1
}
mkpod "$POD_A" "$H1"
mkpod "$POD_B" "$H2"
say "WORKLOAD-WAITING"
t0=$SECONDS
while (( SECONDS - t0 < 300 )); do
    a="$(on1 "$K -n $NS get pod $POD_A -o jsonpath='{.status.podIP}' 2>/dev/null")"
    b="$(on1 "$K -n $NS get pod $POD_B -o jsonpath='{.status.podIP}' 2>/dev/null")"
    [[ -n "$a" && -n "$b" ]] && break
    sleep 5
done
A_NODE="$(on1 "$K -n $NS get pod $POD_A -o jsonpath='{.spec.nodeName}' 2>/dev/null")"
B_NODE="$(on1 "$K -n $NS get pod $POD_B -o jsonpath='{.spec.nodeName}' 2>/dev/null")"
POD_B_IP="$b"
if [[ -z "${a:-}" || -z "${b:-}" ]]; then
    say "FATAL the workload never got addresses (a='${a:-}' b='${b:-}') after $((SECONDS - t0))s — there is no dataplane to break"
    exit 2
fi
# ASSERTED, NOT ASSUMED. `different_nodes=no` would make every row below meaningless in a way
# that looks like a healthy matrix, which is the worst shape available.
if [[ -z "$A_NODE" || "$A_NODE" == "$B_NODE" ]]; then
    say "FATAL both pods landed on '$A_NODE' — the nodeSelector pins did not take, so nothing below is cross-node and every row would grade ABSORBED for a reason that has nothing to do with the CNI"
    exit 2
fi
say "WORKLOAD-READY a=$POD_A@$A_NODE/$a b=$POD_B@$B_NODE/$b different_nodes=yes after=$((SECONDS - t0))s"

# ── IS THE OVERLAY EVEN IN THE PATH? DERIVED, NOT ASSUMED ───────────────────────────────
#
# Calico's VXLAN mode may be `CrossSubnet`, in which case two nodes that share a subnet — as
# these two do, being on one wire — talk DIRECTLY and the tunnel is decoration. Deleting a
# device nothing routes through is not a fault; the row would report ABSORBED and mean
# "we broke something that was not in the path". So the route is read first, and the tunnel
# row refuses to run rather than collect that rung.
BEFORE0="$(probe)"
PATH_DEV="$(kv "$BEFORE0" path)"
say "PATH dev=$PATH_DEV (the leader's route to the peer's pod)"

# ── 0. THE NO-FAULT CONTROL ─────────────────────────────────────────────────────────────
# Without it, "the harness reported a broken dataplane" cannot be told from a cluster that
# never routed between its nodes at all.
say "ROW=control-no-fault BEFORE[$BEFORE0]"
say "ROW=control-no-fault AFTER[$(probe)] RECOVERED=n/a SECS=0 LIEWINDOW=0 SELFHEAL=n/a"

# ── 1. THE TUNNEL, DELETED WHILE IT IS CARRYING TRAFFIC ─────────────────────────────────
# The one-node matrix's `vxlan-deleted`, asked properly. There the observable was "did Calico
# rebuild the device"; here it is "did the packets stop, and for how long".
if [[ "$PATH_DEV" != vxlan.calico ]]; then
    say "ROW=tunnel-deleted-under-peer SKIPPED reason=the-leaders-route-to-the-peers-pod-is-via-${PATH_DEV}-not-vxlan.calico-so-the-tunnel-is-not-in-the-path"
else
    b4="$(probe)"
    say "ROW=tunnel-deleted-under-peer BEFORE[$b4]"
    start_witness
    on1 "sudo ip link del vxlan.calico" >/dev/null 2>&1
    # ASSERT IT LANDED IMMEDIATELY. Checking a few seconds later cannot tell "deleted and
    # rebuilt fast" from "never deleted", and those grade differently.
    landed=no
    [[ -z "$(on1 'ip link show vxlan.calico 2>/dev/null | head -1')" ]] && landed=yes
    mid="$(probe)"
    if [[ "$landed" == no ]]; then
        read_witness
        say "ROW=tunnel-deleted-under-peer INJECTOR-FAILED the device was still present immediately after the delete — the fault never happened"
    else
        await_x "$SELFHEAL_WAIT"
        selfheal="$X_OK"; secs="$X_SECS"; lie="$X_LIE"; rec="$X_OK"
        # Read BEFORE the recovery verb below, so the count covers the injected fault and not
        # the restart's own blip.
        read_witness
        if [[ "$X_OK" == no ]]; then
            # GRADE AFTER ATTEMPTING THE RECOVERY THE SYSTEM OFFERS. The verb here is the one
            # an operator has: restart the CNI on the node whose tunnel is gone.
            on1 "$K delete pod -n kube-system -l k8s-app=calico-node --field-selector spec.nodeName=$H1 --grace-period=0 --force" >/dev/null 2>&1
            await_x "$RECOVER_WAIT"
            rec="$([[ "$X_OK" == yes ]] && echo via-calico-node-restart || echo no)"
            secs="$secs+$X_SECS"; lie=$((lie + X_LIE))
        else
            rec=yes
        fi
        say "ROW=tunnel-deleted-under-peer MID[$mid] AFTER[$(probe)] RECOVERED=$rec SECS=$secs LANDED=gone-at-once LOSS=$W_LOSS LIEWINDOW=$lie SELFHEAL=$([[ "$selfheal" == yes ]] && echo yes || echo no)"
    fi
fi

# ── 2. F.6, WITH A WITNESS ──────────────────────────────────────────────────────────────
# Node 2's chosen address moves to one node 1 cannot route to, while node 1's pod is pinging
# node 2's pod. Every other lab in this family has reproduced the mechanism; this is the first
# time anything has been on the other end to notice.
b4="$(probe)"
say "ROW=peer-address-moved BEFORE[$b4]"

# THE DEVICE IS RESOLVED FROM THE ADDRESS, not assumed to be `enp0s4`. That name is a guess
# about PCI slots, firmware and udev — three things this lab does not control — and the same
# reasoning that makes guest-peer-wire.sh match on the MAC applies here.
WIRE_DEV2="$(on2 'ip -o -4 addr show' | awk -v want="$N2_IP/$WIRE_PREFIX" '$4==want {print $2; exit}')"
if [[ -z "$WIRE_DEV2" ]]; then
    say "ROW=peer-address-moved INJECTOR-FAILED no interface on $H2 holds $N2_IP/$WIRE_PREFIX, so there is no chosen address to move: $(on2 'ip -o -4 addr show' | awk '{printf "%s=%s ", $2, $4}')"
else
    start_witness
    on2 "sudo ip addr del $N2_IP/$WIRE_PREFIX dev $WIRE_DEV2" >/dev/null 2>&1
    on2 "sudo ip addr add $N2_ALT_IP/$WIRE_PREFIX dev $WIRE_DEV2" >/dev/null 2>&1
    MOVED=yes
    # ASSERT THE FAULT LANDED, on both halves: the old address gone AND the new one present.
    # Checking only the second would pass a node that quietly kept both, where nothing has
    # moved and the row would grade ABSORBED having changed nothing.
    addrs="$(on2 'ip -o -4 addr show')"
    if [[ "$addrs" == *"$N2_IP/$WIRE_PREFIX"* || "$addrs" != *"$N2_ALT_IP/$WIRE_PREFIX"* ]]; then
        read_witness
        say "ROW=peer-address-moved INJECTOR-FAILED the move did not take on $WIRE_DEV2: $(awk '{printf "%s=%s ", $2, $4}' <<<"$addrs")"
        restore_peer_address
    else
        mid="$(probe)"
        # Does the peer follow on its own? Calico re-detects on a timer, so it should — and
        # the row is really about the SIZE of the window before it does, and about what the
        # cluster was saying during it.
        await_x "$SELFHEAL_WAIT"
        selfheal="$X_OK"; secs="$X_SECS"; lie="$X_LIE"
        # Read here, before EITHER branch below touches the address again: the restore is a
        # second move with an outage of its own, and counting its packets against this row
        # would be grading a fault nobody injected.
        read_witness
        if [[ "$X_OK" == yes ]]; then
            # AFTER is read BEFORE the address is put back: the restore is a second move, and
            # taking the final snapshot after it would grade this row on the recovery from a
            # fault nobody asked about.
            after="$(probe)"; rec=yes
            restore_peer_address
            # Not graded, but the pair must be left healthy and at the address the rest of the
            # lab names. Reported so a reader can see it happened.
            await_x "$RECOVER_WAIT"
            say "ROW=peer-address-moved RESTORED to=$N2_IP reconverged=$X_OK after=${X_SECS}s"
        else
            # THE RECOVERY VERB: put the address back. Named `via-address-restored` and never
            # folded into a self-heal, because "it fixed itself" and "somebody fixed it" are
            # different rungs.
            restore_peer_address
            await_x "$RECOVER_WAIT"
            rec="$([[ "$X_OK" == yes ]] && echo via-address-restored || echo no)"
            secs="$secs+$X_SECS"; lie=$((lie + X_LIE))
            after="$(probe)"
        fi
        say "ROW=peer-address-moved MID[$mid] AFTER[$after] RECOVERED=$rec SECS=$secs LANDED=addr-moved-$N2_IP-to-$N2_ALT_IP-on-$WIRE_DEV2 MOVED_TO=$N2_ALT_IP LOSS=$W_LOSS LIEWINDOW=$lie SELFHEAL=$([[ "$selfheal" == yes ]] && echo yes || echo no)"
    fi
fi

# The pods stay. This driver is re-runnable and a fresh pair costs a minute of scheduling; the
# namespace is left for `sandbox.sh cross-chaos --clean` to remove, so a failed run's evidence
# is still there to look at.
say "END"
