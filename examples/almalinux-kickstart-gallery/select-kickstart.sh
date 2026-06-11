#!/usr/bin/env bash
# select-kickstart.sh — Pick a gallery variant and (re)build the iPXE boot program
#                       that boots the AlmaLinux installer with THAT kickstart.
#
# The AlmaLinux counterpart of the rocky-kickstart-gallery selector.  Thin wrapper
# around the shared netboot/build-ipxe.sh: it bakes the boot params (kernel/initrd
# URL + inst.ks + AppStream addrepo) into boot.ipxe and the ipxe.pxe/.efi binaries,
# so switching variants = rebuilding them.  The pxe-install lab boots boot.ipxe
# directly via the NIC's native iPXE (see the rocky/almalinux-pxe-lab READMEs).
#
#   examples/almalinux-kickstart-gallery/select-kickstart.sh <variant> [OPTIONS]
#
# <variant>  a staged kickstart's SHORT name: gencloud, oci, gcp, azure, vagrant.
#            (Resolves the staged almalinux-<release>.<variant>-<arch>.ks file.)
#            `gencloud` (GenericCloud) is the lean, recommended first variant.
#
# Options:
#   --server     <url>  HTTP server as seen by the guest (default: http://10.0.2.2:8181)
#   --kickstart-dir <d> staged kickstart dir  (default: ~/netboot/almalinux-kickstart)
#   --kernel-url <p>    served path to the installer kernel (default: /vmlinuz)
#   --initrd-url <p>    served path to the installer initrd (default: /initrd.img)
#   --output-dir <d>    where boot.ipxe/ipxe.pxe/.efi are written (default: ~/netboot)
#   --mirror     <url>  AlmaLinux mirror base for the AppStream addrepo
#                       (default: https://repo.almalinux.org/almalinux)
#   --release    <n>    AlmaLinux major release (default: 9) — must match the staged file
#   --arch       <a>    arch: x86_64|aarch64 (default: x86_64) — must match the staged file
#   --print-only        print the resolved build-ipxe command and exit (no build)
#   --help              show this help and exit
#
# After this, serve (Phase 4) + boot (Phase 2):
#   phase4-podman/lab-podman.sh up     --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
#   phase2-qemu-vm/lab-vm.sh    create --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
#   phase2-qemu-vm/lab-vm.sh    start  almalinux-kickstart-install

set -euo pipefail

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

usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Args ─────────────────────────────────────────────────────────────────────
variant=""
server="http://10.0.2.2:8181"
kickstart_dir=""
kernel_url="/vmlinuz"
initrd_url="/initrd.img"
output_dir=""
mirror="https://repo.almalinux.org/almalinux"
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
[[ -n "$kickstart_dir" ]] || kickstart_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/almalinux-kickstart"
[[ -n "$output_dir"    ]] || output_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

# ─── Resolve the variant to a staged filename ────────────────────────────────
# Accept the short name (gencloud), the full file, or the micro-arch _vN form.
resolve_variant() {
    local v="$1" c
    for c in "almalinux-${release}.${v}-${arch}.ks" "$v" "${v}.ks"; do
        [[ -f "${kickstart_dir}/${c}" ]] && { printf '%s' "$c"; return 0; }
    done
    # _vN micro-arch variants (e.g. gencloud-x86_64_v2)
    local m; m="$(compgen -G "${kickstart_dir}/almalinux-${release}.${v}-${arch}_v*.ks" 2>/dev/null | head -1)" || true
    [[ -n "$m" ]] && { printf '%s' "${m##*/}"; return 0; }
    return 1
}
fname="$(resolve_variant "$variant")" || {
    _log error "variant '${variant}' not staged in ${kickstart_dir} (release ${release}, ${arch})"
    if compgen -G "${kickstart_dir}/*.ks" >/dev/null; then
        _log error "available:"
        for f in "${kickstart_dir}"/almalinux-*.ks; do
            [[ "$f" == *"/raw/"* ]] && continue
            printf '    %s\n' "$(basename "$f")" >&2
        done
    else
        _log error "  (nothing staged — run fetch-kickstarts.sh first)"
    fi
    exit 1
}

ks_url="${server%/}/almalinux-kickstart/${fname}"
appstream="${mirror%/}/${release}/AppStream/${arch}/os/"

# ─── Pre-flight: warn (don't fail) if the installer artifacts aren't fetched ──
served_root="${output_dir%/}"
for f in "vmlinuz" "initrd.img" "images/install.img"; do
    if [[ ! -e "${served_root}/${f}" ]]; then
        log_warn "expected ${served_root}/${f} not found — fetch it with:"
        log_warn "    examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release ${release} --arch ${arch}"
    fi
done

build_ipxe="${REPO_ROOT}/netboot/build-ipxe.sh"
[[ -x "$build_ipxe" ]] || die "shared builder not found/executable: ${build_ipxe}"

# Anaconda append:
#   inst.stage2 = the LOCAL install.img (avoids streaming ~1 GB over slirp)
#   inst.ks     = the chosen, lab-patched kickstart (partitions /dev/vda, reboots in)
#   inst.addrepo= AppStream (BaseOS is the kickstart's own `url --url …BaseOS…`, so we
#                 do NOT pass inst.repo — that would clash; AppStream is additive).
#   text + console=ttyS0 so `lab-vm.sh console` follows the install AND the
#                 installed system's serial getty afterwards.
append="inst.stage2=${server%/}/ inst.addrepo=AppStream,${appstream} inst.ks=${ks_url} inst.text console=ttyS0 ip=dhcp"

log_info "variant   : ${fname}"
log_info "kickstart : ${ks_url}"
log_info "kernel    : ${server%/}${kernel_url}"
log_info "initrd    : ${server%/}${initrd_url}"
log_info "repos     : BaseOS (from the kickstart's url) + AppStream addrepo @ ${mirror%/}/${release}/…/${arch}/os/"

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

log_ok "iPXE boot programs built for '${fname}'. Now serve + boot:"
cat >&2 <<EOF
  phase4-podman/lab-podman.sh up     --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
  phase2-qemu-vm/lab-vm.sh    create --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
  phase2-qemu-vm/lab-vm.sh    start  almalinux-kickstart-install
  phase2-qemu-vm/lab-vm.sh    console almalinux-kickstart-install   # watch the unattended install
EOF
