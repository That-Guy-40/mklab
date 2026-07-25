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
# Context comes from the env maas-lab.sh exports: MAAS_BMC, MAAS_REG_BMC (the
# generated bmc-toolkit registry), MAAS_STATE, MAAS_IMAGES_DIR, MAAS_HEALTH_TIMEOUT.
set -uo pipefail

verb="${1:-}"; shift || true
: "${MAAS_STATE:?install driver: MAAS_STATE not set (run via maas-lab.sh)}"

nd() { printf '%s/%s\n' "$MAAS_STATE" "$1"; }
node_field() { local f; f="$(nd "$1")/$2"; [[ -f "$f" ]] && cat "$f" || printf '%s' "${3:-}"; }
# BMC passthrough via the same seam maas-lab.sh uses
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }
# the node's libvirt URI + domain (set at enroll)
V() { virsh -c "$(node_field "$1" uri qemu:///system)" "${@:2}"; }

case "$verb" in
describe)
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
    # The kickstart/preseed ends in `poweroff`; wait for the domain to go 'shut off'
    # (install complete), then boot from disk. Cap generously (installs are slow).
    local_to=$(( ${MAAS_HEALTH_TIMEOUT:-120} * 15 ))   # installs take much longer than a boot
    waited=0
    while :; do
        st="$(V "$node" domstate "$domain" 2>/dev/null || echo unknown)"
        [[ "$st" == "shut off" ]] && break
        sleep 5; waited=$((waited+5))
        [[ $waited -ge $local_to ]] && { echo "install: timed out waiting for the installer to finish (domstate=$st)" >&2; exit 1; }
    done
    echo "install: installer finished (domain shut off); booting from disk" >&2
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
    echo "install: awaiting 'login:' on $console (timeout ${to}s)…" >&2
    while [[ $waited -lt $to ]]; do
        [[ -f "$console" ]] && grep -qE 'login:' "$console" && { echo "install: '$node' reached login (active)" >&2; exit 0; }
        sleep 3; waited=$((waited+3))
    done
    echo "install: '$node' did not reach a login prompt within ${to}s (health gate FAIL)" >&2
    exit 1
    ;;

*) echo "install: unknown verb '$verb' (verify|deploy|health|describe)" >&2; exit 2 ;;
esac
