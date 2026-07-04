#!/usr/bin/env bash
# build-debian-vm.sh — drive debos to bake a bootable Debian VM image, choosing
#                      WHERE the build runs.  The Debian twin of kali-vm-builder,
#                      but pointed at debos DIRECTLY (kali-vm is just a wrapper
#                      around debos, which is itself a Debian project).
#
# It: (1) picks an engine — the official debos CONTAINER (podman/docker, no host
# debos needed) or host-native `debos`; (2) runs `debian-vm.yaml` (which spins up
# debos's own KVM build VM via fakemachine and assembles a partitioned image);
# (3) converts the resulting .img → qcow2 and points you at run-graphical.sh.
#
# Usage:
#   examples/debian-vm-builder/build-debian-vm.sh [options]
#
# Engine:
#   --engine auto|container|podman|docker|host   Default: auto
#                 auto      = container (podman→docker) if /dev/kvm + an engine
#                             are present, else host-native debos.
#                 container = the official ghcr.io/go-debos/debos image (podman→docker)
#                 podman/docker = force that container engine
#                 host      = run host `debos` directly (needs debos + /dev/kvm)
#
# Image knobs:
#   --suite NAME    Debian suite      (default: trixie)
#   --desktop DE    add a desktop: none|xfce|gnome|kde|mate|lxqt (default: none)
#   --disksize SZ   image size        (default: 6G; use 12G+ for --desktop)
#   --mirror URL    apt mirror        (default: http://deb.debian.org/debian/)
#   --workdir DIR   where the recipe + image are built (default: $DEBIAN_VM_DIR
#                   or ~/debian-vm-build). Needs a few GB free.
#   --keep-img      keep the raw .img alongside the .qcow2 (default: remove it)
#   --image TAG     debos container image (default: ghcr.io/go-debos/debos:main)
#   --help          show this help and exit
#
# Output:  <workdir>/debian-vm.qcow2   (boot it with run-graphical.sh)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR RECIPE="debian-vm.yaml"

# Under sudo, default the workdir to the invoking user's home (root's $HOME would
# strand the image where your normal user can't read it).
if [ -n "${DEBIAN_VM_DIR:-}" ]; then WORKDIR="$DEBIAN_VM_DIR"
elif [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    WORKDIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/debian-vm-build"
else WORKDIR="$HOME/debian-vm-build"; fi

ENGINE="auto" SUITE="trixie" DESKTOP="none" DISKSIZE="6G"
MIRROR="http://deb.debian.org/debian/" KEEP_IMG=0
IMAGE="ghcr.io/go-debos/debos:main"

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[build]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[build] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[build] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR>1{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --engine)   ENGINE="${2:?}"; shift 2 ;;
        --suite)    SUITE="${2:?}"; shift 2 ;;
        --desktop)  DESKTOP="${2:?}"; shift 2 ;;
        --disksize) DISKSIZE="${2:?}"; shift 2 ;;
        --mirror)   MIRROR="${2:?}"; shift 2 ;;
        --workdir)  WORKDIR="${2:?}"; shift 2 ;;
        --keep-img) KEEP_IMG=1; shift ;;
        --image)    IMAGE="${2:?}"; shift 2 ;;
        --help|-h)  usage 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done
case "$ENGINE" in auto|container|podman|docker|host) ;; *) die "invalid --engine '$ENGINE'" ;; esac

have() { command -v "$1" >/dev/null 2>&1; }

# ── Resolve the engine ───────────────────────────────────────────────────────
resolve_auto() {
    if [ -e /dev/kvm ] && have podman; then echo podman
    elif [ -e /dev/kvm ] && have docker; then echo docker
    elif have debos; then echo host
    elif have podman; then echo podman
    else die "no usable engine: install podman/docker (for the debos container) or host 'debos', and ensure /dev/kvm exists"; fi
}
case "$ENGINE" in
    auto)      ENGINE="$(resolve_auto)" ;;
    container) if have podman; then ENGINE=podman; elif have docker; then ENGINE=docker; else die "--engine container needs podman or docker"; fi ;;
esac
log "engine: $ENGINE   suite: $SUITE   desktop: $DESKTOP   disksize: $DISKSIZE"

[ -e /dev/kvm ] || warn "/dev/kvm is missing — debos's fakemachine build VM needs KVM; the build will likely fail"
if [ "$ENGINE" != host ] && [ -e /dev/kvm ] && ! id -nG | tr ' ' '\n' | grep -qx kvm; then
    warn "you are not in the 'kvm' group — container KVM access may be denied (sudo adduser \$USER kvm; re-login)"
fi
[ "$ENGINE" = host ] && { have debos || die "host engine needs 'debos' (not packaged everywhere — prefer --engine container)"; }

# ── Stage the recipe into the workdir (debos needs it in the bind-mounted dir) ─
mkdir -p "$WORKDIR"
cp -f "$SCRIPT_DIR/$RECIPE" "$WORKDIR/$RECIPE"

DEBOS_ARGS=(-t "suite:$SUITE" -t "disksize:$DISKSIZE" -t "mirror:$MIRROR" -t "desktop:$DESKTOP" "$RECIPE")

log "building $WORKDIR/debian-vm.img  (debos debootstraps $SUITE + installs a kernel + systemd-boot; a few minutes + a few hundred MB of downloads)"
case "$ENGINE" in
    host)
        ( cd "$WORKDIR" && debos "${DEBOS_ARGS[@]}" ) || die "debos (host) build failed — see output above" ;;
    podman|docker)
        "$ENGINE" run --rm --device /dev/kvm --user "$(id -u)" --workdir /recipes \
            --mount "type=bind,source=$WORKDIR,destination=/recipes" \
            --security-opt label=disable "$IMAGE" "${DEBOS_ARGS[@]}" \
            || die "debos ($ENGINE container) build failed — see output above" ;;
esac

IMG="$WORKDIR/debian-vm.img"
[ -f "$IMG" ] || die "debos finished but no image at $IMG"

# ── Convert to qcow2 (compact, what run-graphical.sh boots) ──────────────────
have qemu-img || die "qemu-img not found (sudo apt install -y qemu-utils) — the raw image is at $IMG"
QCOW="$WORKDIR/debian-vm.qcow2"
log "converting → $QCOW"
qemu-img convert -f raw -O qcow2 "$IMG" "$QCOW"
[ "$KEEP_IMG" -eq 1 ] || rm -f "$IMG"

# Hand root-built artifacts back to the invoking user.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown "$SUDO_USER" "$QCOW" 2>/dev/null || warn "could not chown $QCOW to $SUDO_USER"
fi

log "done: $QCOW ($(du -h "$QCOW" 2>/dev/null | cut -f1 || echo '?') on disk)"
log "boot it graphically:   examples/debian-vm-builder/run-graphical.sh --image $QCOW"
log "  (login: debian / debian, or root / lab)"
