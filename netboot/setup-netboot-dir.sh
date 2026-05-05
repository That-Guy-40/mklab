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
  --help        show this help and exit

Examples:
  sudo netboot/setup-netboot-dir.sh
  sudo netboot/setup-netboot-dir.sh --dir /data/netboot --conf /etc/lab-netboot
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
NETBOOT_DIR="/srv/netboot"
CONF_DIR="/etc/lab-netboot"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)  shift; NETBOOT_DIR="${1:?--dir requires a path}"; shift ;;
        --conf) shift; CONF_DIR="${1:?--conf requires a path}";   shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Root check ─────────────────────────────────────────────────────────────
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "$LAB_PROG must be run as root  (try: sudo $LAB_PROG)"
fi

# ─── Create directories ─────────────────────────────────────────────────────
log_info "creating artifact directory: $NETBOOT_DIR"
mkdir -p "$NETBOOT_DIR"
chmod 755 "$NETBOOT_DIR"

log_info "creating config directory: $CONF_DIR"
mkdir -p "$CONF_DIR"

# ─── Write nginx MIME snippet ────────────────────────────────────────────────
MIME_CONF="$CONF_DIR/ipxe-mime.conf"
log_info "writing nginx MIME snippet: $MIME_CONF"
cat > "$MIME_CONF" <<'EOF'
# ipxe-mime.conf — include this in your nginx http{} or server{} block so
# iPXE clients receive the correct Content-Type for chainboot scripts.
#
#   include /etc/lab-netboot/ipxe-mime.conf;
types {
    application/x-ipxe  ipxe;
}
EOF

# ─── Hand artifact dir to the invoking user ──────────────────────────────────
# When run via sudo, SUDO_UID/SUDO_GID identify the real caller so they can
# write artifacts (kernel, initrd, ipxe images) without needing root again.
TARGET_UID="${SUDO_UID:-$(id -u)}"
TARGET_GID="${SUDO_GID:-$(id -g)}"
chown "${TARGET_UID}:${TARGET_GID}" "$NETBOOT_DIR"
log_info "artifact directory owner set to ${TARGET_UID}:${TARGET_GID}"

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "setup complete"
log_info "  artifact dir : $NETBOOT_DIR"
log_info "  mime conf    : $MIME_CONF"
log_info ""
log_info "next steps:"
log_info "  1. Add to your nginx config:  include $MIME_CONF;"
log_info "  2. Run:  netboot/build-ipxe.sh --output-dir $NETBOOT_DIR"
