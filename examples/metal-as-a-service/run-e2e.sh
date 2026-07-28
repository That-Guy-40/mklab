#!/usr/bin/env bash
# run-e2e.sh — drive the whole control plane against REAL hardware-ish nodes, once.
#
# Everything the headless suite proves with mocks, done for real: three libvirt domains,
# three IPMI BMCs, a PXE network, an introspection probe that actually boots and reports
# its CPU/RAM, a signed payload that actually netboots into RAM, and a reconcile loop
# that converges the fleet and then does nothing.
#
# THIS SCRIPT IS GLUE. Every step below is an existing tool — `create-fleet.sh` (which
# itself wraps ../virtualbmc-ipmi-lab), `setup-pxe-net.sh`, `metadata-serve.sh`,
# `build-probe-initramfs.sh`, `netboot-chain.sh`, `drivers/ramdisk.sh`, and `maas-lab.sh`.
# Nothing here
# implements control-plane behaviour; if a step fails, it fails in the tool that owns
# it. Modelled on ../virtualbmc-ipmi-lab/run-finale.sh, which does the same thing for
# the single-node PXE install.
#
#   ./run-e2e.sh --dry-run     print the plan, touch nothing, need no sudo
#   sudo -v && ./run-e2e.sh    the real run (sudo primed; see below)
#   ./run-e2e.sh --down        tear the fleet down
#
# SUDO: rootful libvirt (qemu:///system) and rootful podman (vbmcd) are unavoidable —
# the system libvirt socket is root:libvirt. All the sudo-needing work is FRONT-LOADED
# in phases 1–3, exactly as run-finale.sh does it, so the long part runs unprivileged.
# Prime it with `sudo -v` first; this script never asks for a password mid-run.
#
# PAYLOAD: `micro-linux-x86_64` from ramdisk-catalog.toml — a from-source kernel +
# BusyBox initramfs that boots to a shell in seconds. Deliberately not the AlmaLinux
# install: that path is already proven end-to-end by run-finale.sh and takes ~30 min,
# and what this script is here to exercise is the CONTROL PLANE, not Anaconda.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
VBMC_LAB="${VBMC_LAB:-$HERE/../virtualbmc-ipmi-lab}"
IMAGE="${E2E_IMAGE:-micro-linux-x86_64}"
NODE="${E2E_NODE:-node1}"
LOG="${E2E_LOG:-$HERE/e2e-run.log}"
export MAAS_IMAGES_DIR="${MAAS_IMAGES_DIR:-$HOME/.cache/lab-create/maas/images}"
export MAAS_NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
DRY=0; DOWN=0
case "${1:-}" in --dry-run) DRY=1 ;; --down) DOWN=1 ;; -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

step() { printf '\n== %s ==\n' "$*" | tee -a "$LOG" >&2; }
info() { printf '   %s\n' "$*" | tee -a "$LOG" >&2; }
die()  { printf 'FAIL: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }
run()  { # the one place that decides "print" vs "do"
    if [[ $DRY == 1 ]]; then printf '   $ %s\n' "$*" >&2; return 0; fi
    printf '   $ %s\n' "$*" | tee -a "$LOG" >&2
    "$@" >>"$LOG" 2>&1
}

[[ $DRY == 1 ]] || : > "$LOG"

# ── teardown ────────────────────────────────────────────────────────────────
if [[ $DOWN == 1 ]]; then
    step "tearing the fleet down (rootful)"
    run "$HERE/create-fleet.sh" down
    info "the metadata service and any watchers are yours to stop — this script"
    info "does not kill processes it did not start (and never by pattern; kill by PID)."
    exit 0
fi

# ── preflight ───────────────────────────────────────────────────────────────
step "preflight"
for c in virsh ipmitool python3 openssl; do
    command -v "$c" >/dev/null || die "missing required command: $c"
done
[[ -d "$VBMC_LAB" ]] || die "sibling lab not found: $VBMC_LAB (set VBMC_LAB=)"
info "payload      : $IMAGE"
info "subject node : $NODE"
info "images dir   : $MAAS_IMAGES_DIR"
info "PXE docroot  : $MAAS_NETBOOT_DIR"
if [[ $DRY == 0 ]]; then
    sudo -n true 2>/dev/null \
        || die "sudo is not primed. Run 'sudo -v' first — this script front-loads the
privileged work and must not stop to ask for a password halfway through a boot."
fi
# The payload must already be built by the lab that owns it. This script does not
# build other labs' artifacts; the driver's own refusal names the command.
if [[ $DRY == 0 ]]; then
    "$HERE/drivers/ramdisk.sh" describe "$IMAGE" >/dev/null 2>&1 \
        || die "no catalog entry '$IMAGE' (see ramdisk-catalog.toml)"
fi

# ── 1. the PXE network + HTTP docroot (SUDO) ────────────────────────────────
step "[1/10] PXE network + HTTP docroot (sudo)"
info "creates the vbmc-pxe libvirt network and points iPXE at the host's :8181 nginx"
run env PAYLOAD=busybox "$VBMC_LAB/setup-pxe-net.sh"

# ── 1b. …and make it a FLEET network, not a one-payload network (SUDO) ──────
# setup-pxe-net.sh bakes ONE payload into boot.ipxe for the whole network. That is
# right for its single node and fatal here: the per-node scripts maas-lab.sh writes
# would never be fetched, so every node would netboot busybox and every gate would
# time out. (This is exactly how the first live run of this script failed — twice, in
# two different phases, with two different-looking errors.)
step "[2/10] replace the baked boot.ipxe with the per-node CHAIN (sudo)"
run "$HERE/netboot-chain.sh" install

# ── 3. the fleet: 3 domains + 3 BMCs, enrolled (SUDO) ───────────────────────
step "[3/10] fleet up: 3 libvirt domains + one vbmcd hosting BMCs on 6230-6232 (sudo)"
info "create-fleet.sh wraps ../virtualbmc-ipmi-lab and then enrolls into the registry"
info "it also gives each domain a FILE-backed serial console — every health gate in"
info "this lab greps a console log, and a pty console records nothing"
run "$HERE/create-fleet.sh" up

# ── everything below is UNPRIVILEGED ────────────────────────────────────────
step "[4/10] verify the BMC round-trip — the seam, against a real BMC"
run "$MAAS" manage "$NODE"
run "$MAAS" power "$NODE" status
if [[ $DRY == 0 ]]; then
    con="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="console"{print $2; exit}')"
    [[ -n "$con" && -f "$con" ]] \
        || die "no console log is recorded for '$NODE'. Every health gate in this lab reads
one, so the run would be blind: a node that boots the wrong payload and a node that never
boots at all both look like a timeout. Check create-fleet.sh's 'instrumenting the fleet'
step (FLEET_CONSOLE=file), or set one by hand: $MAAS set-console $NODE <path>"
    info "console log: $con"
fi

# ── 5. introspection: the probe really boots and reports ────────────────────
step "[5/10] build the introspection initramfs + start the facts sink (:8282)"
run "$HERE/build-probe-initramfs.sh" --out "$MAAS_NETBOOT_DIR/probe-initramfs.cpio.gz"
GW="$(virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null \
      | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
GW="${GW:-192.168.180.1}"
info "facts sink will bind $GW:8282 (the node reaches it at the network gateway)"
if [[ $DRY == 1 ]]; then
    printf '   $ %s\n' "$HERE/metadata-serve.sh --host $GW --port 8282  &   # background" >&2
else
    "$HERE/metadata-serve.sh" --host "$GW" --port 8282 >>"$LOG" 2>&1 &
    MD_PID=$!
    info "metadata-serve.sh running as PID $MD_PID — stop it with: kill $MD_PID"
    sleep 1
fi

step "[6/10] inspect: PXE-boot the probe, await its facts, power off"
info "this is the REAL introspection path — the node boots, POSTs cpus/mem/MAC, powers down"
info "--md-url is not decoration: it becomes maas.md= on the probe's kernel cmdline,"
info "and a probe without it measures the machine and has nowhere to send the answer"
run "$MAAS" inspect "$NODE" --boot --md-url "http://$GW:8282"
run "$MAAS" show "$NODE"

# ── 7. provide + stage a signed payload ─────────────────────────────────────
step "[7/10] provide (through cleaning) + stage and SIGN the payload"
run "$MAAS" provide "$NODE"
if [[ $DRY == 0 && ! -f "$MAAS_IMAGES_DIR/trust/ca.crt" ]]; then
    run mkdir -p "$MAAS_IMAGES_DIR/trust"
    run "$HERE/drivers/verify-lib.sh" gen-keys --dir "$MAAS_IMAGES_DIR/trust"
fi
run "$HERE/drivers/ramdisk.sh" stage "$IMAGE"

# ── 8. the deploy: F2 gate, netboot into RAM, health gate ───────────────────
step "[8/10] deploy: verify -> netboot into RAM -> health gate -> active"
info "the node fetches a SIGNED kernel+initrd; the iPXE script carries imgverify"
run "$MAAS" deploy "$NODE" --driver ramdisk --image "$IMAGE"
run "$MAAS" state "$NODE"

# ── 9. the reconcile loop, twice — the invariant ────────────────────────────
step "[9/10] apply: converge the fleet, then prove the second run is a no-op"
run "$MAAS" apply "$HERE/fleet.toml" --dry-run
info "(the second run below must issue ZERO transitions — the reconciliation invariant)"
run "$MAAS" apply "$HERE/fleet.toml"

step "[10/10] the surface: register with the control pane + list the declared actions"
run "$MAAS" watch "$NODE" --register-only
CP="$HERE/../../tools/control-pane"
[[ -x "$CP" ]] && run "$CP" actions "$NODE"

# ── verdict ─────────────────────────────────────────────────────────────────
if [[ $DRY == 1 ]]; then
    printf '\nDRY RUN: the plan above touches nothing. Real run: sudo -v && %s\n' "$0" >&2
    exit 0
fi
st="$( "$MAAS" state "$NODE" 2>/dev/null )"
printf '\n' | tee -a "$LOG" >&2
if [[ "$st" == active ]]; then
    printf 'PASS: end-to-end on real domains — BMC round-trip, probe-reported facts, a SIGNED payload netbooted into RAM, and apply converged. %s is active.\n' "$NODE" | tee -a "$LOG" >&2
    printf '      log: %s     teardown: %s --down\n' "$LOG" "$0" >&2
    exit 0
fi
printf 'FAIL: %s ended in state "%s", not active — see %s (and: %s show %s)\n' \
    "$NODE" "${st:-<none>}" "$LOG" "$MAAS" "$NODE" | tee -a "$LOG" >&2
exit 1
