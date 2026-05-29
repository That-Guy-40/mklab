#!/usr/bin/env bash
# select-preseed.sh — Pick a gallery variant and (re)build the iPXE ROM that
#                     boots the Kali d-i installer with THAT preseed.
#
# The iPXE ROM bakes in the boot params (kernel/initrd URL + preseed/url), so
# switching variants = rebuilding the tiny ROM.  This is a thin wrapper around
# the shared netboot/build-ipxe.sh with the gallery's defaults filled in.
#
#   examples/kali-preseed-gallery/select-preseed.sh <variant> [OPTIONS]
#
# <variant>  one of the staged names, e.g. xfce-default, kde-large,
#            headless-default, lvm, crypto-multi, packer-preseed …
#            (".cfg" is optional — both 'lvm' and 'lvm.cfg' resolve).
#
# Options:
#   --server   <url>  HTTP server as seen by the guest (default: http://10.0.2.2:8181)
#   --preseed-dir <d> staged preseed dir   (default: ~/netboot/kali-preseed)
#   --kernel-url <p>  served path to the d-i kernel  (default: /kali/linux)
#   --initrd-url <p>  served path to the d-i initrd  (default: /kali/initrd.gz)
#   --output-dir <d>  where ipxe.qcow2 is written     (default: ~/netboot)
#   --arch     <a>    iPXE arch: x86_64|aarch64        (default: x86_64)
#   --print-only      print the resolved build-ipxe command and exit (no build)
#   --help            show this help and exit
#
# After this, serve (Phase 4) + boot (Phase 2):
#   phase4-podman/lab-podman.sh up     --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
#   phase2-qemu-vm/lab-vm.sh    create --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
#   phase2-qemu-vm/lab-vm.sh    start  kali-preseed-install

set -euo pipefail

# repo root = two levels up from examples/kali-preseed-gallery/
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT

_log() {
    local level="$1"; shift
    local color="" reset=""
    if [[ -t 2 ]]; then
        case "$level" in info) color=$'\033[36m';; warn) color=$'\033[33m';;
            error) color=$'\033[31m';; ok) color=$'\033[32m';; esac
        reset=$'\033[0m'
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info(){ _log info "$@"; }; log_warn(){ _log warn "$@"; }
log_ok(){ _log ok "$@"; };     die(){ _log error "$@"; exit 1; }

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Args ─────────────────────────────────────────────────────────────────────
variant=""
server="http://10.0.2.2:8181"
preseed_dir=""
kernel_url="/kali/linux"
initrd_url="/kali/initrd.gz"
output_dir=""
arch="x86_64"
print_only=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)      shift; server="${1:?--server requires a URL}";        shift ;;
        --preseed-dir) shift; preseed_dir="${1:?--preseed-dir requires a path}"; shift ;;
        --kernel-url)  shift; kernel_url="${1:?--kernel-url requires a path}"; shift ;;
        --initrd-url)  shift; initrd_url="${1:?--initrd-url requires a path}"; shift ;;
        --output-dir)  shift; output_dir="${1:?--output-dir requires a path}"; shift ;;
        --arch)        shift; arch="${1:?--arch requires an arch}";           shift ;;
        --print-only)  print_only=1; shift ;;
        --help|-h)     usage ;;
        -*)            die "unknown option: $1  (try --help)" ;;
        *)             [[ -z "$variant" ]] || die "only one <variant> allowed (got '$variant' and '$1')"
                       variant="$1"; shift ;;
    esac
done

[[ -n "$variant" ]] || { _log error "missing <variant> (try --help)"; usage; }
[[ -n "$preseed_dir" ]] || preseed_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/kali-preseed"
[[ -n "$output_dir"  ]] || output_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

# ─── Resolve the variant to a staged filename ────────────────────────────────
# Accept 'lvm' or 'lvm.cfg'; the extension-less 'headless-default' resolves too.
resolve_variant() {
    local v="$1"
    if   [[ -f "${preseed_dir}/${v}"      ]]; then printf '%s' "$v"
    elif [[ -f "${preseed_dir}/${v}.cfg"  ]]; then printf '%s' "${v}.cfg"
    else return 1; fi
}
fname="$(resolve_variant "$variant")" || {
    _log error "variant '${variant}' not staged in ${preseed_dir}"
    if compgen -G "${preseed_dir}/*" >/dev/null; then
        _log error "available variants:"
        for f in "${preseed_dir}"/*; do
            [[ -d "$f" ]] && continue   # skip raw/
            printf '    %s\n' "$(basename "$f")" >&2
        done
    else
        _log error "  (nothing staged — run fetch-preseeds.sh first)"
    fi
    exit 1
}

preseed_url="${server%/}/kali-preseed/${fname}"

# ─── Pre-flight: warn (don't fail) if the kernel/initrd aren't fetched yet ───
# We can only check the local served dir if it's the conventional ~/netboot.
served_root="${output_dir%/}"
for f in "kali/linux" "kali/initrd.gz"; do
    if [[ ! -e "${served_root}/${f}" ]]; then
        log_warn "expected ${served_root}/${f} not found — fetch it with:"
        log_warn "    examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64"
    fi
done

build_ipxe="${REPO_ROOT}/netboot/build-ipxe.sh"
[[ -x "$build_ipxe" ]] || die "shared builder not found/executable: ${build_ipxe}"

# d-i append: fetch the preseed early, answer every prompt from it (auto/critical),
# text frontend + serial console; the trailing `---` hands console= to the
# INSTALLED kernel so `lab-vm.sh console` keeps working after reboot.
append="auto=true priority=critical preseed/url=${preseed_url} DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---"

log_info "variant : ${fname}"
log_info "preseed : ${preseed_url}"
log_info "kernel  : ${server%/}${kernel_url}"
log_info "initrd  : ${server%/}${initrd_url}"

if (( print_only )); then
    log_info "--print-only: would run (no ROM built):"
    printf '%q ' "$build_ipxe" --server "$server" --kernel-path "$kernel_url" \
        --initrd-path "$initrd_url" --append "$append" \
        --output-dir "$output_dir" --arch "$arch" >&2
    printf '\n' >&2
    exit 0
fi

log_info "building iPXE ROM → ${output_dir}/ipxe.qcow2 …"

"$build_ipxe" \
    --server      "$server" \
    --kernel-path "$kernel_url" \
    --initrd-path "$initrd_url" \
    --append      "$append" \
    --output-dir  "$output_dir" \
    --arch        "$arch"

log_ok "iPXE ROM built for '${fname}'. Now serve + boot:"
cat >&2 <<EOF
  phase4-podman/lab-podman.sh up     --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
  phase2-qemu-vm/lab-vm.sh    create --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
  phase2-qemu-vm/lab-vm.sh    start  kali-preseed-install
  phase2-qemu-vm/lab-vm.sh    console kali-preseed-install   # watch the unattended install
EOF
