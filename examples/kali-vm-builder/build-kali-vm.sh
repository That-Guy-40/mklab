#!/usr/bin/env bash
# build-kali-vm.sh — drive the upstream Kali image factory (kali-vm) to produce
#                    a Kali VM image, choosing WHERE the build runs.
#
# This is a thin, lab-flavoured wrapper around kali-vm's own build.sh /
# build-in-container.sh.  It does three things:
#   1. ensures the upstream checkout exists (calls fetch-kali-vm.sh if missing),
#   2. picks an engine — host-native `debos`, or a Podman/Docker container,
#   3. expands a profile (--full / --headless) and runs the build, then points
#      you at run-graphical.sh for the result.
#
# Usage:
#   examples/kali-vm-builder/build-kali-vm.sh [options] [-- <extra kali-vm/debos args>]
#
# Engine:
#   --engine auto|host|podman|docker   Where the build runs. Default: auto
#                 auto   = container (podman→docker) if a /dev/kvm + engine is
#                          present, else host-native debos.
#                 host   = run kali-vm's build.sh directly (needs `debos` etc.)
#                 podman = run kali-vm's build-in-container.sh via Podman
#                 docker = same, forcing Docker
#
# Profile (mutually exclusive; default: --full):
#   --full        Full graphical image: -D xfce -T default   (the faithful Kali VM)
#   --headless    Lean image:           -D none -T headless -s 20
#
# Other:
#   --workdir DIR Where the checkout + images/ live (default: $KALI_VM_DIR or
#                 $HOME/kali-vm-build). Needs tens of GB free.
#   -y, --yes     Don't wait at kali-vm's confirmation prompt (pipe `yes`).
#   --help        show this help and exit
#
# Everything after a literal `--` is forwarded verbatim to build.sh, e.g.
#   build-kali-vm.sh --headless -- -P metasploit-framework -- --scratchsize=50G
#   (the variant defaults to `qemu` → a QCOW2; override with `-- -v generic` etc.)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${KALI_VM_DIR:-$HOME/kali-vm-build}"
ENGINE="auto"
PROFILE="full"
YES=0
PASSTHRU=()

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[build]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[build] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[build] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --engine)   ENGINE="${2:?--engine needs a value}"; shift 2 ;;
        --workdir)  WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --full)     PROFILE="full"; shift ;;
        --headless) PROFILE="headless"; shift ;;
        -y|--yes)   YES=1; shift ;;
        --help|-h)  usage 0 ;;
        --)         shift; PASSTHRU=("$@"); break ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

case "$ENGINE" in auto|host|podman|docker) ;; *) die "invalid --engine '$ENGINE'" ;; esac

# ── Profile → build.sh args.  -v qemu first so the default output is a QCOW2;
#    a `-v ...` in PASSTHRU comes later on the command line and wins. ──────────
BUILD_ARGS=(-v qemu)
case "$PROFILE" in
    full)     BUILD_ARGS+=(-D xfce -T default) ;;
    headless) BUILD_ARGS+=(-D none -T headless -s 20) ;;
esac
BUILD_ARGS+=("${PASSTHRU[@]}")

# ── Ensure the upstream checkout exists ──────────────────────────────────────
CHECKOUT="$WORKDIR/kali-vm"
if [ ! -x "$CHECKOUT/build.sh" ]; then
    log "no checkout at $CHECKOUT — fetching upstream"
    "$SCRIPT_DIR/fetch-kali-vm.sh" --workdir "$WORKDIR" >/dev/null
fi
[ -x "$CHECKOUT/build.sh" ] || die "kali-vm checkout missing build.sh: $CHECKOUT"

# ── Resolve the engine ───────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }
resolve_auto() {
    if [ -e /dev/kvm ] && have podman; then echo podman
    elif [ -e /dev/kvm ] && have docker; then echo docker
    elif have debos; then echo host
    elif have podman; then echo podman   # no kvm — let the engine surface the error
    else die "no usable engine: install 'debos' (host) or podman/docker (container), and ensure /dev/kvm exists"
    fi
}
[ "$ENGINE" = auto ] && ENGINE="$(resolve_auto)"
log "engine: $ENGINE   profile: $PROFILE"

# ── Pre-flight per engine ────────────────────────────────────────────────────
[ -e /dev/kvm ] || warn "/dev/kvm is missing — the debos build VM needs KVM; the build will likely fail"
case "$ENGINE" in
    host)
        have debos || die "host engine needs debos — install:
  sudo apt install -y 7zip debos dosfstools qemu-utils zerofree"
        for c in 7zr mkfs.fat qemu-img zerofree; do
            have "$c" || warn "host engine: '$c' not found (kali-vm may need it): part of 7zip/dosfstools/qemu-utils/zerofree"
        done
        ;;
    podman|docker)
        have "$ENGINE" || die "engine '$ENGINE' not installed"
        if [ -e /dev/kvm ] && ! id -nG | tr ' ' '\n' | grep -qx kvm; then
            warn "you are not in the 'kvm' group — container KVM access may be denied.
  Fix: sudo adduser \$USER kvm   (then log out/in)"
        fi
        ;;
esac

# ── Build ────────────────────────────────────────────────────────────────────
case "$ENGINE" in
    host)            RUNNER=(./build.sh) ;;
    podman)          RUNNER=(env CONTAINER=podman ./build-in-container.sh) ;;
    docker)          RUNNER=(env CONTAINER=docker ./build-in-container.sh) ;;
esac

log "running: ${RUNNER[*]} ${BUILD_ARGS[*]}   (cwd: $CHECKOUT)"
log "this is a long, multi-GB build (downloads a Kali package set; container path also builds a Kali image first)"

cd "$CHECKOUT"
if [ "$YES" -eq 1 ]; then
    yes | "${RUNNER[@]}" "${BUILD_ARGS[@]}"
else
    "${RUNNER[@]}" "${BUILD_ARGS[@]}"
fi

# ── Report the artifact + how to run it ──────────────────────────────────────
IMG="$(ls -t "$CHECKOUT"/images/kali-linux-*-qemu-amd64.qcow2 2>/dev/null | head -1 || :)"
if [ -n "$IMG" ]; then
    log "built image: $IMG"
    log "run it graphically:"
    printf '    %s --image %q\n' "$SCRIPT_DIR/run-graphical.sh" "$IMG" >&2
else
    warn "no kali-linux-*-qemu-amd64.qcow2 found in $CHECKOUT/images/ — check the build log above (different -v variant?)"
fi
