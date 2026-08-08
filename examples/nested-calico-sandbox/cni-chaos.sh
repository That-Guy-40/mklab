#!/usr/bin/env bash
# cni-chaos.sh — run INSIDE the sandbox guest, as root. Injects a fault at each layer of
# the CNI that can fail on its own, and prints a machine-readable `CNI-*` record the
# host-side harness grades on CLAUDE.md's ladder.
#
# ── THE LAYER NOBODY HAD WATCHED FALL OVER ──────────────────────────────────────────────
#
# `CLAUDE.md` asks for an injection point per independently-failing layer. micro-cloud's
# matrix has six rows and the CNI is none of them — because breaking a CNI meant breaking
# the one this machine uses. That objection is what the sandbox removes.
#
# ── WHAT A SINGLE NODE CAN AND CANNOT OBSERVE, STATED UP FRONT ──────────────────────────
#
# This is one node, so the VXLAN tunnel carries NO traffic: there are no peers to reach
# through it. A fault that only harms cross-node traffic therefore has no dataplane
# consequence here, and grading it ABSORBED would be FALSE — it would mean "the fault never
# mattered", not "the CNI absorbed it". Each row below records which observables it could
# actually move, and rows whose real consequence needs a second node say so by name rather
# than collecting a rung they did not earn.
#
# Five observables, collected identically for every row so the rungs are comparable:
#
#   ready   calico-node's DaemonSet ready count      (is the CNI process healthy?)
#   nodeip  the node's projectcalico.org/IPv4Address (what F.6 actually corrupted)
#   tunnel  vxlan.calico's device + address          (the overlay's local endpoint)
#   pods    pod-a -> pod-b ICMP                      (THE DATAPLANE — the outcome)
#   rules   Calico's netfilter rule count            (felix's programming)
#
# `pods` is the one that matters. The others are mechanism; they are collected because when
# the dataplane DOES break they say which layer broke, and because some faults are only
# visible in them.
#
# ── EVERY FAULT IS SCOPED ───────────────────────────────────────────────────────────────
#
# Nothing here touches enp0s3, the interface carrying ssh: a fault that kills the guest's
# own management path sends every remaining row to the same rung and the harness reports a
# uniform, uninformative failure while looking like it works. The no-candidate row uses a
# decoy it created for the purpose.
set -uo pipefail

MK=/snap/bin/microk8s
K="$MK kubectl"
# 240s, NOT 150. findings.env records Calico convergence at 10-200s across runs, so a 150s
# deadline is BELOW a value this lab has already measured — and the first run proved it:
# `chosen-address-removed` was SKIPPED with "calico never took the decoy in 150s", a timeout
# reported as an absent behaviour. A deadline shorter than the measured spread manufactures
# negative results.
RECOVER_WAIT="${CNI_RECOVER_WAIT:-240}"
# The IPAM row gets its OWN, longer deadline for the same reason the 240 above is not 150:
# its recovery is not Calico's poll but KUBELET's retry of a failed sandbox, which backs off
# exponentially to five minutes. A 240 s deadline there would manufacture a STRANDED out of a
# pod that was going to start at 300 s — a timeout reported as an absent behaviour, which this
# file has already been caught doing once.
IPAM_RECOVER_WAIT="${CNI_IPAM_RECOVER_WAIT:-420}"
# How long to WATCH the allocator give addresses back. Deliberately not a deadline anything
# is failed on — see the note at the leak check, where three different values were each
# mistaken for one.
IPAM_LEAK_WAIT="${CNI_IPAM_LEAK_WAIT:-240}"
NS=cnichaos

say() { printf 'CNI-%s\n' "$*"; }

# ── the one fault that edits CLUSTER-WIDE config, and therefore the one that must be
# ── undone even if this script is killed ────────────────────────────────────────────────
# Row 6 disables the cluster's IP pools to run the allocator dry. Every other fault here is
# local and self-healing; that one is a persisted API object, and a script that dies between
# "disable" and "restore" would leave a cluster that can never schedule a pod again — with
# nothing in the record saying why. So the undo is registered before the edit, not after it.
IPAM_TINY_POOL=mc-ipam-tiny
# ONE definition of the tiny pool, because the value recurs in five places — the IPPool
# manifest, two address-prefix greps, the leak check's block filter, and the assertion that
# the CNI's refusal named it. A second copy is a second thing to forget.
IPAM_TINY_CIDR=10.99.9.0/29
IPAM_TINY_PREFIX=10.99.9.
IPAM_DISABLED_POOLS=""
restore_ipam() {
    [[ -z "$IPAM_DISABLED_POOLS" ]] && return 0
    local p
    for p in $IPAM_DISABLED_POOLS; do
        $K patch ippools.crd.projectcalico.org "$p" --type=merge \
            -p '{"spec":{"disabled":false}}' >/dev/null 2>&1
    done
    $K delete ippools.crd.projectcalico.org "$IPAM_TINY_POOL" >/dev/null 2>&1
    IPAM_DISABLED_POOLS=""
}
trap restore_ipam EXIT

# ── observables ────────────────────────────────────────────────────────────
o_ready()  { $K get ds -n kube-system calico-node -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "?"; }
o_nodeip() { $K get node -o jsonpath='{.items[0].metadata.annotations.projectcalico\.org/IPv4Address}' 2>/dev/null || echo "?"; }
o_tunnel() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' | tr ' ' '_' || echo "absent"; }
# Both backends: this repo has been caught once by nft being unable to see legacy xtables,
# and Calico's 140 rules living in the one nobody looked at.
o_rules()  { local n=0 a b
             a="$(nft list ruleset 2>/dev/null | grep -ci cali || true)"; b="$(iptables-legacy-save 2>/dev/null | grep -ci cali || true)"
             n=$(( ${a:-0} + ${b:-0} )); printf '%s' "$n"; }
o_pods()   { # THE OUTCOME: can one pod reach another?
             local ip; ip="$($K get pod -n "$NS" pod-b -o jsonpath='{.status.podIP}' 2>/dev/null)"
             [[ -z "$ip" ]] && { printf 'no-podb-ip'; return; }
             if $K exec -n "$NS" pod-a -- ping -c 2 -W 2 "$ip" >/dev/null 2>&1; then printf 'OK'; else printf 'FAIL'; fi; }

# ── AN OBSERVABLE THAT DOES NOT GO THROUGH THE API ──────────────────────────────────────
#
# `o_pods` runs `kubectl exec`, which needs the API server, which needs the datastore. That
# is fine for every row above — none of them touch it — and it is exactly why the datastore
# row was recorded as blocked rather than written: breaking k8s-dqlite blinds the harness,
# every row grades STRANDED for harness reasons, and the matrix reports on itself.
#
# THE DECISION (2026-08-08): the row is buildable, and the blocker was specific rather than
# fundamental. The CNI dataplane does not need the API to forward a packet — once a pod is
# running, its connectivity is enforced by felix's netfilter rules, Calico's per-pod host
# route and the pod's veth, all of which live in the kernel. So for this row the observable
# is the pod's address pinged FROM THE NODE, and the pod's IP is captured while the API is
# still up. No API is consulted after the fault.
#
# ⚠️ NAMED LIMITATION: this crosses ONE veth, not two. It is a weaker subject than
# pod-a → pod-b and is recorded as such rather than presented as the same measurement. What
# it does prove is the part that matters here — that forwarding survives the control plane.
NOAPI_TARGET=""
o_pods_noapi() {
    [[ -z "$NOAPI_TARGET" ]] && { printf 'no-target-captured'; return; }
    if ping -c 2 -W 2 "$NOAPI_TARGET" >/dev/null 2>&1; then printf 'OK'; else printf 'FAIL'; fi
}

snapshot() { printf 'ready=%s nodeip=%s tunnel=%s pods=%s rules=%s' \
                    "$(o_ready)" "$(o_nodeip)" "$(o_tunnel)" "$(o_pods)" "$(o_rules)"; }

# Wait for the dataplane to come back, up to the deadline. Returns the seconds taken, or
# the deadline if it never did — a timeout is a result, not an error.
await_pods() {
    local t0=$SECONDS
    while (( SECONDS - t0 < RECOVER_WAIT )); do
        [[ "$(o_pods)" == OK ]] && { printf '%s' "$((SECONDS - t0))"; return 0; }
        sleep 5
    done
    printf '%s' "$((SECONDS - t0))"; return 1
}

# ── setup: a real workload to break ────────────────────────────────────────
[[ $EUID -eq 0 ]] || { say "FATAL not-root"; exit 2; }
command -v "$MK" >/dev/null || { say "FATAL no-microk8s"; exit 2; }

# WAIT FOR THE NAMESPACE TO BE USABLE, not merely to exist. A pod created before the
# controller has published `kube-root-ca.crt` into the new namespace fails its
# serviceaccount volume mount — "object cnichaos/kube-root-ca.crt not registered" — and
# lands in ContainerStatusUnknown after having started perfectly well. Measured
# 2026-08-07: both workload pods died that way, and the whole matrix would then have been
# graded against a dataplane that never existed.
#
# `create namespace` returning is not the namespace being ready. Third instance of that
# shape in this repo today.
#
# It must also handle a namespace still TERMINATING from a previous run: `create` fails
# against one, and the loop below would then time out and the matrix would run with no
# workload at all — five rows grading a dataplane that never existed. So the namespace is
# waited OUT first, then created, and the result is ASSERTED rather than assumed. Measured
# 2026-08-07: deleting with `--wait=false` and immediately re-running produced exactly that.
t0=$SECONDS
while (( SECONDS - t0 < 120 )); do
    phase="$($K get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
    [[ "$phase" == Terminating ]] || break
    sleep 3
done
$K create namespace "$NS" >/dev/null 2>&1
t0=$SECONDS
while (( SECONDS - t0 < 120 )); do
    $K -n "$NS" get configmap kube-root-ca.crt >/dev/null 2>&1 && break
    sleep 3
done
# REFUSE TO CONTINUE without a usable namespace. A matrix whose dataplane observable is
# `no-podb-ip` on every row is not a lenient matrix, it is a meaningless one — and it would
# still print five rungs.
if ! $K -n "$NS" get configmap kube-root-ca.crt >/dev/null 2>&1; then
    say "FATAL namespace-$NS-never-became-usable phase=$($K get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null) — refusing to grade a matrix with no dataplane"
    exit 2
fi
say "NAMESPACE-READY after=$((SECONDS - t0))s"

# REUSE A POD ONLY IF IT IS USABLE, NOT MERELY PRESENT.
#
# The first version skipped creation when `get pod` succeeded — i.e. it asked whether the API
# still holds an OBJECT called pod-a, when what the matrix needs is a pod with an address that
# can reach its neighbour. Those come apart exactly when this script has been run before:
# earlier rows delete veths and move the node's address, and a pod can be left as a live
# record of a dataplane that is gone. Measured 2026-08-08, running the suite end to end: the
# preceding G.9 test disturbed the guest's networking, these two pods survived as objects, the
# setup declined to recreate them, and the run then waited out its full 240 s for pods that
# were never going to come up. The no-fault control caught it and refused to grade — which is
# the control doing its job, but the harness should not have needed saving.
for p in pod-a pod-b; do
    if $K -n "$NS" get pod "$p" >/dev/null 2>&1; then
        [[ "$($K -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)" == Running \
        && -n "$($K -n "$NS" get pod "$p" -o jsonpath='{.status.podIP}' 2>/dev/null)" ]] && continue
        $K -n "$NS" delete pod "$p" --grace-period=0 --force >/dev/null 2>&1
    fi
    $K -n "$NS" run "$p" --image=busybox:1.36 --restart=Never -- sleep 3600 >/dev/null 2>&1
done
say "WORKLOAD-WAITING"
t0=$SECONDS
while (( SECONDS - t0 < 240 )); do
    [[ "$($K -n "$NS" get pod pod-a -o jsonpath='{.status.phase}' 2>/dev/null)" == Running \
    && "$($K -n "$NS" get pod pod-b -o jsonpath='{.status.phase}' 2>/dev/null)" == Running ]] && break
    sleep 5
done
say "WORKLOAD-READY after=$((SECONDS - t0))s a=$($K -n "$NS" get pod pod-a -o jsonpath='{.status.podIP}' 2>/dev/null) b=$($K -n "$NS" get pod pod-b -o jsonpath='{.status.podIP}' 2>/dev/null)"

# ROWS ARE NOT INDEPENDENT UNLESS SOMETHING MAKES THEM SO. Measured 2026-08-07: by row 5
# the workload had vanished (`pods=no-podb-ip`, rules 200 -> 142) — killed as collateral by
# an earlier row — so the last row graded against a dataplane that no longer existed and
# came out STRANDED for a reason that had nothing to do with its own fault. A matrix whose
# observable silently degrades across rows is comparing rungs that are not comparable.
ensure_workload() {
    [[ "$(o_pods)" == OK ]] && return 0
    say "WORKLOAD-RESTORING (the dataplane was lost by an earlier row)"
    for p in pod-a pod-b; do
        $K -n "$NS" delete pod "$p" --grace-period=0 --force >/dev/null 2>&1
        $K -n "$NS" run "$p" --image=busybox:1.36 --restart=Never -- sleep 3600 >/dev/null 2>&1
    done
    local t0=$SECONDS
    while (( SECONDS - t0 < 180 )); do
        [[ "$(o_pods)" == OK ]] && { say "WORKLOAD-RESTORED after=$((SECONDS - t0))s"; return 0; }
        sleep 5
    done
    say "WORKLOAD-UNRESTORABLE after=$((SECONDS - t0))s — rows below grade without a dataplane and must say so"
    return 1
}

# ── 0. THE NO-FAULT CONTROL ────────────────────────────────────────────────
# Without it, "the harness reported failures" cannot be told from a CNI that never worked.
#
# It gets `ensure_workload` like every other row, and the asymmetry is worth naming: the
# control was the ONE row that did not, so it alone had to be handed a healthy dataplane by
# the setup above rather than being able to establish one. When the setup was fooled by a
# leftover pod, this row failed for a reason that had nothing to do with the CNI — the row
# whose entire job is to tell those two apart.
ensure_workload
say "ROW=control-no-fault BEFORE[$(snapshot)]"
say "ROW=control-no-fault AFTER[$(snapshot)] RECOVERED=n/a SECS=0"

# ── 1. the CNI PROCESS: delete calico-node's pod ───────────────────────────
# A DaemonSet should replace it. This is the layer's own supervisor, and the question is
# whether the dataplane survives the gap.
ensure_workload
say "ROW=calico-node-killed BEFORE[$(snapshot)]"
uid_before="$($K get pod -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null)"
$K delete pod -n kube-system -l k8s-app=calico-node --grace-period=0 --force >/dev/null 2>&1
sleep 5
mid="$(snapshot)"
uid_after="$($K get pod -n kube-system -l k8s-app=calico-node -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null)"
# ASSERT THE FAULT LANDED: a DIFFERENT pod uid means the old one really was destroyed. The
# ready count alone cannot show this — it is 1 before and 1 after either way.
if [[ -n "$uid_before" && "$uid_before" == "$uid_after" ]]; then
    say "ROW=calico-node-killed INJECTOR-FAILED uid unchanged ($uid_before) — the pod was never replaced, so this row would grade a fault that never happened"
else
    secs="$(await_pods)"; rec=$?
    say "ROW=calico-node-killed MID[$mid] AFTER[$(snapshot)] RECOVERED=$([[ $rec -eq 0 ]] && echo yes || echo no) SECS=$secs LANDED=uid-${uid_before:0:8}->${uid_after:0:8}"
fi

# ── 2. felix's PROGRAMMING: flush Calico's netfilter rules ─────────────────
# The dataplane's actual enforcement. felix reconciles on a timer; the question is whether
# it notices someone else's edit.
# THE INJECTOR HAS TO REACH THE RIGHT BACKEND, AND THE RIGHT CHAINS.
#
# Measured 2026-08-07 in this guest: Calico's 200 rules are in LEGACY xtables and
# `nft list ruleset` sees **zero** of them — the two-netfilter-backends trap this repo has
# already been caught by once on the host. So an nft flush is a no-op here.
#
# And `iptables-legacy -F` alone is *also* a no-op for this purpose: it flushes BUILT-IN
# chains, while Calico's rules live in custom `cali-*` chains that survive it. The first
# draft did exactly that and the rule count came back 200 unchanged — an injector that
# reported a fault it had not caused, which would have graded the row ABSORBED for the
# wrong reason. Flush the builtins to drop the jumps, THEN delete the custom chains.
ensure_workload
say "ROW=netfilter-flushed BEFORE[$(snapshot)]"
rules_before="$(o_rules)"
for t in filter nat mangle raw; do
    iptables-legacy -t "$t" -F 2>/dev/null
    iptables-legacy -t "$t" -X 2>/dev/null
done
nft list ruleset 2>/dev/null | grep -qi cali && nft flush ruleset 2>/dev/null
rules_after_flush="$(o_rules)"
sleep 5
mid="$(snapshot)"
# ASSERT THE FAULT LANDED before grading the recovery. A row whose injector silently did
# nothing grades ABSORBED and means "nothing was broken" — the exact defect found in
# micro-cloud's vsock matrix, where a no-op injector left its row passing.
if (( rules_after_flush >= rules_before )); then
    say "ROW=netfilter-flushed INJECTOR-FAILED before=$rules_before after=$rules_after_flush — the rules were NOT removed, so this row would grade a fault that never happened"
else
    secs="$(await_pods)"; rec=$?
    say "ROW=netfilter-flushed MID[$mid] AFTER[$(snapshot)] RECOVERED=$([[ $rec -eq 0 ]] && echo yes || echo no) SECS=$secs LANDED=$rules_before->$rules_after_flush"
fi

# ── 3. one POD's veth, deleted underneath it ───────────────────────────────
# Scoped to a single pod on purpose: a fault that breaks every pod would send this row and
# the next to the same rung, and the difference between them is the finding.
ensure_workload
say "ROW=pod-veth-deleted BEFORE[$(snapshot)]"
# THE RIGHT VETH, not the first one. `grep -oE 'cali[0-9a-f]+' | head -1` picks whatever
# the kernel lists first — usually CoreDNS's — so deleting it leaves pod-a -> pod-b working
# and the row grades ABSORBED while testing nothing. Calico installs a host route per pod,
# so the pod's OWN veth is the one that route points at.
a_ip="$($K get pod -n "$NS" pod-a -o jsonpath='{.status.podIP}' 2>/dev/null)"
veth="$(ip route show 2>/dev/null | awk -v ip="$a_ip" '$1==ip {print $3; exit}')"
if [[ -n "$veth" ]]; then
    ip link del "$veth" 2>/dev/null
    sleep 5
    # ASSERT IT LANDED before grading anything.
    if ip link show "$veth" >/dev/null 2>&1; then
        say "ROW=pod-veth-deleted INJECTOR-FAILED veth=$veth still present — the fault never happened"
        veth=""
    fi
fi
if [[ -n "$veth" ]]; then
    mid="$(snapshot)"
    secs="$(await_pods)"; rec=$?
    # GRADE AFTER ATTEMPTING THE RECOVERY THE SYSTEM OFFERS. If it did not self-heal, the
    # verb Kubernetes offers is "delete the pod and let it be rescheduled" — and whether
    # that works is the difference between HALTED and STRANDED.
    if (( rec != 0 )); then
        $K delete pod -n "$NS" pod-a --grace-period=0 --force >/dev/null 2>&1
        $K -n "$NS" run pod-a --image=busybox:1.36 --restart=Never -- sleep 3600 >/dev/null 2>&1
        sleep 10; secs2="$(await_pods)"; rec2=$?
        say "ROW=pod-veth-deleted MID[$mid] AFTER[$(snapshot)] RECOVERED=$([[ $rec2 -eq 0 ]] && echo via-pod-recreate || echo no) SECS=$secs+$secs2"
    else
        say "ROW=pod-veth-deleted MID[$mid] AFTER[$(snapshot)] RECOVERED=yes SECS=$secs"
    fi
else
    say "ROW=pod-veth-deleted SKIPPED reason=no-veth-resolved-for-pod-a-ip-${a_ip:-none}"
fi

# ── 4. the OVERLAY device, deleted ─────────────────────────────────────────
# ⚠️ Its real consequence needs a SECOND NODE: on one node the tunnel carries no traffic, so
# `pods` cannot move here no matter what happens. The observable that CAN move is whether
# Calico rebuilds the device, and the row is graded on that alone — explicitly, so it does
# not collect an ABSORBED it did not earn.
ensure_workload
say "ROW=vxlan-deleted BEFORE[$(snapshot)]"
ip link del vxlan.calico 2>/dev/null
# ASSERT IT LANDED — immediately, before Calico can rebuild it. Checking 5s later cannot
# tell "deleted and rebuilt fast" from "never deleted", and those grade differently.
gone_at_once=no
ip link show vxlan.calico >/dev/null 2>&1 || gone_at_once=yes
sleep 5
mid="$(snapshot)"
if [[ "$gone_at_once" == no ]]; then
    say "ROW=vxlan-deleted INJECTOR-FAILED the device was still present immediately after the delete — the fault never happened"
    ip link del vxlan.calico 2>/dev/null
fi
t0=$SECONDS; rebuilt=no
while (( SECONDS - t0 < RECOVER_WAIT )); do
    [[ "$(o_tunnel)" != absent ]] && { rebuilt=yes; break; }
    sleep 5
done
say "ROW=vxlan-deleted MID[$mid] AFTER[$(snapshot)] RECOVERED=$rebuilt SECS=$((SECONDS - t0)) LANDED=$gone_at_once NOTE=single-node-dataplane-unaffected-by-design"

# ── 5. the ADDRESS Calico chose, taken away ────────────────────────────────
# The F.6 mechanism run forwards: give Calico a decoy to bind to, then delete the decoy out
# from under it. Does it re-detect, or keep advertising an address that no longer exists?
# A node advertising a dead IP is the LIED rung — the record and reality disagree — and on a
# multi-node cluster it is an outage that looks like a healthy node.
#
# The decoy is created for this row so the fault is scoped: enp0s3 carries ssh and is never
# touched.
#
# IT IS CALLED `mc-cnidecoy` AND NOT `cni-decoy`, AND THAT IS A MEASUREMENT, NOT A STYLE
# CHOICE. The first two runs SKIPPED this row with "calico never took the decoy" — at 150s
# and again at 240s. The reason was the NAME: Calico's first-found exclusion list contains
# `^cni.*` as well as the `^br-.*` this lab set out to test, so `cni-decoy` was excluded by
# the very mechanism under study. Renaming it proved it — `mc-probe`, identical in every
# other respect, was taken in 20 seconds. A second exclusion pattern, found by accident,
# with its own control.
ensure_workload
say "ROW=chosen-address-removed BEFORE[$(snapshot)]"
ip link add mc-cnidecoy type dummy 2>/dev/null
ip addr add 10.88.0.1/24 dev mc-cnidecoy 2>/dev/null
ip link set mc-cnidecoy up 2>/dev/null
t0=$SECONDS; took=no
while (( SECONDS - t0 < RECOVER_WAIT )); do
    [[ "$(o_nodeip)" == 10.88.0.1* ]] && { took=yes; break; }
    sleep 5
done
if [[ "$took" == yes ]]; then
    say "ROW=chosen-address-removed DECOY-TAKEN after=$((SECONDS - t0))s nodeip=$(o_nodeip)"
    ip link del mc-cnidecoy 2>/dev/null
    sleep 10
    mid="$(snapshot)"
    t0=$SECONDS; redetected=no
    while (( SECONDS - t0 < RECOVER_WAIT )); do
        ip="$(o_nodeip)"
        [[ -n "$ip" && "$ip" != 10.88.0.1* && "$ip" != "?" ]] && { redetected=yes; break; }
        sleep 5
    done
    say "ROW=chosen-address-removed MID[$mid] AFTER[$(snapshot)] RECOVERED=$redetected SECS=$((SECONDS - t0))"
else
    ip link del mc-cnidecoy 2>/dev/null
    say "ROW=chosen-address-removed SKIPPED reason=calico-never-took-the-decoy-in-${RECOVER_WAIT}s"
fi

# ── 6. the ADDRESS ALLOCATOR, run dry ──────────────────────────────────────
# The analogue of micro-cloud's DHCP-pool row, one layer up: there, a dnsmasq pool of four
# addresses; here, Calico's IPAM.
#
# ── THE POINT IS NOT "IT RUNS OUT". IT IS *HOW* IT RUNS OUT ─────────────────────────────
#
# Running out of addresses is arithmetic, not a bug. What the ladder asks is what the CNI
# does at the moment it has none left, and — exactly as in the DHCP row — the answer differs
# for two subjects that this one fault hits at the same instant:
#
#   INCUMBENT   pods that already hold an address. They should not notice at all. A
#               dataplane that breaks because the *allocator* ran dry would mean allocation
#               and forwarding are coupled when they must not be.        → expect ABSORBED
#
#   NEW POD     admitted at the same instant, with nothing left to give. HALTED is the good
#               answer — refused, by a name a human can act on, and recoverable by the verb
#               the system offers (free an address). The bad answers are LIED (Running with
#               no address, or handed one already in use) and STRANDED (still refused after
#               capacity comes back).                                    → measured below
#
# The two are emitted as separate rows because they are separate subjects, and because the
# incumbent row is the negative control for the new-pod row: without it, "new pods were
# refused" cannot be told from "the whole CNI fell over".
#
# ── HOW THE POOL IS MADE SMALL ENOUGH TO FILL ───────────────────────────────────────────
#
# The cluster's pool is a /16 — 65k addresses, which nobody is going to fill with pods. So
# the pools in use are DISABLED and a deliberately tiny one (/29, eight addresses) is offered
# in their place, then filled with real pods that make real CNI ADD calls. Same trick as the
# DHCP row's four-address pool, and for the same reason: the interesting behaviour is at the
# boundary, and the boundary has to be reachable.
#
# ⚠️ THE FILL IS ASSERTED TO HAVE LANDED, and that assertion is load-bearing rather than
# decorative: it is the one that checks the assumption this whole row rests on — that
# `disabled: true` really does stop Calico allocating from a pool it already holds an affine
# block in. If it does not, the fillers come up with 10.1.x.x addresses out of the ORIGINAL
# pool, the pool never runs dry, nothing is ever refused, and the row would grade ABSORBED
# while having injected nothing whatsoever. So the fillers' addresses are checked to be
# inside the tiny pool BY PREFIX before anything is graded.
ensure_workload
say "ROW=ipam-exhausted BEFORE[$(snapshot)]"

# PRECONDITION, derived rather than assumed. Everything below manipulates IPPool CRDs, which
# are decoration unless the CNI is actually using calico-ipam — with host-local IPAM the
# addresses come from the node's podCIDR and not one line of this row would mean anything. An
# unmet precondition is UNKNOWN, and UNKNOWN is never a pass.
if ! grep -rqs 'calico-ipam' /var/snap/microk8s/current/args/cni-network/ 2>/dev/null; then
    say "ROW=ipam-exhausted SKIPPED reason=cni-is-not-using-calico-ipam-so-the-ippool-crds-are-decoration"
    say "ROW=ipam-exhausted-incumbent SKIPPED reason=cni-is-not-using-calico-ipam"
else
    # allocations still live in the tiny pool's block, by prefix. 0 = nothing left behind.
    tiny_allocated() {
        $K get ipamblocks.crd.projectcalico.org -o json 2>/dev/null | python3 -c '
import json,sys
pfx = sys.argv[1]
try: d = json.load(sys.stdin)
except Exception: print("?"); sys.exit(0)
n = 0
for b in d.get("items", []):
    if not str(b.get("spec", {}).get("cidr", "")).startswith(pfx): continue
    n += sum(1 for a in b.get("spec", {}).get("allocations", []) if a is not None)
print(n)' "$IPAM_TINY_PREFIX" 2>/dev/null || printf '?'
    }
    fill_ips()  { $K -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.podIP}{"\n"}{end}' 2>/dev/null | grep '^fill-' || true; }
    n_filled()  { fill_ips | grep -cF "=$IPAM_TINY_PREFIX" || true; }
    n_noip()    { fill_ips | grep -c '=$' || true; }

    # disable every pool currently in use, remembering which, so the undo is exact
    PREEXISTING_DISABLED=0
    for p in $($K get ippools.crd.projectcalico.org -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        [[ -z "$p" ]] && continue
        if [[ "$($K get ippools.crd.projectcalico.org "$p" -o jsonpath='{.spec.disabled}' 2>/dev/null)" == true ]]; then
            PREEXISTING_DISABLED=$((PREEXISTING_DISABLED+1)); continue
        fi
        IPAM_DISABLED_POOLS="$IPAM_DISABLED_POOLS $p"
    done
    # match the incumbent's encapsulation: a pool with the wrong one is a different fault.
    vxmode="$($K get ippools.crd.projectcalico.org -o jsonpath='{.items[0].spec.vxlanMode}' 2>/dev/null)"
    [[ -z "$vxmode" ]] && vxmode=Never
    $K apply -f - >/dev/null 2>&1 <<EOF
apiVersion: crd.projectcalico.org/v1
kind: IPPool
metadata:
  name: $IPAM_TINY_POOL
spec:
  cidr: $IPAM_TINY_CIDR
  blockSize: 29
  ipipMode: Never
  vxlanMode: $vxmode
  natOutgoing: true
  disabled: false
  nodeSelector: all()
EOF
    for p in $IPAM_DISABLED_POOLS; do
        $K patch ippools.crd.projectcalico.org "$p" --type=merge -p '{"spec":{"disabled":true}}' >/dev/null 2>&1
    done

    # FILL IT. Twelve pods against eight addresses: the surplus is what gets refused, and
    # asking for more than the pool can hold is the whole point.
    for i in $(seq 1 12); do
        $K -n "$NS" run "fill-$i" --image=busybox:1.36 --restart=Never -- sleep 3600 >/dev/null 2>&1
    done
    t0=$SECONDS; prev=-1; stable=0
    while (( SECONDS - t0 < 180 )); do
        cur="$(n_filled)"
        if [[ "$cur" == "$prev" ]]; then stable=$((stable+1)); (( stable >= 3 )) && break
        else stable=0; fi
        prev="$cur"; sleep 10
    done
    filled="$(n_filled)"; denied="$(n_noip)"
    say "ROW=ipam-exhausted FILL filled=$filled denied=$denied after=$((SECONDS - t0))s"

    if (( filled == 0 )); then
        # The assumption failed, and it says so instead of grading. Either `disabled` does not
        # stop allocation from an already-affine block (in which case the fillers are sitting
        # on 10.1.x.x and the pool never ran dry), or no pod could start at all.
        say "ROW=ipam-exhausted INJECTOR-FAILED no pod took an address from $IPAM_TINY_POOL — the allocator was never run dry. Observed: $(fill_ips | tr '\n' ' ')"
        say "ROW=ipam-exhausted-incumbent SKIPPED reason=the-injector-did-not-land"
    elif (( denied == 0 )); then
        say "ROW=ipam-exhausted INJECTOR-FAILED all 12 pods got addresses from an eight-address pool — nothing was ever refused, so there is no exhaustion to grade"
        say "ROW=ipam-exhausted-incumbent SKIPPED reason=the-injector-did-not-land"
    else
        mid="$(snapshot)"
        # WHAT THE REFUSAL SAID. HALTED requires a NAMED error state; a pod sitting silently
        # in Pending with no reason recorded is a worse answer than the same pod with
        # "failed to assign an IP address" against it, and the ladder distinguishes them.
        #
        # ⚠️ THE TEST FOR "NAMED" IS A VALUE *THIS SCRIPT* CHOSE, NOT A PHRASE CALICO MIGHT
        # USE. The first draft classified the message by grepping for `assign an IP`,
        # `no IP addresses available` and `IPAM` — three strings invented at the desk. The
        # real message says:
        #
        #   plugin type="calico" failed (add): failed to request IPv4 addresses:
        #   Assigned 0 out of 1 requested IPv4 addresses; No IPs available in pools:
        #   [10.99.9.0/29]
        #
        # …which is about as honest a refusal as a CNI can produce, and ALL THREE guesses
        # missed it ("Assigned", not "assign an IP"; "No IPs", not "no IP addresses"; no
        # "IPAM" anywhere). The row would have been failed for dishonesty by an assertion
        # that was itself asserting a mechanism it had made up. Measured 2026-08-08.
        #
        # So the question asked is the one that actually matters to an operator and cannot
        # drift with upstream's wording: DID IT NAME THE POOL THAT RAN OUT? The CIDR is ours,
        # so matching it is not a guess about anyone else's strings.
        reason=none; denial_text=""
        stuck="$(fill_ips | grep '=$' | head -1 | cut -d= -f1)"
        if [[ -n "$stuck" ]]; then
            ev="$($K -n "$NS" describe pod "$stuck" 2>/dev/null | tr '\n' ' ')"
            # `describe` was flattened with tr, so the next event's table columns follow the
            # message on the same line; they are cut at the column gap (3+ spaces) so the
            # record shows the message and not the layout around it.
            denial_text="$(printf '%s' "$ev" | grep -o 'Failed to create pod sandbox.*' | head -1 | sed 's/   \+.*$//' | cut -c1-400)"
            case "$denial_text" in
                *"$IPAM_TINY_CIDR"*) reason=named-the-exhausted-pool ;;
                *IPv4*|*"IP address"*|*IPs*) reason=named-an-address-failure-but-not-which-pool ;;
                "") reason=silent ;;
                *) reason=sandbox-failed-without-naming-addresses ;;
            esac
        fi
        # The verbatim text, on its own line, because a classification is a lossy summary of
        # it and the reader should be able to see what the CNI actually said.
        say "ROW=ipam-exhausted DENIAL-TEXT ${denial_text:-<no event recorded against $stuck>}"
        # A REFUSED POD MUST NOT CLAIM TO BE RUNNING. That combination is the LIED rung: the
        # record and reality disagree, and on a real cluster it is a workload the scheduler
        # believes is serving traffic and which has no address to serve it on.
        lied=no
        for p in $(fill_ips | grep '=$' | cut -d= -f1); do
            [[ "$($K -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)" == Running ]] && lied=yes
        done
        say "ROW=ipam-exhausted DENIAL stuck=${stuck:-none} reason=$reason lied=$lied"

        # THE INCUMBENT'S OWN ROW: the fault landed, and the question is whether the pods
        # that already had addresses noticed. Graded by the generic dataplane rule.
        say "ROW=ipam-exhausted-incumbent MID[$mid] AFTER[$(snapshot)] RECOVERED=n/a SECS=0 LANDED=filled-${filled}-denied-${denied}"

        # RECOVERY, and the arithmetic control inside it. Free exactly ONE address by
        # deleting one filler GRACEFULLY (so the CNI's DEL actually runs), and exactly one of
        # the refused pods should then start. If none does, the refusal was not arithmetic and
        # the row is STRANDED; if the count jumps by more than one, something else changed
        # underneath and the measurement is not clean.
        victim="$(fill_ips | grep '=10\.99\.9\.' | head -1 | cut -d= -f1)"
        before_free="$filled"
        $K -n "$NS" delete pod "$victim" --grace-period=1 >/dev/null 2>&1
        t0=$SECONDS; recovered=no
        while (( SECONDS - t0 < IPAM_RECOVER_WAIT )); do
            (( $(n_filled) >= before_free )) && { recovered=yes; break; }
            sleep 5
        done
        say "ROW=ipam-exhausted MID[$mid] AFTER[$(snapshot)] RECOVERED=$recovered SECS=$((SECONDS - t0)) LANDED=filled-${filled}-denied-${denied} REASON=$reason LIED=$lied REFILLED=$(n_filled)/$before_free"

        # ── THE LEAK CHECK: does the allocation outlive the pod? ────────────────────────
        # This repo's bug class #1, asked of the allocator. Calico's IPAM records live in
        # `ipamblocks`, and an address whose pod is gone but whose allocation is not is a
        # record that outlived its subject — invisible until the pool runs dry for real, at
        # which point it presents as capacity that exists on paper and not in fact.
        for p in $(fill_ips | cut -d= -f1); do
            $K -n "$NS" delete pod "$p" --grace-period=1 >/dev/null 2>&1
        done
        t0=$SECONDS
        while (( SECONDS - t0 < 120 )); do
            [[ -z "$(fill_ips)" ]] && break
            sleep 5
        done
        # WAIT FOR THE RELEASE; DO NOT SAMPLE ONCE. Measured 2026-08-08: sampling ten seconds
        # after the last pod left the API reported `allocations_left=1` — and the block was
        # completely free minutes later. The address was never leaked; the CHECK was early.
        #
        # That direction of error matters as much as the other. A leak detector that cries
        # leak on a healthy cluster fails CI for a defect that is not there, and the fix a
        # reader reaches for first is to stop believing the detector. The IPAM release is
        # asynchronous to the pod's removal from the API, so the honest measurement is
        # "how long until it came back", with a generous deadline, and a leak declared only
        # if it never does.
        # ── RECLAMATION HAS TWO SPEEDS, AND ONLY ONE OF THEM IS TESTABLE ────────────────
        #
        # Three runs, one shape every time: of seven addresses, SIX are back the moment the
        # last pod leaves the API, and exactly ONE lingers and is reclaimed by something much
        # slower. That tail has now outrun three separate deadlines:
        #
        #   10 s  (sample once)  → reported a leak; free when looked at ~4 min later
        #   180 s                → reported a leak; free ~80 s after the script gave up
        #   600 s                → reported a leak; free by the next manual check
        #
        # Each time the harness rendered "I stopped watching" as "it never happened" — UNKNOWN
        # printed as a verdict, and each time it would have failed a healthy cluster. Picking a
        # bigger number is the same mistake with more patience, so the QUESTION changed instead.
        #
        # "Did it leak?" means "is it NEVER reclaimed", and no test can establish never. What
        # IS answerable, and is asserted by the grader:
        #
        #   - the prompt path must work: most addresses come back at delete time. If NONE do
        #     (`first` == `filled`), the allocator is not returning addresses at all, and that
        #     is a real defect with a real failure mode.
        #   - the tail is OBSERVED and REPORTED, never failed on. `first` distinguishes one
        #     lingering allocation from seven released while nobody was looking — without it,
        #     the two are the same number at the end.
        #
        # So the window below is for taking a reading, not for passing judgement.
        t0=$SECONDS; leak_first="$(tiny_allocated)"; leak="$leak_first"
        while (( SECONDS - t0 < IPAM_LEAK_WAIT )); do
            leak="$(tiny_allocated)"
            [[ "$leak" == 0 ]] && break
            sleep 10
        done
        say "ROW=ipam-exhausted LEAK of_filled=$filled first=$leak_first allocations_left=$leak released_after=$((SECONDS - t0))s pods_left=$(fill_ips | wc -l)"
    fi

    # RESTORE, and PROVE it. Leaving the cluster's pools disabled would poison every later
    # run with a fault nobody injected — and it would look like Calico had broken itself.
    #
    # The filler pods are swept here rather than only on the success path: the two
    # INJECTOR-FAILED branches above exit without deleting them, and litter left by a run
    # that already went wrong is the litter most likely to confuse the next one.
    for p in $(fill_ips | cut -d= -f1); do
        $K -n "$NS" delete pod "$p" --grace-period=1 >/dev/null 2>&1
    done
    restore_ipam
    sleep 5
    # COMPARED AGAINST WHAT WAS DISABLED BEFORE, not against zero: a cluster that already had
    # a pool switched off for its own reasons is not this row's litter, and failing the run
    # for it would be the harness blaming Calico for a state it found.
    still_off=0
    for p in $($K get ippools.crd.projectcalico.org -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        [[ "$($K get ippools.crd.projectcalico.org "$p" -o jsonpath='{.spec.disabled}' 2>/dev/null)" == true ]] && still_off=$((still_off+1))
    done
    still_off=$(( still_off - PREEXISTING_DISABLED ))
    say "ROW=ipam-exhausted RESTORED disabled_pools_remaining=$still_off tiny_pool_present=$($K get ippools.crd.projectcalico.org "$IPAM_TINY_POOL" >/dev/null 2>&1 && echo yes || echo no)"
fi

# ── 7. the DATASTORE beneath Calico, stopped ───────────────────────────────
# The layer §4 of the grader has been naming as "not covered" since the matrix was written:
# k8s-dqlite, which is a layer BELOW the CNI and which breaks the API this harness talks to.
#
# THE QUESTION IS THE ONE OPERATORS ASSUME AND RARELY VERIFY: when the control plane is
# gone, do the pods that are already running keep forwarding? A CNI whose dataplane needs a
# reachable datastore to move a packet has coupled two things that must not be coupled, and
# the blast radius of a datastore outage becomes every workload rather than every API call.
#
# It is graded on `o_pods_noapi` — see the long note at its definition. The target address is
# captured HERE, while the API still works, because after the fault there is nothing to ask.
ensure_workload
NOAPI_TARGET="$($K get pod -n "$NS" pod-b -o jsonpath='{.status.podIP}' 2>/dev/null)"
if [[ -z "$NOAPI_TARGET" ]]; then
    say "ROW=datastore-stopped SKIPPED reason=could-not-capture-pod-b-address-before-the-fault"
elif ! systemctl list-unit-files 'snap.microk8s.daemon-k8s-dqlite.service' >/dev/null 2>&1 \
     || ! systemctl cat snap.microk8s.daemon-k8s-dqlite.service >/dev/null 2>&1; then
    # DERIVED, not assumed. A microk8s built on a different datastore (etcd, or dqlite folded
    # into kubelite) has no such unit, and stopping nothing would grade this row ABSORBED
    # while injecting nothing at all.
    say "ROW=datastore-stopped SKIPPED reason=no-k8s-dqlite-unit-on-this-cluster-so-there-is-no-separate-datastore-to-stop"
else
    say "ROW=datastore-stopped BEFORE[$(snapshot)] noapi_target=$NOAPI_TARGET"
    before_noapi="$(o_pods_noapi)"
    systemctl stop snap.microk8s.daemon-k8s-dqlite.service 2>/dev/null
    sleep 10
    # ASSERT THE FAULT LANDED — and assert it on the API, not on the unit's own status. A
    # stopped unit whose API still answers means something else is serving it, and this row
    # would then be grading a control plane that never went away.
    api_down=no
    $K get --raw /readyz >/dev/null 2>&1 || api_down=yes
    if [[ "$api_down" == no ]]; then
        systemctl start snap.microk8s.daemon-k8s-dqlite.service 2>/dev/null
        say "ROW=datastore-stopped INJECTOR-FAILED the API still answers /readyz with k8s-dqlite stopped — the datastore was never actually removed from the path"
    else
        mid_noapi="$(o_pods_noapi)"
        say "ROW=datastore-stopped API-DOWN mid_noapi=$mid_noapi"
        # RECOVERY, then grade. HALTED means "a verb the system offers brings it back".
        systemctl start snap.microk8s.daemon-k8s-dqlite.service 2>/dev/null
        t0=$SECONDS; api_back=no
        while (( SECONDS - t0 < RECOVER_WAIT )); do
            $K get --raw /readyz >/dev/null 2>&1 && { api_back=yes; break; }
            sleep 5
        done
        after_noapi="$(o_pods_noapi)"
        say "ROW=datastore-stopped MID[pods_noapi=$mid_noapi] AFTER[$(snapshot)] RECOVERED=$api_back SECS=$((SECONDS - t0)) LANDED=api-readyz-refused BEFORE_NOAPI=$before_noapi MID_NOAPI=$mid_noapi AFTER_NOAPI=$after_noapi"
    fi
fi

say "END"
