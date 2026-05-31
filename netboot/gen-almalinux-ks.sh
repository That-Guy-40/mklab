#!/usr/bin/env bash
# gen-almalinux-ks.sh — Render an AlmaLinux kickstart file for a specific host MAC.
#
# Copies (or in future: renders with per-host substitutions) the kickstart
# template to <out>/ks/<mac:hexhyp>.ks, where <mac:hexhyp> is the MAC address
# in lowercase hyphen-separated form (e.g. 52:54:00:AA:BB:CC → 52-54-00-aa-bb-cc).
#
# The file is named after the MAC so the iPXE embedded script can request it by
# the URL  http://<server>/ks/${mac:hexhyp}.ks  at boot time, giving each host
# a unique kickstart without the nginx server needing to know about individual
# machines in advance.
#
# Usage:
#   netboot/gen-almalinux-ks.sh [OPTIONS]
#
# Options:
#   --mac       <MAC>   MAC address (colon-separated, e.g. 52:54:00:AA:BB:CC)
#   --default           also write ks/default.ks (fallback for un-enumerated MACs)
#   --template  <file>  kickstart template path
#                       (default: examples/almalinux-pxe-lab/almalinux-zerotouch.ks
#                        relative to the script directory, or CWD if not found there)
#   --out       <dir>   output directory for ks/ subdir  (default: ~/netboot)
#   --help              show this help and exit
#
# Output:
#   <out>/ks/<mac:hexhyp>.ks
#
# Note on placeholders:
#   The current template uses DHCP networking and has no per-host placeholders,
#   so a direct copy is correct.  Future per-host customisation (static IP,
#   hostname) would add sed substitutions here before the copy step.
#
# Examples:
#   netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01
#   netboot/gen-almalinux-ks.sh --mac 52:54:00:AA:BB:CC --out /srv/netboot

set -euo pipefail

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
Usage: netboot/gen-almalinux-ks.sh --mac <MAC> [OPTIONS]

Render an AlmaLinux kickstart file for a specific host MAC address.
The output file is named <mac:hexhyp>.ks (lowercase, hyphen-separated)
and placed in <out>/ks/ so nginx can serve it at /ks/<mac:hexhyp>.ks.

Options:
  --mac       MAC    MAC address (colon-separated, e.g. 52:54:00:AA:BB:CC)  [required]
  --default          also write ks/default.ks (nginx fallback for un-enumerated MACs)
  --template  FILE   kickstart template  (default: examples/almalinux-pxe-lab/almalinux-zerotouch.ks)
  --out       DIR    output directory for ks/ subdir  (default: ~/netboot)
  --help             show this help and exit

Output:
  <out>/ks/<mac:hexhyp>.ks

Examples:
  netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01
  netboot/gen-almalinux-ks.sh --mac 52:54:00:AA:BB:CC --out /srv/netboot
  netboot/gen-almalinux-ks.sh --mac 52:54:00:AA:BB:CC \
      --template /path/to/custom.ks --out ~/netboot
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
mac_raw=""
write_default=""
# Look for the template relative to the script first, then fall back to CWD.
default_template="${SCRIPT_DIR}/../examples/almalinux-pxe-lab/almalinux-zerotouch.ks"
template=""
out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mac)      shift; mac_raw="${1:?--mac requires a MAC address}";   shift ;;
        --default)  write_default=1; shift ;;
        --template) shift; template="${1:?--template requires a path}";    shift ;;
        --out)      shift; out_dir="${1:?--out requires a path}";          shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Validate required args ──────────────────────────────────────────────────
[[ -n "$mac_raw" ]] || die "--mac is required (e.g. --mac 52:54:00:AA:BB:CC)"

# ─── Resolve template ────────────────────────────────────────────────────────
if [[ -z "$template" ]]; then
    # Try path relative to the script directory first.
    if [[ -f "$default_template" ]]; then
        template="$(cd "$(dirname "$default_template")" && pwd)/$(basename "$default_template")"
    else
        die "default template not found at ${default_template}; pass --template explicitly"
    fi
fi

[[ -f "$template" ]] || die "template not found: ${template}"

# ─── Normalise MAC → lowercase hyphen-separated ──────────────────────────────
# Accept any colon-separated form (upper or lower case) and normalise to the
# lowercase-hyphen form that iPXE uses for ${mac:hexhyp}.
# Example: 52:54:00:AA:BB:CC → 52-54-00-aa-bb-cc
mac_hexhyp="$(printf '%s' "$mac_raw" | tr '[:upper:]' '[:lower:]' | tr ':' '-')"

# Basic sanity check: should now be exactly 17 characters (xx-xx-xx-xx-xx-xx).
if [[ ${#mac_hexhyp} -ne 17 ]]; then
    die "MAC address '${mac_raw}' did not normalise to the expected 17-char form; got '${mac_hexhyp}'"
fi

# ─── Create output directory ─────────────────────────────────────────────────
ks_dir="${out_dir}/ks"
mkdir -p "$ks_dir"

# ─── Copy (render) the template ──────────────────────────────────────────────
out_file="${ks_dir}/${mac_hexhyp}.ks"

# Currently a straight copy because the template has no per-host placeholders
# (DHCP networking is sufficient for QEMU).  When per-host static IP / hostname
# support is added, replace this with a sed substitution block, e.g.:
#   sed -e "s/__HOSTNAME__/${hostname}/g" \
#       -e "s/__IPADDR__/${ip}/g" \
#       "$template" > "$out_file"
cp "$template" "$out_file"

log_info "kickstart written: ${out_file}"
log_info "  MAC (hexhyp) : ${mac_hexhyp}"
log_info "  template     : ${template}"
log_info ""
log_info "serve this file with:"
log_info "  phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml"
log_info "iPXE will fetch it at:"
log_info "  http://<server>/ks/${mac_hexhyp}.ks"

# Optionally write ks/default.ks — nginx fallback for un-enumerated MACs.
# Safety note: this installs ANY unknown machine that PXE-boots.  Disable
# or remove default.ks when you only want known MACs to install.
if [[ -n "$write_default" ]]; then
    default_ks="${ks_dir}/default.ks"
    cp "$template" "$default_ks"
    log_info "default.ks written: ${default_ks}"
    log_info "  To serve as an nginx fallback, add to the nginx server{} block:"
    log_info "    location /ks/ {"
    log_info "      root $(dirname "$ks_dir");"
    log_info "      try_files \$uri /ks/default.ks =404;"
    log_info "    }"
    log_info "  (see examples/almalinux-pxe-lab/nginx-ks-fallback.conf for a ready-to-include snippet)"
fi

# Print the output path on stdout so callers can capture it.
printf '%s\n' "$out_file"
