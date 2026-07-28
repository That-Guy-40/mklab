#!/usr/bin/env bash
# ramdisk.sh — the `ramdisk` deploy driver: netboot a kernel + initramfs and run the
# machine ENTIRELY IN RAM. Nothing is written to the node's disk. Ever.
#
# The payload comes from ../ramdisk-catalog.toml, which routes to the lab that owns
# it (RAM-INFRA trio / micro-linux / floppinux / busybox). This driver does not build
# any of them — it stages what they produced, signs it, points the node's iPXE script
# at it, and gates activation on the signal the catalog entry declares.
#
# HOW THIS DIFFERS FROM `install`, and why the differences are the lesson:
#
#   - There is no `bootdev disk` at the end. The node netboots on EVERY boot, forever;
#     switching it to its disk would boot whatever a previous tenant left there.
#   - There is no wait for the node to power itself off. A finished install powers
#     down; a RAM-resident service NEVER does — powering off IS the failure mode. So
#     the driver waits for `on` and then hands over to the health gate.
#   - `cleaning` after this is a no-op in substance: nothing was persisted, so there
#     is nothing to wipe. That contrast is exactly why the plan (§3) put the RAM
#     driver next to the disk one — it is the cleanest way to show WHY disk deploys
#     need an explicit wipe between tenants and RAM deploys do not. The driver records
#     `persistence=none` so the registry can say so; it does NOT weaken maas-lab.sh's
#     cleaning guard, because a node's disk may still hold a PREVIOUS tenant's data
#     that this deploy simply never touched.
#
# Verbs: describe | verify | deploy | health   (+ `stage`, an operator verb — see below)
#
# Context from maas-lab.sh: MAAS_BMC, MAAS_REG_BMC, MAAS_STATE, MAAS_IMAGES_DIR,
# MAAS_HEALTH_TIMEOUT. Knobs: MAAS_POLL_INTERVAL, MAAS_POWERON_TIMEOUT,
# MAAS_CATALOG (default ../ramdisk-catalog.toml), MAAS_NETBOOT_DIR (default
# ~/netboot — where the PXE HTTP endpoint serves from, :8181).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd -- "$HERE/.." && pwd)"
REPO="$(cd -- "$LAB/../.." && pwd)"
CATALOG="${MAAS_CATALOG:-$LAB/ramdisk-catalog.toml}"
CATPY="$LAB/lib/catalog.py"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"
POLL="${MAAS_POLL_INTERVAL:-5}"

verb="${1:-}"; shift || true

nd() { printf '%s/%s\n' "${MAAS_STATE:?ramdisk driver: MAAS_STATE not set (run via maas-lab.sh)}" "$1"; }
node_field() { local f; f="$(nd "$1")/$2"; [[ -f "$f" ]] && cat "$f" || printf '%s' "${3:-}"; }
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }
die() { echo "ramdisk: $*" >&2; exit 1; }

# cat_get <image> — load the catalog entry into IMG_* variables, or die naming the
# images that DO exist (a typo'd --image should not read like a broken catalog).
cat_get() {
    [[ -r "$CATALOG" ]] || die "no catalog at $CATALOG"
    local out
    out="$(python3 "$CATPY" "$CATALOG" get "$1" 2>&1)" || die "$out"
    eval "$out"
}

# resolve a catalog path: absolute as-is, otherwise relative to the repo root
abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$REPO" "$1" ;; esac; }

# await_power — same shape as the install driver's: the BMC is the only way to ask a
# machine in a rack whether it is running. (Never `virsh` — see install.sh's header.)
await_power() {
    local node="$1" want="$2" to="$3" what="$4" waited=0 st step
    step="${POLL%%.*}"; [[ -z "$step" || "$step" -eq 0 ]] && step=1
    while [[ $waited -lt $to ]]; do
        st="$(bmc "$node" power status 2>/dev/null || printf 'unknown')"
        [[ "$st" == *"is $want"* ]] && return 0
        sleep "$POLL"; waited=$(( waited + step ))
    done
    echo "ramdisk: timed out after ${to}s waiting for $what (chassis power != $want; last: ${st:-<no answer>})" >&2
    return 1
}

# region_check <image> — after health, prove the node actually JOINED the region it was
# deployed into (fast-follow: ramdisk -> resilient region). A RAM node that is up but
# not announcing is the failure this catches: the service answers locally and the
# region never sees it, so traffic goes nowhere and every dashboard says "healthy".
# The check is declared per image (`region_check_*`), like health — the driver invents
# nothing about what membership means.
region_check() {
    local node="$1" region="$2" to="${MAAS_REGION_TIMEOUT:-${MAAS_HEALTH_TIMEOUT:-120}}"
    local waited=0 step; step="${POLL%%.*}"; [[ -z "$step" || "$step" -eq 0 ]] && step=1
    local kind="${IMG_REGION_CHECK:-}"
    if [[ -z "$kind" ]]; then
        echo "ramdisk: '$IMG_NAME' declares no region_check — cannot prove '$node' joined '$region'. Refusing to claim membership this driver cannot verify." >&2
        return 1
    fi
    echo "ramdisk: verifying '$node' joined region '$region' ($kind)…" >&2
    while [[ $waited -lt $to ]]; do
        case "$kind" in
        console)
            local con; con="$(node_field "$node" console "")"
            [[ -n "$con" ]] || con="$(nd "$node")/console.log"
            [[ -f "$con" ]] && grep -qE -- "${IMG_REGION_MARKER:-.}" "$con" && return 0 ;;
        http)
            command -v curl >/dev/null || { echo "ramdisk: region_check=http needs curl" >&2; return 1; }
            curl -fsS --max-time 5 "${IMG_REGION_URL:?}" >/dev/null 2>&1 && return 0 ;;
        dns)
            command -v dig >/dev/null || { echo "ramdisk: region_check=dns needs dig" >&2; return 1; }
            local qn="${IMG_REGION_QUERY%@*}" qs="${IMG_REGION_QUERY#*@}"
            [[ -n "$(dig +short +time=2 +tries=1 "@$qs" "$qn" 2>/dev/null)" ]] && return 0 ;;
        *) echo "ramdisk: unknown region_check kind '$kind'" >&2; return 1 ;;
        esac
        sleep "$POLL"; waited=$((waited+step))
    done
    echo "ramdisk: '$node' is UP but never joined region '$region' within ${to}s — it is serving nothing the region can reach" >&2
    return 1
}

case "$verb" in

describe)
    if [[ -n "${1:-}" ]]; then
        cat_get "$1"
        printf 'ramdisk/%s: %s\n' "$IMG_NAME" "$IMG_SUMMARY"
        printf '  from   %s   (build: %s)\n' "$IMG_LAB" "$IMG_BUILD"
        case "$IMG_HEALTH" in
            console) printf '  active = console matches /%s/\n' "$IMG_MARKER" ;;
            http)    printf '  active = HTTP 200 from %s%s\n' "$IMG_URL" "${IMG_MARKER:+ containing '$IMG_MARKER'}" ;;
            dns)     printf '  active = %s resolves\n' "$IMG_QUERY" ;;
        esac
    else
        echo "ramdisk: netboot a kernel+initramfs and run entirely in RAM; nothing is written to disk."
        echo "images (--image NAME), from $CATALOG:"
        while read -r n; do [[ -n "$n" ]] && printf '  %s\n' "$n"; done < <(python3 "$CATPY" "$CATALOG" names)
    fi
    ;;

# stage <image> — OPERATOR verb, not part of the driver dispatch contract. Copies the
# catalog's artifacts into the signed image store and signs them, so `verify` (F2) has
# something to check. Separate from `deploy` on purpose: staging touches no hardware
# and is the step you re-run after rebuilding a payload.
stage)
    image="${1:?ramdisk stage <image> [--unsigned]}"; shift
    unsigned=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # --unsigned: stage WITHOUT signing, and remove any stale signatures. This
            # produces a genuinely UNSIGNED image, which the host-side F2 gate will and
            # should REFUSE — `deploy` sends the node to `error` before it powers on.
            # That is the correct behaviour and this flag exists to exercise it.
            #
            # It is NOT the way to run on firmware that cannot verify. That was the
            # first thing it was used for and it does not work, because both halves of
            # F2 read the same .sig files: removing them disarms the on-node check by
            # first failing the host-side one. To keep the host-side gate real and drop
            # only the in-firmware half, sign normally and set MAAS_NO_IMGVERIFY=1 at
            # deploy (see the boot-script writer below).
            --unsigned) unsigned=1; shift ;;
            *) die "stage: unknown option '$1' (usage: stage <image> [--unsigned])" ;;
        esac
    done
    cat_get "$image"
    : "${MAAS_IMAGES_DIR:?ramdisk stage: MAAS_IMAGES_DIR not set}"
    k="$(abspath "$IMG_KERNEL")"; i="$(abspath "$IMG_INITRD")"
    missing=0
    [[ -f "$k" ]] || { echo "ramdisk: kernel not found: $k" >&2; missing=1; }
    [[ -f "$i" ]] || { echo "ramdisk: initramfs not found: $i" >&2; missing=1; }
    if [[ $missing == 1 ]]; then
        cat >&2 <<EOF
ramdisk: '$image' has not been built. This driver does not build it — ${IMG_LAB} owns it:
    $IMG_BUILD
Then re-run: drivers/ramdisk.sh stage $image
EOF
        exit 1
    fi
    dir="$MAAS_IMAGES_DIR/$image"; mkdir -p "$dir"
    cp -f "$k" "$dir/kernel" || die "could not stage the kernel"
    cp -f "$i" "$dir/initrd" || die "could not stage the initramfs"
    printf '%s\n' "$IMG_CMDLINE" > "$dir/cmdline"
    if [[ $unsigned == 1 ]]; then
        rm -f "$dir/kernel.sig" "$dir/initrd.sig"
        echo "ramdisk: staged '$image' into $dir — DELIBERATELY UNSIGNED (--unsigned)." >&2
        echo "ramdisk: the host-side F2 gate will REFUSE this image: 'deploy' sends the node" >&2
        echo "ramdisk: to 'error' without powering it on. That is the point of the flag." >&2
        echo "ramdisk: to deploy it anyway, add --no-verify. To keep the gate real and skip" >&2
        echo "ramdisk: only the in-firmware check, re-stage SIGNED and set MAAS_NO_IMGVERIFY=1." >&2
    elif [[ -d "$MAAS_IMAGES_DIR/trust" ]]; then
        "$HERE/verify-lib.sh" sign "$dir/kernel" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null \
            || die "signing the kernel failed"
        "$HERE/verify-lib.sh" sign "$dir/initrd" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null \
            || die "signing the initramfs failed"
        echo "ramdisk: staged + SIGNED '$image' into $dir" >&2
    else
        # Say so loudly. An unsigned payload deploys only with --no-verify, and a
        # reader who does not notice would think F2 was covering them.
        echo "ramdisk: staged '$image' into $dir — NOT SIGNED (no $MAAS_IMAGES_DIR/trust)." >&2
        echo "ramdisk: run 'drivers/verify-lib.sh gen-keys --dir $MAAS_IMAGES_DIR/trust' and re-stage, or deploy --no-verify." >&2
    fi
    ;;

verify)
    # F2: the signed kernel+initrd for this image. Same CMS format as install's, and
    # the same format netboot/sign-payload.sh produces for iPXE's own `imgverify`.
    image="${1:?ramdisk verify <image>}"
    cat_get "$image" >/dev/null 2>&1 || die "no catalog entry '$image' — verify refuses an image it cannot even describe"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    [[ -d "$dir" ]] || die "'$image' is not staged (run: drivers/ramdisk.sh stage $image)"
    exec "$HERE/verify-lib.sh" verify-dir "$dir" --ca "${MAAS_IMAGES_DIR}/trust/ca.crt"
    ;;

deploy)
    node="${1:?ramdisk deploy <node> <image> <slot>}"; image="${2:?}"; slot="${3:-current}"
    cat_get "$image"
    dir="${MAAS_IMAGES_DIR:?}/$image"
    [[ -f "$dir/kernel" && -f "$dir/initrd" ]] \
        || die "'$image' is not staged (run: drivers/ramdisk.sh stage $image)"

    # The per-node iPXE script: what the firmware fetches and runs. `imgverify` is the
    # in-firmware half of F2 — the host-side `verify` above gates BEFORE we touch the
    # node, this gates at boot on the node itself. Both, or neither is a chain.
    mkdir -p "$NETBOOT_DIR/maas"
    script="$NETBOOT_DIR/maas/$node.ipxe"
    base="http://\${next-server}:8181/maas/$image"
    {
        printf '#!ipxe\n'
        printf '# generated by maas-lab.sh ramdisk driver for node %s (slot=%s)\n' "$node" "$slot"
        printf 'kernel %s/kernel %s maas.node=%s maas.image=%s\n' "$base" "$IMG_CMDLINE" "$node" "$image"
        printf 'initrd %s/initrd\n' "$base"
        # MAAS_NO_IMGVERIFY=1 drops the ON-NODE half and keeps the host-side one. That is
        # the only correct way to separate them: the two halves share the .sig files, so
        # deleting the signatures does not disable the on-node check — it fails the
        # HOST-side gate first and the node never boots at all. (Learned live: a run that
        # staged --unsigned to dodge a firmware without IMAGE_TRUST_CMD was refused by
        # `verify` before it got anywhere near the firmware.) The escape hatch has to be
        # here, at the line the firmware reads, not back at the signing step.
        if [[ -f "$dir/kernel.sig" && "${MAAS_NO_IMGVERIFY:-0}" != 1 ]]; then
            printf 'imgverify kernel %s/kernel.sig\n' "$base"
            printf 'imgverify initrd %s/initrd.sig\n' "$base"
        elif [[ -f "$dir/kernel.sig" ]]; then
            printf '# MAAS_NO_IMGVERIFY=1: on-node imgverify omitted. The payload IS signed and\n'
            printf '# the host-side F2 gate verified it before this script was written.\n'
        fi
        printf 'boot\n'
    } > "$script" || die "could not write the node's iPXE script at $script"
    echo "ramdisk: wrote $script (payload '$image', RAM-resident, no disk write)" >&2

    # Serve the payload from the PXE docroot. Copy, don't symlink: the HTTP server
    # may be a container that cannot follow a link out of its docroot.
    mkdir -p "$NETBOOT_DIR/maas/$image"
    cp -f "$dir"/kernel "$dir"/initrd "$NETBOOT_DIR/maas/$image/" 2>/dev/null
    cp -f "$dir"/kernel.sig "$dir"/initrd.sig "$NETBOOT_DIR/maas/$image/" 2>/dev/null || true

    bmc "$node" bootdev pxe || die "bootdev pxe failed"
    bmc "$node" power on    || die "power on failed"
    # A RAM node has no "installer finished" moment — it just has to BE up. Confirm it
    # powered, then let the health gate decide whether what came up is the payload.
    await_power "$node" on "${MAAS_POWERON_TIMEOUT:-60}" "'$node' to power on for the RAM boot" \
        || exit 1
    # NOTE: no `bootdev disk`. This node netboots on every boot, by design.
    printf 'none\n' > "$(nd "$node")/persistence" 2>/dev/null || true
    echo "ramdisk: '$node' is netbooting '$image' into RAM (persistence=none)" >&2
    ;;

health)
    node="${1:?ramdisk health <node> <image>}"; image="${2:?}"
    cat_get "$image"
    # a node deployed into a region is not healthy until it has JOINED it
    REGION="$(node_field "$node" region "")"
    to="${MAAS_HEALTH_TIMEOUT:-120}"; waited=0
    step="${POLL%%.*}"; [[ -z "$step" || "$step" -eq 0 ]] && step=1
    case "$IMG_HEALTH" in
    console)
        console="$(node_field "$node" console "")"
        [[ -n "$console" ]] || console="$(nd "$node")/console.log"
        # same virtlogd-rotation hazard as install.sh's health: an unreadable
        # console must be named, not timed out as "never printed its marker"
        if [[ -f "$console" && ! -r "$console" ]]; then
            echo "ramdisk: console $console exists but is NOT readable by $(id -un) — virtlogd rotation recreates it 0600 root. chmod 0666 it (and raise virtlogd max_size)." >&2
            exit 1
        fi
        echo "ramdisk: awaiting /$IMG_MARKER/ on $console (timeout ${to}s)…" >&2
        while [[ $waited -lt $to ]]; do
            [[ -f "$console" ]] && grep -qE -- "$IMG_MARKER" "$console" \
                && { [[ -z "$REGION" ]] || region_check "$node" "$REGION" || exit 1
                     echo "ramdisk: '$node' matched its console marker (active)" >&2; exit 0; }
            sleep "$POLL"; waited=$((waited+step))
        done
        echo "ramdisk: '$node' never printed /$IMG_MARKER/ within ${to}s (health gate FAIL)" >&2
        ;;
    http)
        command -v curl >/dev/null || die "health=http needs curl"
        echo "ramdisk: probing $IMG_URL (timeout ${to}s)…" >&2
        while [[ $waited -lt $to ]]; do
            body="$(curl -fsS --max-time 5 "$IMG_URL" 2>/dev/null)" && {
                if [[ -z "${IMG_MARKER:-}" || "$body" == *"$IMG_MARKER"* ]]; then
                    [[ -z "$REGION" ]] || region_check "$node" "$REGION" || exit 1
                    echo "ramdisk: '$node' is serving $IMG_URL (active)" >&2; exit 0
                fi
            }
            sleep "$POLL"; waited=$((waited+step))
        done
        echo "ramdisk: $IMG_URL did not answer${IMG_MARKER:+ with '$IMG_MARKER'} within ${to}s (health gate FAIL)" >&2
        ;;
    dns)
        command -v dig >/dev/null || die "health=dns needs dig (bind9-dnsutils)"
        qname="${IMG_QUERY%@*}"; qserver="${IMG_QUERY#*@}"
        echo "ramdisk: resolving $qname against $qserver (timeout ${to}s)…" >&2
        while [[ $waited -lt $to ]]; do
            ans="$(dig +short +time=2 +tries=1 "@$qserver" "$qname" 2>/dev/null)"
            [[ -n "$ans" ]] && { [[ -z "$REGION" ]] || region_check "$node" "$REGION" || exit 1
                                 echo "ramdisk: '$node' answered DNS for $qname -> $ans (active)" >&2; exit 0; }
            sleep "$POLL"; waited=$((waited+step))
        done
        echo "ramdisk: $qname did not resolve against $qserver within ${to}s (health gate FAIL)" >&2
        ;;
    *) die "catalog entry '$image' declares an unknown health kind '$IMG_HEALTH'" ;;
    esac
    exit 1
    ;;

*) echo "ramdisk: unknown verb '$verb' (describe|stage|verify|deploy|health)" >&2; exit 2 ;;
esac
