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
NS=cnichaos

say() { printf 'CNI-%s\n' "$*"; }

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

for p in pod-a pod-b; do
    $K -n "$NS" get pod "$p" >/dev/null 2>&1 && continue
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

say "END"
