#!/usr/bin/env bash
# fetch-kali-vm.sh — clone/update the upstream Kali VM image builder (kali-vm)
#                    into a local work directory, ready for build-kali-vm.sh.
#
# Upstream: https://gitlab.com/kalilinux/build-scripts/kali-vm
#   kali-vm builds the *official* Kali VM images with `debos` (which itself
#   spins up a QEMU/KVM build VM via fakemachine).  We keep a CHECKOUT — not the
#   artifacts — under a work dir OUTSIDE this repo, because a build writes a
#   multi-GB image into its own images/ plus a ~45 GB scratch area.
#
# Usage:
#   examples/kali-vm-builder/fetch-kali-vm.sh [--workdir DIR] [--ref REF] [--force]
#
# Options:
#   --workdir DIR  Where to keep the checkout. Default: $KALI_VM_DIR or
#                  $HOME/kali-vm-build. The checkout lands in <workdir>/kali-vm.
#                  Put this on a disk with tens of GB free (e.g. a roomy drive).
#   --ref REF      git ref/branch/tag to check out. Default: main
#   --url URL      upstream repo URL. Default: the GitLab kali-vm repo
#   --force        re-clone from scratch even if the checkout already exists
#   --help         show this help and exit

set -euo pipefail

URL_DEFAULT="https://gitlab.com/kalilinux/build-scripts/kali-vm.git"
WORKDIR="${KALI_VM_DIR:-$HOME/kali-vm-build}"
REF="main"
URL="$URL_DEFAULT"
FORCE=0

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[fetch]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[fetch] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[fetch] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir) WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --ref)     REF="${2:?--ref needs a value}";        shift 2 ;;
        --url)     URL="${2:?--url needs a value}";         shift 2 ;;
        --force)   FORCE=1; shift ;;
        --help|-h) usage 0 ;;
        *)         die "unknown argument: $1  (try --help)" ;;
    esac
done

command -v git >/dev/null || die "git not found — install it (sudo apt install -y git)"

CHECKOUT="$WORKDIR/kali-vm"

if [ "$FORCE" -eq 1 ] && [ -d "$CHECKOUT" ]; then
    log "removing existing checkout (--force): $CHECKOUT"
    rm -rf "$CHECKOUT"
fi

mkdir -p "$WORKDIR"

if [ -d "$CHECKOUT/.git" ]; then
    log "updating existing checkout: $CHECKOUT"
    git -C "$CHECKOUT" fetch --depth 1 origin "$REF"
    git -C "$CHECKOUT" checkout -q "$REF"
    # Fast-forward if REF is a branch (a tag/sha will already be at FETCH_HEAD).
    git -C "$CHECKOUT" merge --ff-only FETCH_HEAD >/dev/null 2>&1 || :
else
    log "cloning $URL (ref: $REF) → $CHECKOUT"
    git clone --depth 1 --branch "$REF" "$URL" "$CHECKOUT" 2>/dev/null \
        || git clone --depth 1 "$URL" "$CHECKOUT"   # fallback if REF is a sha
fi

HEAD_SHA="$(git -C "$CHECKOUT" rev-parse --short HEAD)"
log "ready: $CHECKOUT @ $HEAD_SHA"
[ -x "$CHECKOUT/build.sh" ] || warn "build.sh not found/executable in the checkout — upstream layout may have changed"
printf '%s\n' "$CHECKOUT"
