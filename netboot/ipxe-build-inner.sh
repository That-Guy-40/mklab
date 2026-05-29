#!/usr/bin/env bash
# ipxe-build-inner.sh — Build iPXE inside a Debian bookworm Docker container.
#
# This script is called BY build-ipxe.sh via `docker run`.  Do not invoke it
# directly on the host — it expects a container environment and writes its
# outputs to /out/ (which is bind-mounted from the host's --output-dir).
#
# Args (positional, set by build-ipxe.sh):
#   $1  server_url   e.g. http://10.0.2.2:8080  or  https://
#   $2  kernel_path  e.g. /kernel
#   $3  initrd_path  e.g. /initrd.gz
#   $4  append       e.g. "console=ttyS0 root=/dev/ram0 rw"
#   $5  arch         x86_64 | aarch64 | riscv64
#   $6  ipxe_ref     git branch/tag/SHA  e.g. master
#   $7  tls_mode     "1" to compile with HTTPS support (DOWNLOAD_PROTO_HTTPS)
#   $8  cert_path    DER cert to embed in trust store (empty = none)
#
# Outputs written to /out/:
#   boot.ipxe   embedded boot script (copy of what was compiled in)
#   ipxe.usb    raw USB disk image   (x86_64 only)
#   ipxe.efi    UEFI binary          (all arches)

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
tls_mode="${7:-}"
cert_path="${8:-}"

log_info "ipxe-build-inner starting"
log_info "  server_url  : $server_url"
log_info "  kernel_path : $kernel_path"
log_info "  initrd_path : $initrd_path"
log_info "  append      : $append"
log_info "  arch        : $arch"
log_info "  ipxe_ref    : $ipxe_ref"

# ─── Validate arch ──────────────────────────────────────────────────────────
case "$arch" in
    x86_64|aarch64|riscv64) ;;
    *) die "unsupported arch '$arch': choose x86_64, aarch64, or riscv64" ;;
esac

# ─── Install build dependencies ─────────────────────────────────────────────
log_info "installing build dependencies..."
apt-get update -qq
apt-get install -y -qq \
    gcc make git liblzma-dev mtools perl \
    isolinux syslinux binutils wget ca-certificates

# Cross-compilation toolchains for non-x86 arches.
if [[ "$arch" == "aarch64" ]]; then
    apt-get install -y -qq gcc-aarch64-linux-gnu
elif [[ "$arch" == "riscv64" ]]; then
    apt-get install -y -qq gcc-riscv64-linux-gnu
fi
# HTTPS support needs the OpenSSL dev headers inside the container.
if [[ -n "$tls_mode" ]]; then
    apt-get install -y -qq libssl-dev
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

# ─── Patch iPXE config for HTTPS (if requested) ─────────────────────────────
if [[ -n "$tls_mode" ]]; then
    log_info "enabling HTTPS download support in iPXE config..."
    # iPXE ships a per-feature config in src/config/general.h.  Override it by
    # adding a local config header that undef/redefines the relevant symbol.
    mkdir -p /tmp/ipxe/src/config/local
    cat > /tmp/ipxe/src/config/local/general.h <<'IPXECFG'
/* local/general.h: compiled-in overrides for this lab build. */
#include <config/general.h>
#undef  DOWNLOAD_PROTO_HTTPS
#define DOWNLOAD_PROTO_HTTPS
IPXECFG
    log_info "  DOWNLOAD_PROTO_HTTPS enabled"
fi

# If a DER cert was provided, embed it in the iPXE trust store.
if [[ -n "$cert_path" && -f "$cert_path" ]]; then
    log_info "embedding trust cert: $cert_path"
    mkdir -p /tmp/ipxe/src/config/local
    cat >> /tmp/ipxe/src/config/local/general.h <<'IPXETRUST'
#undef  CERT_CMD
#define CERT_CMD
IPXETRUST
    cp "$cert_path" /tmp/ipxe/src/config/certstore.der
    # The CERTSTORE macro points iPXE to the DER bytes to compile in.
    EXTRA_MAKE_FLAGS="CERTSTORE=/tmp/ipxe/src/config/certstore.der"
    log_info "  embedded cert in trust store"
fi

# ─── Write embedded boot script ─────────────────────────────────────────────
# Collapse every run of whitespace in --append (incl. stray newlines/tabs that
# sneak in when a long single-quoted --append is copy-pasted out of a wrapped
# terminal/markdown line) down to single spaces.  Without this, an embedded
# newline splits the `kernel` command across two iPXE script lines and the tail
# (e.g. "console=ttyS0 ip=dhcp") is parsed as a bogus command, aborting the boot.
append_oneline="$(printf '%s' "$append" | tr '\n\t' '  ' | tr -s ' ')"
append_oneline="${append_oneline#"${append_oneline%%[![:space:]]*}"}"   # ltrim
append_oneline="${append_oneline%"${append_oneline##*[![:space:]]}"}"   # rtrim

# Retry loop instead of a one-shot `dhcp`: a single transient DHCP/HTTP failure
# (e.g. the NIC re-initialising over UNDI after a binary chainload) would abort
# the whole script and drop back to the BIOS boot order ("No bootable device").
# Looping re-attempts every 3s; once `boot` succeeds the kernel takes over and
# the loop is never reached.
log_info "writing embedded boot script to /tmp/ipxe/src/boot.ipxe"
cat > /tmp/ipxe/src/boot.ipxe <<EOF
#!ipxe
:start
dhcp || goto retry
kernel ${server_url}${kernel_path} ${append_oneline} || goto retry
initrd ${server_url}${initrd_path} || goto retry
boot || goto retry
:retry
echo iPXE boot step failed -- retrying in 3s
sleep 3
goto start
EOF

# Rewrite the {MAC} placeholder (written literally by the caller via --append)
# to the iPXE runtime variable ${mac:hexhyp}, which iPXE expands at boot to
# the lowercase hyphen-separated MAC of the booting NIC (e.g. 52-54-00-a1-9a-01).
# This must happen after the heredoc because bash would eat ${mac:hexhyp} at
# write time if it appeared directly in an unquoted heredoc.
sed -i 's/{MAC}/${mac:hexhyp}/g' /tmp/ipxe/src/boot.ipxe

# ─── Build ──────────────────────────────────────────────────────────────────
JOBS=$(nproc)
log_info "building iPXE with -j${JOBS} (arch=$arch)..."

cd /tmp/ipxe/src

EXTRA_MAKE_FLAGS="${EXTRA_MAKE_FLAGS:-}"
case "$arch" in
    x86_64)
        # ipxe.hd = bootable HARD-DISK image (the right one for booting iPXE off a
        # virtio-blk disk under SeaBIOS); ipxe.usb is the USB-stick image, which
        # SeaBIOS can fail to boot as an HDD ("could not read the boot disk").
        # ipxe.efi = the UEFI binary (slirp-TFTP / ESP boot).
        # ipxe.pxe = a BIOS PXE NBP (network bootstrap program).  Served over
        #   slirp TFTP and chainloaded by the NIC's stock PXE ROM, it's the BIOS
        #   analogue of ipxe.efi for the pxe-install backend (SeaBIOS reaches it
        #   via "Booting from ROM" → TFTP → our iPXE + embedded script).
        # shellcheck disable=SC2086
        make -j"${JOBS}" EMBED=boot.ipxe $EXTRA_MAKE_FLAGS \
            bin/ipxe.hd bin/ipxe.usb bin/ipxe.pxe bin-x86_64-efi/ipxe.efi \
            || die "iPXE make failed for x86_64"
        ;;
    aarch64)
        # Cross-compile: set CROSS_COMPILE so iPXE's Makefile picks up the
        # aarch64 toolchain installed above.
        # shellcheck disable=SC2086
        make -j"${JOBS}" EMBED=boot.ipxe \
            CROSS_COMPILE=aarch64-linux-gnu- \
            $EXTRA_MAKE_FLAGS \
            bin-arm64-efi/ipxe.efi \
            || die "iPXE make failed for aarch64"
        ;;
    riscv64)
        # RISC-V EFI: cross-compile with the riscv64-linux-gnu toolchain.
        # iPXE uses ARCH=riscv for its internal arch name.
        # Note: riscv64 iPXE support is experimental upstream; requires a
        # recent iPXE commit (2023+).  Use --ipxe-ref master or a recent tag.
        # shellcheck disable=SC2086
        make -j"${JOBS}" EMBED=boot.ipxe \
            CROSS_COMPILE=riscv64-linux-gnu- \
            ARCH=riscv \
            $EXTRA_MAKE_FLAGS \
            bin-riscv-efi/ipxe.efi \
            || die "iPXE make failed for riscv64"
        ;;
esac

# ─── Copy outputs to /out/ ──────────────────────────────────────────────────
log_info "copying outputs to /out/"

# The embedded boot.ipxe is always copied so the host can inspect/serve it.
cp /tmp/ipxe/src/boot.ipxe /out/boot.ipxe
log_info "  /out/boot.ipxe"

case "$arch" in
    x86_64)
        cp /tmp/ipxe/src/bin/ipxe.hd              /out/ipxe.hd
        cp /tmp/ipxe/src/bin/ipxe.usb             /out/ipxe.usb
        cp /tmp/ipxe/src/bin/ipxe.pxe             /out/ipxe.pxe
        cp /tmp/ipxe/src/bin-x86_64-efi/ipxe.efi /out/ipxe.efi
        log_info "  /out/ipxe.hd"
        log_info "  /out/ipxe.usb"
        log_info "  /out/ipxe.pxe"
        log_info "  /out/ipxe.efi"
        ;;
    aarch64)
        cp /tmp/ipxe/src/bin-arm64-efi/ipxe.efi /out/ipxe.efi
        log_info "  /out/ipxe.efi  (arm64; no USB image for aarch64)"
        ;;
    riscv64)
        cp /tmp/ipxe/src/bin-riscv-efi/ipxe.efi /out/ipxe.efi
        log_info "  /out/ipxe.efi  (riscv64; no USB image for riscv64)"
        ;;
esac

log_info "ipxe-build-inner done"
