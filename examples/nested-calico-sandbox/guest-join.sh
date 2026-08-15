#!/usr/bin/env bash
# guest-join.sh — the two halves of turning two microk8s into one two-node cluster.
# Runs as root inside a guest. Every step prints a JOIN-* marker, because a step that
# silently half-worked is the one that shows up three layers later wearing someone else's
# clothes.
#
#   guest-join.sh leader  <my-ip> <wire-cidr> <token>
#   guest-join.sh worker  <my-ip> <leader-ip> <token>
set -uo pipefail
say() { printf 'JOIN-%s\n' "$*"; }
MK=/snap/bin/microk8s
K="$MK kubectl"

# ── WHY --node-ip IS NOT OPTIONAL HERE ──────────────────────────────────────────────────
# Every slirp guest is 10.0.2.15. Both of these nodes therefore believe they live at the
# same address, and a two-node cluster whose nodes advertise one IP is not a cluster — it is
# two machines each convinced it is the other. kubelet is told the wire address explicitly.
set_node_ip() {
    local ip="$1" f=/var/snap/microk8s/current/args/kubelet
    [[ -f "$f" ]] || { say "FATAL no kubelet args at $f"; exit 2; }
    sed -i '/--node-ip=/d' "$f"
    printf -- '--node-ip=%s\n' "$ip" >> "$f"
    say "NODE-IP $ip"

    # ── THE SERVING CERT IS A RECORD OF THE ADDRESS THE NODE USED TO HAVE ───────────────
    # microk8s issues each node's kubelet serving certificate with a SAN list built at
    # install time — here, `IP: 10.0.2.15` — and moving --node-ip does not reissue it. The
    # certificate stays perfectly valid and simply stops describing its subject: this repo's
    # bug class #1, in x509.
    #
    # Nothing fails at join, or at `get nodes`, or at any readiness check. It fails at the
    # first `kubectl exec`, with `certificate is valid for 10.0.2.15, not 10.77.0.11` —
    # which is to say it fails in the CHAOS HARNESS, whose entire dataplane observable is
    # `kubectl exec … ping`. A two-node matrix would have graded every row STRANDED and
    # blamed the CNI. Measured 2026-08-08.
    local tpl=/var/snap/microk8s/current/certs/csr.conf.template
    if [[ -f "$tpl" ]] && ! grep -q "IP.90 = $ip" "$tpl"; then
        sed -i "s|^#MOREIPS|IP.90 = $ip\n#MOREIPS|" "$tpl"
        grep -q "IP.90 = $ip" "$tpl" \
            || { say "FATAL could not add $ip to the cert SAN template (no #MOREIPS marker?)"; exit 2; }
        $MK refresh-certs --cert server.crt >/tmp/certs.log 2>&1 \
            || $MK refresh-certs -e server.crt >>/tmp/certs.log 2>&1 \
            || { say "FATAL refresh-certs failed: $(tail -2 /tmp/certs.log)"; exit 2; }
        say "APISERVER-CERT-REISSUED san+=$ip"
    fi

    # ── AND THE KUBELET'S SERVING CERT IS A DIFFERENT CERTIFICATE ───────────────────────
    # `refresh-certs --cert server.crt` reissues the API SERVER's cert. `kubelet.crt` has its
    # own SAN list, built at install time from the hostname and the address the node had then,
    # and nothing above touches it. The first attempt stopped here and printed a confident
    # CERT-REISSUED — a marker for a command that exited 0, not for a SAN that changed. The
    # `kubectl exec` still failed with the identical message, which is what sent anyone
    # reading it back to look at the apiserver cert that was already correct.
    #
    # Reissued explicitly against the cluster's own CA, keeping the ORIGINAL slirp address in
    # the list: 10.0.2.15 is still how the node reaches itself, and dropping it would trade
    # this failure for a different one.
    local certs=/var/snap/microk8s/current/certs
    if ! openssl x509 -in "$certs/kubelet.crt" -noout -text 2>/dev/null | grep -q "IP Address:$ip"; then
        local ext="/tmp/kubelet-san.cnf"
        printf '[v3]\nsubjectAltName=DNS:%s,IP:%s,IP:127.0.0.1,IP:10.0.2.15\nextendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n' \
            "$(hostname)" "$ip" > "$ext"
        openssl req -new -key "$certs/kubelet.key" -out /tmp/kubelet.csr \
            -subj "/CN=system:node:$(hostname)/O=system:nodes" >/dev/null 2>&1 \
            && openssl x509 -req -in /tmp/kubelet.csr -CA "$certs/ca.crt" -CAkey "$certs/ca.key" \
                 -CAcreateserial -out "$certs/kubelet.crt" -days 3650 \
                 -extfile "$ext" -extensions v3 >/dev/null 2>&1 \
            || { say "FATAL could not reissue kubelet.crt"; exit 2; }
        # ASSERT THE OUTCOME. The SAN is read back out of the certificate on disk, because
        # "openssl exited 0" is exactly the evidence that was already believed once here.
        openssl x509 -in "$certs/kubelet.crt" -noout -text 2>/dev/null | grep -q "IP Address:$ip" \
            || { say "FATAL kubelet.crt was rewritten and STILL does not carry $ip"; exit 2; }
        snap restart microk8s >/dev/null 2>&1 || true
        $MK status --wait-ready --timeout 300 >/dev/null 2>&1 || true
        say "KUBELET-CERT-REISSUED san+=$ip (verified in the certificate, not in an exit status)"
    fi
    snap restart microk8s >/dev/null 2>&1 || systemctl restart snap.microk8s.daemon-kubelite >/dev/null 2>&1
    $MK status --wait-ready --timeout 300 >/dev/null 2>&1 \
        || { say "FATAL cluster did not come back after setting --node-ip=$ip"; exit 2; }
    say "READY-AFTER-NODE-IP $ip"
}

case "${1:?usage: guest-join.sh leader|worker ...}" in
leader)
    MYIP="${2:?}"; CIDR="${3:?}"; TOKEN="${4:?}"

    # ── THE API SERVER MUST ADVERTISE THE WIRE TOO, AND THIS ONE COST A JOIN ────────────
    # Measured 2026-08-08. Setting --node-ip alone produces a join that REPORTS SUCCESS and
    # a worker that never registers. The worker's kubelet talks to microk8s's apiserver-proxy
    # on 127.0.0.1:16443, and the proxy forwards to whatever address the leader advertised —
    # which was 10.0.2.15, the leader's slirp address.
    #
    # On the worker, 10.0.2.15 IS THE WORKER. Every slirp guest has it. So the proxy dialled
    # itself, and kubelet logged `Unable to register node … EOF` in a loop while `microk8s
    # join` had already printed "Successfully joined the cluster." A false success on top of
    # an address that means something different on each machine.
    #
    # It is set BEFORE the token is minted, because the token carries the endpoint.
    api=/var/snap/microk8s/current/args/kube-apiserver
    if [[ -f "$api" ]]; then
        sed -i '/--advertise-address=/d' "$api"
        printf -- '--advertise-address=%s\n' "$MYIP" >> "$api"
        say "ADVERTISE-ADDRESS $MYIP"
    else
        say "FATAL no kube-apiserver args at $api"; exit 2
    fi
    set_node_ip "$MYIP"

    # ── TELL CALICO WHICH INTERFACE, AND SAY WHY THAT IS A DIFFERENT SUBJECT ────────────
    # The one-node sandbox exists to measure `first-found`, so it must never be told. These
    # nodes are told, because first-found would pick the slirp NIC whose address both guests
    # share. Recorded as a deliberate divergence, not smuggled in: the two-node findings are
    # about cross-node behaviour, never about autodetection.
    #
    # ⚠️ `cidr=` DOES NOT ORDER ITS CANDIDATES THE WAY `first-found` DOES, and the cross-node
    # chaos row was designed twice because of it. Measured 2026-08-15 on this pair: with a
    # /16 handed in and a dummy interface holding 10.77.99.1 — a higher ifindex, a matching
    # address, the same shape of decoy `first-found` took in 20 s in the one-node lab —
    # Calico kept the wire address for 205 s, and kept it through a full calico-node restart
    # as well. Extrapolating one method's ordering to the other would have produced a row
    # whose injector never lands.
    $K set env daemonset/calico-node -n kube-system "IP_AUTODETECTION_METHOD=cidr=$CIDR" >/dev/null 2>&1 \
        || { say "FATAL could not set IP_AUTODETECTION_METHOD"; exit 2; }
    say "CALICO-AUTODETECT cidr=$CIDR"
    # ASSERT IT TOOK. `set env` returning is the DaemonSet being patched, not the pod having
    # rolled and re-detected. A node still advertising 10.0.2.15 here would join a cluster
    # that then cannot route between its own nodes, and the symptom would appear as a CNI
    # fault rather than as this step.
    t0=$SECONDS; got=""
    while (( SECONDS - t0 < 300 )); do
        got="$($K get node -o jsonpath='{.items[0].metadata.annotations.projectcalico\.org/IPv4Address}' 2>/dev/null)"
        [[ "$got" == "$MYIP"* ]] && break
        sleep 5
    done
    [[ "$got" == "$MYIP"* ]] \
        || { say "FATAL calico still advertises '${got:-<none>}' and not $MYIP after $((SECONDS - t0))s — the fix did not take, and every cross-node row below would measure a cluster that cannot route to itself"; exit 2; }
    say "CALICO-ADVERTISES $got after=$((SECONDS - t0))s"

    $MK add-node --token "$TOKEN" --token-ttl 3600 >/tmp/addnode.log 2>&1 \
        || { say "FATAL add-node failed: $(tail -2 /tmp/addnode.log)"; exit 2; }
    say "TOKEN-MINTED"
    ;;

worker)
    MYIP="${2:?}"; LEADER="${3:?}"; TOKEN="${4:?}"
    set_node_ip "$MYIP"
    # `--worker` on purpose: microk8s HA wants three nodes to form a datastore quorum, and a
    # two-node control plane is a quorum question this lab is not asking. A worker still runs
    # its own kubelet and its own calico-node with its own tunnel endpoint, which is the
    # entire subject.
    $MK join "$LEADER:25000/$TOKEN" --worker >/tmp/join.log 2>&1 \
        || { say "FATAL join failed: $(tail -3 /tmp/join.log)"; exit 2; }
    say "JOINED $LEADER"

    # ── `Successfully joined the cluster` IS NOT JOINING THE CLUSTER ────────────────────
    # It printed exactly that while kubelet looped on `Unable to register node … EOF`. So the
    # endpoint the join actually installed is READ BACK and checked against the wire, rather
    # than trusted because the tool said so. If the leader was prepared correctly this is a
    # no-op; it exists because the failure it catches is silent and looks like a CNI problem
    # two layers away.
    prov=/var/snap/microk8s/current/args/traefik/provider.yaml
    ep="$(grep -oE 'address: [0-9.]+:[0-9]+' "$prov" 2>/dev/null | head -1 | awk '{print $2}')"
    say "APISERVER-ENDPOINT ${ep:-<none>}"
    if [[ "$ep" != "$LEADER":* ]]; then
        # NAMED AND REPAIRED, never repaired quietly. A silent fix here would hide the fact
        # that the leader is still advertising an address that means a different machine on
        # every guest — which would come back the next time anyone joins a third node.
        say "ENDPOINT-WRONG got=${ep:-<none>} want=$LEADER:16443 — the leader advertised an address that resolves to THIS machine on every slirp guest; rewriting the proxy's endpoint"
        sed -i "s|address: [0-9.]*:16443|address: $LEADER:16443|" "$prov"
        snap restart microk8s.daemon-apiserver-proxy >/dev/null 2>&1 \
            || systemctl restart snap.microk8s.daemon-apiserver-proxy >/dev/null 2>&1
        say "ENDPOINT-REPAIRED $(grep -oE 'address: [0-9.]+:[0-9]+' "$prov" | head -1 | awk '{print $2}')"
    fi
    ;;
*)  say "FATAL unknown role '$1'"; exit 2 ;;
esac
