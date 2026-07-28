#!/usr/bin/env bash
# image.sh — the `image` deploy driver: lay a GOLDEN WHOLE-DISK image onto the node.
#
# A deployer ramdisk netboots, `dd`s a raw whole-disk image over the node's disk,
# registers a UEFI boot entry, and the node then boots what was written. Routes to
# the proven mechanism in ../nixos-ipxe-deploy/ (its "Tier B — image lay-down":
# modules/deployer.nix + stage-deploy.sh --tier-b); this driver does not reimplement
# it, it stages the payload, points the node at it, and gates activation.
#
# WHERE IT SITS BETWEEN ITS TWO SIBLINGS — the three drivers differ in exactly the
# ways the underlying mechanisms differ, and each difference is asserted:
#
#                     install            ramdisk              image
#   completion    node powers itself   (never — a RAM      a console marker from
#   signal        off (installer end)   service stays up)   the deployer ramdisk
#   ends with     bootdev disk         NOTHING (netboots   bootdev disk (the node
#                                       every boot)         now owns its disk)
#   persistence   full                 none                full, and DESTRUCTIVE
#
# The last cell is the one with teeth. `install` writes a filesystem; `image`
# OVERWRITES THE WHOLE DISK, including whatever a previous tenant left. That is why
# `deploy` is only reachable from `available` (post-`cleaning`) and `active` — the
# state machine already enforces it, and this driver records `persistence=full` so
# `release` cannot treat the node as if nothing was written.
#
# Verbs: describe | stage | verify | deploy | health   (`stage` is an operator verb,
# outside the 4-verb dispatch contract, exactly as in ramdisk.sh)
#
# Context from maas-lab.sh: MAAS_BMC, MAAS_REG_BMC, MAAS_STATE, MAAS_IMAGES_DIR,
# MAAS_HEALTH_TIMEOUT. Knobs: MAAS_POLL_INTERVAL, MAAS_POWERON_TIMEOUT,
# MAAS_WRITE_TIMEOUT (how long a whole-disk write may take — default 20x the health
# timeout; dd'ing a few GB is slower than a boot), MAAS_NETBOOT_DIR.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
POLL="${MAAS_POLL_INTERVAL:-5}"

# The deployer ramdisk announces the write is done. Keep this in step with the
# `image` profile in ../milestones.toml (§5c: the terminal milestone and the health
# gate are two consumers of one declaration).
WRITE_DONE_RE="${MAAS_IMAGE_WRITE_MARKER:-(bytes .* copied|Image written|Deploy complete)}"
UP_RE="${MAAS_IMAGE_UP_MARKER:-login:}"

verb="${1:-}"; shift || true

nd() { printf '%s/%s\n' "${MAAS_STATE:?image driver: MAAS_STATE not set (run via maas-lab.sh)}" "$1"; }
node_field() { local f; f="$(nd "$1")/$2"; [[ -f "$f" ]] && cat "$f" || printf '%s' "${3:-}"; }
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }
die() { echo "image: $*" >&2; exit 1; }
console_of() {
    local c; c="$(node_field "$1" console "")"
    [[ -n "$c" ]] || c="$(nd "$1")/console.log"
    printf '%s' "$c"
}

# await_power / await_console — the node is reached ONLY through the BMC and its
# console. Never the hypervisor (see install.sh's header for why that matters).
_step() { local s="${POLL%%.*}"; [[ -z "$s" || "$s" -eq 0 ]] && s=1; printf '%s' "$s"; }
await_power() {
    local node="$1" want="$2" to="$3" what="$4" waited=0 st; local step; step="$(_step)"
    while [[ $waited -lt $to ]]; do
        st="$(bmc "$node" power status 2>/dev/null || printf 'unknown')"
        [[ "$st" == *"is $want"* ]] && return 0
        sleep "$POLL"; waited=$(( waited + step ))
    done
    echo "image: timed out after ${to}s waiting for $what (chassis power != $want; last: ${st:-<no answer>})" >&2
    return 1
}
await_console() {
    local node="$1" re="$2" to="$3" what="$4" waited=0 con; local step; step="$(_step)"
    con="$(console_of "$node")"
    while [[ $waited -lt $to ]]; do
        [[ -f "$con" ]] && grep -qE -- "$re" "$con" && return 0
        sleep "$POLL"; waited=$(( waited + step ))
    done
    echo "image: timed out after ${to}s waiting for $what (/$re/ never appeared on $con)" >&2
    return 1
}

case "$verb" in

describe)
    echo "image: a deployer ramdisk dd's a golden whole-disk image onto the node, then it boots from disk; active = the deployed image's login. DESTRUCTIVE: the whole disk is overwritten"
    ;;

# stage <name> --from <raw> — copy a whole-disk raw into the signed image store and
# sign it. Separate from deploy because staging touches no hardware and is what you
# re-run after rebuilding the golden image.
stage)
    image="${1:?image stage <name> --from <whole-disk.raw>}"; shift
    src=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from) src="$2"; shift 2 ;;
            *) die "stage: unknown option '$1'" ;;
        esac
    done
    [[ -n "$src" ]] || die "stage: --from <whole-disk.raw> is required"
    [[ -f "$src" ]] || die "stage: no such image: $src
This driver does not build golden images. ../nixos-ipxe-deploy/ does (Tier B):
    examples/nixos-ipxe-deploy/stage-deploy.sh --tier-b
or point --from at any UEFI-bootable whole-disk raw."
    : "${MAAS_IMAGES_DIR:?stage: MAAS_IMAGES_DIR not set}"
    dir="$MAAS_IMAGES_DIR/$image"; mkdir -p "$dir"
    cp -f "$src" "$dir/disk.raw" || die "could not stage the image"
    if [[ -d "$MAAS_IMAGES_DIR/trust" ]]; then
        "$HERE/verify-lib.sh" sign "$dir/disk.raw" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null \
            || die "signing the image failed"
        echo "image: staged + SIGNED '$image' ($(du -h "$dir/disk.raw" | cut -f1)) into $dir" >&2
    else
        echo "image: staged '$image' into $dir — NOT SIGNED (no $MAAS_IMAGES_DIR/trust)." >&2
        echo "image: run 'drivers/verify-lib.sh gen-keys --dir $MAAS_IMAGES_DIR/trust' and re-stage, or deploy --no-verify." >&2
    fi
    ;;

verify)
    image="${1:?image verify <image>}"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    [[ -d "$dir" ]] || die "'$image' is not staged (run: drivers/image.sh stage $image --from <raw>)"
    exec "$HERE/verify-lib.sh" verify-dir "$dir" --ca "${MAAS_IMAGES_DIR}/trust/ca.crt"
    ;;

deploy)
    node="${1:?image deploy <node> <image> <slot>}"; image="${2:?}"; slot="${3:-current}"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    [[ -f "$dir/disk.raw" ]] || die "'$image' is not staged (run: drivers/image.sh stage $image --from <raw>)"

    # Publish the raw + the per-node deployer script the ramdisk fetches.
    mkdir -p "$NETBOOT_DIR/maas/$image" "$NETBOOT_DIR/maas"
    cp -f "$dir/disk.raw" "$NETBOOT_DIR/maas/$image/disk.raw" 2>/dev/null \
        || die "could not publish the image to the PXE docroot ($NETBOOT_DIR/maas/$image)"
    cp -f "$dir/disk.raw.sig" "$NETBOOT_DIR/maas/$image/" 2>/dev/null || true
    script="$NETBOOT_DIR/maas/$node.ipxe"
    base="http://\${next-server}:8181/maas/$image"
    {
        printf '#!ipxe\n'
        printf '# generated by maas-lab.sh image driver for node %s (slot=%s)\n' "$node" "$slot"
        printf '# the deployer ramdisk writes %s over the node disk, then reports on the console\n' "$image"
        printf 'kernel http://${next-server}:8181/maas/deployer/vmlinuz console=ttyS0 maas.node=%s maas.image=%s maas.url=%s/disk.raw\n' \
            "$node" "$image" "$base"
        printf 'initrd http://${next-server}:8181/maas/deployer/initrd\n'
        [[ -f "$dir/disk.raw.sig" ]] && printf 'imgverify disk %s/disk.raw.sig\n' "$base"
        printf 'boot\n'
    } > "$script" || die "could not write the node's iPXE script at $script"
    echo "image: wrote $script (golden image '$image' -> whole disk; DESTRUCTIVE)" >&2

    bmc "$node" bootdev pxe || die "bootdev pxe failed"
    bmc "$node" power on    || die "power on failed"
    await_power "$node" on "${MAAS_POWERON_TIMEOUT:-60}" "'$node' to power on for the image lay-down" \
        || exit 1
    # Unlike `install` there is no self-poweroff to wait for: the deployer ramdisk
    # writes and reboots. The write completing is reported on the CONSOLE, which is
    # also what `watch` renders as the image profile's "writing image" milestone.
    await_console "$node" "$WRITE_DONE_RE" \
        "${MAAS_WRITE_TIMEOUT:-$(( ${MAAS_HEALTH_TIMEOUT:-120} * 20 ))}" \
        "the deployer to finish writing '$image' to disk" || exit 1
    echo "image: '$image' written; pointing '$node' at its own disk" >&2
    # The node now owns its disk — unlike a ramdisk node, it must boot from it.
    bmc "$node" bootdev disk || die "bootdev disk failed"
    bmc "$node" power cycle  || die "power cycle into the deployed image failed"
    printf 'full\n' > "$(nd "$node")/persistence" 2>/dev/null || true
    ;;

health)
    node="${1:?image health <node> <image>}"; image="${2:?}"
    to="${MAAS_HEALTH_TIMEOUT:-120}"
    echo "image: awaiting /$UP_RE/ on $(console_of "$node") (timeout ${to}s)…" >&2
    if await_console "$node" "$UP_RE" "$to" "the deployed image to reach a login"; then
        echo "image: '$node' booted '$image' to a login (active)" >&2
        exit 0
    fi
    exit 1
    ;;

*) echo "image: unknown verb '$verb' (describe|stage|verify|deploy|health)" >&2; exit 2 ;;
esac
