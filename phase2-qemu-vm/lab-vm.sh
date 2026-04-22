#!/usr/bin/env bash
# lab-vm.sh — Phase 2 of LAB_CREATE_V2: QEMU full VMs and microvms.
#
# Backends : disk-image (cached cloud images + cloud-init NoCloud seed)
#            kernel+initrd (direct -kernel/-initrd boot, microvm-friendly)
#            from-chroot   (Phase-1 chroot tree → bootable disk; v0.1: stub)
# Arches   : x86_64 aarch64 armv7l ppc64le riscv64 s390x
# Accel    : kvm if host arch == guest arch and /dev/kvm usable; else tcg
# Config   : CLI flags or TOML file (--config FILE)
#
# Self-contained per the per-phase rule: helpers from Phase 1 are duplicated
# inline. Do not source files from sibling phases.

set -euo pipefail
shopt -s nullglob

readonly LAB_VERSION="0.1.0"
readonly LAB_PROG="${0##*/}"

# ─── State / cache locations ────────────────────────────────────────────────
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    readonly LAB_STATE_DIR="/var/lib/lab-create"
    readonly LAB_CACHE_DIR="/var/cache/lab-create"
else
    readonly LAB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create"
    readonly LAB_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/lab-create"
fi
readonly LAB_VM_STATE_DIR="${LAB_STATE_DIR}/vms"
readonly LAB_IMG_CACHE_DIR="${LAB_CACHE_DIR}/images"

# ─── Logging ────────────────────────────────────────────────────────────────
LAB_LOG_LEVEL="${LAB_LOG_LEVEL:-info}"

_log() {
    local level="$1"; shift
    local prio cur
    case "$level" in debug) prio=0;; info) prio=1;; warn) prio=2;; error) prio=3;; esac
    case "$LAB_LOG_LEVEL" in debug) cur=0;; info) cur=1;; warn) cur=2;; error) cur=3;; *) cur=1;; esac
    [[ $prio -lt $cur ]] && return 0
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            debug) color=$'\033[2m' ;;
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_debug() { _log debug "$@"; }
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

# ─── Host / arch detection ──────────────────────────────────────────────────
detect_host_distro() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s' "${ID:-unknown}" )
    else
        printf 'unknown'
    fi
}

detect_host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)         printf 'x86_64' ;;
        aarch64|arm64)        printf 'aarch64' ;;
        armv7l|armv7|armhf)   printf 'armv7l' ;;
        ppc64le|powerpc64le)  printf 'ppc64le' ;;
        riscv64)              printf 'riscv64' ;;
        s390x)                printf 's390x' ;;
        *)                    printf 'unknown' ;;
    esac
}

# arch_map CANONICAL COLUMN
# Columns: qemu-system | machine | default-cpu | firmware-pkg | microvm-supported
arch_map() {
    local c="$1" col="$2"
    case "${c}:${col}" in
        x86_64:qemu-system)         printf 'x86_64'   ;;
        x86_64:machine)             printf 'q35'      ;;
        x86_64:default-cpu)         printf 'host'     ;;  # only meaningful with kvm
        x86_64:firmware-pkg)        printf 'ovmf'     ;;
        x86_64:microvm-supported)   printf 'yes'      ;;

        aarch64:qemu-system)        printf 'aarch64'  ;;
        aarch64:machine)            printf 'virt'     ;;
        aarch64:default-cpu)        printf 'cortex-a72' ;;
        aarch64:firmware-pkg)       printf 'qemu-efi-aarch64' ;;
        aarch64:microvm-supported)  printf 'yes'      ;;  # since QEMU 5.0+

        armv7l:qemu-system)         printf 'arm'      ;;
        armv7l:machine)             printf 'virt'     ;;
        armv7l:default-cpu)         printf 'cortex-a15' ;;
        armv7l:firmware-pkg)        printf 'u-boot-qemu' ;;
        armv7l:microvm-supported)   printf 'no'       ;;

        ppc64le:qemu-system)        printf 'ppc64'    ;;
        ppc64le:machine)            printf 'pseries'  ;;
        ppc64le:default-cpu)        printf 'POWER9'   ;;
        ppc64le:firmware-pkg)       printf 'qemu-system-ppc' ;;  # SLOF bundled
        ppc64le:microvm-supported)  printf 'no'       ;;

        riscv64:qemu-system)        printf 'riscv64'  ;;
        riscv64:machine)            printf 'virt'     ;;
        riscv64:default-cpu)        printf 'rv64'     ;;
        riscv64:firmware-pkg)       printf 'opensbi u-boot-qemu' ;;
        riscv64:microvm-supported)  printf 'no'       ;;

        s390x:qemu-system)          printf 's390x'    ;;
        s390x:machine)              printf 's390-ccw-virtio' ;;
        s390x:default-cpu)          printf 'max'      ;;
        s390x:firmware-pkg)         printf 'qemu-system-s390x' ;;  # bios bundled
        s390x:microvm-supported)    printf 'no'       ;;

        *) return 1 ;;
    esac
}

is_known_arch() {
    case "$1" in
        x86_64|aarch64|armv7l|ppc64le|riscv64|s390x) return 0 ;;
        *) return 1 ;;
    esac
}

# ─── Dependency probing ─────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

install_hint() {
    local tool="$1"
    local host; host="$(detect_host_distro)"
    case "$host" in
        debian|ubuntu|kali) printf 'sudo apt-get install -y %s' "$tool" ;;
        rocky|rhel|fedora|almalinux) printf 'sudo dnf install -y %s' "$tool" ;;
        *) printf '(install %q via your package manager)' "$tool" ;;
    esac
}

require_cmd() {
    local tool="$1"
    have "$tool" || die "$tool not found. Install with:  $(install_hint "$tool")"
}

# ─── Acceleration decision ──────────────────────────────────────────────────
choose_accel() {
    # choose_accel GUEST_ARCH  →  prints "kvm" or "tcg", logs the decision
    local guest="$1" host
    host="$(detect_host_arch)"
    if [[ "$guest" != "$host" ]]; then
        log_info "accel: tcg (guest $guest != host $host)"
        printf 'tcg'
        return
    fi
    if [[ ! -e /dev/kvm ]]; then
        log_warn "accel: tcg (no /dev/kvm; install qemu-kvm or load kvm modules)"
        printf 'tcg'
        return
    fi
    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        log_warn "accel: tcg (/dev/kvm exists but not r+w by uid=$(id -u); add user to kvm group)"
        printf 'tcg'
        return
    fi
    log_info "accel: kvm"
    printf 'kvm'
}

# ─── Firmware path discovery ────────────────────────────────────────────────
firmware_for() {
    # firmware_for GUEST_ARCH MICROVM
    # Prints absolute path to a firmware blob, or empty for arches that
    # don't need an explicit -bios/-drive if=pflash. Errors if expected file
    # is missing.
    local arch="$1" microvm="$2"
    case "$arch" in
        x86_64)
            if [[ "$microvm" == "true" ]]; then
                # microvm has no default firmware.  For direct -kernel boot
                # (kernel+initrd backend) nothing is needed, but the
                # disk-image backend requires a BIOS to read the MBR.
                # qboot is a minimal BIOS authored for microvm exactly this
                # use case.  Always emit it if found — harmless under
                # -kernel (QEMU bypasses BIOS for linux-boot).
                local cands=(
                    /usr/share/qemu/qboot.rom
                    /usr/share/qemu-kvm/qboot.rom
                )
                local p
                for p in "${cands[@]}"; do
                    [[ -r "$p" ]] && { printf '%s' "$p"; return 0; }
                done
                printf ''
                return 0
            fi
            local cands=(
                /usr/share/OVMF/OVMF_CODE.fd
                /usr/share/OVMF/OVMF_CODE_4M.fd
                /usr/share/edk2/ovmf/OVMF_CODE.fd
                /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
            )
            ;;
        aarch64)
            local cands=(
                /usr/share/AAVMF/AAVMF_CODE.fd
                /usr/share/qemu-efi-aarch64/QEMU_EFI.fd
                /usr/share/edk2/aarch64/QEMU_EFI.fd
            )
            ;;
        armv7l)
            local cands=(
                /usr/share/u-boot/qemu_arm/u-boot.bin
                /usr/lib/u-boot/qemu_arm/u-boot.bin
            )
            ;;
        riscv64)
            local cands=(
                /usr/share/opensbi/lp64/generic/firmware/fw_jump.elf
                /usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.elf
            )
            ;;
        ppc64le|s390x)
            # SLOF / s390-ccw bios are bundled inside the QEMU binary.
            printf ''
            return 0
            ;;
        *) die "no firmware mapping for arch $arch" ;;
    esac
    local p
    for p in "${cands[@]}"; do
        [[ -r "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    die "no firmware found for $arch.  Tried: ${cands[*]}.  Install with:  $(install_hint "$(arch_map "$arch" firmware-pkg)")"
}

# ─── TOML parser abstraction (jq required either way) ──────────────────────
toml_to_json() {
    local file="$1"
    [[ -r "$file" ]] || die "config file not readable: $file"
    if have tomlq; then
        tomlq -c '.' "$file"
    elif have yq && yq --version 2>&1 | grep -qi 'mikefarah'; then
        yq -p toml -o json "$file"
    elif have dasel; then
        dasel -f "$file" -r toml -w json
    else
        die "no TOML parser found.  Install one with:
        $(install_hint yq)        # mikefarah/yq, supports -p toml
   or   pipx install yq           # kislyuk/yq → tomlq
   or   install dasel from https://github.com/tomwright/dasel"
    fi
}

# ─── State / manifest management ────────────────────────────────────────────
state_init() {
    install -d -m 0755 "$LAB_VM_STATE_DIR" "$LAB_IMG_CACHE_DIR"
}

vm_dir()      { printf '%s/%s' "$LAB_VM_STATE_DIR" "$1"; }
vm_disk()     { printf '%s/disk.qcow2'     "$(vm_dir "$1")"; }
vm_seed()     { printf '%s/seed.iso'       "$(vm_dir "$1")"; }
vm_pidfile()  { printf '%s/qemu.pid'       "$(vm_dir "$1")"; }
vm_monitor()  { printf '%s/monitor.sock'   "$(vm_dir "$1")"; }
vm_serial()   { printf '%s/serial.sock'    "$(vm_dir "$1")"; }
vm_qmp()      { printf '%s/qmp.sock'       "$(vm_dir "$1")"; }
vm_manifest() { printf '%s/manifest.toml'  "$(vm_dir "$1")"; }
vm_log()      { printf '%s/qemu.log'       "$(vm_dir "$1")"; }

write_vm_manifest() {
    # write_vm_manifest NAME  (reads other fields from globals MF_*)
    local name="$1"
    local mp; mp="$(vm_manifest "$name")"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$mp" <<EOF
# lab-vm manifest — do not edit by hand
name        = "${name}"
backend     = "${MF_BACKEND}"
distro      = "${MF_DISTRO}"
suite       = "${MF_SUITE}"
arch        = "${MF_ARCH}"
memory      = "${MF_MEMORY}"
cpus        = ${MF_CPUS}
microvm     = ${MF_MICROVM}
accel       = "${MF_ACCEL}"
ssh_port    = ${MF_SSH_PORT}
disk        = "${MF_DISK:-}"
seed        = "${MF_SEED:-}"
kernel      = "${MF_KERNEL:-}"
initrd      = "${MF_INITRD:-}"
append      = "${MF_APPEND:-}"
ssh_user    = "${MF_SSH_USER:-lab}"
created_at  = "${now}"
version     = "${LAB_VERSION}"
EOF
}

read_manifest_field() {
    local mp; mp="$(vm_manifest "$1")"
    [[ -r "$mp" ]] || return 1
    awk -v k="$2" '
        /^[[:space:]]*#/ { next }
        $1 == k { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$mp"
}

vm_exists() { [[ -r "$(vm_manifest "$1")" ]]; }

vm_running() {
    local pf; pf="$(vm_pidfile "$1")"
    [[ -r "$pf" ]] || return 1
    local pid; pid="$(cat "$pf" 2>/dev/null || true)"
    [[ -n "$pid" ]] || return 1
    [[ -d "/proc/$pid" ]]
}

list_vm_names() {
    local d
    for d in "$LAB_VM_STATE_DIR"/*/; do
        [[ -d "$d" ]] || continue
        local n="${d%/}"; n="${n##*/}"
        printf '%s\n' "$n"
    done
}

# ─── Image cache (cloud images) ─────────────────────────────────────────────
# Mapping: distro+suite+arch → upstream URL (and known suffixes).
image_url() {
    local distro="$1" suite="$2" arch="$3"
    local a_deb a_other
    case "$arch" in
        x86_64)  a_deb=amd64;   a_other=x86_64 ;;
        aarch64) a_deb=arm64;   a_other=aarch64 ;;
        ppc64le) a_deb=ppc64el; a_other=ppc64le ;;
        s390x)   a_deb=s390x;   a_other=s390x ;;
        riscv64) a_deb=riscv64; a_other=riscv64 ;;
        armv7l)  a_deb=armhf;   a_other=armhf ;;
        *) die "unknown arch for image lookup: $arch" ;;
    esac
    case "$distro" in
        debian)
            printf 'https://cloud.debian.org/images/cloud/%s/latest/debian-%s-genericcloud-%s.qcow2' \
                "$suite" "$(debian_release_num "$suite")" "$a_deb"
            ;;
        ubuntu)
            printf 'https://cloud-images.ubuntu.com/%s/current/%s-server-cloudimg-%s.img' \
                "$suite" "$suite" "$a_deb"
            ;;
        rocky)
            printf 'https://download.rockylinux.org/pub/rocky/%s/images/%s/Rocky-%s-GenericCloud.latest.%s.qcow2' \
                "$suite" "$a_other" "$suite" "$a_other"
            ;;
        alpine)
            # NoCloud variant for cloud-init seed compatibility.
            printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/releases/cloud/nocloud_alpine-%s.0-%s-uefi-cloudinit-r0.qcow2' \
                "$suite" "$suite" "$a_other"
            ;;
        *) die "no cloud image URL for distro $distro" ;;
    esac
}

debian_release_num() {
    case "$1" in
        bookworm) printf '12' ;;
        trixie)   printf '13' ;;
        bullseye) printf '11' ;;
        buster)   printf '10' ;;
        *) die "unknown debian suite: $1 (expected bookworm/trixie/bullseye/...)" ;;
    esac
}

cache_image() {
    # cache_image DISTRO SUITE ARCH  →  prints local cache path
    local distro="$1" suite="$2" arch="$3"
    install -d -m 0755 "$LAB_IMG_CACHE_DIR"
    local url; url="$(image_url "$distro" "$suite" "$arch")"
    local fname="${distro}-${suite}-${arch}.qcow2"
    local dest="${LAB_IMG_CACHE_DIR}/${fname}"
    if [[ -r "$dest" && -s "$dest" ]]; then
        log_debug "cache hit: $dest"
        printf '%s' "$dest"
        return 0
    fi
    require_cmd curl
    log_info "downloading $url"
    local tmp="${dest}.partial"
    curl --fail --location --output "$tmp" "$url" \
        || { rm -f "$tmp"; die "download failed: $url"; }
    # If the image isn't qcow2 (e.g., raw .img), convert.
    require_cmd qemu-img
    if ! qemu-img info "$tmp" 2>/dev/null | grep -q 'file format: qcow2'; then
        log_info "converting downloaded image to qcow2"
        local tmp2="${dest}.converted"
        qemu-img convert -O qcow2 "$tmp" "$tmp2" \
            || { rm -f "$tmp" "$tmp2"; die "qemu-img convert failed"; }
        mv "$tmp2" "$dest"
        rm -f "$tmp"
    else
        mv "$tmp" "$dest"
    fi
    log_info "cached at $dest"
    printf '%s' "$dest"
}

# ═══════════════════════════════════════════════════════════════════════
# Alpine microvm builder — follow-ups 1-4 rolled into lab-vm.sh itself.
#
# Given (suite, arch) + feature flags, produce a self-contained microvm
# kernel + initramfs.  Handles:
#   1. Auto-build  — fetch kernel + minirootfs + apk.static into cache
#   2. Networking  — udhcpc eth0 at boot (network=true)
#   3. SSH         — dropbear + authorized_keys (ssh=true)
#   4. Persist     — /data mount from a virtio-blk disk (persist=SIZE)
# ═══════════════════════════════════════════════════════════════════════

# Known-good patch versions per Alpine suite.  Update when new patches ship.
alpine_patch_for_suite() {
    case "$1" in
        3.19) printf '5' ;;
        3.20) printf '3' ;;
        *)    die "alpine microvm: no known patch version for suite $1 (update alpine_patch_for_suite)" ;;
    esac
}

# Parse APKINDEX to find the current version of a package in a given
# suite/repo.  APKINDEX is a newline-separated, blank-line-delimited
# record set bundled inside APKINDEX.tar.gz.  Each record has:
#
#   P:<package-name>
#   V:<version>
#   ...other fields...
#
# Writing this ourselves (rather than shelling out to apk.static --search)
# avoids the chicken-and-egg of needing apk.static to FIND apk.static.
alpine_query_pkg_version() {
    local suite="$1" arch="$2" pkg="$3"
    require_cmd curl tar awk
    local cache; cache="$(alpine_mv_cache_dir "$suite" "$arch")/APKINDEX"
    local url; url="$(alpine_mirror_base "$suite" "$arch" main)/APKINDEX.tar.gz"
    # Refresh the index if older than 1 day — versions drift slowly.
    if [[ ! -s "$cache" ]] || [[ $(find "$cache" -mtime +1 2>/dev/null) ]]; then
        local tmp; tmp="$(mktemp -d)"
        install -d -m 0755 "$(dirname "$cache")"
        curl --fail --silent --location --output "$tmp/APKINDEX.tar.gz" "$url" \
            || { rm -rf "$tmp"; die "could not fetch $url"; }
        tar -xzf "$tmp/APKINDEX.tar.gz" -C "$tmp" APKINDEX 2>/dev/null
        mv "$tmp/APKINDEX" "$cache"
        rm -rf "$tmp"
    fi
    awk -v pkg="$pkg" '
        BEGIN { RS = ""; FS = "\n" }
        {
            name = ""; ver = ""
            for (i = 1; i <= NF; i++) {
                if (substr($i, 1, 2) == "P:") name = substr($i, 3)
                if (substr($i, 1, 2) == "V:") ver  = substr($i, 3)
            }
            if (name == pkg) { print ver; exit }
        }
    ' "$cache"
}

alpine_mirror_base() {
    # $1=suite, $2=arch, $3=repo (main|community)
    printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/%s/%s' "$1" "$3" "$2"
}

alpine_netboot_base() {
    # $1=suite, $2=arch
    printf 'https://dl-cdn.alpinelinux.org/alpine/v%s/releases/%s' "$1" "$2"
}

alpine_mv_cache_dir() {
    # Shared cache dir for alpine microvm artifacts.  $1=suite, $2=arch
    printf '%s/netboot/alpine-%s-%s' "$LAB_CACHE_DIR" "$1" "$2"
}

# Download a URL to cache if missing; print the local path.
alpine_mv_fetch() {
    local url="$1" dest="$2"
    if [[ ! -s "$dest" ]]; then
        require_cmd curl
        install -d -m 0755 "$(dirname "$dest")"
        log_info "downloading $url"
        curl --fail --location --output "${dest}.partial" "$url" \
            || { rm -f "${dest}.partial"; die "download failed: $url"; }
        mv "${dest}.partial" "$dest"
    fi
    printf '%s' "$dest"
}

# Kernel for alpine microvm.
cache_alpine_microvm_kernel() {
    local suite="$1" arch="$2"
    local dir; dir="$(alpine_mv_cache_dir "$suite" "$arch")"
    alpine_mv_fetch "$(alpine_netboot_base "$suite" "$arch")/netboot/vmlinuz-virt" \
                    "$dir/vmlinuz-virt"
}

# Minirootfs tarball (still compressed — extract at build time).
cache_alpine_minirootfs_tar() {
    local suite="$1" arch="$2" patch="$3"
    local dir; dir="$(alpine_mv_cache_dir "$suite" "$arch")"
    local f="alpine-minirootfs-${suite}.${patch}-${arch}.tar.gz"
    alpine_mv_fetch "$(alpine_netboot_base "$suite" "$arch")/$f" "$dir/$f"
}

# modloop-virt (squashfs of kernel modules).  Extracted once into the
# shared cache; returns the path to the .../modules/<kver> tree.
# Why we need this:
#   Alpine's vmlinuz-virt is built for VMs that mount modloop-virt at
#   boot (the netboot installer does this automatically via the alpine
#   init script).  Core virtio drivers — virtio_mmio, virtio_blk,
#   virtio_net — ship as MODULES, not builtin.  Our initramfs runs its
#   own init, never touches modloop, and therefore has no eth0/vda.
#   So: download modloop, extract it, and cherry-pick the modules we
#   need into the initramfs.
cache_alpine_modloop_tree() {
    local suite="$1" arch="$2"
    local dir; dir="$(alpine_mv_cache_dir "$suite" "$arch")"
    local extract="$dir/modloop-extracted"
    if [[ -d "$extract/modules" ]]; then
        printf '%s' "$extract"; return 0
    fi
    command -v unsquashfs >/dev/null 2>&1 \
        || die "unsquashfs not found.  Install with: apt-get install squashfs-tools (Debian/Ubuntu) or dnf install squashfs-tools (Fedora/Rocky)"
    local ml; ml="$dir/modloop-virt"
    # alpine_mv_fetch echoes the dest path to stdout; redirect or it
    # concatenates into our own final printf and breaks the caller's
    # `$(cache_alpine_modloop_tree ...)` capture.
    alpine_mv_fetch "$(alpine_netboot_base "$suite" "$arch")/netboot/modloop-virt" "$ml" >/dev/null
    log_info "extracting modloop-virt → $extract"
    rm -rf "$extract"
    unsquashfs -q -f -d "$extract" "$ml" >/dev/null 2>&1 \
        || die "unsquashfs failed on $ml"
    printf '%s' "$extract"
}

# Install a curated subset of kernel modules into the staging initramfs:
# virtio transport (pci + mmio) and the drivers for block + network.
# These are enough to bring up eth0 and /dev/vda on microvm.  Uses the
# pre-built modules.{dep,alias,builtin} from modloop so modprobe deps
# resolve cleanly — we don't need depmod on the host.
_alpine_mv_install_modules() {
    local root="$1" modloop_root="$2"
    local kmodules="$modloop_root/modules"
    local kver; kver="$(ls "$kmodules" | head -1)"
    [[ -n "$kver" ]] || die "no kernel version found in $kmodules"
    log_info "installing kernel modules (kernel=$kver)"

    local dst="$root/lib/modules/$kver"
    mkdir -p "$dst"

    # Preserve dep/alias indices so modprobe works.
    cp "$kmodules/$kver/modules.dep"     "$dst/" 2>/dev/null || true
    cp "$kmodules/$kver/modules.alias"   "$dst/" 2>/dev/null || true
    cp "$kmodules/$kver/modules.builtin" "$dst/" 2>/dev/null || true
    cp "$kmodules/$kver/modules.symbols" "$dst/" 2>/dev/null || true

    # Core virtio transport + infrastructure (virtio, virtio_ring, and
    # both PCI and MMIO transports).
    mkdir -p "$dst/kernel/drivers/virtio"
    cp -a "$kmodules/$kver/kernel/drivers/virtio/." "$dst/kernel/drivers/virtio/" 2>/dev/null

    # Specific modules we need + their transitive deps.  Alpine -virt
    # ships almost everything as modules, so each feature we enable
    # trails a small dependency chain.  Grouped by purpose below; when
    # adding more, always check modules.dep first:
    #   grep ^kernel/.../foo\.ko modules.dep
    local m
    for m in \
        kernel/drivers/block/virtio_blk.ko   \
        kernel/drivers/net/virtio_net.ko     \
        kernel/drivers/net/net_failover.ko   \
        kernel/net/core/failover.ko          \
        kernel/net/packet/af_packet.ko       \
        kernel/drivers/char/virtio_console.ko \
        kernel/fs/ext4/ext4.ko               \
        kernel/fs/jbd2/jbd2.ko               \
        kernel/fs/mbcache.ko                 \
        kernel/lib/crc16.ko                  \
        kernel/crypto/crc32c_generic.ko
    do
        if [[ -f "$kmodules/$kver/$m" ]]; then
            install -d "$dst/$(dirname "$m")"
            cp "$kmodules/$kver/$m" "$dst/$m"
        fi
    done
}

# apk-tools-static: extract apk.static from the .apk (which is a tar.gz).
# Version is resolved dynamically from APKINDEX so we never rot on
# Alpine mirrors dropping old package builds.
cache_alpine_apk_static() {
    local suite="$1" arch="$2"
    local dir; dir="$(alpine_mv_cache_dir "$suite" "$arch")"
    local out="$dir/apk.static"
    if [[ -x "$out" ]]; then printf '%s' "$out"; return 0; fi

    require_cmd curl tar
    local ver; ver="$(alpine_query_pkg_version "$suite" "$arch" apk-tools-static)"
    [[ -n "$ver" ]] || die "apk-tools-static not listed in Alpine $suite/main APKINDEX"
    log_info "apk-tools-static: version $ver (from APKINDEX)"
    local url="$(alpine_mirror_base "$suite" "$arch" main)/apk-tools-static-${ver}.apk"
    local tmp; tmp="$(mktemp)"
    curl --fail --silent --location --output "$tmp" "$url" \
        || { rm -f "$tmp"; die "fetch failed: $url"; }
    local extract_dir; extract_dir="$(mktemp -d)"
    # .apk is a concatenation of signature + control + data gzipped streams.
    # tar errors on the non-data sections but still extracts the data payload.
    tar -xzf "$tmp" -C "$extract_dir" 2>/dev/null || true
    [[ -x "$extract_dir/sbin/apk.static" ]] \
        || { rm -rf "$extract_dir" "$tmp"; die "apk-tools-static $ver has no /sbin/apk.static payload"; }
    install -m 0755 "$extract_dir/sbin/apk.static" "$out"
    rm -rf "$extract_dir" "$tmp"
    printf '%s' "$out"
}

# Install packages into a staging root using apk.static.  Uses
# --allow-untrusted since we're not threading Alpine's signing keys
# through; the apk downloads come from dl-cdn.alpinelinux.org over
# HTTPS, which is our trust boundary here.
alpine_apk_add() {
    local suite="$1" arch="$2" root="$3"; shift 3
    local apk_static; apk_static="$(cache_alpine_apk_static "$suite" "$arch")"
    local repo; repo="$(alpine_mirror_base "$suite" "$arch" main)"
    local repo_c; repo_c="$(alpine_mirror_base "$suite" "$arch" community)"
    log_info "apk add into $root: $*"
    # Notes on the flags used:
    #   --initdb         initialize a fresh apk db inside $root (the
    #                    minirootfs ships an *installed-packages* list but
    #                    not an apk-tools cache; without --initdb, apk
    #                    can't write lock/index files and fails obscurely).
    #   --allow-untrusted  skip signature verification — we trust the
    #                    dl-cdn HTTPS mirror as our trust boundary here.
    #   --no-scripts     skip maintainer scripts; those try to chroot into
    #                    $root, which needs CAP_SYS_CHROOT (not typical
    #                    non-root).  Missing a post-install step is OK for
    #                    our use case (we're about to cpio-pack anyway).
    # We also swallow "errors updating directory permissions" and trigger
    # chroot failures — they're expected when running as non-root, and the
    # package *files* have still been placed correctly.
    "$apk_static" \
        --root "$root" \
        --arch "$arch" \
        --initdb --allow-untrusted --no-cache --no-scripts \
        --repository "$repo" \
        --repository "$repo_c" \
        add "$@" 2>&1 \
        | grep -vE 'errors updating directory permissions|chroot: Operation not permitted|busybox-.*\.trigger' \
        >&2 \
        || true
    # Verify at least the requested packages' headline binaries landed.
    local pkg
    for pkg in "$@"; do
        case "$pkg" in
            dropbear)   [[ -x "$root/usr/sbin/dropbear" ]] || die "dropbear install failed (no /usr/sbin/dropbear)" ;;
            e2fsprogs)  [[ -x "$root/sbin/mkfs.ext4"     ]] || die "e2fsprogs install failed (no /sbin/mkfs.ext4)" ;;
            iproute2)   [[ -x "$root/sbin/ip"            ]] || die "iproute2 install failed (no /sbin/ip)" ;;
        esac
    done
}

# Emit a feature-gated busybox init configuration into the staging root.
# Creates /sbin/init -> /bin/busybox and a matching /etc/inittab.
_alpine_mv_emit_busybox_init() {
    local root="$1" want_network="$2" want_ssh="$3" want_persist="$4"
    mkdir -p "$root/sbin" "$root/etc"
    ln -sf /bin/busybox "$root/sbin/init"

    # Build inittab programmatically so feature flags compose cleanly.
    local inittab="$root/etc/inittab"
    {
        cat <<'HEAD'
# microvm inittab — generated by lab-vm.sh
::sysinit:/bin/mount -t proc     none /proc
::sysinit:/bin/mount -t sysfs    none /sys
::sysinit:/bin/mount -t devtmpfs none /dev
::sysinit:/bin/mount -t tmpfs    none /tmp
::sysinit:/bin/mount -t tmpfs    none /run
::sysinit:/bin/hostname alpine-microvm
# Load drivers extracted from modloop-virt.  Order is irrelevant —
# modprobe resolves deps via modules.dep.  af_packet is needed by
# udhcpc (DHCP clients open AF_PACKET raw sockets for the initial
# bootp broadcast before an IP is assigned).
::sysinit:/sbin/modprobe virtio_mmio
::sysinit:/sbin/modprobe virtio_pci
::sysinit:/sbin/modprobe virtio_blk
::sysinit:/sbin/modprobe virtio_net
::sysinit:/sbin/modprobe af_packet
::sysinit:/sbin/modprobe ext4
HEAD
        if [[ "$want_persist" == "1" ]]; then
            cat <<'PERSIST'
# Mount the persistence disk at /data.  virtio_blk loads synchronously
# but the device probe is async — /dev/vda may not exist in devtmpfs
# the instant modprobe returns.  Poll briefly (1s max) before giving up.
# Format-on-first-boot: if the disk has no filesystem yet, lay down ext4.
::sysinit:/bin/sh -c 'for i in 1 2 3 4 5; do [ -b /dev/vda ] && break; sleep 0.2; done; [ -b /dev/vda ] && { /bin/mkdir -p /data; blkid /dev/vda >/dev/null 2>&1 || /sbin/mkfs.ext4 -F -L labdata /dev/vda >/dev/null 2>&1; /bin/mount /dev/vda /data; }'
PERSIST
        fi
        if [[ "$want_network" == "1" ]]; then
            cat <<'NET'
# Bring up eth0 and DHCP (user-mode slirp serves 10.0.2.0/24).
::sysinit:/sbin/ip link set eth0 up
::sysinit:/sbin/udhcpc -i eth0 -b -t 3 -n -q -s /usr/share/udhcpc/default.script
NET
        fi
        if [[ "$want_ssh" == "1" ]]; then
            cat <<'SSH'
# Generate host keys on first boot; start dropbear.
::sysinit:/bin/sh -c '[ -s /etc/dropbear/dropbear_ed25519_host_key ] || { /bin/mkdir -p /etc/dropbear; /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1; /usr/bin/dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1; }'
::sysinit:/bin/sh -c '/usr/sbin/dropbear -R -B -F 2>/dev/null &'
SSH
        fi
        cat <<'TAIL'

# Interactive login shell on the serial console, respawned if exited.
# `-l` sources /etc/profile → /etc/profile.d/*.sh → banner prints.
ttyS0::respawn:/bin/sh -l

# Handle poweroff/reboot cleanly.
::shutdown:/bin/umount -a -r
::ctrlaltdel:/sbin/reboot
TAIL
    } > "$inittab"

    # Drop a banner for the serial console.
    mkdir -p "$root/etc/profile.d"
    cat > "$root/etc/profile.d/labvm-banner.sh" <<'BANNER'
if [ -z "$LABVM_BANNER_SHOWN" ]; then
    export LABVM_BANNER_SHOWN=1
    printf '\n═══════════════════════════════════════════════\n'
    printf ' alpine microvm (lab-vm.sh auto-build)\n'
    printf '═══════════════════════════════════════════════\n'
    printf ' kernel : %s\n' "$(uname -r)"
    [ -d /data ] && printf ' persist: /data (size: %s)\n' "$(df -h /data 2>/dev/null | awk 'NR==2{print $2}')"
    command -v dropbear >/dev/null 2>&1 && printf ' sshd   : dropbear on :22\n'
    command -v udhcpc >/dev/null 2>&1 && printf ' net    : eth0 via udhcpc\n'
    printf '\n'
fi
BANNER
    mkdir -p "$root/etc/profile.d"
}

# Emit a hand-rolled C init (myinit.c) into the staging root, compiled
# statically with -D flags matching the feature set.  Replaces /sbin/init.
#
# Design choice: PID 1 duties stay in C (mount, fork, setsid + TIOCSCTTY,
# waitpid reap, reboot syscall), and the "messy" setup (udhcpc, mkfs,
# dropbearkey) is delegated to fork+exec of /bin/sh — which keeps the C
# source readable AND correctly sequences work that would otherwise require
# reimplementing apk's post-install scripts in C.
_alpine_mv_emit_custom_init() {
    local root="$1" want_network="$2" want_ssh="$3" want_persist="$4"
    command -v cc >/dev/null 2>&1 \
        || die "init_flavour=custom needs 'cc' on the host (apt install build-essential, or dnf install gcc)"

    # cc infers language from extension; .c is required or ld misreads
    # the stdin-style temp as a linker script.
    local src; src="$(mktemp --suffix=.c)"
    cat > "$src" <<'MYINIT_C'
/*
 * myinit.c — a minimal hand-rolled PID 1 for an Alpine microvm.
 * Compile-time flags (wire up features without touching this source):
 *   -DLAB_NETWORK   run udhcpc on eth0 at boot
 *   -DLAB_SSH       generate dropbear host keys + start dropbear
 *   -DLAB_PERSIST   format & mount /dev/vda at /data (first-boot ext4)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t want_poweroff = 0;
static volatile sig_atomic_t want_reboot   = 0;
static void on_poweroff(int s) { (void)s; want_poweroff = 1; }
static void on_rebootreq(int s){ (void)s; want_reboot   = 1; }

static void try_mount(const char *s, const char *t, const char *ty) {
    if (mount(s, t, ty, 0, NULL) < 0 && errno != EBUSY)
        fprintf(stderr, "[myinit] mount %s (%s): %s\n", t, ty, strerror(errno));
}

/* fork/exec /bin/sh -c CMD, wait for completion.  Used for setup steps
 * where a tiny shell pipeline is easier to read than equivalent C. */
static void run_setup(const char *name, const char *script) {
    dprintf(2, "[myinit] setup: %s\n", name);
    pid_t pid = fork();
    if (pid < 0) { perror("[myinit] fork setup"); return; }
    if (pid == 0) {
        execl("/bin/sh", "sh", "-c", script, (char *)NULL);
        _exit(127);
    }
    int st; waitpid(pid, &st, 0);
    if (WIFEXITED(st) && WEXITSTATUS(st) != 0)
        dprintf(2, "[myinit] setup '%s' exited %d\n", name, WEXITSTATUS(st));
}

static pid_t spawn_shell(void) {
    pid_t pid = fork();
    if (pid < 0) { perror("[myinit] fork shell"); return -1; }
    if (pid > 0) return pid;

    if (setsid() < 0) perror("[myinit] setsid");
    int tty = open("/dev/ttyS0", O_RDWR);
    if (tty < 0) { perror("[myinit] open /dev/ttyS0"); _exit(1); }
    if (ioctl(tty, TIOCSCTTY, 0) < 0) perror("[myinit] TIOCSCTTY");
    dup2(tty, 0); dup2(tty, 1); dup2(tty, 2);
    if (tty > 2) close(tty);

    struct sigaction dfl = { .sa_handler = SIG_DFL };
    sigaction(SIGINT,  &dfl, NULL);
    sigaction(SIGQUIT, &dfl, NULL);
    sigaction(SIGTSTP, &dfl, NULL);
    sigaction(SIGTTIN, &dfl, NULL);
    sigaction(SIGTTOU, &dfl, NULL);

    execl("/bin/sh", "-sh", (char *)NULL);
    perror("[myinit] exec /bin/sh");
    _exit(127);
}

int main(void) {
    /* 1. Pseudofs */
    mkdir("/proc", 0555);  mkdir("/sys", 0555);
    mkdir("/dev",  0755);  mkdir("/tmp", 01777);  mkdir("/run", 0755);
    try_mount("none", "/proc", "proc");
    try_mount("none", "/sys",  "sysfs");
    try_mount("none", "/dev",  "devtmpfs");
    try_mount("none", "/tmp",  "tmpfs");
    try_mount("none", "/run",  "tmpfs");

    /* 2. Load virtio drivers from /lib/modules (extracted from Alpine's
     *    modloop-virt by the builder — without this, microvm has no
     *    eth0 or /dev/vda because the Alpine -virt kernel ships these
     *    drivers as modules).  Always runs — harmless if nothing needs
     *    them.  Ordering: this FIRST so persist/network below have
     *    block + net devices to work with.                              */
    run_setup("modules",
        "modprobe virtio_mmio; "
        "modprobe virtio_pci; "
        "modprobe virtio_blk; "
        "modprobe virtio_net; "
        "modprobe af_packet; "
        "modprobe ext4");

    /* 3. Feature setup — each block is a no-op unless its -D flag was
     *    set at compile time.  Ordering: persist first (so /data exists
     *    before anyone writes there), network next (so sshd can bind
     *    its listener on a usable interface).                            */
#ifdef LAB_PERSIST
    /* Poll /dev/vda briefly — virtio_blk probe is async vs modprobe. */
    run_setup("persist",
        "for i in 1 2 3 4 5; do [ -b /dev/vda ] && break; sleep 0.2; done; "
        "[ -b /dev/vda ] && mkdir -p /data && "
        "{ blkid /dev/vda >/dev/null 2>&1 || mkfs.ext4 -F -L labdata /dev/vda >/dev/null 2>&1; } && "
        "mount /dev/vda /data");
#endif
#ifdef LAB_NETWORK
    run_setup("network",
        "ip link set eth0 up && "
        "udhcpc -i eth0 -b -t 3 -n -q -s /usr/share/udhcpc/default.script");
#endif
#ifdef LAB_SSH
    run_setup("sshd",
        "mkdir -p /etc/dropbear && "
        "{ [ -s /etc/dropbear/dropbear_ed25519_host_key ] || dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1; } && "
        "{ [ -s /etc/dropbear/dropbear_rsa_host_key ]     || dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1; } && "
        "dropbear -R -B 2>/dev/null");
#endif

    /* 3. Banner */
    int b = open("/dev/ttyS0", O_WRONLY);
    if (b >= 0) {
        dprintf(b,
            "\n"
            "═══════════════════════════════════════════════\n"
            " alpine microvm — hand-rolled PID 1 (myinit.c)\n"
            "═══════════════════════════════════════════════\n"
            " flavour: custom (static C binary)\n"
#ifdef LAB_NETWORK
            " net    : udhcpc eth0\n"
#endif
#ifdef LAB_SSH
            " sshd   : dropbear :22\n"
#endif
#ifdef LAB_PERSIST
            " persist: /data (ext4 on /dev/vda)\n"
#endif
            "\n poweroff: `poweroff -f`  (direct reboot syscall)\n"
            " or      : `poweroff`     (SIGUSR2 to PID 1)\n\n");
        close(b);
    }

    /* 4. Signal handlers + supervise loop */
    struct sigaction sa = { 0 };
    sa.sa_handler = on_poweroff;
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_rebootreq;
    sigaction(SIGINT, &sa, NULL);

    pid_t shell = spawn_shell();
    for (;;) {
        if (want_poweroff) { sync(); reboot(RB_POWER_OFF); _exit(0); }
        if (want_reboot)   { sync(); reboot(RB_AUTOBOOT);  _exit(0); }
        int st; pid_t who = waitpid(-1, &st, 0);
        if (who < 0) {
            if (errno == EINTR)  continue;
            if (errno == ECHILD) { shell = spawn_shell(); continue; }
            perror("[myinit] waitpid"); continue;
        }
        if (who == shell) shell = spawn_shell();
    }
}
MYINIT_C

    # Build the -D list matching the feature flags.
    local defs=()
    (( want_network )) && defs+=(-DLAB_NETWORK)
    (( want_ssh     )) && defs+=(-DLAB_SSH)
    (( want_persist )) && defs+=(-DLAB_PERSIST)

    mkdir -p "$root/sbin"
    log_info "compiling custom init (flags: ${defs[*]:-none})"
    cc -static -Os -Wall -Wextra "${defs[@]}" -o "$root/sbin/init" "$src" \
        || { rm -f "$src"; die "custom-init compile failed"; }
    strip "$root/sbin/init" 2>/dev/null || true
    rm -f "$src"

    # Also drop a banner in /etc/profile.d — the respawn shell will be
    # spawned by myinit with stdin/stdout on ttyS0; -sh starts a login
    # shell which sources /etc/profile.
    mkdir -p "$root/etc/profile.d"
    cat > "$root/etc/profile.d/labvm-banner.sh" <<'BANNER'
if [ -z "$LABVM_BANNER_SHOWN" ]; then
    export LABVM_BANNER_SHOWN=1
    printf '\n[login shell] kernel=%s  uptime=%ss\n' "$(uname -r)" "$(cut -d' ' -f1 /proc/uptime)"
    [ -d /data ] && printf '[login shell] /data mounted: %s\n' "$(df -h /data 2>/dev/null | awk 'NR==2{print $2}')"
    printf '\n'
fi
BANNER
}

# Master entry point: build (or fetch from cache) the initramfs matching
# the requested flavour + feature set.  Prints the path to the initramfs.
build_alpine_microvm_initramfs() {
    local suite="$1" arch="$2"
    local want_network="$3" want_ssh="$4" want_persist="$5"
    local pubkey="$6" init_flavour="${7:-busybox}"

    case "$init_flavour" in
        busybox|custom) ;;
        *) die "init_flavour must be 'busybox' or 'custom' (got: $init_flavour)" ;;
    esac

    local patch;  patch="$(alpine_patch_for_suite "$suite")"
    local cache;  cache="$(alpine_mv_cache_dir "$suite" "$arch")"
    install -d -m 0755 "$cache"

    # Cache key: flavour + feature flags + (if ssh) pubkey fingerprint.
    # Rotating any of these forces a rebuild; reusing the same set is a
    # cache hit in microseconds.
    local flags=""
    (( want_network )) && flags+="n"
    (( want_ssh     )) && flags+="s"
    (( want_persist )) && flags+="p"
    [[ -z "$flags" ]] && flags="base"
    local keyhash=""
    if (( want_ssh )) && [[ -n "$pubkey" ]]; then
        keyhash="-$(printf '%s' "$pubkey" | sha256sum | cut -c1-8)"
    fi
    local out="$cache/initramfs-${init_flavour}-${flags}${keyhash}.gz"
    if [[ -s "$out" ]]; then
        log_debug "initramfs cache hit: $out"
        printf '%s' "$out"
        return 0
    fi

    # Fetch inputs.
    local tar; tar="$(cache_alpine_minirootfs_tar "$suite" "$arch" "$patch")"

    local work; work="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$work'" RETURN

    log_info "extracting minirootfs → $work"
    tar -xzf "$tar" -C "$work"

    # Install kernel modules (virtio drivers) — required for network +
    # block devices on alpine -virt kernel regardless of feature flags,
    # because the microvm's devices are virtio.
    local modloop_root; modloop_root="$(cache_alpine_modloop_tree "$suite" "$arch")"
    _alpine_mv_install_modules "$work" "$modloop_root"

    # Add extra packages if any features need them.
    local pkgs=()
    (( want_ssh     )) && pkgs+=(dropbear)
    (( want_persist )) && pkgs+=(e2fsprogs blkid)
    (( want_network )) && pkgs+=(iproute2)
    if (( ${#pkgs[@]} > 0 )); then
        alpine_apk_add "$suite" "$arch" "$work" "${pkgs[@]}"
    fi

    # SSH: pubkey + clear root password.  The shadow clear MUST run even
    # when the user has no pubkey (dropbear refuses accounts with locked
    # password `*`), so it's deliberately outside the pubkey branch.
    if (( want_ssh )); then
        sed -i 's|^root:[^:]*:|root::|' "$work/etc/shadow" 2>/dev/null || true
        if [[ -n "$pubkey" ]]; then
            mkdir -p "$work/root/.ssh"
            chmod 700 "$work/root/.ssh"
            printf '%s\n' "$pubkey" > "$work/root/.ssh/authorized_keys"
            chmod 600 "$work/root/.ssh/authorized_keys"
        else
            log_warn "ssh=true but no SSH public key found on host — falling back to blank-password auth (dropbear -B).  Consider: ssh-keygen -t ed25519"
        fi
    fi

    # Install the init — pick emitter based on flavour.
    case "$init_flavour" in
        busybox) _alpine_mv_emit_busybox_init "$work" "$want_network" "$want_ssh" "$want_persist" ;;
        custom)  _alpine_mv_emit_custom_init  "$work" "$want_network" "$want_ssh" "$want_persist" ;;
    esac

    log_info "packing cpio → $out"
    (cd "$work" && find . -print0 \
        | cpio --null -o -H newc --owner=0:0 --quiet \
        | gzip -9) > "${out}.partial"
    mv "${out}.partial" "$out"
    printf '%s' "$out"
}

# ─── cloud-init NoCloud seed ─────────────────────────────────────────────────
default_pubkey() {
    # Find a usable SSH public key. Prefer the invoking user's, not root's.
    # Skips files that are missing, empty, or don't contain a recognisable key.
    local home="${SUDO_USER:+/home/$SUDO_USER}"; home="${home:-$HOME}"
    local f keys
    for f in "${home}/.ssh/id_ed25519.pub" "${home}/.ssh/id_ecdsa.pub" \
             "${home}/.ssh/id_rsa.pub"     "${home}/.ssh/authorized_keys"; do
        [[ -r "$f" && -s "$f" ]] || continue
        keys="$(grep -E '^(ssh-(rsa|ed25519|dss)|ecdsa-) ' "$f" 2>/dev/null || true)"
        if [[ -n "$keys" ]]; then
            printf '%s\n' "$keys"
            return 0
        fi
    done
    return 1
}

make_seed_iso() {
    # make_seed_iso NAME OUT_PATH PUBKEY_OPTIONAL DISTRO_OPTIONAL
    # Note: we use a subshell + EXIT trap rather than a function-level RETURN
    # trap, because RETURN traps in bash are global and fire for every later
    # function return — they cannot reference now-out-of-scope locals.
    local name="$1" out="$2" pubkey="${3:-}" distro="${4:-}"
    # Alpine ships busybox's /bin/ash by default and no /bin/bash — setting
    # shell=/bin/bash in the cloud-init user block would let the account
    # authenticate but then fail at session start with "can't execute
    # /bin/bash: No such file or directory".  Pick the right shell per distro.
    local user_shell
    case "$distro" in
        alpine) user_shell="/bin/ash"  ;;
        *)      user_shell="/bin/bash" ;;
    esac
    if   have genisoimage; then :
    elif have xorrisofs;   then :
    elif have mkisofs;     then :
    else die "no ISO maker (need genisoimage, xorriso, or mkisofs)"
    fi

    ( set -e
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      cat > "$tmp/meta-data" <<EOF
instance-id: lab-vm-${name}
local-hostname: ${name}
EOF

    {
        printf '#cloud-config\n'
        printf 'preserve_hostname: false\n'
        printf 'hostname: %s\n' "$name"
        printf 'manage_etc_hosts: true\n'
        printf 'users:\n'
        printf '  - default\n'
        printf '  - name: lab\n'
        # Privilege escalation: Debian/Ubuntu/Rocky/etc. ship sudo; Alpine
        # ships doas (sudo isn't installed by default).  Writing a sudo
        # rule on Alpine is a silent no-op, so branch.
        case "$distro" in
            alpine)
                printf '    groups: [wheel]\n'
                ;;
            *)
                printf '    sudo: ALL=(ALL) NOPASSWD:ALL\n'
                printf '    groups: [sudo, wheel]\n'
                ;;
        esac
        printf '    shell: %s\n' "$user_shell"
        printf '    lock_passwd: false\n'
        printf "    plain_text_passwd: 'lab'\n"
        if [[ -n "$pubkey" ]]; then
            printf '    ssh_authorized_keys:\n'
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                printf '      - %s\n' "$line"
            done <<<"$pubkey"
        fi
        printf 'ssh_pwauth: true\n'
        printf 'chpasswd:\n'
        printf "  list: |\n"
        printf "    root:lab\n"
        printf "  expire: false\n"
        # On Alpine, drop in a doas rule granting lab passwordless root.
        # Stock Alpine cloud images already have doas installed and read
        # /etc/doas.d/*.conf at runtime; no package install needed.
        if [[ "$distro" == "alpine" ]]; then
            printf 'write_files:\n'
            printf '  - path: /etc/doas.d/lab.conf\n'
            printf "    permissions: '0400'\n"
            printf '    owner: root:root\n'
            printf '    content: |\n'
            printf '      permit nopass lab\n'
        fi
    } > "$tmp/user-data"

      if have genisoimage; then
          genisoimage -output "$out" -volid cidata -joliet -rock \
              "$tmp/user-data" "$tmp/meta-data" >/dev/null 2>&1
      elif have xorrisofs; then
          xorrisofs -o "$out" -V cidata -J -r \
              "$tmp/user-data" "$tmp/meta-data" >/dev/null 2>&1
      else
          mkisofs -output "$out" -volid cidata -joliet -rock \
              "$tmp/user-data" "$tmp/meta-data" >/dev/null 2>&1
      fi
    )
    log_debug "seed iso → $out"
}

# ─── Spec construction ─────────────────────────────────────────────────────
spec_from_cli() {
    require_cmd jq
    jq -n \
        --arg name     "${OPT_NAME:-}" \
        --arg backend  "${OPT_BACKEND:-disk-image}" \
        --arg distro   "${OPT_DISTRO:-}" \
        --arg suite    "${OPT_SUITE:-}" \
        --arg arch     "${OPT_ARCH:-$(detect_host_arch)}" \
        --arg memory   "${OPT_MEMORY:-2G}" \
        --arg cpus     "${OPT_CPUS:-2}" \
        --arg microvm  "${OPT_MICROVM:-false}" \
        --arg image    "${OPT_IMAGE:-}" \
        --arg kernel   "${OPT_KERNEL:-}" \
        --arg initrd   "${OPT_INITRD:-}" \
        --arg append   "${OPT_APPEND:-}" \
        --arg ssh_port "${OPT_SSH_PORT:-0}" \
        --arg pubkey   "${OPT_PUBKEY:-}" \
        --arg network  "${OPT_NETWORK:-false}" \
        --arg ssh      "${OPT_SSH_ENABLE:-false}" \
        --arg persist  "${OPT_PERSIST:-}" \
        --arg init_flavour "${OPT_INIT_FLAVOUR:-busybox}" \
        '{name:$name, backend:$backend, distro:$distro, suite:$suite, arch:$arch,
          memory:$memory, cpus:($cpus|tonumber), microvm:($microvm=="true"),
          image:$image, kernel:$kernel, initrd:$initrd, append:$append,
          ssh_port:($ssh_port|tonumber), pubkey:$pubkey,
          network:($network=="true"), ssh:($ssh=="true"), persist:$persist,
          init_flavour:$init_flavour}'
}

specs_from_config() {
    local file="$1"
    require_cmd jq
    local json; json="$(toml_to_json "$file")"
    printf '%s' "$json" | jq -c '
        if .vm? then (.vm | if type=="array" then .[] else . end) else . end
        | { name:    (.name    // ""),
            backend: (.backend // "disk-image"),
            distro:  (.distro  // ""),
            suite:   (.suite   // ""),
            arch:    (.arch    // ""),
            memory:  (.memory  // "2G"),
            cpus:    (.cpus    // 2),
            microvm: (.microvm // false),
            image:   (.image   // ""),
            kernel:  (.kernel  // ""),
            initrd:  (.initrd  // ""),
            append:  (.append  // ""),
            ssh_port:(.ssh_port // 0),
            pubkey:  (.pubkey  // ""),
            network: (.network // false),
            ssh:     (.ssh     // false),
            persist: (.persist // ""),
            init_flavour: (.init_flavour // "busybox") }
    '
}

spec_get() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }

# ─── Validation ─────────────────────────────────────────────────────────────
validate_spec() {
    local spec="$1"
    local name backend arch
    name="$(spec_get "$spec" name)"
    backend="$(spec_get "$spec" backend)"
    arch="$(spec_get "$spec" arch)"

    [[ -n "$name"    ]] || die "spec missing required field: name"
    [[ -n "$arch"    ]] || die "spec ($name) missing arch"
    is_known_arch "$arch" || die "spec ($name) unknown arch: $arch"

    case "$backend" in
        disk-image)
            local distro suite
            distro="$(spec_get "$spec" distro)"
            suite="$(spec_get "$spec" suite)"
            local image; image="$(spec_get "$spec" image)"
            if [[ -z "$image" ]]; then
                [[ -n "$distro" && -n "$suite" ]] \
                    || die "spec ($name) backend=disk-image needs either image or (distro+suite)"
            fi
            ;;
        kernel+initrd)
            local kernel initrd distro suite
            kernel="$(spec_get "$spec" kernel)"
            initrd="$(spec_get "$spec" initrd)"
            distro="$(spec_get "$spec" distro)"
            suite="$(spec_get "$spec" suite)"
            # If both paths are empty and distro=alpine + suite is set, the
            # kernel+initrd will be auto-built at create-time (follow-up 1:
            # auto-build).  Only validate readability when paths ARE given.
            if [[ -z "$kernel" && -z "$initrd" ]]; then
                if [[ "$distro" != "alpine" || -z "$suite" ]]; then
                    die "spec ($name) backend=kernel+initrd needs either (kernel+initrd paths) or (distro=alpine + suite) for auto-build"
                fi
            else
                [[ -r "$kernel" ]] || die "spec ($name) kernel not readable: $kernel"
                [[ -r "$initrd" ]] || die "spec ($name) initrd not readable: $initrd"
            fi
            ;;
        from-chroot)
            die "spec ($name) backend=from-chroot is not yet implemented in v0.1.  Workaround: build a chroot in Phase 1, install a kernel inside it, then use backend=kernel+initrd pointing at the extracted vmlinuz/initrd."
            ;;
        *) die "spec ($name) unknown backend: $backend" ;;
    esac

    if [[ "$(spec_get "$spec" microvm)" == "true" ]]; then
        local sup; sup="$(arch_map "$arch" microvm-supported)"
        if [[ "$sup" != "yes" ]]; then
            log_warn "microvm machine type not supported on $arch — falling back to standard 'virt'/'q35'"
        fi
        # microvm on x86_64 has no UEFI and only a tiny BIOS (qboot).  Stock
        # cloud images are GPT+ESP (UEFI-only) and won't boot off qboot.
        # Require an explicit kernel/initrd pair (direct-boot) for microvm +
        # disk-image — otherwise the VM "runs" but halts at an unbootable
        # disk with no console output, which is deeply confusing.
        if [[ "$backend" == "disk-image" ]]; then
            local k; k="$(spec_get "$spec" kernel)"
            [[ -n "$k" ]] || die "spec ($name) backend=disk-image + microvm=true without an explicit kernel is unsupported.
  Stock cloud images are UEFI-only; microvm has no UEFI.  Either:
    - set microvm=false (boots via OVMF on q35), or
    - extract vmlinuz/initrd from the image and set kernel=/initrd= in the spec."
        fi
    fi
}

# ─── Port allocation ───────────────────────────────────────────────────────
pick_ssh_port() {
    # Find a free TCP port starting from 2222. Prints the chosen port.
    # "Free" = not listening right now AND not reserved by another VM's
    # manifest.  The second check matters because VMs get a port at
    # create-time but only bind it at start-time, so two freshly-created
    # (both stopped) VMs must still get distinct ports.
    local p taken_ports=()
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        local mp; mp="$(read_manifest_field "$n" ssh_port 2>/dev/null)"
        [[ -n "$mp" && "$mp" != "0" ]] && taken_ports+=("$mp")
    done < <(list_vm_names)

    for p in $(seq 2222 2400); do
        # Skip if listening on host.
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$"; then
            continue
        fi
        # Skip if reserved by an existing VM manifest.
        local t skip=0
        for t in "${taken_ports[@]}"; do
            [[ "$t" == "$p" ]] && { skip=1; break; }
        done
        (( skip )) && continue
        printf '%s' "$p"; return 0
    done
    die "no free port in 2222–2400"
}

# ─── QEMU command construction ─────────────────────────────────────────────
build_qemu_argv() {
    # Builds the QEMU argv into the QEMU_ARGV global array.
    # Inputs (via globals): name, arch, microvm, accel, memory, cpus, disk,
    # seed, kernel, initrd, append, ssh_port, firmware
    QEMU_ARGV=()

    local qsys; qsys="$(arch_map "$arch" qemu-system)"
    local qbin="qemu-system-${qsys}"
    have "$qbin" || die "$qbin not found.  Install with:  $(install_hint qemu-system)"

    QEMU_ARGV+=("$qbin")

    # Machine type
    local mach
    if [[ "$microvm" == "true" && "$(arch_map "$arch" microvm-supported)" == "yes" ]]; then
        case "$arch" in
            x86_64)  mach="microvm,pic=off,pit=off,rtc=off" ;;
            aarch64) mach="microvm" ;;
        esac
    else
        mach="$(arch_map "$arch" machine)"
    fi
    QEMU_ARGV+=(-machine "${mach},accel=${accel}")

    # CPU
    local cpu
    if [[ "$accel" == "kvm" && "$arch" == "$(detect_host_arch)" ]]; then
        cpu="host"
    else
        cpu="$(arch_map "$arch" default-cpu)"
    fi
    QEMU_ARGV+=(-cpu "$cpu")

    # SMP / memory
    QEMU_ARGV+=(-smp "$cpus" -m "$memory")

    # No graphics — serial console only.
    QEMU_ARGV+=(-display none -nographic -no-user-config -nodefaults)

    # Firmware (UEFI / loader)
    if [[ -n "$firmware" ]]; then
        # microvm on x86_64 uses a single-file BIOS (qboot), not pflash.
        if [[ "$arch" == "x86_64" && "$microvm" == "true" ]]; then
            QEMU_ARGV+=(-bios "$firmware")
        else
        case "$arch" in
            x86_64|aarch64)
                # Two-file pflash setup: code (read-only) + vars (per-VM, RW).
                local vars_dst="$(vm_dir "$name")/vars.fd"
                local vars_src
                case "$arch" in
                    x86_64)
                        for vars_src in /usr/share/OVMF/OVMF_VARS.fd \
                                        /usr/share/OVMF/OVMF_VARS_4M.fd \
                                        /usr/share/edk2/ovmf/OVMF_VARS.fd; do
                            [[ -r "$vars_src" ]] && break
                        done
                        ;;
                    aarch64)
                        for vars_src in /usr/share/AAVMF/AAVMF_VARS.fd \
                                        /usr/share/qemu-efi-aarch64/QEMU_VARS.fd; do
                            [[ -r "$vars_src" ]] && break
                        done
                        ;;
                esac
                if [[ -r "$vars_src" && ! -r "$vars_dst" ]]; then
                    cp "$vars_src" "$vars_dst"
                fi
                QEMU_ARGV+=(
                    -drive "if=pflash,format=raw,readonly=on,file=${firmware}"
                )
                if [[ -r "$vars_dst" ]]; then
                    QEMU_ARGV+=(-drive "if=pflash,format=raw,file=${vars_dst}")
                fi
                ;;
            armv7l)
                QEMU_ARGV+=(-bios "$firmware")
                ;;
            riscv64)
                QEMU_ARGV+=(-bios "$firmware")
                ;;
        esac
        fi
    fi

    # Direct kernel boot (kernel+initrd backend, OR microvm with cloud image
    # extraction — left to user for now)
    if [[ -n "$kernel" ]]; then
        QEMU_ARGV+=(-kernel "$kernel")
        [[ -n "$initrd" ]] && QEMU_ARGV+=(-initrd "$initrd")
        [[ -n "$append" ]] && QEMU_ARGV+=(-append "$append")
    fi

    # Pick the virtio transport suffix for the current machine.  `-drive
    # if=virtio` is NOT transport-aware — it always emits virtio-blk-pci,
    # which fails on microvm (mmio-only) and s390x (channel bus).  Use
    # explicit -drive if=none + -device virtio-blk-<suffix> everywhere so
    # disk/seed/net all agree with the machine's bus.
    #   microvm   → mmio        → virtio-*-device
    #   s390x     → channel bus → virtio-*-ccw
    #   otherwise → PCI(e)      → virtio-*-pci
    local virtio_suffix
    if [[ "$microvm" == "true" && "$(arch_map "$arch" microvm-supported)" == "yes" ]]; then
        virtio_suffix="device"
    elif [[ "$arch" == "s390x" ]]; then
        virtio_suffix="ccw"
    else
        virtio_suffix="pci"
    fi

    # Disk
    if [[ -n "$disk" ]]; then
        QEMU_ARGV+=(
            -drive  "file=${disk},if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap"
            -device "virtio-blk-${virtio_suffix},drive=disk0"
        )
    fi

    # cloud-init seed
    if [[ -n "$seed" ]]; then
        QEMU_ARGV+=(
            -drive  "file=${seed},if=none,id=seed0,format=raw,readonly=on"
            -device "virtio-blk-${virtio_suffix},drive=seed0"
        )
    fi

    # Network: user-mode with hostfwd for ssh.
    QEMU_ARGV+=(
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
        -device "virtio-net-${virtio_suffix},netdev=net0"
    )

    # Serial console exposed as a unix socket so `lab-vm.sh console` can attach
    QEMU_ARGV+=(
        -chardev "socket,id=ser0,path=$(vm_serial "$name"),server=on,wait=off"
        -serial "chardev:ser0"
    )

    # QEMU monitor (text) on a separate socket
    QEMU_ARGV+=(
        -chardev "socket,id=mon0,path=$(vm_monitor "$name"),server=on,wait=off"
        -mon "chardev=mon0,mode=readline"
    )

    # QMP for graceful shutdown via JSON
    QEMU_ARGV+=(
        -chardev "socket,id=qmp0,path=$(vm_qmp "$name"),server=on,wait=off"
        -mon "chardev=qmp0,mode=control"
    )

    # PID file + run as a background process
    QEMU_ARGV+=(
        -pidfile "$(vm_pidfile "$name")"
        -daemonize
    )
}

# ─── Subcommand: create ────────────────────────────────────────────────────
create_one() {
    local spec="$1"
    validate_spec "$spec"

    local name backend arch microvm
    name="$(spec_get "$spec" name)"
    backend="$(spec_get "$spec" backend)"
    arch="$(spec_get "$spec" arch)"
    microvm="$(spec_get "$spec" microvm)"

    if vm_exists "$name"; then
        die "VM '$name' already exists.  Destroy it first:  $LAB_PROG destroy $name"
    fi

    state_init
    install -d -m 0755 "$(vm_dir "$name")"

    # Cleanup-on-failure: if any step below fails before write_vm_manifest,
    # remove the half-built VM dir so a re-run doesn't see "already exists"
    # (and so the user isn't left with state that `destroy` can't help with,
    # since `destroy` requires a manifest). Embed the literal path into the
    # trap string at trap-set time — bash function-scoped traps fire when
    # the *script* exits, by which point local vars are out of scope; with
    # `set -u` that manifests as "$var: unbound variable" instead of cleanup.
    local _vm_dir; _vm_dir="$(vm_dir "$name")"
    trap "log_warn 'cleaning up partial VM dir: ${_vm_dir}'; rm -rf -- '${_vm_dir}'" EXIT

    log_info "── creating VM '$name' (backend=$backend, arch=$arch) ──"

    local distro suite memory cpus image kernel initrd append ssh_port pubkey
    local network_enabled ssh_enabled persist_size ssh_user init_flavour
    distro="$(spec_get "$spec" distro)"
    suite="$(spec_get "$spec" suite)"
    memory="$(spec_get "$spec" memory)"
    cpus="$(spec_get "$spec" cpus)"
    image="$(spec_get "$spec" image)"
    kernel="$(spec_get "$spec" kernel)"
    initrd="$(spec_get "$spec" initrd)"
    append="$(spec_get "$spec" append)"
    ssh_port="$(spec_get "$spec" ssh_port)"
    pubkey="$(spec_get "$spec" pubkey)"
    network_enabled="$(spec_get "$spec" network)"
    ssh_enabled="$(spec_get "$spec" ssh)"
    persist_size="$(spec_get "$spec" persist)"
    init_flavour="$(spec_get "$spec" init_flavour)"
    [[ -z "$init_flavour" ]] && init_flavour="busybox"
    ssh_user="lab"  # default for cloud-init VMs

    [[ "$ssh_port" == "0" || -z "$ssh_port" ]] && ssh_port="$(pick_ssh_port)"
    [[ -z "$pubkey" ]] && pubkey="$(default_pubkey || true)"

    # Build / acquire base disk + seed depending on backend.
    local disk; disk="$(vm_disk "$name")"
    local seed=""

    case "$backend" in
        disk-image)
            require_cmd qemu-img
            local base
            if [[ -n "$image" ]]; then
                [[ -r "$image" ]] || die "image not readable: $image"
                base="$image"
            else
                base="$(cache_image "$distro" "$suite" "$arch")"
            fi
            log_info "creating overlay qcow2: $disk (backed by $base)"
            qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" >/dev/null
            seed="$(vm_seed "$name")"
            log_info "generating cloud-init seed iso"
            make_seed_iso "$name" "$seed" "$pubkey" "$distro"
            ;;
        kernel+initrd)
            # Alpine microvm auto-build: if both kernel and initrd are empty
            # and distro=alpine, construct them from the minirootfs using the
            # feature flags (network, ssh, persist) in the spec.  ssh/persist
            # imply network.
            if [[ -z "$kernel" && -z "$initrd" ]]; then
                [[ "$distro" == "alpine" ]] \
                    || die "kernel+initrd auto-build only supported for distro=alpine"
                [[ -n "$suite" ]] || die "kernel+initrd auto-build needs suite (e.g. 3.19)"
                local want_net=0 want_ssh=0 want_persist=0
                [[ "$network_enabled" == "true" ]] && want_net=1
                if [[ "$ssh_enabled" == "true" ]]; then
                    want_ssh=1
                    want_net=1
                    ssh_user="root"  # microvm dropbear logs in as root
                fi
                [[ -n "$persist_size" ]] && { want_persist=1; want_net=1 || true; }
                kernel="$(cache_alpine_microvm_kernel "$suite" "$arch")"
                initrd="$(build_alpine_microvm_initramfs \
                    "$suite" "$arch" "$want_net" "$want_ssh" "$want_persist" \
                    "$pubkey" "$init_flavour")"
                [[ -z "$append" ]] && append="console=ttyS0 rdinit=/sbin/init"
            fi
            # Disk selection:
            #   - explicit --image: bake-in backing file (existing v0.1 behaviour)
            #   - persist=SIZE: create a fresh qcow2 at that size for /data
            #   - else: no disk
            if [[ -n "$image" ]]; then
                require_cmd qemu-img
                qemu-img create -f qcow2 -F qcow2 -b "$image" "$disk" >/dev/null
            elif [[ -n "$persist_size" ]]; then
                require_cmd qemu-img
                log_info "creating persist disk: $disk ($persist_size)"
                qemu-img create -f qcow2 "$disk" "$persist_size" >/dev/null
            else
                disk=""
            fi
            ;;
    esac

    # Choose accel
    local accel; accel="$(choose_accel "$arch")"

    # Stash for build_qemu_argv
    local firmware
    firmware="$(firmware_for "$arch" "$microvm")"

    # Persist manifest before first boot so partial-failure is visible.
    MF_BACKEND="$backend" MF_DISTRO="$distro" MF_SUITE="$suite" \
    MF_ARCH="$arch" MF_MEMORY="$memory" MF_CPUS="$cpus" MF_MICROVM="$microvm" \
    MF_ACCEL="$accel" MF_SSH_PORT="$ssh_port" MF_SEED="$seed" MF_DISK="$disk" \
    MF_KERNEL="$kernel" MF_INITRD="$initrd" MF_APPEND="$append" \
    MF_SSH_USER="$ssh_user" \
    write_vm_manifest "$name"

    # Success — clear the cleanup-on-failure trap.
    trap - EXIT

    log_info "── VM '$name' provisioned (not started; run:  $LAB_PROG start $name) ──"
    if [[ "$ssh_user" == "root" ]]; then
        log_info "ssh access after boot:  ssh -p $ssh_port root@127.0.0.1   (pubkey auth via dropbear)"
    else
        log_info "ssh access after boot:  ssh -p $ssh_port $ssh_user@127.0.0.1   (default password 'lab')"
    fi
}

cmd_create() {
    if [[ -n "${OPT_CONFIG:-}" ]]; then
        local spec
        while IFS= read -r spec; do
            [[ -z "$spec" ]] && continue
            create_one "$spec"
        done < <(specs_from_config "$OPT_CONFIG")
    else
        local spec; spec="$(spec_from_cli)"
        create_one "$spec"
    fi
}

# ─── Subcommand: start ─────────────────────────────────────────────────────
cmd_start() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG start <name>"
    vm_exists "$name" || die "no VM named '$name' (try 'list')"
    if vm_running "$name"; then
        log_info "$name is already running (pid $(cat "$(vm_pidfile "$name")"))"
        return 0
    fi

    # Reload manifest into globals expected by build_qemu_argv.
    local arch microvm accel memory cpus ssh_port disk seed kernel initrd append firmware
    arch="$(read_manifest_field "$name" arch)"
    microvm="$(read_manifest_field "$name" microvm)"
    accel="$(read_manifest_field "$name" accel)"
    memory="$(read_manifest_field "$name" memory)"
    cpus="$(read_manifest_field "$name" cpus)"
    ssh_port="$(read_manifest_field "$name" ssh_port)"
    disk="$(read_manifest_field "$name" disk)"
    seed="$(read_manifest_field "$name" seed)"
    kernel="$(read_manifest_field "$name" kernel)"
    initrd="$(read_manifest_field "$name" initrd)"
    append="$(read_manifest_field "$name" append)"
    firmware="$(firmware_for "$arch" "$microvm")"

    # Clean up any stale unix sockets from a previous run.
    rm -f "$(vm_serial "$name")" "$(vm_monitor "$name")" "$(vm_qmp "$name")"

    build_qemu_argv

    log_info "starting $name (accel=$accel arch=$arch mem=$memory cpus=$cpus)"
    log_debug "argv: ${QEMU_ARGV[*]}"

    if "${QEMU_ARGV[@]}" >>"$(vm_log "$name")" 2>&1; then
        sleep 0.3
        if vm_running "$name"; then
            log_info "$name running (pid $(cat "$(vm_pidfile "$name")"))"
            log_info "ssh:     ssh -p $ssh_port lab@127.0.0.1"
            log_info "console: $LAB_PROG console $name"
        else
            die "qemu reported success but no live process; see $(vm_log "$name")"
        fi
    else
        die "qemu failed to start; see $(vm_log "$name")"
    fi
}

# ─── Subcommand: stop ──────────────────────────────────────────────────────
qmp_powerdown() {
    local sock="$1"
    require_cmd socat
    {
        printf '{"execute":"qmp_capabilities"}\n'
        sleep 0.1
        printf '{"execute":"system_powerdown"}\n'
        sleep 0.1
    } | socat - "UNIX-CONNECT:${sock}" >/dev/null 2>&1 || return 1
}

cmd_stop() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG stop <name> [--force]"
    vm_exists "$name" || die "no VM named '$name'"
    if ! vm_running "$name"; then
        log_info "$name not running"
        return 0
    fi
    local pid; pid="$(cat "$(vm_pidfile "$name")")"

    if [[ -n "${OPT_FORCE:-}" ]]; then
        log_info "killing $name (pid $pid)"
        kill -TERM "$pid" 2>/dev/null || true
    else
        log_info "graceful shutdown via QMP"
        if ! qmp_powerdown "$(vm_qmp "$name")"; then
            log_warn "QMP powerdown failed; falling back to SIGTERM"
            kill -TERM "$pid" 2>/dev/null || true
        fi
    fi

    # Wait up to 30s for the process to exit
    local i
    for i in $(seq 1 30); do
        [[ -d "/proc/$pid" ]] || { log_info "$name stopped"; return 0; }
        sleep 1
    done
    log_warn "$name did not stop within 30s; sending SIGKILL"
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
    [[ ! -d "/proc/$pid" ]] || die "could not stop $name"
    log_info "$name stopped (SIGKILL)"
}

# ─── Subcommand: console ───────────────────────────────────────────────────
cmd_console() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG console <name>"
    vm_exists "$name" || die "no VM named '$name'"
    vm_running "$name" || die "$name is not running"
    require_cmd socat
    # socat puts the terminal into raw mode — Ctrl-C does NOT interrupt,
    # it gets forwarded to the guest as a literal 0x03 byte.  The only
    # way out is the escape char (Ctrl-], i.e. 0x1d), which socat itself
    # intercepts.  On any exit path (normal, SIGINT, SIGTERM), restore
    # the terminal so a badly-wedged guest doesn't leave the shell in
    # raw mode.
    trap 'stty sane 2>/dev/null || true' EXIT INT TERM
    printf >&2 '\n[info] attaching to serial console\n'
    printf >&2 '[info] to detach, press:  Ctrl-]\n'
    printf >&2 '[info] (Ctrl-C is forwarded to the guest, not to this shell)\n\n'
    socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:$(vm_serial "$name")"
}

# ─── Subcommand: ssh ───────────────────────────────────────────────────────
cmd_ssh() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG ssh <name> [-- cmd args...]"
    vm_exists "$name" || die "no VM named '$name'"
    vm_running "$name" || die "$name is not running (try '$LAB_PROG start $name')"
    local port user
    port="$(read_manifest_field "$name" ssh_port)"
    user="$(read_manifest_field "$name" ssh_user)"
    [[ -z "$user" ]] && user="lab"
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        # Two conventions users expect after `--`:
        #   (a)  lv ssh host -- cmd arg1 arg2       (argv-style, shell-quote each)
        #   (b)  lv ssh host -- 'a | b && c; d'     (pipeline string, pass as-is)
        # We pick by arity:
        #   1 arg → treat as a shell snippet, pass raw so `;`, `|`, redirects
        #            etc. remote-side-parse naturally.
        #   2+    → argv-style; printf %q each so local shell's lost quoting
        #            (e.g. `grep -E '^(a|b)='`) is reinstated before ssh
        #            concatenates with spaces and the remote shell re-parses.
        local remote_cmd
        if (( ${#EXTRA_ARGS[@]} == 1 )); then
            remote_cmd="${EXTRA_ARGS[0]}"
        else
            remote_cmd="$(printf '%q ' "${EXTRA_ARGS[@]}")"
        fi
        ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@127.0.0.1" "$remote_cmd"
    else
        ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${user}@127.0.0.1"
    fi
}

# ─── Subcommand: destroy ───────────────────────────────────────────────────
cmd_destroy() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG destroy <name> [--force] [--keep-disk]"
    vm_exists "$name" || die "no VM named '$name'"

    if vm_running "$name"; then
        log_info "$name is running; stopping first"
        OPT_FORCE=1 cmd_stop
    fi

    if [[ -z "${OPT_FORCE:-}" ]]; then
        printf 'About to destroy VM:\n  name: %s\n  dir : %s\nProceed? [y/N] ' \
            "$name" "$(vm_dir "$name")" >&2
        read -r ans </dev/tty || true
        case "$ans" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
    fi

    if [[ -n "${OPT_KEEP_DISK:-}" ]]; then
        local kept; kept="$(vm_dir "$name")/disk.qcow2"
        local dest="${LAB_STATE_DIR}/orphaned-disks/${name}-$(date +%s).qcow2"
        install -d "${dest%/*}"
        mv "$(vm_disk "$name")" "$dest" 2>/dev/null && log_info "kept disk: $dest"
    fi

    rm -rf -- "$(vm_dir "$name")"
    log_info "destroyed: $name"
}

# ─── Subcommand: list ──────────────────────────────────────────────────────
cmd_list() {
    state_init
    printf '%-20s  %-13s  %-10s  %-8s  %-8s  %-7s  %s\n' \
        NAME BACKEND DISTRO ARCH STATUS SSHPORT MEMORY
    local n state port
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        if vm_running "$n"; then state="running"; else state="stopped"; fi
        port="$(read_manifest_field "$n" ssh_port)"
        printf '%-20s  %-13s  %-10s  %-8s  %-8s  %-7s  %s\n' \
            "$n" \
            "$(read_manifest_field "$n" backend)" \
            "$(read_manifest_field "$n" distro)" \
            "$(read_manifest_field "$n" arch)" \
            "$state" \
            "$port" \
            "$(read_manifest_field "$n" memory)"
    done < <(list_vm_names)
}

# ─── CLI parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG $LAB_VERSION — QEMU VM management (LAB_CREATE_V2 phase 2)

USAGE
  $LAB_PROG create   --name N [opts...] | --config FILE
  $LAB_PROG start    <name>
  $LAB_PROG stop     <name> [--force]
  $LAB_PROG console  <name>          # attach to serial console (Ctrl-] to detach)
  $LAB_PROG ssh      <name> [-- cmd args...]
  $LAB_PROG destroy  <name> [--force] [--keep-disk]
  $LAB_PROG list
  $LAB_PROG version | help

CREATE OPTIONS
  --name      <vm-name>                  (required)
  --backend   {disk-image|kernel+initrd|from-chroot}   (default: disk-image)
  --distro    {debian|ubuntu|rocky|alpine}             (disk-image)
  --suite     <release>                  e.g. bookworm | jammy | 9 | 3.19
  --arch      {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x}  (default: host arch)
  --memory    <size>                     (default: 2G)
  --cpus      <n>                        (default: 2)
  --microvm                              (use the microvm machine type, x86_64/aarch64)
  --image     /path/to/qcow2|.img        (override the cached cloud image)
  --kernel    /path/to/vmlinuz           (kernel+initrd backend)
  --initrd    /path/to/initrd            (kernel+initrd backend)
  --append    "<cmdline>"                (kernel+initrd backend)
  --ssh-port  <port>                     (default: auto-allocate from 2222)
  --pubkey    /path/to/id_rsa.pub        (default: invoking user's ~/.ssh/*.pub)
  --config    /path/to/vm.toml

ENVIRONMENT
  LAB_LOG_LEVEL  debug|info|warn|error  (default: info)

EXAMPLES
  $LAB_PROG create --name deb1 --distro debian --suite bookworm --arch x86_64
  $LAB_PROG start  deb1
  $LAB_PROG ssh    deb1
  $LAB_PROG stop   deb1
  $LAB_PROG destroy deb1
EOF
}

POS_ARGS=()
EXTRA_ARGS=()

parse_args() {
    OPT_CONFIG=""
    OPT_NAME="" OPT_BACKEND="" OPT_DISTRO="" OPT_SUITE="" OPT_ARCH=""
    OPT_MEMORY="" OPT_CPUS="" OPT_MICROVM="false"
    OPT_IMAGE="" OPT_KERNEL="" OPT_INITRD="" OPT_APPEND=""
    OPT_SSH_PORT="" OPT_PUBKEY="" OPT_FORCE="" OPT_KEEP_DISK=""

    [[ $# -eq 0 ]] && { usage; exit 0; }
    SUBCMD="$1"; shift

    local seen_doubledash=0
    while [[ $# -gt 0 ]]; do
        if (( seen_doubledash )); then EXTRA_ARGS+=("$1"); shift; continue; fi
        case "$1" in
            --)             seen_doubledash=1; shift ;;
            --config)       OPT_CONFIG="$2"; shift 2 ;;
            --name)         OPT_NAME="$2"; shift 2 ;;
            --backend)      OPT_BACKEND="$2"; shift 2 ;;
            --distro)       OPT_DISTRO="$2"; shift 2 ;;
            --suite)        OPT_SUITE="$2"; shift 2 ;;
            --arch)         OPT_ARCH="$2"; shift 2 ;;
            --memory)       OPT_MEMORY="$2"; shift 2 ;;
            --cpus)         OPT_CPUS="$2"; shift 2 ;;
            --microvm)      OPT_MICROVM="true"; shift ;;
            --image)        OPT_IMAGE="$2"; shift 2 ;;
            --kernel)       OPT_KERNEL="$2"; shift 2 ;;
            --initrd)       OPT_INITRD="$2"; shift 2 ;;
            --append)       OPT_APPEND="$2"; shift 2 ;;
            --ssh-port)     OPT_SSH_PORT="$2"; shift 2 ;;
            --pubkey)
                [[ -r "$2" ]] || die "pubkey file not readable: $2"
                OPT_PUBKEY="$(cat "$2")"; shift 2 ;;
            --force|-f)     OPT_FORCE=1; shift ;;
            --keep-disk)    OPT_KEEP_DISK=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            -v|--version)   printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION"; exit 0 ;;
            -*)             die "unknown option: $1 (try --help)" ;;
            *)              POS_ARGS+=("$1"); shift ;;
        esac
    done
}

main() {
    parse_args "$@"
    case "$SUBCMD" in
        create)  cmd_create  ;;
        start)   cmd_start   ;;
        stop)    cmd_stop    ;;
        console) cmd_console ;;
        ssh)     cmd_ssh     ;;
        destroy) cmd_destroy ;;
        list)    cmd_list    ;;
        help)    usage       ;;
        version) printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)       usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

main "$@"
