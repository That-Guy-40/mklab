#!/usr/bin/env bash
# build-minimal.sh — build the custom minimal bootc base image from this lab's
# Containerfile, with the privileges the upstream tutorial's §9.3 requires.
#
# This is the automated equivalent of RUNBOOK.md §9.2–§9.4.  We do NOT drive the
# build through phase4-podman/lab-podman.sh because the inner `build-rootfs` step
# needs build privileges that the phase tool deliberately does not inject
# (--cap-add=all, a relaxed SELinux type, and --device /dev/fuse) — the same
# "needs a privilege the phase tool won't inject" case as micro-linux/muxup.
#
# Usage:
#   ./build-minimal.sh [--base centos|rhel] [--tag TAG] [--no-cache]
#
#   --base centos   (default) build Containerfile.centos on CentOS Stream 9 bootc
#                   — freely pullable, no subscription.  VERIFIED path.
#   --base rhel     build Containerfile.rhel on registry.redhat.io/rhel9/rhel-bootc
#                   — needs an active Red Hat subscription + `podman login
#                   registry.redhat.io`, and a heredoc-aware builder (podman >= 5).
#   --tag TAG       image tag (default: localhost/bootc-minimal:<base>)
#   --no-cache      pass --no-cache to podman build
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
base="centos"
tag=""
nocache=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base)     base="${2:?--base needs centos|rhel}"; shift 2 ;;
        --tag)      tag="${2:?--tag needs a value}";        shift 2 ;;
        --no-cache) nocache=(--no-cache);                   shift   ;;
        -h|--help)  sed -n '2,25p' "${BASH_SOURCE[0]}";     exit 0  ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

case "$base" in
    centos) cf="$here/Containerfile.centos" ;;
    rhel)   cf="$here/Containerfile.rhel" ;;
    *) echo "--base must be 'centos' or 'rhel' (got: $base)" >&2; exit 2 ;;
esac
[[ -r "$cf" ]] || { echo "missing Containerfile: $cf" >&2; exit 1; }
[[ -n "$tag" ]] || tag="localhost/bootc-minimal:$base"

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }

echo "==> building $tag from $(basename "$cf")"
echo "    privileges (tutorial §9.3): --cap-add=all --security-opt=label=type:container_runtime_t --device /dev/fuse"
# A build context is required; the Containerfile pulls everything from registries,
# so an empty context (this dir) is fine.
podman build "${nocache[@]}" \
    -f "$cf" \
    -t "$tag" \
    --cap-add=all \
    --security-opt=label=type:container_runtime_t \
    --device /dev/fuse \
    "$here"

echo
echo "==> built: $tag"
podman image inspect "$tag" --format '    size: {{.Size}} bytes' 2>/dev/null || true
echo "==> verifying contents (bootc, dnf, kernel, sshd):"
podman run --rm "$tag" sh -c '
    for b in bootc dnf sshd; do printf "    %-7s " "$b:"; command -v "$b" || echo MISSING; done
    printf "    %-7s " "kernel:"; ls /usr/lib/modules/*/vmlinuz 2>/dev/null || echo MISSING
'
echo "==> bootc container lint:"
podman run --rm "$tag" bootc container lint && echo "    lint OK"
echo
echo "Next: turn this image into a bootable disk and run it — see RUNBOOK.md \"Boot it\"."
