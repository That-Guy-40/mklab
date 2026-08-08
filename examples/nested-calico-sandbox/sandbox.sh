#!/usr/bin/env bash
# sandbox.sh — bring up a Calico we are allowed to break, run the experiment, tear it down.
#
#   sandbox.sh up          create + resize + boot, and wait for the cluster
#   sandbox.sh up2         the TWO-NODE pair, joined by a private QEMU socket wire
#   sandbox.sh join2       make those two one cluster (leader + worker)
#   sandbox.sh down2       destroy the two-node pair
#   sandbox.sh experiment  copy guest-experiment.sh in and run it, printing NCS-* lines
#   sandbox.sh cni-chaos   inject a fault at each CNI layer and print the CNI-* record
#   sandbox.sh status      where the guest's tunnel is right now
#   sandbox.sh down        destroy the VM
#
# ⚠️ THIS SCRIPT MUST NEVER TOUCH THE HOST'S NETWORKING. The guest is `network_mode = user`
# (slirp): no tap, no bridge, no fabric on this side. The host runs a LIVE microk8s whose
# tunnel has moved three times in six days on its own; the entire value of this lab is that
# it asks its questions somewhere that is safe to wreck. `status` prints the host's binding
# too, purely so a reader can SEE it did not move.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"
LAB_VM="$REPO/phase2-qemu-vm/lab-vm.sh"
SPEC="$HERE/nested-calico-sandbox.toml"
VM=calico-sandbox
DISK_SIZE="${NCS_DISK_SIZE:-16G}"
READY_TIMEOUT="${NCS_READY_TIMEOUT:-900}"

# ── the two-node sandbox: a SEPARATE pair of VMs, deliberately ──────────────────────────
# The one-node `calico-sandbox` is left untouched by everything below. `findings.env` is
# stamped to what that VM measured, and adding a second NIC to it would change the very thing
# it measures — the set of interfaces Calico's first-found autodetection chooses between.
SPEC2="$HERE/nested-calico-two-node.toml"
N1=calico-n1
N2=calico-n2
N1_MAC=52:54:00:ca:11:01
N2_MAC=52:54:00:ca:11:02
N1_IP=10.77.0.11
N2_IP=10.77.0.12
WIRE_CIDR=10.77.0.0/24

info() { printf '[info] %s\n' "$*" >&2; }
die()  { printf '[error] %s\n' "$*" >&2; exit 1; }

# These take a VM NAME and default to the one-node sandbox, so the two-node verbs can reuse
# them without a second copy that drifts.
vm_state_dir() { printf '%s/.local/state/lab-create/vms/%s\n' "$HOME" "${1:-$VM}"; }
serial_sock()  { printf '%s/serial.sock\n' "$(vm_state_dir "${1:-$VM}")"; }
console()      { printf '%s/ncs-console.log\n' "$(vm_state_dir "${1:-$VM}")"; }

# THE CONSOLE IS A UNIX SOCKET, NOT A FILE. lab-vm.sh exposes it as
# `-chardev socket,...,server=on` so `lab-vm.sh console` can attach; nothing writes a log.
# The first draft of this script waited for a `console.log` that is never created — it would
# have sat out its full 900 s timeout and reported a cluster failure that had not happened.
# So we capture it ourselves.
#
# ⚠️ ONE CLIENT AT A TIME on that socket: a second reader silently steals the bytes. While
# this capture runs, `lab-vm.sh console <vm>` will see nothing — read the log instead.
CAPTURE_PIDS=()
start_capture() {  # start_capture [vm]
    local vm="${1:-$VM}"
    command -v socat >/dev/null 2>&1 || die "socat is required to capture the guest console (the console is a unix socket, not a file)"
    : > "$(console "$vm")"
    socat -u "UNIX-CONNECT:$(serial_sock "$vm")" "OPEN:$(console "$vm"),append" >/dev/null 2>&1 &
    CAPTURE_PIDS+=($!)
}
stop_capture() {
    # BY PID. Never `pkill -f serial.sock`: QEMU's own command line carries that exact path,
    # and in this repo that pattern has killed a live VM and the agent's shell (exit 144).
    # An array because the two-node verbs capture two consoles; the rule is the same and the
    # temptation to reach for a pattern is stronger with more than one.
    local p
    for p in ${CAPTURE_PIDS+"${CAPTURE_PIDS[@]}"}; do
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    CAPTURE_PIDS=()
}

# grow_overlay <vm> — the 3 GiB cached image is not enough for microk8s; see `up`.
grow_overlay() {
    local vm="$1" disk before after
    disk="$(vm_state_dir "$vm")/disk.qcow2"
    [[ -f "$disk" ]] || die "expected an overlay at $disk after create"
    before="$(qemu-img info --output=json "$disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')" \
        || die "could not read $vm's overlay virtual size"
    qemu-img resize "$disk" "$DISK_SIZE" >/dev/null || die "could not resize $vm's overlay to $DISK_SIZE"
    after="$(qemu-img info --output=json "$disk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])')" \
        || die "could not re-read $vm's overlay virtual size"
    (( after > before )) || die "$vm's overlay did not grow: still $((after / 1024 / 1024))M"
    info "$vm overlay virtual-size $(( before / 1024 / 1024 ))M -> $(( after / 1024 / 1024 ))M"
}

# await_marker <vm> <marker> <seconds> — wait on the guest's OWN console marker.
await_marker() {
    local vm="$1" marker="$2" limit="$3" c t0
    c="$(console "$vm")"; t0=$SECONDS
    while (( SECONDS - t0 < limit )); do
        [[ -f "$c" ]] && grep -q "$marker" "$c" 2>/dev/null && {
            info "$vm reached $marker after $((SECONDS - t0))s"; return 0; }
        sleep 10
    done
    die "$vm never printed $marker within ${limit}s; console: $c"
}

host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || echo '<absent>'; }

case "${1:-}" in
up)
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required to resize the overlay"
    [[ -x "$LAB_VM" ]] || die "phase-2 driver not executable: $LAB_VM"

    HOST_BEFORE="$(host_binding)"
    info "host Calico binding BEFORE (recorded so teardown can prove we did not move it):"
    info "  $HOST_BEFORE"

    bash "$LAB_VM" create --config "$SPEC" || die "create failed"

    # THE RESIZE, and why it is here rather than in the spec. The cached Debian cloud image
    # is 3 GiB virtual; microk8s wants ~10. `disk_size` in a spec only reaches the
    # from-chroot backend, so the overlay is grown directly — cloud-init's `growpart` (on by
    # default in every stock cloud image) extends the root partition into it on first boot.
    disk="$(vm_state_dir)/disk.qcow2"
    [[ -f "$disk" ]] || die "expected an overlay at $disk after create"

    # READ THE TOP-LEVEL virtual-size, and do it with a JSON parser.
    #
    # The first draft grepped `"virtual-size"` out of the JSON with sed and took `head -1`.
    # That is the WRONG match: qemu-img nests a `children[].info` block describing the
    # qcow2 FILE, whose virtual-size appears first. So the guard compared the file's size
    # rather than the disk's — and it PASSED, because writing new metadata makes the file
    # marginally bigger. It reported "grown 0M -> 0M" and carried on: a guard that cannot
    # detect the failure it exists for, which is the cheap check answering a different,
    # easier question. Caught 2026-08-07 by reading its own output instead of its exit code.
    vsize() { qemu-img info --output=json "$1" \
                | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])'; }

    before="$(vsize "$disk")" || die "could not read the overlay's virtual size"
    qemu-img resize "$disk" "$DISK_SIZE" >/dev/null || die "could not resize the overlay to $DISK_SIZE"
    after="$(vsize "$disk")" || die "could not re-read the overlay's virtual size"
    (( after > before )) \
        || die "the overlay did not grow: virtual-size is still $((after / 1024 / 1024))M.
cloud-init would then run out of space installing microk8s, and the failure would surface as
a snap error with nothing pointing back here."
    info "overlay virtual-size $(( before / 1024 / 1024 ))M -> $(( after / 1024 / 1024 ))M"

    bash "$LAB_VM" start "$VM" || die "start failed"
    start_capture
    trap stop_capture EXIT

    # Wait on the guest's OWN marker, not on a sleep. The console is the only channel that
    # works before the network does, so a guest that fails to install still tells us so.
    info "waiting up to ${READY_TIMEOUT}s for the cluster (first boot pulls ~200 MB of snap)"
    c="$(console)"; t0=$SECONDS
    while (( SECONDS - t0 < READY_TIMEOUT )); do
        if [[ -f "$c" ]] && grep -q 'NCS-READY-FOR-EXPERIMENT' "$c" 2>/dev/null; then
            # The character class needs LOWERCASE: without it `NCS-CALICO=docker.io/...`
            # printed as a bare `NCS-CALICO=` and read as an empty marker twice — the
            # display truncating a value that was there all along.
            grep -oE 'NCS-[A-Za-z0-9=./:_-]+' "$c" | sort -u | sed 's/^/  /' >&2
            grep -q 'NCS-K8S-READY' "$c" \
                || die "the guest booted but the cluster never became ready — see $c"
            info "cluster ready after $((SECONDS - t0))s"
            exit 0
        fi
        sleep 10
    done
    die "timed out after ${READY_TIMEOUT}s; console: $c" ;;

up2)
    # ── the two-node sandbox ────────────────────────────────────────────────────────────
    # Order is load-bearing: node1 LISTENS on the peer wire and node2 CONNECTS to it. A
    # connect against nothing does not fail loudly — QEMU retries quietly — so starting them
    # the other way round produces two guests, two NICs, and a segment that never carries a
    # frame, with nothing anywhere saying why.
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is required to resize the overlays"
    [[ -x "$LAB_VM" ]] || die "phase-2 driver not executable: $LAB_VM"

    HOST_BEFORE="$(host_binding)"
    info "host Calico binding BEFORE: $HOST_BEFORE"

    bash "$LAB_VM" create --config "$SPEC2" || die "create failed"
    grow_overlay "$N1"
    grow_overlay "$N2"

    info "starting $N1 (the LISTEN end of the wire) first"
    bash "$LAB_VM" start "$N1" || die "start $N1 failed"
    start_capture "$N1"
    trap stop_capture EXIT
    await_marker "$N1" 'NCS2-BOOT' 300

    info "starting $N2 (the CONNECT end)"
    bash "$LAB_VM" start "$N2" || die "start $N2 failed"
    start_capture "$N2"

    info "waiting for both guests to finish installing microk8s (~10 min each, in parallel)"
    await_marker "$N1" 'NCS2-NODE-READY' "$READY_TIMEOUT"
    await_marker "$N2" 'NCS2-NODE-READY' "$READY_TIMEOUT"
    for n in "$N1" "$N2"; do
        grep -q 'NCS2-K8S-READY' "$(console "$n")" \
            || die "$n installed microk8s but its cluster never became ready — see $(console "$n")"
    done

    # ── THE WIRE, BEFORE ANYTHING IS BUILT ON IT ────────────────────────────────────────
    # Proven by a round-trip ping between the two guests, not by carrier or by `ip link`
    # saying UP. A tap's carrier means the VMM holds the device open; it has meant "healthy"
    # through a total outage in this repo before.
    info "bringing up the private wire and proving a frame crosses it"
    bash "$LAB_VM" ssh "$N1" -- 'cat > /tmp/wire.sh' < "$HERE/guest-peer-wire.sh" || die "could not copy wire.sh to $N1"
    bash "$LAB_VM" ssh "$N2" -- 'cat > /tmp/wire.sh' < "$HERE/guest-peer-wire.sh" || die "could not copy wire.sh to $N2"
    # node1 first and WITHOUT its reachability gate mattering yet — node2 has no address at
    # this point, so a ping from node1 must not be read as the wire being broken.
    bash "$LAB_VM" ssh "$N1" -- "sudo bash /tmp/wire.sh $N1_MAC $N1_IP/24 $N2_IP" 2>&1 | sed 's/^/  n1: /' || true
    rc=0
    bash "$LAB_VM" ssh "$N2" -- "sudo bash /tmp/wire.sh $N2_MAC $N2_IP/24 $N1_IP" 2>&1 | sed 's/^/  n2: /' || rc=$?
    (( rc == 0 )) || die "the private wire did not carry a frame between the two guests. Nothing below is buildable: a two-node cluster over a segment that does not pass traffic would fail later, somewhere else, wearing someone else's clothes"
    info "NCS2-WIRE-UP $N1_IP <-> $N2_IP"

    printf '  NCS2-TWO-NODE-WIRE-READY\n' >&2
    info "next: 'sandbox.sh join2' to make these two a cluster"
    info "host Calico binding AFTER: $(host_binding)" ;;

join2)
    # Make the two guests one cluster. Separate from `up2` because it is the step most likely
    # to need re-running, and re-running it must not mean re-booting two VMs.
    TOKEN="${NCS2_TOKEN:-ncs2joiningtoken0123456789abcdef}"
    info "leader: pinning the node IP to the wire and pointing Calico at $WIRE_CIDR"
    bash "$LAB_VM" ssh "$N1" -- 'cat > /tmp/join.sh' < "$HERE/guest-join.sh" || die "copy to $N1 failed"
    bash "$LAB_VM" ssh "$N2" -- 'cat > /tmp/join.sh' < "$HERE/guest-join.sh" || die "copy to $N2 failed"
    rc=0
    bash "$LAB_VM" ssh "$N1" -- "sudo bash /tmp/join.sh leader $N1_IP $WIRE_CIDR $TOKEN" 2>&1 | sed 's/^/  n1: /' || rc=$?
    (( rc == 0 )) || die "the leader could not be prepared — see the JOIN-FATAL line above"
    info "worker: joining"
    rc=0
    bash "$LAB_VM" ssh "$N2" -- "sudo bash /tmp/join.sh worker $N2_IP $N1_IP $TOKEN" 2>&1 | sed 's/^/  n2: /' || rc=$?
    (( rc == 0 )) || die "the worker did not join — see the JOIN-FATAL line above"

    # ── THE CLUSTER IS TWO NODES ONLY WHEN BOTH ARE Ready AND HOLD DIFFERENT IPs ────────
    # `get nodes` showing two lines is not the property: two nodes advertising one address
    # is exactly the failure this whole node-ip dance exists to prevent, and it would print
    # two lines too.
    info "waiting for both nodes to be Ready with distinct addresses"
    t0=$SECONDS; ok=no
    while (( SECONDS - t0 < 420 )); do
        ips="$(bash "$LAB_VM" ssh "$N1" -- "sudo /snap/bin/microk8s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.addresses[?(@.type==\"InternalIP\")].address};{.status.conditions[?(@.type==\"Ready\")].status} '" 2>/dev/null || true)"
        # `;True`, not `=True`. The first draft counted `=True` while the field separator is
        # `;`, so the readiness count was ALWAYS 0 and this gate could never pass — on any
        # cluster, however healthy. It timed out against a perfectly good two-node cluster and
        # the obvious reading was "the join is slow, raise the timeout", which would have
        # buried an assertion that never fires under a bigger number. Measured, not reasoned:
        # the parse was run against the live output before it was believed.
        n_ready="$(grep -o ';True' <<<"$ips" | wc -l)"
        n_uniq="$(tr ' ' '\n' <<<"$ips" | sed 's/.*=\([0-9.]*\);.*/\1/' | grep -c '^10\.77\.0\.' || true)"
        if (( n_ready >= 2 && n_uniq >= 2 )); then ok=yes; break; fi
        sleep 10
    done
    printf '  NCS2-NODES %s\n' "$ips" >&2
    [[ "$ok" == yes ]] \
        || die "the cluster did not reach two Ready nodes on distinct wire addresses within $((SECONDS - t0))s: $ips"
    printf '  NCS2-CLUSTER-READY nodes=2 after=%ss\n' "$((SECONDS - t0))" >&2
    info "host Calico binding AFTER join: $(host_binding)" ;;

down2)
    for n in "$N2" "$N1"; do
        bash "$LAB_VM" destroy "$n" --force || info "destroy $n failed (may not exist)"
    done
    info "host Calico binding after teardown: $(host_binding)" ;;

experiment)
    # `-o StrictHostKeyChecking=no` is not needed: lab-vm.sh's ssh verb manages its own
    # known_hosts for the VM it created.
    info "copying guest-experiment.sh into the guest and running it as root"
    bash "$LAB_VM" ssh "$VM" -- 'cat > /tmp/guest-experiment.sh' < "$HERE/guest-experiment.sh" \
        || die "could not copy the experiment into the guest"
    # `set -e` would exit on a non-zero ssh BEFORE `rc=$?` ever ran, so the status is
    # captured in the same statement. The experiment's own exit code is the verdict and must
    # reach the caller intact.
    rc=0
    bash "$LAB_VM" ssh "$VM" -- 'sudo NCS_POLL_WAIT='"${NCS_POLL_WAIT:-240}"' bash /tmp/guest-experiment.sh' || rc=$?
    info "host Calico binding AFTER the experiment: $(host_binding)"
    exit $rc ;;

cni-chaos)
    # Same shape as `experiment`: the script travels in and runs as root there. It is a
    # separate verb rather than a flag because it takes ~20 minutes, deletes things, and
    # nobody should reach it by accident.
    info "copying cni-chaos.sh into the guest and running it as root (~20 min: it waits out"
    info "  each layer's recovery rather than sampling once)"
    bash "$LAB_VM" ssh "$VM" -- 'cat > /tmp/cni-chaos.sh' < "$HERE/cni-chaos.sh" \
        || die "could not copy the chaos script into the guest"
    rc=0
    bash "$LAB_VM" ssh "$VM" -- 'sudo CNI_RECOVER_WAIT='"${CNI_RECOVER_WAIT:-240}"' bash /tmp/cni-chaos.sh' || rc=$?
    info "host Calico binding AFTER the chaos run: $(host_binding)"
    exit $rc ;;

status)
    bash "$LAB_VM" ssh "$VM" -- 'ip -d link show vxlan.calico 2>/dev/null | grep -oE "local [0-9.]+ dev [a-zA-Z0-9._-]+" || echo "<absent>"' 2>/dev/null \
        | sed 's/^/  guest: /' || info "  guest: unreachable"
    printf '  host : %s   <- must be unchanged by anything this lab does\n' "$(host_binding)" >&2 ;;

down)
    bash "$LAB_VM" destroy "$VM" --force || die "destroy failed"
    info "host Calico binding after teardown: $(host_binding)" ;;

*)
    sed -n '3,10p' "$0" >&2; exit 1 ;;
esac
