#!/usr/bin/env bash
# vbmc-lab.sh — thin driver for the VirtualBMC spike.
#
# Wires together the three moving parts:
#   1. a containerised vbmcd (the virtual BMC),
#   2. a libvirt domain it manages (created by ./create-node.sh),
#   3. ipmitool on the host driving power over IPMI-over-LAN.
#
#       host ipmitool ──UDP 6230──> vbmcd (container, --network host)
#                                     │  libvirt API via mounted socket
#                                     ▼
#                              libvirt domain "alpine-node"
#
# Why the container is ROOTFUL (sudo podman): qemu:///system's socket
# (/var/run/libvirt/libvirt-sock) is owned root:libvirt, mode 0660.  A rootless
# container maps your uid into a userns where it is NOT in the libvirt group, so
# it can't open the socket.  Rootful podman's real-root process can.  Building
# rootful too keeps one image store (no rootless->root save/load trap).
#
# Usage:
#   ./vbmc-lab.sh build           # build the vbmcd image
#   ./vbmc-lab.sh node            # define the alpine-node domain (= create-node.sh)
#   ./vbmc-lab.sh up              # run vbmcd (mounts libvirt socket, host net)
#   ./vbmc-lab.sh add             # vbmc add + start alpine-node on port 6230
#   ./vbmc-lab.sh power <cmd>     # ipmitool chassis power status|on|off|reset|cycle
#   ./vbmc-lab.sh bootdev <dev>   # ipmitool chassis bootdev pxe|disk|cdrom (+ show libvirt boot)
#   ./vbmc-lab.sh status          # vbmc list + ipmitool power status + virsh domstate
#   ./vbmc-lab.sh console         # libvirt serial console (NOT IPMI SOL — vbmc has none)
#   ./vbmc-lab.sh netboot         # bootdev=pxe + power reset/on (step 3 — see setup-pxe-net.sh)
#   ./vbmc-lab.sh down            # stop + remove the vbmcd container
#   ./vbmc-lab.sh pxe-down        # tear down the PXE network + http server
#   ./vbmc-lab.sh destroy         # down + remove domain + image (full teardown)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- knobs ------------------------------------------------------------------
PODMAN="${PODMAN:-sudo podman}"          # rootful by default (see header)
IMAGE="${IMAGE:-localhost/vbmcd:lab}"
CTR="${CTR:-vbmcd-lab}"
NODE="${NODE:-alpine-node}"
PORT="${PORT:-6230}"                     # unprivileged (IPMI default 623 needs root)
IPMI_USER="${IPMI_USER:-admin}"          # VirtualBMC defaults
IPMI_PASS="${IPMI_PASS:-password}"       # throwaway lab creds — loopback only
BMC_HOST="${BMC_HOST:-127.0.0.1}"
LIBVIRT_DIR="${LIBVIRT_DIR:-/var/run/libvirt}"
STATE="${STATE:-$here/state/vbmc}"       # persists vbmc config across up/down
VIRSH="virsh -c qemu:///system"

vexec() { $PODMAN exec "$CTR" "$@"; }    # run a command inside the vbmcd container
ipmi()  { ipmitool -I lanplus -H "$BMC_HOST" -p "$PORT" -U "$IPMI_USER" -P "$IPMI_PASS" "$@"; }

cmd="${1:-help}"; shift || true
case "$cmd" in

build)
    echo "==> building $IMAGE"
    $PODMAN build -f "$here/Containerfile.vbmcd" -t "$IMAGE" "$here"
    ;;

node)
    exec "$here/create-node.sh"
    ;;

up)
    command -v ipmitool >/dev/null || echo "WARN: ipmitool not installed on host (apt install ipmitool)" >&2
    [[ -S "$LIBVIRT_DIR/libvirt-sock" ]] || echo "WARN: $LIBVIRT_DIR/libvirt-sock not found — is libvirtd running?" >&2
    mkdir -p "$STATE"
    # Remove any stale container, then run vbmcd:
    #   --network host        : IPMI UDP listener lands on the host netns
    #   -v $LIBVIRT_DIR        : reach the host's libvirtd over its socket
    #   -v $STATE:/root/.vbmc  : persist `vbmc add` config across restarts
    $PODMAN rm -f "$CTR" >/dev/null 2>&1 || true
    echo "==> starting vbmcd container $CTR (image $IMAGE)"
    $PODMAN run -d --name "$CTR" \
        --network host \
        -v "$LIBVIRT_DIR:$LIBVIRT_DIR" \
        -v "$STATE:/root/.vbmc" \
        "$IMAGE" >/dev/null
    # vbmcd needs a moment to open its CLI socket.
    for _ in $(seq 1 10); do vexec vbmc list >/dev/null 2>&1 && break; sleep 0.5; done
    echo "==> vbmcd up:"; vexec vbmc list || true
    ;;

add)
    echo "==> registering domain '$NODE' as a virtual BMC on port $PORT"
    vexec vbmc add "$NODE" --port "$PORT" --username "$IPMI_USER" --password "$IPMI_PASS" \
        || echo "(already added? continuing)"
    vexec vbmc start "$NODE"
    vexec vbmc list
    echo
    echo "Try:  ./vbmc-lab.sh power status"
    ;;

power)
    sub="${1:?usage: power <status|on|off|reset|cycle|soft>}"
    ipmi chassis power "$sub"
    ;;

status)
    echo "== vbmc list =="                ; vexec vbmc list || true
    echo; echo "== ipmitool chassis power status =="; ipmi chassis power status || true
    echo; echo "== virsh domstate $NODE ==" ; $VIRSH domstate "$NODE" || true
    ;;

bootdev)
    # VirtualBMC's set_boot_device() rewrites the domain's <os><boot dev=...>:
    #   pxe -> network, disk -> hd, cdrom -> optical.  So the IPMI call actually
    #   re-orders the libvirt boot — we set it, then show the result from XML.
    sub="${1:?usage: bootdev <pxe|disk|cdrom>}"
    ipmi chassis bootdev "$sub"
    echo "==> libvirt domain boot order now (set via IPMI -> libvirt XML):"
    $VIRSH dumpxml "$NODE" | grep -E '<boot ' || echo "    (no <boot> element found)"
    ;;

console)
    # IMPORTANT: VirtualBMC does NOT implement IPMI Serial-over-LAN (no
    # activate_payload).  It is scoped to power + boot device.  The console is
    # libvirt's own serial console — the honest substitute for SOL.  Use this to
    # watch the node boot (and, in the PXE step, netboot).  One consumer at a
    # time on the console pty.
    echo "==> libvirt serial console for $NODE (Ctrl-] to exit)"
    echo "    (this is libvirt's console, NOT IPMI SOL — VirtualBMC has none)"
    # virsh console needs a RUNNING domain — power it on first if it's off.
    if [[ "$($VIRSH domstate "$NODE" 2>/dev/null)" != "running" ]]; then
        echo "    $NODE is not running — power it on first:  ./vbmc-lab.sh power on" >&2
        exit 1
    fi
    $VIRSH console "$NODE"
    ;;

netboot)
    # The step-3 payoff, as ONE foreground command: tell the node (over IPMI) to
    # boot from the network, power it on (or reset if already up) so the firmware
    # PXE-boots against setup-pxe-net.sh's libvirt dnsmasq, then attach the
    # console so you watch the netboot live.  Ctrl-] to exit.
    echo "==> bootdev=pxe + power $NODE, then attaching console (Ctrl-] to exit)"
    ipmi chassis bootdev pxe
    if [[ "$($VIRSH domstate "$NODE" 2>/dev/null)" == "running" ]]; then
        ipmi chassis power reset
    else
        ipmi chassis power on
    fi
    sleep 1
    exec $VIRSH console "$NODE"      # exec: Ctrl-] returns straight to your shell
    ;;

pxe-down)
    echo "==> tearing down PXE network ${NET_PXE:-vbmc-pxe} + vbmc-http"
    sudo $VIRSH net-destroy  "${NET_PXE:-vbmc-pxe}" >/dev/null 2>&1 || true
    sudo $VIRSH net-undefine "${NET_PXE:-vbmc-pxe}" >/dev/null 2>&1 || true
    podman rm -f vbmc-http >/dev/null 2>&1 || true   # rootless (started by setup-pxe-net.sh)
    ;;

down)
    echo "==> removing container $CTR"
    $PODMAN rm -f "$CTR" >/dev/null 2>&1 || true
    ;;

destroy)
    "$0" down
    echo "==> undefining domain $NODE"
    $VIRSH destroy  "$NODE" >/dev/null 2>&1 || true
    $VIRSH undefine "$NODE" --nvram >/dev/null 2>&1 || $VIRSH undefine "$NODE" >/dev/null 2>&1 || true
    echo "==> removing image $IMAGE"
    $PODMAN rmi -f "$IMAGE" >/dev/null 2>&1 || true
    echo "(domain disk under /var/lib/libvirt/images and ./cache left in place)"
    ;;

help|*)
    sed -n '2,30p' "${BASH_SOURCE[0]}"
    ;;
esac
