#!/usr/bin/env bash
# run-e2e-image.sh — the IMAGE-driver live path (DEFERRED item 2's second half):
# a deployer ramdisk netboots, streams a golden whole-disk raw straight onto the
# node's disk, verifies what landed by reading it back, and the node then boots
# the image it was given.
#
# THE DESTRUCTIVE ONE. `install` writes a filesystem; this OVERWRITES THE WHOLE
# DISK of whatever node it is pointed at, including anything a previous tenant
# left. The subject node defaults to node2 rather than node1 for exactly that
# reason — node1 carries the AlmaLinux install the install-driver run produced,
# and re-imaging it would silently destroy that evidence.
#
# SEPARATE from run-e2e.sh and run-e2e-install.sh: same reasoning, different clock.
# The fleet must already be UP (run-e2e.sh, or FLEET_NIC_ROM=1 ./create-fleet.sh up).
#
# Knobs:
#   E2E_NODE=node2               the subject node (its disk is destroyed)
#   E2E_IMAGE=golden-alpine      the staged golden image
#   E2E_GOLDEN_SRC=<raw>         stage from this raw if the image is not staged
#   MAAS_WRITE_TIMEOUT           how long the lay-down may take (default 20x health)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MAAS="$HERE/maas-lab.sh"
NODE="${E2E_NODE:-node2}"
IMAGE="${E2E_IMAGE:-golden-alpine}"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
PORT="${MAAS_NETBOOT_PORT:-8181}"
export MAAS_IMAGES_DIR="${MAAS_IMAGES_DIR:-$("$MAAS" _images-dir)}"
[[ -n "$MAAS_IMAGES_DIR" ]] || { echo "run-e2e-image: maas-lab.sh _images-dir returned nothing" >&2; exit 1; }
export MAAS_STATE="${MAAS_STATE:-$("$MAAS" _state-root)}"
export MAAS_HEALTH_TIMEOUT="${MAAS_HEALTH_TIMEOUT:-240}"

die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '   %s\n' "$*" >&2; }
step() { printf '\n== %s ==\n' "$*" >&2; }

step "preflight"

( "$MAAS" show "$NODE" ) >/dev/null 2>&1 \
    || die "node '$NODE' is not enrolled — bring the fleet up first:
    FLEET_NIC_ROM=1 ./create-fleet.sh up"
( "$MAAS" power "$NODE" status ) >/dev/null 2>&1 \
    || die "the BMC for '$NODE' is not answering — is vbmcd up? (FLEET_NIC_ROM=1 ./create-fleet.sh up)"
info "fleet: '$NODE' enrolled, BMC answers"

# The destructive check, stated plainly and refusable. A node running something
# somebody cares about must not be re-imaged because a default pointed here.
st="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
if [[ "$st" == active && "${E2E_FORCE:-0}" != 1 ]]; then
    cur="$( ( "$MAAS" show "$NODE" ) 2>/dev/null | awk '$1=="image"{print $2; exit}')"
    info "NOTE: '$NODE' is active on '$cur'. This run OVERWRITES ITS WHOLE DISK."
    info "That is the point of the image driver — but if that node is carrying"
    info "something you want, stop now and set E2E_NODE=<other>. Continuing in 5s…"
    sleep 5
fi

grep -q 'netboot-chain.sh' /var/lib/libvirt/tftp-vbmc/boot.ipxe 2>/dev/null \
    || die "the PXE network's boot.ipxe is not the per-node CHAIN — the per-node script this
run writes would never be fetched. Install it: ./netboot-chain.sh install (sudo)"

GW="$(virsh -c qemu:///system net-dumpxml vbmc-pxe 2>/dev/null \
      | sed -nE "s/.*<ip address='([^']+)'.*/\1/p" | head -1)"
[[ -n "$GW" ]] || die "could not read the vbmc-pxe gateway address (is the network defined?)"
curl -fsS --max-time 5 -o /dev/null "http://$GW:$PORT/maas/deployer/vmlinuz" \
    || die "the deployer ramdisk is not being served at http://$GW:$PORT/maas/deployer/vmlinuz.
Build and publish it (host-safe, no sudo):
    ./build-probe-initramfs.sh --init deployer-init.sh --out /tmp/deployer.cpio.gz
    mkdir -p $NETBOOT_DIR/maas/deployer
    cp ../../micro-linux/out/x86_64/kernel $NETBOOT_DIR/maas/deployer/vmlinuz
    cp /tmp/deployer.cpio.gz $NETBOOT_DIR/maas/deployer/initrd
    ./drivers/verify-lib.sh sign $NETBOOT_DIR/maas/deployer/vmlinuz --keydir $MAAS_IMAGES_DIR/trust
    ./drivers/verify-lib.sh sign $NETBOOT_DIR/maas/deployer/initrd  --keydir $MAAS_IMAGES_DIR/trust"
info "deployer ramdisk: served at http://$GW:$PORT/maas/deployer/"

# The firmware verifies the DEPLOYER (it is what iPXE fetches). Without these
# signatures a MAAS_IPXE_TRUSTS_CA=1 run would boot an unverified ramdisk and
# still call the deploy "verified" — the claim has to match what is checked.
if [[ "${MAAS_IPXE_TRUSTS_CA:-0}" == 1 ]]; then
    for f in vmlinuz initrd; do
        [[ -f "$NETBOOT_DIR/maas/deployer/$f.sig" ]] \
            || die "MAAS_IPXE_TRUSTS_CA=1 but $NETBOOT_DIR/maas/deployer/$f.sig is missing — the
firmware would have nothing to check for the deployer ramdisk. Sign it:
    ./drivers/verify-lib.sh sign $NETBOOT_DIR/maas/deployer/$f --keydir $MAAS_IMAGES_DIR/trust"
    done
    dom="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="domain"{print $2; exit}')"
    virsh -c qemu:///system dumpxml --inactive "${dom:-$NODE}" 2>/dev/null | grep -q '<rom file=' \
        || die "MAAS_IPXE_TRUSTS_CA=1, but domain '${dom:-$NODE}' carries no <rom file=> — its stock
ROM cannot honour imgverify. Re-create the fleet: FLEET_NIC_ROM=1 ./create-fleet.sh up"
    info "verifying ROM attached, deployer signed — the firmware can honour imgverify"
fi

step "stage + sign '$IMAGE' (host-side F2)"
if [[ ! -f "$MAAS_IMAGES_DIR/$IMAGE/disk.raw" ]]; then
    [[ -n "${E2E_GOLDEN_SRC:-}" && -f "$E2E_GOLDEN_SRC" ]] \
        || die "'$IMAGE' is not staged and E2E_GOLDEN_SRC is unset/missing. Stage a golden
whole-disk raw first, e.g. from this host's cached Alpine cloud image:
    qemu-img convert -f qcow2 -O raw ../virtualbmc-ipmi-lab/cache/generic_alpine-*.qcow2 ~/golden.raw
    ./drivers/image.sh stage $IMAGE --from ~/golden.raw"
    "$HERE/drivers/image.sh" stage "$IMAGE" --from "$E2E_GOLDEN_SRC" || die "staging failed"
fi
( "$HERE/drivers/image.sh" verify "$IMAGE" ) \
    || die "the staged '$IMAGE' does not pass the host-side F2 gate"
info "staged + verified ($(du -h "$MAAS_IMAGES_DIR/$IMAGE/disk.raw" | cut -f1))"

step "deploy: netboot the deployer -> stream the raw to disk -> verify -> boot it"

CON="$("$MAAS" show "$NODE" 2>/dev/null | awk '$1=="console"{print $2; exit}')"
[[ -n "$CON" && -f "$CON" ]] || die "no console log recorded for '$NODE' — the write gate and the
health gate both read it, so this run would be blind"
[[ -r "$CON" ]] || die "$CON is not readable by $(id -un) — virtlogd rotation recreates console
logs 0600 root. sudo chmod 0666 $CON (and raise virtlogd's max_size)"
# Rotate: the write marker AND the login marker are both greps over this file, and
# a previous tenant's login line would satisfy the health gate instantly.
cp -f "$CON" "$HERE/e2e-image-console.prev.log" 2>/dev/null || true
: > "$CON" || die "cannot truncate $CON"
info "console rotated (previous boot's log kept at e2e-image-console.prev.log)"

# From rest, like every other deploy: `power on` against a running node is a no-op
# and nothing would ever PXE.
( "$MAAS" power "$NODE" off ) >/dev/null 2>&1 || true

# The node must be deployable. `available` is the post-cleaning state the state
# machine requires for a destructive lay-down.
case "$st" in
    active)     info "'$NODE' is active — releasing it back to available first"
                ( "$MAAS" release "$NODE" --wiped ) >/dev/null 2>&1 || true ;;
    error)      ( "$MAAS" retry "$NODE" ) >/dev/null 2>&1 || true
                ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1 || true ;;
    manageable) ( "$MAAS" provide "$NODE" ) >/dev/null 2>&1 || true ;;
esac

"$MAAS" deploy "$NODE" --driver image --image "$IMAGE" \
    || die "deploy did not reach active — state: $( ( "$MAAS" state "$NODE" ) 2>/dev/null ). Console tail:
$(tail -8 "$CON" 2>/dev/null | tr -d '\r')"

step "verdict"
st2="$( ( "$MAAS" state "$NODE" ) 2>/dev/null )"
[[ "$st2" == active ]] || die "deploy returned success but '$NODE' is in '$st2'"
grep -qa 'MAAS-DEPLOY: verified: the bytes' "$CON" \
    || die "'$NODE' is active but the deployer never reported verifying what it wrote — the
run cannot claim the disk holds the published image"
[[ "$( ( "$MAAS" show "$NODE" ) 2>/dev/null | awk '$1=="persistence"{print $2; exit}')" == full ]] \
    || info "NOTE: persistence was not recorded as 'full' — cleaning would treat this node as diskless"
info "deployer: $(grep -a 'bytes.*copied' "$CON" | tail -1 | tr -d '\r')"
info "verified: $(grep -a 'MAAS-DEPLOY: verified' "$CON" | tail -1 | tr -d '\r')"
printf 'PASS: %s reached active through the IMAGE driver — a deployer ramdisk streamed a golden whole-disk image onto the node, read it back and matched its sha256, and the node booted the image it was given\n' "$NODE"
