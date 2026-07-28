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

verb="${1:-}"; shift || true
: "${MAAS_STATE:?install driver: MAAS_STATE not set (run via maas-lab.sh)}"

nd() { printf '%s/%s\n' "$MAAS_STATE" "$1"; }
node_field() { local f; f="$(nd "$1")/$2"; [[ -f "$f" ]] && cat "$f" || printf '%s' "${3:-}"; }
# BMC passthrough via the same seam maas-lab.sh uses
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }

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
        [[ -d "$dir" ]] \
            || { echo "install: no image '$img' staged at $dir — nothing to install" >&2; exit 1; }
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
        echo "install/$img: PXE kickstart/preseed writes the OS to disk; active = installed OS 'login:' on serial"
        exit 0
    fi
    echo "install: PXE kickstart/preseed writes the OS to disk; active = installed OS 'login:' on serial"
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
    # Prereq (author-run, once): the PXE net + this image's kickstart/payload staged.
    #   ( cd ../virtualbmc-ipmi-lab && PAYLOAD=<image> ./setup-pxe-net.sh )
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
    echo "install: installer finished ('$node' powered itself off); booting from disk" >&2
    bmc "$node" bootdev disk  || { echo "install: bootdev disk failed" >&2; exit 1; }
    bmc "$node" power on      || { echo "install: power-on-from-disk failed" >&2; exit 1; }
    exit 0
    ;;

health)
    # active = the installed OS's serial login is up. Poll the node's console log
    # (the SAME signal `maas-lab.sh watch` renders as the terminal milestone, §5c)
    # for a `login:` prompt within the timeout.
    node="${1:?install health <node> <image>}"; image="${2:-}"
    console="$(node_field "$node" console "")"
    [[ -n "$console" ]] || console="$(nd "$node")/console.log"
    to="${MAAS_HEALTH_TIMEOUT:-120}"; waited=0
    step="${POLL%%.*}"; [[ -z "$step" || "$step" -eq 0 ]] && step=1
    echo "install: awaiting 'login:' on $console (timeout ${to}s)…" >&2
    while [[ $waited -lt $to ]]; do
        [[ -f "$console" ]] && grep -qE 'login:' "$console" && { echo "install: '$node' reached login (active)" >&2; exit 0; }
        sleep "$POLL"; waited=$((waited+step))
    done
    echo "install: '$node' did not reach a login prompt within ${to}s (health gate FAIL)" >&2
    exit 1
    ;;

*) echo "install: unknown verb '$verb' (verify|deploy|health|describe)" >&2; exit 2 ;;
esac
