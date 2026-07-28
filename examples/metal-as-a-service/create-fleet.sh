#!/usr/bin/env bash
# create-fleet.sh — stand up (or enroll) the Metal-as-a-Service fleet from fleet.toml.
#
# It does NOT reinvent libvirt/vbmc plumbing: it WRAPS the proven sibling anchor
# examples/virtualbmc-ipmi-lab/ (create-node.sh + vbmc-lab.sh), which is already
# parameterized by NODE/PORT/NET and whose RUNBOOK sanctions fanning out onto
# 6231/6232 in one rootful vbmcd container. One vbmcd hosts every node's BMC.
#
# Modes:
#   enroll         HEADLESS — register the fleet into maas-lab.sh's registry only
#                  (no libvirt, no root). Proves the fleet wiring + generated BMC
#                  registry. This is the increment-1 verifiable path.
#   up             AUTHOR-RUN (rootful) — build+create the 3 libvirt domains, start
#                  vbmcd, `vbmc add` each on 6230–6232, then enroll. Needs sudo +
#                  qemu:///system + rootful podman (inherited from the vbmc lab).
#   down           AUTHOR-RUN — tear the fleet's domains + BMCs down.
#   status         show the fleet via `maas-lab.sh list`.
#
# Security (AUDIT.md): BMC ports are loopback-only (F1); teardown kills by the
# container/domain lifecycle verbs, never `pkill -f` (F8); disk removal under
# /var/lib/libvirt is handed to the user.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
MAAS="$HERE/maas-lab.sh"
FLEET_PY="$HERE/lib/fleet.py"
FLEET_TOML="${FLEET_TOML:-$HERE/fleet.toml}"
VBMC_LAB="${VBMC_LAB:-$HERE/../virtualbmc-ipmi-lab}"
# Where each node's serial console is RECORDED. Under /var/lib/libvirt so libvirt's
# AppArmor helper grants qemu the path; the files are pre-created 0666 so the
# unprivileged control plane can read them back. See lib/console_xml.py for why the
# console is a file and not a pty.
CONSOLE_DIR="${MAAS_CONSOLE_DIR:-/var/lib/libvirt/maas-console}"
FLEET_CONSOLE="${FLEET_CONSOLE:-file}"        # file | pty (pty = the old, unlogged behaviour)
VIRSH="virsh -c qemu:///system"

die()  { printf 'create-fleet: %s\n' "$*" >&2; exit 1; }
info() { printf '  - %s\n' "$*" >&2; }
step() { printf '==> %s\n' "$*" >&2; }

command -v python3 >/dev/null || die "python3 required (fleet.toml is TOML)"
[[ -f "$FLEET_TOML" ]] || die "no fleet spec: $FLEET_TOML"

fleet_names() { python3 "$FLEET_PY" "$FLEET_TOML" names; }
# Load one node's merged fields (defaults + per-node) into NODE_* shell vars.
load_node() {  # load_node <name>  -> sets NODE_NAME, NODE_BMC_PORT, NODE_MEMORY_MB, ...
    local line
    while IFS= read -r line; do eval "$line"; done < <(python3 "$FLEET_PY" "$FLEET_TOML" get "$1")
}

# ── enroll: headless registry population (the increment-1 verifiable path) ────
do_enroll() {
    local name
    for name in $(fleet_names); do
        load_node "$name"
        if "$MAAS" state "$name" >/dev/null 2>&1; then
            info "$name already enrolled (state=$("$MAAS" state "$name")) — skipping"
            continue
        fi
        "$MAAS" enroll "$name" \
            --bmc-port "${NODE_BMC_PORT}" \
            --domain "$name" \
            --firmware "${NODE_FIRMWARE:-bios}" \
            --uri "${NODE_URI:-qemu:///system}" \
            --bmc-user "${NODE_BMC_USER:-admin}" \
            --bmc-pass "${NODE_BMC_PASS:-password}" >/dev/null \
            || die "enroll $name failed"
        info "enrolled $name (bmc port ${NODE_BMC_PORT})"
    done
    step "fleet enrolled; generated BMC registry: $(python3 "$FLEET_PY" "$FLEET_TOML" names | wc -l) nodes"
    "$MAAS" list
}

# ── the two things a fleet needs that a single-node lab does not ─────────────
#
# Both were missing on the first live end-to-end run, and both failed the same way:
# silently, with a timeout somewhere far downstream.
#
# 1. A CONSOLE THAT IS RECORDED. Every health gate greps <node>/console.log; a pty
#    console keeps nothing when no one is attached, so the run was blind.
# 2. A DHCP RESERVATION. The PXE chain (netboot-chain.sh) resolves the per-node boot
#    script by ${hostname}, which the node learns from DHCP option 12 — dnsmasq only
#    sends it for a host it has a reservation for. Without it every node falls through
#    to the MAC-keyed name and then to default.ipxe.

# give_console <node> — swap the domain's pty console for a file, and tell the
# registry where it is (the `console` field the drivers already read).
give_console() {
    local name="$1" log="$CONSOLE_DIR/$name.log"
    if [[ "$FLEET_CONSOLE" != file ]]; then
        info "$name: FLEET_CONSOLE=$FLEET_CONSOLE — leaving the pty console (health gates that read a console log will time out)"
        return 0
    fi
    # Pre-create it 0666: qemu (uid libvirt-qemu) writes, the unprivileged control
    # plane reads. If qemu created it itself the mode would be 0600 and every gate
    # would fail on a permission error instead of on the machine's behaviour.
    sudo mkdir -p "$CONSOLE_DIR" && sudo chmod 0755 "$CONSOLE_DIR" \
        || { info "$name: could not create $CONSOLE_DIR — leaving the pty console"; return 1; }
    sudo install -m 0666 /dev/null "$log" \
        || { info "$name: could not create $log — leaving the pty console"; return 1; }
    $VIRSH dumpxml "$name" \
        | python3 "$HERE/lib/console_xml.py" "$log" \
        | sudo $VIRSH define /dev/stdin >/dev/null \
        || { info "$name: could not redefine with a file console — leaving the pty console"; return 1; }
    "$MAAS" set-console "$name" "$log" >/dev/null 2>&1 \
        || info "$name: console file created but not recorded in the registry"
    info "$name: console recorded to $log"
}

# reserve_dhcp <node> <net> <index> — record the domain's MAC and give it a DHCP
# reservation, so the node's own name reaches iPXE as ${hostname} (DHCP option 12).
reserve_dhcp() {
    local name="$1" net="${2:-vbmc-pxe}" idx="${3:-0}" mac gw prefix ip
    mac="$($VIRSH domiflist "$name" 2>/dev/null | awk '$3=="'"$net"'" {print $5; exit}')"
    [[ -n "$mac" ]] || mac="$($VIRSH domiflist "$name" 2>/dev/null | awk 'NR>2 && NF {print $5; exit}')"
    [[ -n "$mac" ]] || { info "$name: no MAC found on $net — skipping the DHCP reservation"; return 1; }
    "$MAAS" set-mac "$name" "$mac" >/dev/null 2>&1 || true

    # libvirt REQUIRES an IP in a static host definition ("Missing IP address in static
    # host definition"), so a mac+name reservation is rejected — which is how the first
    # attempt at this silently added nothing. Derive the subnet from the network itself
    # rather than hardcoding it, and allocate ABOVE the dynamic range (which this lab's
    # setup-pxe-net.sh puts at .10-.99) so a reservation can never collide with a lease.
    gw="$($VIRSH net-dumpxml "$net" 2>/dev/null | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
    [[ -n "$gw" ]] || { info "$name: could not read $net's gateway — skipping the reservation"; return 1; }
    prefix="${gw%.*}"; ip="$prefix.$((101 + idx))"

    # --live --config: apply to the running network AND persist. Re-adding an existing
    # host is an error rather than a no-op, so a re-run falls through to modify.
    if sudo $VIRSH net-update "$net" add ip-dhcp-host \
           "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null 2>&1; then
        info "$name: DHCP reservation on $net ($mac -> $name @ $ip)"
    elif sudo $VIRSH net-update "$net" modify ip-dhcp-host \
           "<host mac='$mac' name='$name' ip='$ip'/>" --live --config >/dev/null 2>&1; then
        info "$name: DHCP reservation updated on $net ($mac -> $name @ $ip)"
    else
        # Not fatal — the PXE chain falls back to the MAC-keyed script — but it is not
        # nothing either, so say what was lost instead of "continuing".
        info "$name: could NOT reserve $ip for $mac on $net. The node will not receive a"
        info "  hostname over DHCP, so the boot chain falls through to maas/\${net0/mac}.ipxe."
    fi
}

# verify_bmc_bindings — prove each node's BMC actuates THAT node before anything trusts it.
#
# The failure this catches cost two full end-to-end runs. VirtualBMC lets two domains
# register on one port; only one binds, the loser sits in `error`, and the winner
# answers IPMI for both. The sibling lab's own `alpine-node` defaults to 6230 — which is
# also node1's port — so every command the control plane sent for node1 was served,
# plausibly and successfully, by a different machine. `manage` verified creds, `power
# status` said "on", `bootdev pxe` and `power on` were accepted, and node1 never booted.
#
# The control plane cannot catch this: the BMC seam is precisely the abstraction that
# hides which machine is on the other end. So it is checked here, where we still know
# this is vbmcd.
verify_bmc_bindings() {
    local name want=() out
    for name in $(fleet_names); do
        load_node "$name"
        want+=("$name:${NODE_BMC_PORT}")
    done
    out="$( ( cd "$VBMC_LAB" && ./vbmc-lab.sh list ) 2>/dev/null )"
    if ! printf '%s\n' "$out" | python3 "$HERE/lib/vbmc_check.py" "${want[@]}"; then
        die "the fleet's BMCs are not wired to the fleet's nodes (see above). Refusing to
continue: every verb from here on would be sent to a machine that answers correctly and
is not the one you asked for — which passes every check and deploys nothing."
    fi
}

# ── up: author-run rootful bring-up ──────────────────────────────────────────
do_up() {
    [[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB (set VBMC_LAB=)"
    step "building the vbmcd image (rootful podman) — one container hosts all BMCs"
    ( cd "$VBMC_LAB" && ./vbmc-lab.sh build ) || die "vbmc build failed"

    local name
    # STOP ANY RUNNING FLEET DOMAIN FIRST. create-node.sh rewrites the node's disk with
    # `qemu-img convert` BEFORE it destroys the domain, so a node still running from an
    # earlier attempt holds a write lock and the convert fails:
    #     qemu-img: ... error while converting qcow2: Failed to get "write" lock
    # A fleet run that ends on a health-gate failure leaves its nodes powered on, so the
    # NEXT `up` hits this every time. Use the lifecycle verb, and only on domains this
    # fleet owns.
    for name in $(fleet_names); do
        if [[ "$($VIRSH domstate "$name" 2>/dev/null)" == running ]]; then
            info "$name is still running from an earlier attempt — stopping it so its disk can be rewritten"
            $VIRSH destroy "$name" >/dev/null 2>&1 \
                || sudo $VIRSH destroy "$name" >/dev/null 2>&1 \
                || die "'$name' is running and could not be stopped; its disk is write-locked and create-node.sh would fail. Stop it by hand: virsh -c qemu:///system destroy $name"
        fi
    done
    for name in $(fleet_names); do
        load_node "$name"
        step "creating libvirt domain '$name' (${NODE_MEMORY_MB}MiB, disk ${NODE_DISK_SIZE}, net ${NODE_NETWORK})"
        ( cd "$VBMC_LAB" && \
          NODE="$name" MEMORY_MB="${NODE_MEMORY_MB:-4096}" DISK_SIZE="${NODE_DISK_SIZE:-10G}" \
          NET="${NODE_NETWORK:-default}" ./create-node.sh ) \
            || die "create-node $name failed"
    done

    step "starting vbmcd"
    ( cd "$VBMC_LAB" && ./vbmc-lab.sh up ) || die "vbmc up failed"


    for name in $(fleet_names); do
        load_node "$name"
        step "registering BMC for '$name' on port ${NODE_BMC_PORT}"
        ( cd "$VBMC_LAB" && NODE="$name" PORT="${NODE_BMC_PORT}" ./vbmc-lab.sh add ) \
            || die "vbmc add $name failed"
    done

    step "verifying each node OWNS its BMC port (not a squatter's)"
    verify_bmc_bindings

    step "enrolling the fleet into the control plane"
    do_enroll

    # AFTER enroll: both of these record something in the node's registry entry, which
    # does not exist until the node is enrolled.
    step "instrumenting the fleet: recorded consoles + DHCP reservations"
    local i=0
    for name in $(fleet_names); do
        load_node "$name"
        give_console "$name"
        reserve_dhcp "$name" "${NODE_NETWORK:-vbmc-pxe}" "$i"
        i=$((i+1))
    done

    step "fleet up. Verify a BMC round-trip:  $MAAS manage node1 && $MAAS power node1 status"
    info "next: ./netboot-chain.sh install — without it every node boots the network's"
    info "baked payload and the per-node scripts the drivers write are never fetched."
}

# ── down: author-run teardown ────────────────────────────────────────────────
do_down() {
    [[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB"
    local name
    for name in $(fleet_names); do
        step "destroying domain + BMC for '$name'"
        # vbmc-lab.sh destroy is single-node (NODE env); loop it. It stops the
        # container on the first call, so subsequent calls just undefine domains.
        ( cd "$VBMC_LAB" && NODE="$name" ./vbmc-lab.sh destroy ) || info "(teardown of $name reported an issue — continuing)"
    done
    info "fleet domains + BMCs town down. Registry state kept under the MAAS state dir."
    info "disk images under /var/lib/libvirt/images/ are left for you to remove (F7):"
    for name in $(fleet_names); do
        printf '    sudo rm -f /var/lib/libvirt/images/%s.qcow2 /var/lib/libvirt/images/%s-seed.iso\n' "$name" "$name" >&2
    done
}

usage() {
    cat >&2 <<EOF
create-fleet.sh — stand up / enroll the MAAS fleet from fleet.toml ($FLEET_TOML)

  enroll     HEADLESS: register the fleet into maas-lab.sh (no libvirt/root) — increment-1 path
  up         AUTHOR-RUN (rootful): create 3 libvirt domains + vbmcd + BMCs on 6230–6232, then enroll
  down       AUTHOR-RUN: tear the fleet down
  status     show the fleet (maas-lab.sh list)

Wraps the sibling anchor: $VBMC_LAB (override with VBMC_LAB=).
EOF
}

case "${1:-}" in
    enroll)        do_enroll ;;
    up)            do_up ;;
    down)          do_down ;;
    status|list)   "$MAAS" list ;;
    ""|-h|--help)  usage ;;
    *) die "unknown mode '$1' (enroll|up|down|status)" ;;
esac
