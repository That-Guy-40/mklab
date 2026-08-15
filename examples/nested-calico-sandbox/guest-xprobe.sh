#!/usr/bin/env bash
# guest-xprobe.sh <ns> <src-pod> <dst-ip> — every CROSS-NODE observable, on ONE line, in ONE
# round trip. Runs as root on the LEADER.
#
# ── WHY IT IS A SCRIPT AND NOT SIX ssh CALLS ────────────────────────────────────────────
#
# The driver lives on the host and reaches each guest over its own slirp NIC, so a snapshot
# assembled from one observable per ssh costs six connections — and, worse, six DIFFERENT
# INSTANTS. A row's MID snapshot is taken while a fault is landing; spreading it over ten
# seconds means the fields describe a system that never existed in that combination. One
# invocation, one instant.
#
# ── THE FIELDS, AND WHICH ONE IS THE OUTCOME ────────────────────────────────────────────
#
#   xpods    src-pod (on node 1) -> dst pod IP (on node 2), ICMP     ← THE OUTCOME
#   path     the device this node's kernel routes the peer's pod through
#   tunnel   vxlan.calico's local endpoint here
#   nodeips  every node's projectcalico.org/IPv4Address — what F.6 corrupted
#   ready    every node's Ready condition — what the CLUSTER claims while that happens
#
# `xpods` is the one that matters and the only one a single node could not ask: with no peer
# the tunnel carries nothing, so on the one-node matrix this measurement does not exist.
#
# `ready` is here for one reason, and it is the whole point of a witness. The F.6 incident was
# not "a node broke" — it was an outage that looked like a healthy cluster. A matrix that
# records only the dataplane can say the traffic stopped; it cannot say that nothing in the
# cluster admitted it. Recording both is what makes the LIED rung measurable rather than
# rhetorical.
set -uo pipefail

NS="${1:?usage: guest-xprobe.sh <ns> <src-pod> <dst-ip>}"
SRC="${2:?}"
DST="${3:-}"
K="/snap/bin/microk8s kubectl"

# `timeout` on the exec: when the datastore or the kubelet path is unwell, `kubectl exec` can
# block far longer than the ping it carries. A probe that hangs turns a measured outage into a
# harness that stopped reporting, and those look identical in a log that simply stops.
xpods() {
    [[ -z "$DST" ]] && { printf 'no-target'; return; }
    if timeout 25 $K exec -n "$NS" "$SRC" -- ping -c 2 -W 1 "$DST" >/dev/null 2>&1
    then printf 'OK'; else printf 'FAIL'; fi
}

# The NODE's route to the peer's pod. Not the pod's own first hop — that is its veth, and the
# same for every destination — but the decision that follows it, which is the one the overlay
# owns. Named as a proxy rather than presented as the packet's path.
path() {
    local d
    d="$(ip route get "$DST" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
    printf '%s' "${d:-none}"
}

tunnel() {
    ip -d link show vxlan.calico 2>/dev/null \
        | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' | tr ' ' '_' || printf 'absent'
}

# Both node-scoped fields are emitted for EVERY node, keyed by name, rather than as `n1ip=` /
# `n2ip=` — a fixed pair of keys silently describes the wrong nodes the moment a third joins,
# and this lab has already been caught once by a record that outlived its subject.
nodeips() {
    $K get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.annotations.projectcalico\.org/IPv4Address}{","}{end}' 2>/dev/null \
        | sed 's/,$//' || printf '?'
}
ready() {
    $K get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{.status.conditions[?(@.type=="Ready")].status}{","}{end}' 2>/dev/null \
        | sed 's/,$//' || printf '?'
}

# ── THE SECOND RECORD OF THE SAME ADDRESS, AND IT IS THE ONE PEOPLE READ ────────────────
#
# A node's address is written down TWICE: Calico's `projectcalico.org/IPv4Address` annotation
# (above) and the node's `InternalIP` in its status, which kubelet publishes from its
# `--node-ip` flag. They are maintained by different components on different schedules, so
# they can disagree — and measured here on 2026-08-15 they did: after node 2's address was
# moved, Calico's annotation followed within ~50 s while the InternalIP kept naming the
# address that had ceased to exist, indefinitely.
#
# The stale one is the one `kubectl get nodes -o wide` prints. It is collected for exactly
# that reason: bug class #1 is a record that outlives its subject, and this is a case where
# the cluster keeps two and the more visible one is the one that does not track.
internalips() {
    $K get nodes -o jsonpath='{range .items[*]}{.metadata.name}:{.status.addresses[?(@.type=="InternalIP")].address}{","}{end}' 2>/dev/null \
        | sed 's/,$//' || printf '?'
}

printf 'xpods=%s path=%s tunnel=%s nodeips=%s internalips=%s ready=%s\n' \
    "$(xpods)" "$(path)" "$(tunnel)" "$(nodeips)" "$(internalips)" "$(ready)"
