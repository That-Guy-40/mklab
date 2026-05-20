#!/usr/bin/env bash
# build-ipxe.sh — Build iPXE from source inside Docker and package outputs.
#
# The build runs inside a Debian bookworm container so the host is not
# polluted with compiler toolchains.  After Docker exits the USB image is
# converted to qcow2 for Phase 2 QEMU booting.
#
# Usage:
#   netboot/build-ipxe.sh \
#       --server http://10.0.2.2:8080 \
#       [--kernel-path /kernel] \
#       [--initrd-path /initrd.gz] \
#       [--append "console=ttyS0 root=/dev/ram0 rw"] \
#       [--output-dir /srv/netboot] \
#       [--arch x86_64|aarch64] \
#       [--ipxe-ref master]
#
# Outputs (in --output-dir):
#   boot.ipxe     plain-text chainboot script (served by nginx / Phase 4 podman)
#   ipxe.usb      raw disk image  →  dd if=ipxe.usb of=/dev/sdX
#   ipxe.efi      UEFI binary     →  copy to EFI partition
#   ipxe.qcow2    qcow2 of usb   →  Phase 2 QEMU -drive file=ipxe.qcow2
#
# Requires:
#   docker   (running daemon)
#   qemu-img (for qcow2 conversion; skipped with a warning if absent)
#
# Examples:
#   # QEMU slirp simulation (host is 10.0.2.2 from inside the guest):
#   netboot/build-ipxe.sh --server http://10.0.2.2:8080
#
#   # Real hardware on LAN:
#   netboot/build-ipxe.sh --server http://192.168.1.10:8080 --arch x86_64

set -euo pipefail

readonly LAB_PROG="${0##*/}"
# Resolve the directory containing this script so we can pass it into Docker
# even when called from a different working directory.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_DIR

# ─── Logging ────────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
            *)     color='' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

# ─── Usage ──────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: netboot/build-ipxe.sh [OPTIONS]

Build iPXE from source inside a Debian Docker container and produce USB,
EFI, and qcow2 boot images along with a plain-text boot.ipxe script.

Options:
  --server      URL   HTTP server seen by the booting machine
                      (default: http://10.0.2.2:8080  — QEMU slirp host)
  --kernel-path PATH  URL path to the kernel   (default: /kernel)
  --initrd-path PATH  URL path to the initrd   (default: /initrd.gz)
  --append      STR   kernel command-line args  (default: "console=ttyS0 root=/dev/ram0 rw")
                      Use the literal placeholder {MAC} to embed the booting
                      NIC's MAC address at runtime.  At build time {MAC} is
                      rewritten to the iPXE variable ${mac:hexhyp}; iPXE then
                      expands it to the lowercase hyphen-separated MAC of the
                      booting interface (e.g. 52-54-00-al-ma-01).
                      Example (per-host AlmaLinux kickstart):
                        --append 'inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks'
  --output-dir  PATH  where to write outputs   (default: /srv/netboot)
  --arch        ARCH  x86_64 or aarch64        (default: x86_64)
  --ipxe-ref    REF   git branch/tag/SHA to build from (default: master)
  --help              show this help and exit

Outputs written to --output-dir:
  boot.ipxe   chainboot script (serve this via nginx)
  ipxe.usb    raw USB disk image (dd to a USB stick)
  ipxe.efi    UEFI binary
  ipxe.qcow2  qcow2 conversion of ipxe.usb (Phase 2 QEMU)

Examples:
  netboot/build-ipxe.sh --server http://10.0.2.2:8080
  netboot/build-ipxe.sh --server http://192.168.1.10:8080 --arch aarch64
  netboot/build-ipxe.sh --server http://10.0.2.2:8080 --ipxe-ref v1.21.1
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
server="http://10.0.2.2:8080"
kernel_path="/kernel"
initrd_path="/initrd.gz"
append="console=ttyS0 root=/dev/ram0 rw"
output_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"
arch="x86_64"
ipxe_ref="master"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)      shift; server="${1:?--server requires a URL}";         shift ;;
        --kernel-path) shift; kernel_path="${1:?--kernel-path requires a path}"; shift ;;
        --initrd-path) shift; initrd_path="${1:?--initrd-path requires a path}"; shift ;;
        --append)      shift; append="${1:?--append requires a string}";      shift ;;
        --output-dir)  shift; output_dir="${1:?--output-dir requires a path}"; shift ;;
        --arch)        shift; arch="${1:?--arch requires x86_64 or aarch64}"; shift ;;
        --ipxe-ref)    shift; ipxe_ref="${1:?--ipxe-ref requires a git ref}"; shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Validate arch ──────────────────────────────────────────────────────────
case "$arch" in
    x86_64|aarch64) ;;
    *) die "unsupported arch '$arch': choose x86_64 or aarch64" ;;
esac

# ─── Pre-flight checks ──────────────────────────────────────────────────────
log_info "checking Docker daemon..."
if ! docker info &>/dev/null; then
    die "Docker daemon is not running or not accessible.
  Start it with:  sudo systemctl start docker
  Or ensure your user is in the 'docker' group:  sudo usermod -aG docker \$USER"
fi
log_info "Docker OK"

mkdir -p "$output_dir"

# ─── Build iPXE inside Docker ────────────────────────────────────────────────
# boot.ipxe is written by ipxe-build-inner.sh and copied to /out/boot.ipxe.
log_info "starting Docker build (arch=$arch ref=$ipxe_ref) — this takes several minutes..."
log_info "  output dir : $output_dir"
log_info "  build ctx  : $SCRIPT_DIR"

docker run --rm \
    -v "$output_dir:/out" \
    -v "$SCRIPT_DIR:/build-ctx:ro" \
    debian:bookworm \
    bash /build-ctx/ipxe-build-inner.sh \
        "$server" "$kernel_path" "$initrd_path" "$append" "$arch" "$ipxe_ref"

# ─── Convert USB image to qcow2 ──────────────────────────────────────────────
if command -v qemu-img &>/dev/null; then
    if [[ -f "$output_dir/ipxe.usb" ]]; then
        log_info "converting ipxe.usb → ipxe.qcow2 (for Phase 2 QEMU boot)..."
        qemu-img convert -f raw -O qcow2 "$output_dir/ipxe.usb" "$output_dir/ipxe.qcow2"
        log_info "converted: $output_dir/ipxe.qcow2"
    else
        log_warn "ipxe.usb not found; skipping qcow2 conversion (aarch64 only produces EFI)"
    fi
else
    log_warn "qemu-img not found; skipping qcow2 conversion"
    log_warn "  install with:  sudo apt-get install qemu-utils"
    log_warn "  or use:        dd if=$output_dir/ipxe.usb of=/dev/sdX  (USB only)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "build complete — outputs in $output_dir:"
for f in boot.ipxe ipxe.usb ipxe.efi ipxe.qcow2; do
    fp="$output_dir/$f"
    if [[ -f "$fp" ]]; then
        size=$(du -sh "$fp" 2>/dev/null | cut -f1)
        log_info "  $f  ($size)"
    fi
done
log_info ""
log_info "next steps:"
log_info "  QEMU (Phase 2):    lab-vm.sh --disk $output_dir/ipxe.qcow2"
log_info "  USB (real hw):     sudo dd if=$output_dir/ipxe.usb of=/dev/sdX bs=4M status=progress"
log_info "  Serve artifacts:   lab-podman.sh (Phase 4 nginx on :8080)"
