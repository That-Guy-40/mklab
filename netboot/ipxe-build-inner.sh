#!/usr/bin/env bash
# ipxe-build-inner.sh — Build iPXE inside a Debian bookworm Docker container.
#
# This script is called BY build-ipxe.sh via `docker run`.  Do not invoke it
# directly on the host — it expects a container environment and writes its
# outputs to /out/ (which is bind-mounted from the host's --output-dir).
#
# Args (positional, set by build-ipxe.sh):
#   $1  server_url   e.g. http://10.0.2.2:8080
#   $2  kernel_path  e.g. /kernel
#   $3  initrd_path  e.g. /initrd.gz
#   $4  append       e.g. "console=ttyS0 root=/dev/ram0 rw"
#   $5  arch         x86_64 | aarch64
#   $6  ipxe_ref     git branch/tag/SHA  e.g. master
#
# Outputs written to /out/:
#   boot.ipxe   embedded boot script (copy of what was compiled in)
#   ipxe.usb    raw USB disk image   (x86_64 only)
#   ipxe.efi    UEFI binary          (both arches)

set -euo pipefail

# ─── Logging (no colour needed inside Docker, but keep parity) ───────────────
_log() {
    local level="$1"; shift
    printf '[%s] %s\n' "$level" "$*" >&2
}
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

# ─── Args ───────────────────────────────────────────────────────────────────
server_url="${1:?arg 1 (server_url) is required}"
kernel_path="${2:?arg 2 (kernel_path) is required}"
initrd_path="${3:?arg 3 (initrd_path) is required}"
append="${4:?arg 4 (append) is required}"
arch="${5:?arg 5 (arch) is required}"
ipxe_ref="${6:?arg 6 (ipxe_ref) is required}"

log_info "ipxe-build-inner starting"
log_info "  server_url  : $server_url"
log_info "  kernel_path : $kernel_path"
log_info "  initrd_path : $initrd_path"
log_info "  append      : $append"
log_info "  arch        : $arch"
log_info "  ipxe_ref    : $ipxe_ref"

# ─── Validate arch ──────────────────────────────────────────────────────────
case "$arch" in
    x86_64|aarch64) ;;
    *) die "unsupported arch '$arch': choose x86_64 or aarch64" ;;
esac

# ─── Install build dependencies ─────────────────────────────────────────────
log_info "installing build dependencies..."
apt-get update -qq
apt-get install -y -qq \
    gcc make git liblzma-dev mtools perl \
    isolinux syslinux binutils wget ca-certificates

# aarch64 cross-compilation deps (not needed for native x86_64 inside Docker)
if [[ "$arch" == "aarch64" ]]; then
    apt-get install -y -qq gcc-aarch64-linux-gnu
fi

# ─── Clone iPXE ─────────────────────────────────────────────────────────────
log_info "cloning iPXE (ref=$ipxe_ref)..."

# Try shallow clone of the branch/tag directly; fall back to a full-depth
# clone + checkout for arbitrary SHAs (shallow clone can't target a bare SHA).
if git clone --depth 1 --branch "$ipxe_ref" https://github.com/ipxe/ipxe.git /tmp/ipxe 2>/dev/null; then
    log_info "cloned branch/tag '$ipxe_ref' (shallow)"
else
    log_warn "shallow branch clone failed; trying full clone + checkout (may be a SHA ref)..."
    if ! git clone https://github.com/ipxe/ipxe.git /tmp/ipxe; then
        die "git clone failed — check network connectivity inside Docker"
    fi
    git -C /tmp/ipxe checkout "$ipxe_ref" \
        || die "git checkout '$ipxe_ref' failed — is '$ipxe_ref' a valid iPXE ref?"
    log_info "checked out ref '$ipxe_ref'"
fi

# ─── Write embedded boot script ─────────────────────────────────────────────
log_info "writing embedded boot script to /tmp/ipxe/src/boot.ipxe"
cat > /tmp/ipxe/src/boot.ipxe <<EOF
#!ipxe
dhcp
kernel ${server_url}${kernel_path} ${append}
initrd ${server_url}${initrd_path}
boot
EOF

# Rewrite the {MAC} placeholder (written literally by the caller via --append)
# to the iPXE runtime variable ${mac:hexhyp}, which iPXE expands at boot to
# the lowercase hyphen-separated MAC of the booting NIC (e.g. 52-54-00-al-ma-01).
# This must happen after the heredoc because bash would eat ${mac:hexhyp} at
# write time if it appeared directly in an unquoted heredoc.
sed -i 's/{MAC}/${mac:hexhyp}/g' /tmp/ipxe/src/boot.ipxe

# ─── Build ──────────────────────────────────────────────────────────────────
JOBS=$(nproc)
log_info "building iPXE with -j${JOBS} (arch=$arch)..."

cd /tmp/ipxe/src

case "$arch" in
    x86_64)
        make -j"${JOBS}" EMBED=boot.ipxe bin/ipxe.usb bin-x86_64-efi/ipxe.efi \
            || die "iPXE make failed for x86_64"
        ;;
    aarch64)
        # Cross-compile: set CROSS_COMPILE so iPXE's Makefile picks up the
        # aarch64 toolchain installed above.
        make -j"${JOBS}" EMBED=boot.ipxe \
            CROSS_COMPILE=aarch64-linux-gnu- \
            bin-arm64-efi/ipxe.efi \
            || die "iPXE make failed for aarch64"
        ;;
esac

# ─── Copy outputs to /out/ ──────────────────────────────────────────────────
log_info "copying outputs to /out/"

# The embedded boot.ipxe is always copied so the host can inspect/serve it.
cp /tmp/ipxe/src/boot.ipxe /out/boot.ipxe
log_info "  /out/boot.ipxe"

case "$arch" in
    x86_64)
        cp /tmp/ipxe/src/bin/ipxe.usb          /out/ipxe.usb
        cp /tmp/ipxe/src/bin-x86_64-efi/ipxe.efi /out/ipxe.efi
        log_info "  /out/ipxe.usb"
        log_info "  /out/ipxe.efi"
        ;;
    aarch64)
        cp /tmp/ipxe/src/bin-arm64-efi/ipxe.efi /out/ipxe.efi
        log_info "  /out/ipxe.efi  (arm64; no USB image for aarch64)"
        ;;
esac

log_info "ipxe-build-inner done"
