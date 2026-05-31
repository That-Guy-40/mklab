#!/usr/bin/env bash
# setup-netboot-dir.sh — One-time host setup for the LAB_CREATE_V2 netboot pipeline.
#
# Creates the artifact directory and an nginx MIME config snippet so that
# iPXE clients receive the correct Content-Type for .ipxe chainboot scripts.
#
# Usage:
#   sudo netboot/setup-netboot-dir.sh [--dir /srv/netboot] [--conf /etc/lab-netboot]
#
# Creates:
#   <dir>/                          world-readable; re-owned to the invoking user
#   <conf>/                         config directory
#   <conf>/ipxe-mime.conf           nginx types{} snippet for .ipxe MIME type
#
# Options:
#   --dir  PATH   artifact directory  (default: /srv/netboot)
#   --conf PATH   config directory    (default: /etc/lab-netboot)
#   --help        show this help
#
# Examples:
#   sudo netboot/setup-netboot-dir.sh
#   sudo netboot/setup-netboot-dir.sh --dir /data/netboot --conf /etc/lab-netboot

set -euo pipefail

readonly LAB_PROG="${0##*/}"

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
Usage: sudo netboot/setup-netboot-dir.sh [--dir PATH] [--conf PATH] [--help]

  --dir  PATH   artifact directory  (default: /srv/netboot)
  --conf PATH   config directory    (default: /etc/lab-netboot)
  --tls         generate a self-signed TLS cert + nginx ssl config snippet
  --help        show this help and exit

Examples:
  sudo netboot/setup-netboot-dir.sh
  sudo netboot/setup-netboot-dir.sh --dir /data/netboot --conf /etc/lab-netboot
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
NETBOOT_DIR="${LAB_NETBOOT_DIR:-$HOME/netboot}"
CONF_DIR="${LAB_NETBOOT_CONF:-$HOME/.config/lab-netboot}"
TLS_MODE=""

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)  shift; NETBOOT_DIR="${1:?--dir requires a path}"; shift ;;
        --conf) shift; CONF_DIR="${1:?--conf requires a path}";   shift ;;
        --tls)  TLS_MODE=1 ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Create directories ─────────────────────────────────────────────────────
# Defaults live under $HOME — no root needed. Override via --dir / --conf or
# LAB_NETBOOT_DIR / LAB_NETBOOT_CONF env vars if you prefer a system path.
# NOTE: snap Docker (Docker Root Dir = /var/snap/...) can only bind-mount
# paths under /home, /tmp, /media, /mnt. Using /srv or /etc requires
# non-snap Docker. The $HOME default avoids this issue entirely.
log_info "creating artifact directory: $NETBOOT_DIR"
mkdir -p "$NETBOOT_DIR"
chmod 755 "$NETBOOT_DIR"

log_info "creating config directory: $CONF_DIR"
mkdir -p "$CONF_DIR"

# ─── Write nginx MIME snippet ────────────────────────────────────────────────
MIME_CONF="$CONF_DIR/ipxe-mime.conf"
log_info "writing nginx MIME snippet: $MIME_CONF"
cat > "$MIME_CONF" <<'EOF'
# ipxe-mime.conf — volume-mounted into the nginx container by lab-podman.sh.
# No host nginx changes needed; the lab scripts handle the bind-mount.
# If you run a host nginx, add:  include <CONF_DIR>/ipxe-mime.conf;
types {
    application/x-ipxe  ipxe;
}
EOF

# ─── TLS cert + nginx ssl config (optional) ─────────────────────────────────
if [[ -n "$TLS_MODE" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
        log_warn "--tls requested but openssl not found; skipping cert generation"
        log_warn "  install with: apt-get install openssl"
    else
        CERT_PEM="$CONF_DIR/netboot.crt"
        KEY_PEM="$CONF_DIR/netboot.key"
        CERT_DER="$CONF_DIR/netboot.der"
        SSL_CONF="$CONF_DIR/ipxe-ssl.conf"
        if [[ ! -f "$CERT_PEM" ]]; then
            log_info "generating self-signed TLS cert: $CERT_PEM"
            openssl req -x509 -newkey rsa:4096 -keyout "$KEY_PEM" -out "$CERT_PEM"                 -days 3650 -nodes                 -subj "/CN=netboot-lab"                 -addext "subjectAltName=IP:127.0.0.1,IP:10.0.2.2"                 2>/dev/null
            openssl x509 -in "$CERT_PEM" -outform DER -out "$CERT_DER" 2>/dev/null
            chmod 600 "$KEY_PEM"
            log_info "  cert (PEM) : $CERT_PEM"
            log_info "  key  (PEM) : $KEY_PEM"
            log_info "  cert (DER) : $CERT_DER  ← embed this in iPXE with --tls-cert"
        else
            log_info "TLS cert already exists: $CERT_PEM"
        fi
        log_info "writing nginx SSL config snippet: $SSL_CONF"
        cat > "$SSL_CONF" <<EOF
# ipxe-ssl.conf — add to your nginx server{} block alongside ipxe-mime.conf.
# Requires ssl_certificate and ssl_certificate_key to be set in the same block.
# Example:
#   ssl_certificate     $CERT_PEM;
#   ssl_certificate_key $KEY_PEM;
#   include             $SSL_CONF;
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         HIGH:!aNULL:!MD5;
ssl_session_cache   shared:SSL:1m;
ssl_session_timeout 10m;
EOF
    fi
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "setup complete"
log_info "  artifact dir : $NETBOOT_DIR"
log_info "  mime conf    : $MIME_CONF"
log_info ""
log_info "next steps:"
log_info "  1. Build iPXE (inside Docker, ~15 min first run):"
log_info "       netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\"
log_info "           --output-dir $NETBOOT_DIR"
log_info "     (use your LAN IP instead of 10.0.2.2 for real hardware)"
log_info "  2. Build the initrd rootfs (needs sudo):"
log_info "       sudo phase1-chroot/lab-chroot.sh create \\"
log_info "           --config examples/chroot-netboot-minimal.toml"
log_info "  3. Package kernel + initrd (needs sudo):"
log_info "       sudo phase1-chroot/lab-chroot.sh export-initrd netboot-minimal \\"
log_info "           --kernel $NETBOOT_DIR/kernel \\"
log_info "           --output $NETBOOT_DIR/initrd.gz"
log_info "  4. Start the nginx container (rootless):"
log_info "       phase4-podman/lab-podman.sh up \\"
log_info "           --config examples/podman-netboot-server.toml"
log_info "  Note: the nginx MIME config ($MIME_CONF)"
log_info "        is volume-mounted into the container automatically — no host"
log_info "        nginx changes needed."
