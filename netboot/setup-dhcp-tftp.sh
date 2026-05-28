#!/usr/bin/env bash
# setup-dhcp-tftp.sh — Set up a TFTP directory and dnsmasq ProxyDHCP config
#                      for traditional DHCP/TFTP PXE boot on real hardware.
#
# What it does:
#   1. Creates the TFTP root directory ($NETBOOT_DIR/tftp/)
#   2. Copies iPXE EFI/USB binaries to the TFTP root
#   3. Writes a dnsmasq.conf for ProxyDHCP + TFTP service
#   4. Prints a podman/docker run command to start dnsmasq
#
# ProxyDHCP mode: dnsmasq responds to PXE requests but does NOT assign IP
# addresses — your existing router/DHCP server keeps doing that.  This is
# the safe default for lab use on a shared LAN.  dnsmasq only adds options
# 66 (TFTP server IP) and 67 (boot filename) to the PXE-client's DHCP reply.
#
# For QEMU testing, use lab-vm.sh --pxe-dir instead — QEMU's slirp provides
# built-in DHCP+TFTP without any external server.  This script is for real
# hardware or bridge/tap networking.
#
# Usage:
#   netboot/setup-dhcp-tftp.sh [OPTIONS]
#
# Options:
#   --dir        PATH   netboot artifact directory   (default: ~/netboot)
#   --tftp-dir   PATH   TFTP root (default: <dir>/tftp)
#   --conf-dir   PATH   config directory             (default: ~/.config/lab-netboot)
#   --server-ip  IP     IP of this host on the LAN   (required for real hardware)
#   --iface      IFACE  network interface dnsmasq listens on (default: eth0)
#   --bootfile   FILE   TFTP bootfile sent to PXE clients (default: ipxe.efi)
#   --full-dhcp         Use full DHCP instead of ProxyDHCP (implies ownership
#                       of the subnet; use only on isolated/lab networks)
#   --range      RANGE  DHCP range for --full-dhcp   (e.g. 192.168.100.50,192.168.100.100)
#   --help              show this help

set -euo pipefail

readonly LAB_PROG="${0##*/}"

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
die()       { _log error "$@"; exit 1; }

usage() {
    cat >&2 <<'EOF'
Usage: netboot/setup-dhcp-tftp.sh [OPTIONS]

  --dir       PATH    netboot artifact directory  (default: ~/netboot)
  --tftp-dir  PATH    TFTP root                   (default: <dir>/tftp)
  --conf-dir  PATH    config directory             (default: ~/.config/lab-netboot)
  --server-ip IP      this host's LAN IP (required for real-hardware setup)
  --iface     IFACE   interface for dnsmasq        (default: eth0)
  --bootfile  FILE    TFTP bootfile for PXE clients (default: ipxe.efi)
  --full-dhcp         full DHCP mode (not proxy); use only on isolated networks
  --range     RANGE   DHCP range for --full-dhcp
  --help              show this help and exit
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
netboot_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"
tftp_dir=""
conf_dir="${LAB_NETBOOT_CONF:-$HOME/.config/lab-netboot}"
server_ip=""
iface="eth0"
bootfile="ipxe.efi"
full_dhcp=""
dhcp_range=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)       shift; netboot_dir="${1:?}"; shift ;;
        --tftp-dir)  shift; tftp_dir="${1:?}"; shift ;;
        --conf-dir)  shift; conf_dir="${1:?}"; shift ;;
        --server-ip) shift; server_ip="${1:?}"; shift ;;
        --iface)     shift; iface="${1:?}"; shift ;;
        --bootfile)  shift; bootfile="${1:?}"; shift ;;
        --full-dhcp) full_dhcp=1; shift ;;
        --range)     shift; dhcp_range="${1:?}"; shift ;;
        --help|-h)   usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

[[ -n "$tftp_dir" ]] || tftp_dir="$netboot_dir/tftp"

# ─── Warn about full-dhcp ───────────────────────────────────────────────────
if [[ -n "$full_dhcp" ]]; then
    log_warn "--full-dhcp: dnsmasq will serve DHCP for the entire interface."
    log_warn "  Use ONLY on an isolated/lab network.  Running two DHCP servers"
    log_warn "  on a shared LAN will disrupt other machines."
    [[ -n "$dhcp_range" ]] \
        || die "--full-dhcp requires --range (e.g. 192.168.100.50,192.168.100.100,12h)"
fi

# ─── Create directories ─────────────────────────────────────────────────────
log_info "creating TFTP root: $tftp_dir"
mkdir -p "$tftp_dir"
chmod 755 "$tftp_dir"
mkdir -p "$conf_dir"

# ─── Copy iPXE binaries to TFTP root ────────────────────────────────────────
copied=0
for f in ipxe.efi ipxe-signed.efi ipxe.usb boot.ipxe; do
    src="$netboot_dir/$f"
    if [[ -f "$src" ]]; then
        cp "$src" "$tftp_dir/$f"
        log_info "  copied $f → $tftp_dir/$f"
        copied=$((copied+1))
    fi
done
if (( copied == 0 )); then
    log_warn "No iPXE binaries found in $netboot_dir"
    log_warn "  Run 'netboot/build-ipxe.sh' first, then re-run this script."
fi

# ─── Write dnsmasq config ───────────────────────────────────────────────────
dnsmasq_conf="$conf_dir/dnsmasq-pxe.conf"
log_info "writing dnsmasq config: $dnsmasq_conf"

{
    cat <<EOF
# dnsmasq-pxe.conf — Generated by netboot/setup-dhcp-tftp.sh
# $(date -u '+%Y-%m-%dT%H:%M:%SZ')
#
# Provides TFTP service and $(
    if [[ -n "$full_dhcp" ]]; then echo "full DHCP"; else echo "ProxyDHCP (PXE-only DHCP responses)"; fi
) for traditional PXE boot.
# The container must run with --network=host (or macvlan) to receive
# DHCP broadcasts from real hardware clients.
#
# Interface binding
interface=$iface
bind-interfaces
# No DNS (we only want DHCP+TFTP)
port=0
# TFTP
enable-tftp
tftp-root=$tftp_dir
EOF

    if [[ -n "$full_dhcp" ]]; then
        cat <<EOF
# Full DHCP mode — only use on an isolated lab network.
dhcp-range=$dhcp_range
dhcp-boot=$bootfile
EOF
    else
        # ProxyDHCP mode — only responds to PXE clients (option 60 = PXEClient)
        # Does not interfere with existing DHCP servers.
        cat <<EOF
# ProxyDHCP mode — safe to run alongside an existing LAN DHCP server.
# Only responds to DHCP requests that include option 60 = "PXEClient".
dhcp-range=${server_ip:+${server_ip},}${server_ip:+${server_ip},}proxy
dhcp-boot=$bootfile
# Architecture-aware boot: UEFI x64 clients (option 93 = 9) get ipxe.efi;
# legacy BIOS clients (option 93 = 0) fall back to the default bootfile.
# Remove the lines below if you only have UEFI clients.
dhcp-match=x86PC,option:client-arch,0
dhcp-match=BC_EFI,option:client-arch,7
dhcp-match=x86_64_EFI,option:client-arch,9
dhcp-boot=tag:x86PC,ipxe.usb,$([ -n "$server_ip" ] && echo "$server_ip" || echo "REPLACE_WITH_YOUR_IP")
dhcp-boot=tag:BC_EFI,ipxe.efi,$([ -n "$server_ip" ] && echo "$server_ip" || echo "REPLACE_WITH_YOUR_IP")
dhcp-boot=tag:x86_64_EFI,ipxe.efi,$([ -n "$server_ip" ] && echo "$server_ip" || echo "REPLACE_WITH_YOUR_IP")
EOF
    fi

    cat <<EOF
# Logging (verbose — disable in production)
log-dhcp
log-queries
EOF
} > "$dnsmasq_conf"

if [[ -z "$server_ip" ]]; then
    log_warn "No --server-ip given; replace 'REPLACE_WITH_YOUR_IP' in $dnsmasq_conf"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "── setup-dhcp-tftp complete ──"
log_info "  TFTP root  : $tftp_dir"
log_info "  dnsmasq cfg: $dnsmasq_conf"
log_info ""
log_info "Start dnsmasq in Docker (needs --network=host and root for DHCP):"
log_info "  sudo docker run --rm -d \\"
log_info "      --name pxe-dnsmasq \\"
log_info "      --network host \\"
log_info "      --cap-add NET_ADMIN \\"
log_info "      -v $tftp_dir:/tftp:ro \\"
log_info "      -v $dnsmasq_conf:/etc/dnsmasq.conf:ro \\"
log_info "      alpine:latest \\"
log_info "      sh -c 'apk add -q dnsmasq && dnsmasq --no-daemon'"
log_info ""
log_info "Or run dnsmasq directly on the host (root required):"
log_info "  sudo dnsmasq --conf-file=$dnsmasq_conf --no-daemon"
log_info ""
log_info "For QEMU testing (no dnsmasq needed), use:"
log_info "  lab-vm.sh create --name pxe-test ... --pxe-dir $netboot_dir --pxe-bootfile $bootfile"
