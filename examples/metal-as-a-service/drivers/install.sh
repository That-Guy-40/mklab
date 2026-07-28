#!/usr/bin/env bash
# install.sh — the `install` deploy driver: PXE-install an OS to disk (Anaconda
# kickstart / debian-installer preseed), then boot from disk. Reaches `active`
# when the installed OS's serial login is up. Wraps the proven sibling
# examples/virtualbmc-ipmi-lab/ finale (bootdev pxe -> power on -> installer writes
# disk + powers off -> bootdev disk -> power on -> login), reusing its
# setup-pxe-net.sh + kickstart. Cite: almalinux-pxe-lab / debian-pxe-lab.
#
# AUTHOR-RUN: real installs need rootful libvirt (qemu:///system) + the PXE net +
# an Anaconda/d-i payload. The driver CONTRACT (verify/deploy/health/describe) is
# what maas-lab.sh's health gate + A/B rollback drive; the mock driver
# (tests/mock-driver.sh) exercises that logic headlessly.
#
# EVERY out-of-band effect goes through the BMC seam — including "has the installer
# finished?". An earlier version of this driver asked `virsh domstate` instead, which
# was wrong twice over: it reached AROUND the BMC into the hypervisor (a capability no
# real bare-metal control plane has — there is no `virsh` for a machine in a rack), and
# it made the one un-mockable call in the lab, so this driver could not be tested at
# all. The out-of-band truth about a powered-off machine is `chassis power status`.
#
# Context comes from the env maas-lab.sh exports: MAAS_BMC, MAAS_REG_BMC (the
# generated bmc-toolkit registry), MAAS_STATE, MAAS_IMAGES_DIR, MAAS_HEALTH_TIMEOUT.
# Timing knobs (injectable so the sequence is testable without a real 20-minute
# install): MAAS_INSTALL_TIMEOUT (default 15x the health timeout — installs are slow),
# MAAS_POLL_INTERVAL (default 5s between BMC polls).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB="$(cd -- "$HERE/.." && pwd)"
CATALOG="${MAAS_INSTALL_CATALOG:-$LAB/install-catalog.toml}"
CATPY="$LAB/lib/catalog.py"
NETBOOT_DIR="${MAAS_NETBOOT_DIR:-$HOME/netboot}"

verb="${1:-}"; shift || true

# MAAS_STATE is demanded LAZILY, where node context is actually read — not at the
# top of the file. `stage`/`verify`/`describe` are operator verbs that touch only
# the image store, and demanding registry context they never use broke the first
# live run of run-e2e-install.sh at the staging step (found live, 2026-07-28).
nd() { printf '%s/%s\n' "${MAAS_STATE:?install driver: MAAS_STATE not set (run via maas-lab.sh)}" "$1"; }
node_field() { local f; f="$(nd "$1")/$2"; [[ -f "$f" ]] && cat "$f" || printf '%s' "${3:-}"; }
# BMC passthrough via the same seam maas-lab.sh uses
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }
die() { echo "install: $*" >&2; exit 1; }

# cat_get <image> — load the catalog entry into IMG_* vars (same machinery as the
# ramdisk driver's; install-catalog.toml is the sibling registry it reads).
cat_get() {
    [[ -r "$CATALOG" ]] || return 1
    local out
    out="$(python3 "$CATPY" "$CATALOG" get "$1" 2>&1)" || return 1
    eval "$out"
}

# is_staged_installer <dir> — the shape `stage` below writes: kernel + initrd +
# ks.cfg. Distinct BY CONSTRUCTION from the ramdisk driver's kernel+initrd+cmdline
# triple: the `cmdline` file exists only to boot a payload straight into RAM, and
# a kickstart exists only to drive an installer. Each driver's staged shape is its
# ownership fingerprint.
is_staged_installer() { [[ -f "$1/kernel" && -f "$1/initrd" && -f "$1/ks.cfg" ]]; }

POLL="${MAAS_POLL_INTERVAL:-5}"

# await_power <node> <on|off> <timeout> <what> — poll the BMC until chassis power
# reaches the wanted state. `ipmitool chassis power status` prints
# "Chassis Power is on|off"; every backend in bmc-toolkit answers in that shape.
await_power() {
    local node="$1" want="$2" to="$3" what="$4" waited=0 st step
    # a sub-second poll (tests) still advances the clock by 1, so the loop always ends
    step="${POLL%%.*}"; [[ -z "$step" || "$step" -eq 0 ]] && step=1
    while [[ $waited -lt $to ]]; do
        st="$(bmc "$node" power status 2>/dev/null || printf 'unknown')"
        [[ "$st" == *"is $want"* ]] && return 0
        sleep "$POLL"; waited=$(( waited + step ))
    done
    echo "install: timed out after ${to}s waiting for $what (chassis power != $want; last: ${st:-<no answer>})" >&2
    return 1
}

case "$verb" in
describe)
    # WITH an image argument this is the contract's ownership question — "is this one
    # yours?" — and answering "yes" unconditionally is how this driver came to netboot a
    # RAM payload onto a live node and then block 30 minutes waiting for an installer
    # that was never there. An installer payload is one with a kickstart or a preseed in
    # it; a kernel+initrd is somebody else's image, however well signed.
    if [[ -n "${1:-}" ]]; then
        img="$1"; dir="${MAAS_IMAGES_DIR:?}/$img"
        # A staged RAM payload is kernel + initrd + cmdline — that triple is written by
        # `ramdisk.sh stage` and by nothing else here. An installer payload is also a
        # kernel and an initrd, so the FILE LIST alone cannot tell them apart; the
        # `cmdline` file is what makes the difference legible, because it exists only to
        # tell a firmware what to append when booting the payload directly into RAM.
        # This is a narrow test and it is deliberately narrow: it catches the case that
        # actually happened (a rollback handing this driver the previous ramdisk image)
        # without inventing a contract for install payloads that this lab does not yet
        # have. The broader gap — an image no driver has staged, or a third driver's —
        # is named in PLAN.md rather than half-covered here.
        if [[ -f "$dir/kernel" && -f "$dir/initrd" && -f "$dir/cmdline" ]]; then
            echo "install: '$img' is a RAM payload (kernel+initrd+cmdline staged by the ramdisk driver)," >&2
            echo "install: not an installer image. This driver PXE-boots an installer and then waits for" >&2
            echo "install: it to power the node off; handed a RAM image it waits until the timeout while" >&2
            echo "install: the node sits happily at a login prompt. Deploy it with --driver ramdisk." >&2
            exit 1
        fi
        # The POSITIVE half of the ownership question (the refusal above only knew
        # the one wrong shape that actually happened): an image is this driver's if
        # install-catalog.toml declares it, or if it is staged in this driver's own
        # shape (kernel+initrd+ks.cfg — what `stage` writes). Anything else is an
        # image no driver has claimed, and deploying an unclaimed image is how the
        # rollback incident happened for the ramdisk shape.
        if cat_get "$img"; then
            printf 'install/%s: %s\n' "$IMG_NAME" "$IMG_SUMMARY"
            printf '  from   %s   (build: %s)\n' "$IMG_LAB" "$IMG_BUILD"
            printf '  active = installed OS reaches /%s/ on the serial console\n' "${IMG_MARKER:-login:}"
        elif is_staged_installer "$dir"; then
            echo "install/$img: staged installer payload (kernel+initrd+ks.cfg); active = installed OS 'login:' on serial"
        else
            echo "install: '$img' is not in $CATALOG and is not staged in this driver's shape" >&2
            echo "install: (kernel+initrd+ks.cfg) — no driver has claimed it, so this one must not deploy it." >&2
            exit 1
        fi
        exit 0
    fi
    echo "install: PXE kickstart/preseed writes the OS to disk; active = installed OS 'login:' on serial"
    if [[ -r "$CATALOG" ]]; then
        echo "images (--image NAME), from $CATALOG:"
        while read -r n; do [[ -n "$n" ]] && printf '  %s\n' "$n"; done < <(python3 "$CATPY" "$CATALOG" names)
    fi
    ;;

# stage <image> — OPERATOR verb (same contract as ramdisk.sh's): copy the catalog's
# installer artifacts into the signed image store and sign them, so `verify` (F2)
# has something to check. Stages kernel + initrd + ks.cfg — NO `cmdline` file:
# that file is the ramdisk driver's ownership fingerprint, and writing one here
# would make this image claimable by the wrong driver.
stage)
    image="${1:?install stage <image>}"; shift || true
    cat_get "$image" || die "no catalog entry '$image' in $CATALOG — stage only stages images this driver owns"
    : "${MAAS_IMAGES_DIR:?install stage: MAAS_IMAGES_DIR not set}"
    missing=0
    [[ -f "$IMG_KERNEL" ]] || { echo "install: installer kernel not found: $IMG_KERNEL" >&2; missing=1; }
    [[ -f "$IMG_INITRD" ]] || { echo "install: installer initrd not found: $IMG_INITRD" >&2; missing=1; }
    [[ -f "${IMG_KS:?catalog entry '$image' has no ks field}" ]] \
        || { echo "install: kickstart/preseed not found: $IMG_KS" >&2; missing=1; }
    if [[ $missing == 1 ]]; then
        cat >&2 <<EOF
install: '$image' is not staged on this host. This driver does not fetch it — ${IMG_LAB} owns it:
    $IMG_BUILD
Then re-run: drivers/install.sh stage $image
EOF
        exit 1
    fi
    dir="$MAAS_IMAGES_DIR/$image"; mkdir -p "$dir"
    cp -f "$IMG_KERNEL" "$dir/kernel"  || die "could not stage the installer kernel"
    cp -f "$IMG_INITRD" "$dir/initrd"  || die "could not stage the installer initrd"
    cp -f "$IMG_KS"     "$dir/ks.cfg"  || die "could not stage the kickstart"
    if [[ -d "$MAAS_IMAGES_DIR/trust" ]]; then
        for f in kernel initrd ks.cfg; do
            "$HERE/verify-lib.sh" sign "$dir/$f" --keydir "$MAAS_IMAGES_DIR/trust" >/dev/null \
                || die "signing $f failed"
        done
        echo "install: staged + SIGNED '$image' into $dir (kernel, initrd, ks.cfg)" >&2
    else
        echo "install: staged '$image' into $dir — NOT SIGNED (no $MAAS_IMAGES_DIR/trust)." >&2
        echo "install: run 'drivers/verify-lib.sh gen-keys --dir $MAAS_IMAGES_DIR/trust' and re-stage, or deploy --no-verify." >&2
    fi
    ;;

verify)
    # F2: the signed kernel/initrd/kickstart payload for this image
    image="${1:?install verify <image>}"
    exec "$(dirname "$0")/verify-lib.sh" verify-dir "${MAAS_IMAGES_DIR:?}/$image" \
        --ca "${MAAS_IMAGES_DIR}/trust/ca.crt"
    ;;

deploy)
    node="${1:?install deploy <node> <image> <slot>}"; image="${2:?}"; slot="${3:-current}"
    domain="$(node_field "$node" domain "$node")"
    echo "install: PXE-installing '$image' onto '$node' (domain=$domain, slot=$slot)" >&2
    dir="${MAAS_IMAGES_DIR:?}/$image"
    is_staged_installer "$dir" || die "'$image' is not staged (run: drivers/install.sh stage $image)"

    # The per-node iPXE script — what the fleet's netboot CHAIN resolves for this
    # node. Without it the node falls through to maas/default.ipxe (the honest dead
    # end) and the install never starts: the chain replaced the network-wide baked
    # boot.ipxe this driver used to lean on, so the driver must now answer for its
    # own node like the ramdisk driver does.
    cmdline=""
    cat_get "$image" && cmdline="${IMG_CMDLINE:-}"
    mkdir -p "$NETBOOT_DIR/maas"
    script="$NETBOOT_DIR/maas/$node.ipxe"
    base="http://\${next-server}:8181/maas/$image"
    {
        printf '#!ipxe\n'
        printf '# generated by maas-lab.sh install driver for node %s (slot=%s)\n' "$node" "$slot"
        printf 'kernel %s/kernel %s inst.ks=%s/ks.cfg maas.node=%s maas.image=%s\n' \
            "$base" "$cmdline" "$base" "$node" "$image"
        printf 'initrd %s/initrd\n' "$base"
        # The on-node half of F2 covers what the FIRMWARE fetches: kernel + initrd.
        # The kickstart is fetched later by Anaconda itself, which has no imgverify —
        # its .sig is staged and served, but only the host-side gate checks it. That
        # gap is stated here rather than papered over: the firmware attests the
        # installer it boots, not the recipe the installer then follows.
        if [[ -f "$dir/kernel.sig" && "${MAAS_NO_IMGVERIFY:-0}" != 1 ]]; then
            printf 'imgverify kernel %s/kernel.sig\n' "$base"
            printf 'imgverify initrd %s/initrd.sig\n' "$base"
        elif [[ -f "$dir/kernel.sig" ]]; then
            printf '# MAAS_NO_IMGVERIFY=1: on-node imgverify omitted. The payload IS signed and\n'
            printf '# the host-side F2 gate verified it before this script was written.\n'
        fi
        printf 'boot\n'
    } > "$script" || die "could not write the node's iPXE script at $script"
    echo "install: wrote $script (installer '$image', writes the node's disk)" >&2

    # Serve the payload from the PXE docroot. Copy, don't symlink: the HTTP server
    # may be a container that cannot follow a link out of its docroot.
    mkdir -p "$NETBOOT_DIR/maas/$image"
    cp -f "$dir"/kernel "$dir"/initrd "$dir"/ks.cfg "$NETBOOT_DIR/maas/$image/" 2>/dev/null
    cp -f "$dir"/kernel.sig "$dir"/initrd.sig "$dir"/ks.cfg.sig "$NETBOOT_DIR/maas/$image/" 2>/dev/null || true

    # Netboot the installer:
    bmc "$node" bootdev pxe   || { echo "install: bootdev pxe failed" >&2; exit 1; }
    bmc "$node" power on      || { echo "install: power on failed" >&2; exit 1; }
    # Two distinct waits, because they fail for different reasons and the operator
    # needs to be told which happened:
    #   1. the node actually came up at all (BMC accepted `power on` but the machine
    #      never powered — a dead PSU, a wedged BMC);
    #   2. the installer ran to completion. The kickstart/preseed ends in `poweroff`,
    #      so the node powering ITSELF off is the completion signal, observed
    #      out-of-band. Cap generously: installs take far longer than a boot.
    await_power "$node" on "${MAAS_POWERON_TIMEOUT:-60}" "'$node' to power on for the install" \
        || exit 1
    await_power "$node" off "${MAAS_INSTALL_TIMEOUT:-$(( ${MAAS_HEALTH_TIMEOUT:-120} * 15 ))}" \
        "the installer on '$node' to finish (it ends in poweroff)" || exit 1
    # CONFIRM the off is the installer's, not a blip. A finished install STAYS off;
    # an out-of-band power cycle (an operator "helping", a BMC hiccup) passes
    # through off for a few seconds — and acting on that blip means bootdev disk
    # on a half-written (or never-written) disk. Cost: one extra poll. (Found
    # live: an operator power cycle raced this wait and the driver switched an
    # EMPTY disk to be the boot device.)
    sleep "$POLL"
    st="$(bmc "$node" power status 2>/dev/null || printf 'unknown')"
    if [[ "$st" != *"is off"* ]]; then
        echo "install: '$node' powered off and came BACK ON — that was a power blip or an out-of-band cycle, not the installer finishing. Refusing to switch an unfinished disk to be the boot device." >&2
        exit 1
    fi
    echo "install: installer finished ('$node' powered itself off); booting from disk" >&2
    bmc "$node" bootdev disk  || { echo "install: bootdev disk failed" >&2; exit 1; }
    bmc "$node" power on      || { echo "install: power-on-from-disk failed" >&2; exit 1; }
    exit 0
    ;;

health)
    # active = the installed OS's serial login is up. Poll the node's console log
    # (the SAME signal `maas-lab.sh watch` renders as the terminal milestone, §5c)
    # for the image's marker (catalog `marker`, default `login:`) within the timeout.
    node="${1:?install health <node> <image>}"; image="${2:-}"
    marker="login:"
    [[ -n "$image" ]] && cat_get "$image" && marker="${IMG_MARKER:-login:}"
    console="$(node_field "$node" console "")"
    [[ -n "$console" ]] || console="$(nd "$node")/console.log"
    to="${MAAS_HEALTH_TIMEOUT:-120}"; waited=0
    step="${POLL%%.*}"; [[ -z "$step" || "$step" -eq 0 ]] && step=1
    # A console that EXISTS but cannot be read would otherwise time out as "never
    # reached login" — a lie. virtlogd recreates rotated console logs 0600 root
    # (found live: Anaconda's output tripped the 2 MiB rotation and the readable
    # 0666 file the fleet set up was replaced under us).
    if [[ -f "$console" && ! -r "$console" ]]; then
        echo "install: console $console exists but is NOT readable by $(id -un) — virtlogd rotation recreates it 0600 root. chmod 0666 it (and raise virtlogd max_size) before the health gate can see anything." >&2
        exit 1
    fi
    echo "install: awaiting /$marker/ on $console (timeout ${to}s)…" >&2
    while [[ $waited -lt $to ]]; do
        [[ -f "$console" ]] && grep -qE -- "$marker" "$console" && { echo "install: '$node' reached its login marker (active)" >&2; exit 0; }
        sleep "$POLL"; waited=$((waited+step))
    done
    echo "install: '$node' did not reach /$marker/ within ${to}s (health gate FAIL)" >&2
    exit 1
    ;;

*) echo "install: unknown verb '$verb' (verify|deploy|health|describe|stage)" >&2; exit 2 ;;
esac
