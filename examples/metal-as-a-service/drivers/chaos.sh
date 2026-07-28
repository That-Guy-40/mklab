#!/usr/bin/env bash
# chaos.sh — a deploy driver that FAILS ON PURPOSE, at a point you choose.
#
# The other drivers answer "can the control plane deploy an OS?". This one answers a
# harder question: "when something breaks, how gracefully does it fall?" It is a real
# driver implementing the real contract (verify/deploy/health/describe), so it
# exercises the SAME code path a real deploy takes — the health gate, the A/B
# rollback, the state transitions — with a fault injected at a chosen point.
#
# WHY THE DRIVER LAYER. The deploy interface is the highest layer that still has
# something to be graceful ABOUT: below it there is only "the command failed", above
# it there is only "the operator sees an error". Everything interesting — does the
# node stay up on its previous image, does the registry tell the truth afterwards, is
# there a verb that can rescue it — is decided between those two points. The
# out-of-band layer is fault-injected separately, at the BMC seam
# (MOCK_BMC_FAIL / MOCK_BMC_FAIL_AFTER), because a BMC that dies mid-deploy is a
# different failure class from a payload that will not boot.
#
# Faults (CHAOS_FAULT, one per deploy):
#   none            no fault — the positive control. Without this run, "the chaos
#                   harness reported failures" would be indistinguishable from a
#                   driver that simply never works.
#   verify-fail     the F2 signature gate refuses the image (supply chain)
#   deploy-fail     the deploy step fails cleanly, non-zero with a message
#   deploy-crash    the driver DIES (exit 2, no message) — not the same thing: a
#                   clean refusal is handled, a crash is what actually happens when a
#                   tool is missing or a host is unreachable mid-run
#   deploy-slow     the deploy takes CHAOS_SLOW seconds — used to interrupt the
#                   control plane itself mid-deploy
#   partial         deploy "succeeds" but leaves the payload truncated; health then
#                   fails. The nastiest shape: the step that reports success is not
#                   the step that would notice
#   health-fail     the node boots and never becomes healthy
#   health-flap     healthy on the FIRST check, unhealthy on every one after —
#                   i.e. it passes the activation gate and then dies
#
# The fault applies ONLY to images matching CHAOS_TARGET (default `bad-*`). That is
# what makes the A/B fallback observable: a fault that broke every image would send
# every scenario to `error` and the rollback path would never run — the harness would
# report a uniform, uninformative failure and look like it was working.
#
# CHAOS_USE_BMC=1 makes deploy go through the BMC seam (bootdev pxe + power on) like
# every real driver, so an out-of-band failure can be injected at that layer too.
#
# SAFETY: with CHAOS_USE_BMC unset this driver touches no hardware at all — it logs,
# sleeps, and returns exit codes. With it set, it reaches hardware only as far as
# $MAAS_BMC does, which in the harness is tests/mock-bmc.sh. A tool whose whole
# purpose is to cause failures must not be able to cause a real one by accident.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

verb="${1:-}"; shift || true
FAULT="${CHAOS_FAULT:-none}"
LOG="${CHAOS_LOG:-}"
STATE="${CHAOS_STATE:-${TMPDIR:-/tmp}/maas-chaos}"; mkdir -p "$STATE" 2>/dev/null

log() { [[ -n "$LOG" ]] && printf '%s %s\n' "$verb" "$*" >> "$LOG"; return 0; }
bmc() { BMC_REGISTRY="${MAAS_REG_BMC:-}" "${MAAS_BMC:?}" "$@"; }
# does the fault apply to THIS image?
# shellcheck disable=SC2254   # CHAOS_TARGET is deliberately a glob
targeted() { case "$1" in ${CHAOS_TARGET:-bad-*}) return 0 ;; *) return 1 ;; esac; }

case "$verb" in

describe)
    printf 'chaos: injects a chosen failure into the deploy path (CHAOS_FAULT=%s, target=%s); hardware is touched only via the BMC seam, and only when CHAOS_USE_BMC=1\n' "$FAULT" "${CHAOS_TARGET:-bad-*}"
    ;;

verify)
    image="${1:?chaos verify <image>}"
    log "$image"
    if [[ "$FAULT" == verify-fail ]] && targeted "$image"; then
        echo "chaos: signature verification refused '$image' (injected)" >&2
        exit 1
    fi
    # Otherwise verify for REAL — so a chaos run that is not testing the F2 gate still
    # goes THROUGH it rather than around it.
    #
    # This deliberately does NOT skip when the image directory is missing. The first
    # version did (`-d $dir || exit 0`) and the artifact-layer scenario immediately
    # caught it: delete a staged payload and the deploy "succeeded". A verifier that
    # passes when the artifact is absent is precisely the F2 hole this driver exists
    # to hunt for — verify-lib.sh refuses a missing dir, so just let it.
    if [[ -n "${MAAS_IMAGES_DIR:-}" ]]; then
        exec "$HERE/verify-lib.sh" verify-dir "${MAAS_IMAGES_DIR}/$image" \
            --ca "${MAAS_IMAGES_DIR}/trust/ca.crt"
    fi
    exit 0
    ;;

deploy)
    node="${1:?chaos deploy <node> <image> <slot>}"; image="${2:?}"; slot="${3:-current}"
    log "$node $image $slot"
    if [[ "${CHAOS_USE_BMC:-0}" == 1 ]]; then
        bmc "$node" bootdev pxe || { echo "chaos: bootdev pxe failed (the BMC is not answering)" >&2; exit 1; }
        bmc "$node" power on    || { echo "chaos: power on failed (the BMC is not answering)" >&2; exit 1; }
    fi
    targeted "$image" || { printf '%s\n' "$image" > "$STATE/$node.deployed"; : > "$STATE/$node.healthchecks"; exit 0; }
    case "$FAULT" in
    deploy-fail)
        echo "chaos: deploy of '$image' failed (injected)" >&2; exit 1 ;;
    deploy-crash)
        exit 2 ;;                     # no message, no cleanup — a crash, not a refusal
    deploy-slow)
        sleep "${CHAOS_SLOW:-30}" ;;
    partial)
        # "Succeeded", but the payload is broken. health will find out; deploy will not.
        printf 'partial\n' > "$STATE/$node.partial" ;;
    esac
    printf '%s\n' "$image" > "$STATE/$node.deployed"
    : > "$STATE/$node.healthchecks"
    exit 0
    ;;

health)
    node="${1:?chaos health <node> <image>}"; image="${2:?}"
    log "$node $image"
    targeted "$image" || exit 0
    n=0; [[ -f "$STATE/$node.healthchecks" ]] && n=$(wc -c < "$STATE/$node.healthchecks")
    printf 'x' >> "$STATE/$node.healthchecks"
    case "$FAULT" in
    health-fail)
        echo "chaos: '$node' never became healthy on '$image' (injected)" >&2; exit 1 ;;
    partial)
        if [[ -f "$STATE/$node.partial" ]]; then
            echo "chaos: '$node' deployed '$image' but the payload is incomplete (injected)" >&2
            exit 1
        fi ;;
    health-flap)
        # healthy exactly once — the check that gates activation. Every later check
        # fails, which is how you find out whether anything ever checks again.
        if [[ $n -gt 0 ]]; then
            echo "chaos: '$node' passed its activation gate and then went unhealthy (injected)" >&2
            exit 1
        fi ;;
    esac
    exit 0
    ;;

*) echo "chaos: unknown verb '$verb' (describe|verify|deploy|health)" >&2; exit 2 ;;
esac
