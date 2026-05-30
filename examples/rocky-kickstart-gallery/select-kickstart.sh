#!/usr/bin/env bash
# select-kickstart.sh — Pick a gallery variant and (re)build the iPXE boot
#                       program that boots the Rocky installer with THAT kickstart.
#
# build-ipxe bakes the boot params (kernel/initrd URL + inst.ks/inst.repo) into
# boot.ipxe and the ipxe.pxe/.efi binaries, so switching variants = rebuilding
# them.  The pxe-install lab boots boot.ipxe directly via the NIC's native iPXE
# (see the rocky-pxe-lab README).  This is a thin wrapper around the shared
# netboot/build-ipxe.sh with the gallery's defaults filled in.
#
#   examples/rocky-kickstart-gallery/select-kickstart.sh <variant> [OPTIONS]
#
# <variant>  a staged kickstart, e.g. GenericCloud-Base, Workstation-Lite,
#            EC2-Base, Vagrant-Libvirt, XFCE … (the "Rocky-9-" prefix and ".ks"
#            suffix are optional — 'GenericCloud-Base' resolves the staged file).
#
# Options:
#   --server     <url>  HTTP server as seen by the guest (default: http://10.0.2.2:8181)
#   --kickstart-dir <d> staged kickstart dir  (default: ~/netboot/rocky-kickstart)
#   --kernel-url <p>    served path to the installer kernel (default: /vmlinuz)
#   --initrd-url <p>    served path to the installer initrd (default: /initrd.img)
#   --output-dir <d>    where boot.ipxe/ipxe.pxe/.efi are written (default: ~/netboot)
#   --mirror     <url>  Rocky mirror base for inst.repo/addrepo
#                       (default: https://download.rockylinux.org/pub/rocky)
#   --release    <n>    Rocky major release (default: 9)
#   --arch       <a>    iPXE + repo arch: x86_64|aarch64 (default: x86_64)
#   --print-only        print the resolved build-ipxe command and exit (no build)
#   --help              show this help and exit
#
# After this, serve (Phase 4) + boot (Phase 2):
#   phase4-podman/lab-podman.sh up     --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
#   phase2-qemu-vm/lab-vm.sh    create --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
#   phase2-qemu-vm/lab-vm.sh    start  rocky-kickstart-install

set -euo pipefail

# repo root = two levels up from examples/rocky-kickstart-gallery/
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

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Args ─────────────────────────────────────────────────────────────────────
variant=""
server="http://10.0.2.2:8181"
kickstart_dir=""
kernel_url="/vmlinuz"
initrd_url="/initrd.img"
output_dir=""
mirror="https://download.rockylinux.org/pub/rocky"
release="9"
arch="x86_64"
print_only=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        shift; server="${1:?--server requires a URL}";          shift ;;
        --kickstart-dir) shift; kickstart_dir="${1:?--kickstart-dir requires a path}"; shift ;;
        --kernel-url)    shift; kernel_url="${1:?--kernel-url requires a path}";  shift ;;
        --initrd-url)    shift; initrd_url="${1:?--initrd-url requires a path}";  shift ;;
        --output-dir)    shift; output_dir="${1:?--output-dir requires a path}"; shift ;;
        --mirror)        shift; mirror="${1:?--mirror requires a URL}";          shift ;;
        --release)       shift; release="${1:?--release requires a number}";     shift ;;
        --arch)          shift; arch="${1:?--arch requires an arch}";            shift ;;
        --print-only)    print_only=1; shift ;;
        --help|-h)       usage ;;
        -*)              die "unknown option: $1  (try --help)" ;;
        *)               [[ -z "$variant" ]] || die "only one <variant> allowed (got '$variant' and '$1')"
                         variant="$1"; shift ;;
    esac
done

[[ -n "$variant" ]] || { _log error "missing <variant> (try --help)"; usage; }
[[ -n "$kickstart_dir" ]] || kickstart_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/rocky-kickstart"
[[ -n "$output_dir"    ]] || output_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

# ─── Resolve the variant to a staged filename ────────────────────────────────
# Accept GenericCloud-Base / Rocky-9-GenericCloud-Base / …-Base.ks etc.
resolve_variant() {
    local v="$1" c
    for c in "$v" "${v}.ks" "Rocky-9-${v}" "Rocky-9-${v}.ks"; do
        [[ -f "${kickstart_dir}/${c}" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
fname="$(resolve_variant "$variant")" || {
    _log error "variant '${variant}' not staged in ${kickstart_dir}"
    if compgen -G "${kickstart_dir}/*.ks" >/dev/null; then
        _log error "available variants:"
        for f in "${kickstart_dir}"/*.ks; do printf '    %s\n' "$(basename "${f%.ks}")" >&2; done
    else
        _log error "  (nothing staged — run fetch-kickstarts.sh first)"
    fi
    exit 1
}

# Friendly heads-up: the Container-* variants have no bootloader (container rootfs).
case "$fname" in
    Rocky-9-Container-*) log_warn "'${fname%.ks}' targets a container rootfs (no bootloader) — it will NOT boot as a VM." ;;
esac

ks_url="${server%/}/rocky-kickstart/${fname}"
baseos="${mirror%/}/${release}/BaseOS/${arch}/os/"
appstream="${mirror%/}/${release}/AppStream/${arch}/os/"

# ─── Pre-flight: warn (don't fail) if the installer artifacts aren't fetched ──
served_root="${output_dir%/}"
for f in "vmlinuz" "initrd.img" "images/install.img"; do
    if [[ ! -e "${served_root}/${f}" ]]; then
        log_warn "expected ${served_root}/${f} not found — fetch it with:"
        log_warn "    examples/rocky-pxe-lab/fetch-rocky-installer.sh --release ${release} --arch ${arch}"
    fi
done

build_ipxe="${REPO_ROOT}/netboot/build-ipxe.sh"
[[ -x "$build_ipxe" ]] || die "shared builder not found/executable: ${build_ipxe}"

# Anaconda append:
#   inst.stage2 = the LOCAL install.img (avoids streaming ~1.2 GB over slirp)
#   inst.repo   = BaseOS; inst.addrepo = AppStream (the cloud/container variants
#                 carry no url/repo of their own, and need both)
#   inst.ks     = the chosen, lab-patched kickstart (reboots into the install)
#   text + console=ttyS0 so `lab-vm.sh console` follows the install AND the
#                 installed system's serial getty afterwards.
append="inst.stage2=${server%/}/ inst.repo=${baseos} inst.addrepo=AppStream,${appstream} inst.ks=${ks_url} inst.text console=ttyS0 ip=dhcp"

log_info "variant   : ${fname%.ks}"
log_info "kickstart : ${ks_url}"
log_info "kernel    : ${server%/}${kernel_url}"
log_info "initrd    : ${server%/}${initrd_url}"
log_info "repos     : BaseOS + AppStream @ ${mirror%/}/${release}/…/${arch}/os/"

if (( print_only )); then
    log_info "--print-only: would run (nothing built):"
    printf '%q ' "$build_ipxe" --server "$server" --kernel-path "$kernel_url" \
        --initrd-path "$initrd_url" --append "$append" \
        --output-dir "$output_dir" --arch "$arch" >&2
    printf '\n' >&2
    exit 0
fi

log_info "building iPXE boot programs → ${output_dir}/boot.ipxe (+ ipxe.pxe/.efi) …"

"$build_ipxe" \
    --server      "$server" \
    --kernel-path "$kernel_url" \
    --initrd-path "$initrd_url" \
    --append      "$append" \
    --output-dir  "$output_dir" \
    --arch        "$arch"

log_ok "iPXE boot programs built for '${fname%.ks}'. Now serve + boot:"
cat >&2 <<EOF
  phase4-podman/lab-podman.sh up     --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
  phase2-qemu-vm/lab-vm.sh    create --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
  phase2-qemu-vm/lab-vm.sh    start  rocky-kickstart-install
  phase2-qemu-vm/lab-vm.sh    console rocky-kickstart-install   # watch the unattended install
EOF
