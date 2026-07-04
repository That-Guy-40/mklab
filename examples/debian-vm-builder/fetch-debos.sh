#!/usr/bin/env bash
# fetch-debos.sh — make debos available for build-debian-vm.sh.
#
# The Debian analog of fetch-kali-vm.sh — but there's no big repo to clone:
# debos IS the tool (kali-vm merely wraps it).  So "fetching" debos means either
# pulling the official CONTAINER image (the recommended, no-host-install path) or
# checking for a host `debos`.  build-debian-vm.sh will also pull the image on
# first run; this is here to pre-pull it (and to pin an image tag).
#
# Usage:
#   examples/debian-vm-builder/fetch-debos.sh [--image TAG] [--engine podman|docker] [--check-host]
#
# Options:
#   --image TAG     debos container image (default: ghcr.io/go-debos/debos:main)
#   --engine E      podman (default) | docker
#   --check-host    just report whether a host `debos` + /dev/kvm are present
#   --help          show this help and exit
#
# Upstream: https://github.com/go-debos/debos   (Apache-2.0; a Debian project)

set -euo pipefail

IMAGE="ghcr.io/go-debos/debos:main"
ENGINE="podman"
CHECK_HOST=0

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[fetch]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[fetch] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[fetch] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --image)      IMAGE="${2:?}"; shift 2 ;;
        --engine)     ENGINE="${2:?}"; shift 2 ;;
        --check-host) CHECK_HOST=1; shift ;;
        --help|-h)    usage 0 ;;
        *)            die "unknown argument: $1  (try --help)" ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

[ -e /dev/kvm ] && log "/dev/kvm present" || warn "/dev/kvm missing — debos's build VM needs it"

if [ "$CHECK_HOST" -eq 1 ]; then
    if have debos; then log "host debos: $(command -v debos)  ($(debos --version 2>/dev/null | head -1 || echo 'version unknown'))"
    else warn "no host 'debos' — use the container path (default) or build it from source (Go)"; fi
    exit 0
fi

have "$ENGINE" || die "engine '$ENGINE' not installed — install podman or docker (or use host debos)"

log "pulling debos container image: $IMAGE  (via $ENGINE)"
"$ENGINE" pull "$IMAGE" || die "could not pull $IMAGE"

# Record the digest we pinned to, for reproducibility.
digest="$("$ENGINE" image inspect "$IMAGE" --format '{{ index .RepoDigests 0 }}' 2>/dev/null || :)"
log "ready: ${digest:-$IMAGE}"
log "next: examples/debian-vm-builder/build-debian-vm.sh"
