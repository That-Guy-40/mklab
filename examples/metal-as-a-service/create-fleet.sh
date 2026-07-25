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

# ── up: author-run rootful bring-up ──────────────────────────────────────────
do_up() {
    [[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB (set VBMC_LAB=)"
    step "building the vbmcd image (rootful podman) — one container hosts all BMCs"
    ( cd "$VBMC_LAB" && ./vbmc-lab.sh build ) || die "vbmc build failed"

    local name
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

    step "enrolling the fleet into the control plane"
    do_enroll
    step "fleet up. Verify a BMC round-trip:  $MAAS manage node1 && $MAAS power node1 status"
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
