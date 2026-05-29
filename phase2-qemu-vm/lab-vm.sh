#!/usr/bin/env bash
# lab-vm.sh — Phase 2 of LAB_CREATE_V2: QEMU full VMs and microvms.
#
# Backends : disk-image (cached cloud images + cloud-init NoCloud seed)
#            kernel+initrd (direct -kernel/-initrd boot, microvm-friendly)
#            from-chroot   (Phase-1 chroot tree → bootable BIOS qcow2, x86_64)
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
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-/var/lib/lab-create}"
    readonly LAB_CACHE_DIR="${LAB_CACHE_DIR:-/var/cache/lab-create}"
else
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
    readonly LAB_CACHE_DIR="${LAB_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/lab-create}"
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
    # Parse with awk — sourcing /etc/os-release executes it as shell code
    # (Finding 23; same pattern as phase1 after its audit).
    if [[ -r /etc/os-release ]]; then
        awk -F= '/^ID=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
            /etc/os-release
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
        aarch64:microvm-supported)  printf 'yes'      ;;  # NB: QEMU has no arm 'microvm' machine; we synthesize one as a minimized 'virt' + virtio-mmio (see build_qemu_argv)

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
            local secure_boot="${3:-false}"
            if [[ "$secure_boot" == "true" ]]; then
                # Secure Boot: prefer the secboot OVMF variant (MSRs enabled,
                # Secure Boot enforcement active).  Falls back to snakeoil if
                # secboot not found (snakeoil = pre-enrolled test cert, good
                # for QEMU-only testing with sign-ipxe.sh --use-snakeoil).
                local cands=(
                    /usr/share/OVMF/OVMF_CODE_4M.secboot.fd
                    /usr/share/OVMF/OVMF_CODE_4M.snakeoil.fd
                    /usr/share/OVMF/OVMF_CODE_4M.fd
                )
            else
                local cands=(
                    /usr/share/OVMF/OVMF_CODE.fd
                    /usr/share/OVMF/OVMF_CODE_4M.fd
                    /usr/share/edk2/ovmf/OVMF_CODE.fd
                    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
                )
            fi
            ;;
        aarch64)
            if [[ "$microvm" == "true" ]]; then
                # arm "microvm" = a minimized 'virt' booted directly via -kernel,
                # which needs no UEFI/pflash at all.  Return empty so build_qemu_argv
                # skips the firmware block entirely (mirrors the x86_64 microvm case).
                printf ''
                return 0
            fi
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
vm_target()   { printf '%s/%s-target.qcow2' "$(vm_dir "$1")" "$1"; }
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
    # Escape double-quotes in free-text string fields so the TOML is always
    # well-formed (Finding 2: an unescaped " in e.g. MF_APPEND or MF_KERNEL
    # would allow a crafted --append to inject extra manifest fields, changing
    # network_mode/bridge/tap/cpu_pin on re-read at start time).
    # Enum-validated fields (backend/distro/arch/accel/network_mode) and
    # numeric fields (cpus/ssh_port/cores/threads) cannot contain quotes.
    local _lab="${MF_LAB:-}"          ; _lab="${_lab//\"/\\\"}"
    local _disk="${MF_DISK:-}"        ; _disk="${_disk//\"/\\\"}"
    local _itgt="${MF_INSTALL_TARGET:-}" ; _itgt="${_itgt//\"/\\\"}"
    local _mac="${MF_MAC:-}"          ; _mac="${_mac//\"/\\\"}"
    local _seed="${MF_SEED:-}"        ; _seed="${_seed//\"/\\\"}"
    local _kernel="${MF_KERNEL:-}"    ; _kernel="${_kernel//\"/\\\"}"
    local _initrd="${MF_INITRD:-}"    ; _initrd="${_initrd//\"/\\\"}"
    local _append="${MF_APPEND:-}"    ; _append="${_append//\"/\\\"}"
    local _suser="${MF_SSH_USER:-lab}"; _suser="${_suser//\"/\\\"}"
    local _cpupin="${MF_CPU_PIN:-}"   ; _cpupin="${_cpupin//\"/\\\"}"
    local _pxedir="${MF_PXE_DIR:-}"   ; _pxedir="${_pxedir//\"/\\\"}"
    local _pxebf="${MF_PXE_BOOTFILE:-ipxe.efi}" ; _pxebf="${_pxebf//\"/\\\"}"
    local _bridge="${MF_BRIDGE:-}"    ; _bridge="${_bridge//\"/\\\"}"
    local _tap="${MF_TAP:-}"          ; _tap="${_tap//\"/\\\"}"
    cat > "$mp" <<EOF
# lab-vm manifest — do not edit by hand
name        = "${name}"
lab         = "${_lab}"
backend     = "${MF_BACKEND}"
distro      = "${MF_DISTRO}"
suite       = "${MF_SUITE}"
arch        = "${MF_ARCH}"
memory      = "${MF_MEMORY}"
cpus        = ${MF_CPUS}
microvm     = ${MF_MICROVM}
accel       = "${MF_ACCEL}"
ssh_port    = ${MF_SSH_PORT}
disk        = "${_disk}"
install_target = "${_itgt}"
mac         = "${_mac}"
seed        = "${_seed}"
kernel      = "${_kernel}"
initrd      = "${_initrd}"
append      = "${_append}"
ssh_user    = "${_suser}"
cores       = ${MF_CORES:-0}
secure_boot = "${MF_SECURE_BOOT:-false}"
pxe_dir     = "${_pxedir}"
pxe_bootfile = "${_pxebf}"
threads     = ${MF_THREADS:-0}
cpu_pin     = "${_cpupin}"
network_mode = "${MF_NETWORK_MODE:-user}"
bridge      = "${_bridge}"
tap         = "${_tap}"
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
    # Validate PID is a positive integer before using it in /proc and kill
    # (Finding 16: a non-numeric or path-like PID file entry would make
    # /proc/$pid resolve to an unexpected directory and silently report "running").
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
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
        kali)
            # Kali publishes a prebuilt QEMU VM image as a 7z-compressed
            # qcow2 under /kali-<release>/ (e.g. /kali-2026.1/).  The
            # <release> tag is numeric; "kali-rolling" is the Phase 1
            # debootstrap/apt suite, NOT a valid cdimage path.  Callers
            # should pass the already-resolved release here — see
            # kali_resolve_suite() for the "kali-rolling" alias.  Only
            # amd64 is published in this format; arm64 must go through
            # the installer ISO (unsupported here).  These images are
            # NOT cloud-init-enabled; create_one skips seed ISO
            # generation when distro=kali.  Default in-image creds:
            # kali/kali.
            [[ "$arch" == "x86_64" ]] \
                || die "Kali publishes QEMU prebuilt images for x86_64 only (got arch=$arch)"
            printf 'https://cdimage.kali.org/kali-%s/kali-linux-%s-qemu-%s.7z' \
                "$suite" "$suite" "$a_deb"
            ;;
        *) die "no cloud image URL for distro $distro" ;;
    esac
}

# Kali publishes point releases (e.g. 2026.1) at /kali-<release>/, and
# aliases the newest one as /current/.  "kali-rolling" in Phase 1 means
# "the rolling apt archive"; for VM-image purposes we map it to "the
# release that /current/ currently points at".  Resolved by parsing
# /current/SHA256SUMS, which lists filenames of the form
# kali-linux-<release>-qemu-amd64.7z.  Pinned release tags (like
# "2026.1") pass through unchanged.
kali_resolve_suite() {
    local suite="$1" arch="$2"
    local a_deb
    case "$arch" in
        x86_64)  a_deb=amd64 ;;
        *) die "kali_resolve_suite: arch=$arch not supported for Kali QEMU prebuilt" ;;
    esac
    case "$suite" in
        kali-rolling|rolling|current)
            require_cmd curl
            local sums
            sums="$(curl --fail --location --silent https://cdimage.kali.org/current/SHA256SUMS)" \
                || die "kali-rolling: failed to fetch https://cdimage.kali.org/current/SHA256SUMS"
            local fname
            fname="$(printf '%s\n' "$sums" \
                | awk -v want="^kali-linux-.+-qemu-${a_deb}[.]7z$" '$2 ~ want { print $2; exit }')"
            [[ -n "$fname" ]] \
                || die "kali-rolling: no kali-linux-*-qemu-${a_deb}.7z line in SHA256SUMS"
            local ver="${fname#kali-linux-}"
            ver="${ver%-qemu-${a_deb}.7z}"
            [[ -n "$ver" ]] || die "kali-rolling: failed to parse release tag from '$fname'"
            # Finding 22: cache the hash we already have from this fetch so
            # kali_sha256_for() doesn't need a second network round-trip.
            _KALI_RESOLVED_HASH="$(printf '%s\n' "$sums" | awk -v f="$fname" '$2==f{print $1;exit}')"
            _KALI_RESOLVED_SUITE="$ver"
            printf '%s' "$ver"
            ;;
        *)
            # Already a concrete release tag — pass through.
            printf '%s' "$suite"
            ;;
    esac
}

# Expected sha256 of the Kali QEMU .7z for a RESOLVED release, parsed from that
# release's published SHA256SUMS.  Prints empty (caller skips verification with a
# warning) if it can't be fetched/parsed — never fatal on its own.
# Globals written by kali_resolve_suite when resolving kali-rolling,
# consumed by kali_sha256_for to avoid a duplicate SHA256SUMS fetch.
_KALI_RESOLVED_SUITE=""
_KALI_RESOLVED_HASH=""

kali_sha256_for() {
    local suite="$1" arch="$2" a_deb
    case "$arch" in x86_64) a_deb=amd64 ;; *) return 0 ;; esac
    # Finding 22: reuse the hash already fetched by kali_resolve_suite when
    # resolving "kali-rolling" — both functions need the same SHA256SUMS and
    # previously made two separate network round-trips.
    if [[ -n "${_KALI_RESOLVED_HASH}" && "${_KALI_RESOLVED_SUITE}" == "$suite" ]]; then
        printf '%s' "${_KALI_RESOLVED_HASH}"
        return 0
    fi
    require_cmd curl
    local sums
    # Finding 6: die on fetch failure instead of silently returning empty.
    sums="$(curl --fail --location --silent "https://cdimage.kali.org/kali-${suite}/SHA256SUMS")" \
        || die "kali: could not fetch SHA256SUMS for release ${suite} (integrity check required); use --refresh-image to retry"
    printf '%s\n' "$sums" \
        | awk -v want="^kali-linux-${suite}-qemu-${a_deb}[.]7z$" '$2 ~ want { print $1; exit }'
}

# fetch_cloud_checksum DISTRO SUITE ARCH FILENAME  →  sha256 hex, or "" on miss
# Fetches each distro's published SHA256SUMS / CHECKSUM file and extracts the
# hash for FILENAME.  On any fetch failure, logs a warning and returns empty
# (verify_sha256 skips with a warning rather than hard-failing), so broken CDN
# health doesn't permanently block downloads.
# Finding 5: called for every non-Kali distro after download.
fetch_cloud_checksum() {
    local distro="$1" suite="$2" arch="$3" filename="$4"
    local a_deb a_other
    case "$arch" in
        x86_64)  a_deb=amd64;   a_other=x86_64 ;;
        aarch64) a_deb=arm64;   a_other=aarch64 ;;
        ppc64le) a_deb=ppc64el; a_other=ppc64le ;;
        s390x)   a_deb=s390x;   a_other=s390x ;;
        riscv64) a_deb=riscv64; a_other=riscv64 ;;
        armv7l)  a_deb=armhf;   a_other=armhf ;;
    esac
    local sums_url=""
    case "$distro" in
        debian)  sums_url="https://cloud.debian.org/images/cloud/${suite}/latest/SHA256SUMS" ;;
        ubuntu)  sums_url="https://cloud-images.ubuntu.com/${suite}/current/SHA256SUMS" ;;
        rocky)   sums_url="https://download.rockylinux.org/pub/rocky/${suite}/images/${a_other}/CHECKSUM" ;;
        alpine)  sums_url="https://dl-cdn.alpinelinux.org/alpine/v${suite}/releases/cloud/sha256sums" ;;
        *)       return 0 ;;
    esac
    require_cmd curl
    local sums
    sums="$(curl --fail --location --silent "$sums_url" 2>/dev/null)" || {
        log_warn "could not fetch checksum file from $sums_url — skipping integrity check for $filename"
        return 0
    }
    # Handle two common checksum file formats:
    #   GNU:  "HASH  filename"  or  "HASH *filename"
    #   RPM:  "SHA256 (filename) = HASH"
    printf '%s\n' "$sums" | awk -v fn="$filename" '
        $2 == fn || $2 == ("*" fn) { print $1; exit }
        $1 == "SHA256" && $2 == ("(" fn ")") { print $NF; exit }
    '
}

# verify_sha256 FILE EXPECTED_HEX — die on mismatch; skip (warn) if expected empty.
verify_sha256() {
    local file="$1" expected="$2"
    if [[ -z "$expected" ]]; then
        log_warn "no published sha256 for $(basename "$file") — skipping integrity check"
        return 0
    fi
    require_cmd sha256sum
    local actual; actual="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "$actual" == "$expected" ]] || die "SHA256 mismatch for $(basename "$file")
  expected: $expected
  actual:   $actual
  refusing to use a tampered/corrupt download."
    log_info "sha256 verified: $(basename "$file")"
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
    # cache_image DISTRO SUITE ARCH [FORCE_REFRESH]  →  prints local cache path
    local distro="$1" suite="$2" arch="$3" force_refresh="${4:-}"
    install -d -m 0755 "$LAB_IMG_CACHE_DIR"
    # Rolling-suite resolution (currently Kali only): "kali-rolling"
    # becomes whatever release /current/ points at right now.  We key
    # the on-disk cache off the RESOLVED release so old VMs keep their
    # backing file when a new release ships, and fresh creates pick up
    # the newer image.
    local eff_suite="$suite"
    if [[ "$distro" == "kali" ]]; then
        eff_suite="$(kali_resolve_suite "$suite" "$arch")"
        if [[ "$eff_suite" != "$suite" ]]; then
            log_info "kali: suite=$suite resolved to release $eff_suite (via /current/SHA256SUMS)"
        fi
    fi
    if [[ "$distro" == "alpine" && "$suite" == "latest" ]]; then
        eff_suite="$(alpine_resolve_latest_suite)"
        log_info "alpine: suite=latest resolved to $eff_suite (via latest-releases.yaml)"
    fi
    local url; url="$(image_url "$distro" "$eff_suite" "$arch")"
    local fname="${distro}-${eff_suite}-${arch}.qcow2"
    local dest="${LAB_IMG_CACHE_DIR}/${fname}"
    # --refresh-image: drop the cached copy so the download below re-runs.
    if [[ "$force_refresh" == "true" && -e "$dest" ]]; then
        log_info "refresh-image: removing cached $dest"
        rm -f "$dest"
    fi
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

    # Finding 5: verify the downloaded file against the distro's published
    # SHA256SUMS before trusting or converting it.  Kali is already verified
    # below (inside the 7z branch).  For all other distros, check here using
    # the original filename (last URL component) that SHA256SUMS references.
    if [[ "$url" != *.7z ]]; then
        local _orig_fname="${url##*/}"
        verify_sha256 "$tmp" "$(fetch_cloud_checksum "$distro" "$eff_suite" "$arch" "$_orig_fname")"
    fi

    # Some upstreams (Kali) ship the qcow2 inside a .7z archive.  Detect
    # by URL suffix, extract to a temp dir, and promote the first .qcow2
    # we find to $tmp.  Done before the qemu-img sniff so the rest of
    # this function is agnostic.
    if [[ "$url" == *.7z ]]; then
        # Kali ships the qcow2 in a .7z; verify it against the published
        # SHA256SUMS before trusting/extracting it (HTTPS gives transport
        # integrity, but an explicit content hash catches a tampered mirror).
        if [[ "$distro" == "kali" ]]; then
            verify_sha256 "$tmp" "$(kali_sha256_for "$eff_suite" "$arch")"
        fi
        local sevenz
        if   have 7z;  then sevenz=7z
        elif have 7za; then sevenz=7za
        elif have 7zz; then sevenz=7zz
        else die "need a 7z extractor in PATH (install p7zip-full on Debian/Ubuntu/Kali, p7zip-plugins on Rocky/Fedora)"
        fi
        local xdir="${dest}.extract"
        rm -rf "$xdir"; install -d -m 0755 "$xdir"
        log_info "extracting 7z archive with $sevenz → $xdir"
        "$sevenz" x -y -o"$xdir" "$tmp" >/dev/null \
            || { rm -rf "$xdir"; rm -f "$tmp"; die "7z extract failed: $tmp"; }
        local inner
        inner="$(find "$xdir" -type f -name '*.qcow2' -print -quit)"
        [[ -n "$inner" && -r "$inner" ]] \
            || { rm -rf "$xdir"; rm -f "$tmp"; die "no .qcow2 found inside $(basename "$url")"; }
        rm -f "$tmp"
        mv "$inner" "$tmp"
        rm -rf "$xdir"
    fi

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

# Resolve a suite (X.Y) to its current patch level.  Tries Alpine's CDN-
# published `latest-releases.yaml` first (always current); falls back to a
# static table for offline use and previous minors.  Update the static
# table from time to time so offline boxes don't drift far behind.
alpine_patch_for_suite() {
    local suite="$1"
    if have curl; then
        # latest-releases.yaml carries entries like
        #   branch: v3.23
        #   version: 3.23.4
        # — fetch it once, scan for the matching branch, take the .Z that
        # follows.  Network failure → fall through to the static table.
        local yaml; yaml="$(curl -fsSL --max-time 5 \
            'https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml' \
            2>/dev/null)"
        if [[ -n "$yaml" ]]; then
            local patch
            patch="$(awk -v want="v$suite" '
                /^[[:space:]]+branch:[[:space:]]+/ {
                    sub(/.*branch:[[:space:]]+/, ""); cur=$0
                }
                /^[[:space:]]+version:[[:space:]]+/ {
                    if (cur == want) { sub(/.*version:[[:space:]]+/, ""); split($0, a, "."); print a[3]; exit }
                }' <<<"$yaml")"
            [[ -n "$patch" ]] && { printf '%s' "$patch"; return 0; }
        fi
    fi
    case "$suite" in
        3.19) printf '5' ;;
        3.20) printf '3' ;;
        3.21) printf '4' ;;
        3.22) printf '2' ;;
        3.23) printf '4' ;;
        *)    die "alpine microvm: no known patch version for suite $suite (update alpine_patch_for_suite or check network)" ;;
    esac
}

# Resolve `suite = "latest"` to the current Alpine stable major.minor by
# parsing Alpine's CDN-published `latest-releases.yaml`.  The YAML has
# entries like `  branch: v3.23` — we strip the `v` and use the X.Y as
# the suite.  Falls back to the most recent minor that
# alpine_patch_for_suite() knows about, so a CDN hiccup doesn't brick the
# build.
alpine_resolve_latest_suite() {
    require_cmd curl
    local url='https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml'
    local suite
    suite="$(curl -fsSL "$url" 2>/dev/null \
        | awk '/^[[:space:]]+branch:[[:space:]]+v[0-9]+\.[0-9]+/ {
                sub(/.*v/, "", $0); print; exit
            }')"
    if [[ -z "$suite" ]]; then
        log_warn "could not fetch Alpine latest-releases.yaml; falling back to suite=3.20"
        suite="3.20"
    fi
    printf '%s' "$suite"
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
    #   --keys-dir       verify package RSA signatures against Alpine's
    #                    public keys bundled in the minirootfs under
    #                    $root/etc/apk/keys/.  Finding 14: removed
    #                    --allow-untrusted which silently bypassed all APK
    #                    signature verification, trusting the HTTPS CDN as
    #                    the sole trust boundary.  The minirootfs contains
    #                    the official Alpine signing keys, so we can verify
    #                    without needing a pre-installed system keyring.
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
        --keys-dir "$root/etc/apk/keys" \
        --initdb --no-cache --no-scripts \
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
            # Finding 18: log when using authorized_keys as the source — it is a
            # non-obvious fallback that may inject multiple keys or keys with
            # option prefixes (grep above filters those out, but note the source).
            [[ "$f" == *.pub ]] || log_info "cloud-init: injecting pubkey from $f (authorized_keys fallback)"
            printf '%s\n' "$keys"
            return 0
        fi
    done
    return 1
}

make_seed_iso() {
    # make_seed_iso NAME OUT PUBKEY DISTRO [PACKAGES_JSON] [RUNCMD_JSON] [USER_DATA_FILE]
    # PACKAGES_JSON/RUNCMD_JSON: compact JSON arrays appended to the template as
    # cloud-config `packages:` / `runcmd:`.  USER_DATA_FILE: if set, used verbatim
    # as the entire user-data (full override — template + packages/runcmd ignored).
    # Note: we use a subshell + EXIT trap rather than a function-level RETURN
    # trap, because RETURN traps in bash are global and fire for every later
    # function return — they cannot reference now-out-of-scope locals.
    local name="$1" out="$2" pubkey="${3:-}" distro="${4:-}"
    local packages_json="${5:-[]}" runcmd_json="${6:-[]}" user_data_file="${7:-}"
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

    # Full override: a caller-supplied user-data file wins outright.
    if [[ -n "$user_data_file" ]]; then
      cp "$user_data_file" "$tmp/user-data"
    else
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
                # Finding 11: strip any embedded newlines from the key line so a
                # multi-line key blob cannot break the YAML list structure.
                line="${line//$'\n'/ }"
                printf '      - %s\n' "$line"
            done <<<"$pubkey"
        fi
        # Finding 7: if a pubkey was injected, disable password SSH so the
        # universal 'lab' password is not exploitable over the network.  When
        # no pubkey is available (rare), keep ssh_pwauth: true so there is
        # still a way to log in, but warn loudly.
        if [[ -n "$pubkey" ]]; then
            printf 'ssh_pwauth: false\n'
        else
            log_warn "no SSH pubkey found — VM will use password auth (lab/lab). Add ~/.ssh/id_*.pub to suppress this."
            printf 'ssh_pwauth: true\n'
        fi
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
        # Per-VM overrides: extra packages + first-boot commands (cloud-config
        # `packages:` / `runcmd:`).  Top-level keys, so order vs. the above is fine.
        if [[ "$(jq 'length' <<<"$packages_json")" -gt 0 ]]; then
            printf 'packages:\n'
            jq -r '.[]' <<<"$packages_json" | while IFS= read -r _p; do printf '  - %s\n' "$_p"; done
        fi
        if [[ "$(jq 'length' <<<"$runcmd_json")" -gt 0 ]]; then
            printf 'runcmd:\n'
            # Finding 21: strip embedded newlines from each runcmd entry so a TOML
            # string containing \n does not silently split into two YAML list items.
            jq -r '.[]' <<<"$runcmd_json" | while IFS= read -r _c; do
                _c="${_c//$'\n'/ }"
                printf '  - %s\n' "$_c"
            done
        fi
    } > "$tmp/user-data"
    fi

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
    local packages_json='[]' runcmd_json='[]'
    [[ -n "${OPT_PACKAGES:-}" ]] && packages_json="$(printf '%s\n' "$OPT_PACKAGES" | tr ',' '\n' | jq -R . | jq -s '[.[]|select(length>0)]')"
    if [[ ${#OPT_RUNCMD[@]} -gt 0 ]]; then
        runcmd_json="$(printf '%s\n' "${OPT_RUNCMD[@]}" | jq -R . | jq -s .)"
    fi
    jq -n \
        --argjson packages "$packages_json" \
        --argjson runcmd   "$runcmd_json" \
        --arg user_data    "${OPT_USER_DATA:-}" \
        --arg refresh_image "${OPT_REFRESH_IMAGE:-false}" \
        --arg secure_boot  "${OPT_SECURE_BOOT:+true}" \
        --arg pxe_dir      "${OPT_PXE_DIR:-}" \
        --arg pxe_bootfile "${OPT_PXE_BOOTFILE:-ipxe.efi}" \
        --arg cores        "${OPT_CORES:-0}" \
        --arg threads      "${OPT_THREADS:-0}" \
        --arg cpu_pin      "${OPT_CPU_PIN:-}" \
        --arg network_mode "${OPT_NETWORK_MODE:-user}" \
        --arg bridge       "${OPT_BRIDGE:-}" \
        --arg tap          "${OPT_TAP:-}" \
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
        --arg lab       "${OPT_LAB:-}" \
        --arg chroot    "${OPT_CHROOT:-}" \
        --arg disk_size "${OPT_DISK_SIZE:-}" \
        --arg cloud_init "${OPT_CLOUD_INIT:-true}" \
        '{name:$name, backend:$backend, distro:$distro, suite:$suite, arch:$arch,
          memory:$memory, cpus:($cpus|tonumber), microvm:($microvm=="true"),
          image:$image, kernel:$kernel, initrd:$initrd, append:$append,
          ssh_port:($ssh_port|tonumber), pubkey:$pubkey,
          network:($network=="true"), ssh:($ssh=="true"), persist:$persist,
          init_flavour:$init_flavour, lab:$lab,
          chroot:$chroot, disk_size:$disk_size,
          cloud_init:$cloud_init,
          refresh_image:($refresh_image=="true"),
          secure_boot:($secure_boot=="true"),
          pxe_dir:$pxe_dir,
          pxe_bootfile:$pxe_bootfile,
          cores:($cores|tonumber), threads:($threads|tonumber), cpu_pin:$cpu_pin,
          network_mode:$network_mode, bridge:$bridge, tap:$tap,
          packages:$packages, runcmd:$runcmd, user_data:$user_data}'
}

specs_from_config() {
    local file="$1"
    require_cmd jq
    local json; json="$(toml_to_json "$file")"
    # Propagate top-level [lab].name into every [[vm]] spec so a unified
    # lab.toml (also carrying [[chroot]] / [[service]] for sibling phases)
    # works unchanged.  --lab on the CLI overrides.
    printf '%s' "$json" | jq -c --arg cli_lab "${OPT_LAB:-}" '
        . as $root
        | if .vm? then (.vm | if type=="array" then .[] else . end) else . end
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
            init_flavour: (.init_flavour // "busybox"),
            chroot:    (.chroot    // ""),
            disk_size: (.disk_size // ""),
            cloud_init: (if .cloud_init == false then "false" else "true" end),
            install_target: (.install_target // ""),
            mac:       (.mac       // ""),
            refresh_image: (.refresh_image // false),
            secure_boot:   (.secure_boot   // false),
            pxe_dir:       (.pxe_dir       // ""),
            pxe_bootfile:  (.pxe_bootfile  // "ipxe.efi"),
            cores:     (.cores     // 0),
            threads:   (.threads   // 0),
            cpu_pin:   (.cpu_pin   // ""),
            network_mode: (.network_mode // "user"),
            bridge:    (.bridge    // ""),
            tap:       (.tap       // ""),
            packages:  (.packages  // []),
            runcmd:    (.runcmd     // []),
            user_data: (.user_data // ""),
            lab:     ( if $cli_lab != "" then $cli_lab
                       else ($root.lab.name // "") end ) }
    '
}

spec_get() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }

# ─── Backend: from-chroot (bootable qcow2 from a Phase-1 chroot) ───────────
# Turn an arbitrary chroot tree into a bootable VM disk.  Approach:
#   1. Allocate a raw image (qemu-img create -f raw)
#   2. MBR partition table, single bootable ext4 primary partition
#   3. losetup -P to expose the partition as a loop device
#   4. mkfs.ext4 + mount + rsync the chroot into it
#   5. Write /etc/fstab with the root UUID
#   6. Install extlinux to /boot/extlinux/ + write extlinux.conf pointing
#      at the kernel/initrd already present in the chroot
#   7. dd the syslinux MBR code into sector 0
#   8. umount + detach loop + qemu-img convert raw → qcow2
#
# Requires: root (loop+mkfs+extlinux), plus qemu-img, parted, rsync,
# mkfs.ext4, losetup, extlinux, blkid, dd, syslinux MBR binary.
# v0.1 is x86_64 BIOS only; UEFI/aarch64 is a follow-up.
backend_vm_from_chroot() {
    # backend_vm_from_chroot CHROOT_PATH OUT_QCOW2 [SIZE]
    local chroot_path="$1" out_qcow2="$2" size="${3:-4G}"

    [[ $EUID -eq 0 ]] \
        || die "from-chroot backend requires root (loop mounts, mkfs, extlinux install).  Re-run under sudo."
    require_cmd qemu-img parted mkfs.ext4 losetup extlinux rsync blkid dd

    # Finding 12: validate chroot_path is under the Phase-1 state directory.
    # Running as root with rsync -aAXH, an unchecked --chroot / would copy the
    # entire host filesystem into the VM disk image.
    local _chroot_real; _chroot_real="$(realpath -m "$chroot_path" 2>/dev/null || printf '%s' "$chroot_path")"
    local _allowed_prefix="${LAB_STATE_DIR}/chroots"
    [[ "$_chroot_real" == "$_allowed_prefix"/* ]] \
        || die "from-chroot: chroot path must be under $LAB_STATE_DIR/chroots/ (got: $chroot_path).  Use lab-chroot.sh create to build chroots in the expected location."

    # Locate the kernel + initrd the chroot already has installed.  The
    # user is expected to have done this in Phase 1 (e.g.,
    # `sudo lab-chroot enter foo -- apt-get install -y linux-image-amd64`).
    local kernel initrd
    kernel="$(find "$chroot_path/boot" -maxdepth 1 -name 'vmlinuz-*' \
        -not -name '*.old' -not -name '*.bak' 2>/dev/null | sort -V | tail -1)"
    initrd="$(find "$chroot_path/boot" -maxdepth 1 \
        \( -name 'initrd.img-*' -o -name 'initramfs-*' \) 2>/dev/null \
        | sort -V | tail -1)"
    [[ -n "$kernel" ]] \
        || die "no /boot/vmlinuz-* in chroot.  Install a kernel package first:
  sudo lab-chroot.sh enter <name> -- apt-get install -y linux-image-amd64   # Debian/Ubuntu/Kali
  sudo lab-chroot.sh enter <name> -- dnf install -y kernel                  # Rocky"
    [[ -n "$initrd" ]] \
        || die "no /boot/initrd.img-* or initramfs-* in chroot; the kernel package should have installed one.
  Try inside the chroot:  update-initramfs -u -k all  (Debian/Ubuntu/Kali)
                      or:  dracut -f --regenerate-all  (Rocky/Fedora)"

    # Locate the syslinux MBR blob (path differs across distros).
    local mbr_bin=""
    local p
    for p in \
        /usr/lib/syslinux/mbr/mbr.bin \
        /usr/share/syslinux/mbr.bin \
        /usr/lib/syslinux/mbr.bin \
        /usr/lib/extlinux/mbr.bin; do
        [[ -r "$p" ]] && { mbr_bin="$p"; break; }
    done
    [[ -n "$mbr_bin" ]] \
        || die "syslinux MBR binary (mbr.bin) not found.  Install:
  $(install_hint syslinux-common)  # Debian/Ubuntu/Kali
  $(install_hint syslinux)         # Rocky/Fedora"

    log_info "building bootable qcow2 from $chroot_path  (size=$size)"

    local raw="${out_qcow2}.raw.partial"
    qemu-img create -f raw "$raw" "$size" >/dev/null \
        || die "qemu-img create failed"

    # Cleanup-on-failure: RETURN trap fires before the function returns, while
    # locals are still in scope.  Use single quotes so $mp and $loopdev expand
    # at trap-fire time (when they hold real values), not at trap-set time when
    # they are still empty strings (Finding 3: double-quoted trap expanded
    # mp/loopdev immediately, making the umount/losetup -d calls no-ops on any
    # failure between losetup and mount, leaking loop devices).
    local loopdev="" mp=""
    local _raw="$raw" _out="$out_qcow2"
    # shellcheck disable=SC2016
    trap '
        [[ -n "${mp}" && -d "${mp}" ]] && umount "${mp}" 2>/dev/null
        [[ -n "${mp}" && -d "${mp}" ]] && rmdir  "${mp}" 2>/dev/null
        [[ -n "${loopdev}" ]] && losetup -d "${loopdev}" 2>/dev/null
        rm -f "${_raw}" "${_out}" 2>/dev/null
    ' RETURN

    # Partition: MBR, one bootable ext4 primary from 1 MiB to end.
    log_info "partitioning (MBR + ext4)"
    parted -s "$raw" \
        mklabel msdos \
        mkpart primary ext4 1MiB 100% \
        set 1 boot on >/dev/null

    # losetup -P exposes partitions as ${loopdev}p1 etc.
    loopdev="$(losetup -f --show -P "$raw")" \
        || die "losetup failed"
    local part="${loopdev}p1"
    # Sometimes udev needs a blink to materialise partitions; retry briefly.
    local i
    for i in 1 2 3 4 5; do
        [[ -b "$part" ]] && break
        sleep 0.2
    done
    [[ -b "$part" ]] \
        || die "loop partition $part never appeared; partx/udev issue"

    log_info "mkfs.ext4 on $part"
    mkfs.ext4 -q -L root "$part" \
        || die "mkfs.ext4 failed"

    local uuid; uuid="$(blkid -s UUID -o value "$part")"
    [[ -n "$uuid" ]] || die "blkid couldn't read UUID of $part"
    log_debug "root UUID: $uuid"

    mp="$(mktemp -d)"
    mount "$part" "$mp" \
        || die "mount $part → $mp failed"

    log_info "rsync chroot → root partition"
    rsync -aAXH \
        --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
        --exclude='/run/*'  --exclude='/tmp/*' --exclude='/.lab-chroot-mounts' \
        "$chroot_path/" "$mp/" \
        || die "rsync failed"

    # Recreate pseudo-fs mountpoints the kernel needs on first boot.
    install -d -m 0555 "$mp/proc" "$mp/sys"
    install -d -m 0755 "$mp/dev"  "$mp/run"
    install -d -m 1777 "$mp/tmp"

    # /etc/fstab — single ext4 root mounted by UUID.
    cat > "$mp/etc/fstab" <<EOF
# /etc/fstab — written by lab-vm.sh from-chroot backend
UUID=$uuid / ext4 errors=remount-ro 0 1
EOF

    # extlinux bootloader in /boot/extlinux/.
    log_info "installing extlinux"
    install -d -m 0755 "$mp/boot/extlinux"
    extlinux --install "$mp/boot/extlinux" >/dev/null \
        || die "extlinux --install failed"

    local kbase ibase
    kbase="$(basename -- "$kernel")"
    ibase="$(basename -- "$initrd")"

    cat > "$mp/boot/extlinux/extlinux.conf" <<EOF
# Generated by lab-vm.sh from-chroot backend
DEFAULT linux
TIMEOUT 10
PROMPT 0

LABEL linux
    LINUX /boot/$kbase
    INITRD /boot/$ibase
    APPEND root=UUID=$uuid ro console=tty0 console=ttyS0,115200
EOF

    # Write the MBR bootstrap code.
    dd if="$mbr_bin" of="$raw" bs=440 count=1 conv=notrunc status=none \
        || die "dd MBR failed"

    # Clean unmount + detach.
    sync
    umount "$mp" || die "umount $mp failed"
    rmdir "$mp"; mp=""
    losetup -d "$loopdev" || true
    loopdev=""

    # Raw → qcow2.
    log_info "converting raw → qcow2: $out_qcow2"
    qemu-img convert -f raw -O qcow2 "$raw" "$out_qcow2" \
        || die "qemu-img convert failed"
    rm -f "$raw"

    trap - RETURN
    log_info "bootable qcow2 ready: $out_qcow2"
}

# ─── Validation ─────────────────────────────────────────────────────────────
validate_vm_name() {
    # Reject names that contain path separators or other characters that would
    # allow traversal of LAB_VM_STATE_DIR (Finding 1: vm_dir() builds paths by
    # concatenating the state dir with the name; a name like ../../etc destroys
    # the wrong directory under rm -rf).
    local n="$1"
    [[ -n "$n" ]] || die "VM name is empty"
    [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] \
        || die "invalid VM name '$n': use only [a-zA-Z0-9._-], start with alphanumeric, max 63 chars"
}

validate_spec() {
    local spec="$1"
    local name backend arch
    name="$(spec_get "$spec" name)"
    backend="$(spec_get "$spec" backend)"
    arch="$(spec_get "$spec" arch)"

    [[ -n "$name"    ]] || die "spec missing required field: name"
    validate_vm_name "$name"
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
            local chroot_path; chroot_path="$(spec_get "$spec" chroot)"
            [[ -n "$chroot_path" ]] \
                || die "spec ($name) backend=from-chroot requires a chroot field (path to the Phase-1 tree)"
            [[ -d "$chroot_path" ]] \
                || die "spec ($name) chroot not a directory: $chroot_path"
            # v0.1 limitation: x86_64 BIOS only.  aarch64 would need a
            # different bootloader story (GRUB/efibootmgr) — out of scope.
            [[ "$arch" == "x86_64" ]] \
                || die "spec ($name) backend=from-chroot is x86_64-only in v0.1 (got arch=$arch).
  See PLAN.md Phase 2 and MANUAL_TESTING §X for the manual kernel+initrd
  workaround that works on any arch."
            ;;
        pxe-install) ;;   # validated in create_one
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
    # install_target, mac, seed, kernel, initrd, append, ssh_port, firmware
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
            # QEMU has no arm 'microvm' machine type — the arm equivalent is a
            # 'virt' stripped to virtio-mmio transports + direct -kernel boot (no
            # UEFI; firmware_for returns empty for aarch64+microvm).  Same fast,
            # minimal device model; just a different machine name.
            aarch64) mach="virt" ;;
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

    # SMP / memory.  With cores/threads set, emit an explicit topology
    # (sockets derived by QEMU); otherwise just the vCPU count, as before.
    local smp="$cpus"
    if [[ "${cores:-0}" != "0" || "${threads:-0}" != "0" ]]; then
        local _c="${cores:-0}" _t="${threads:-0}"
        [[ "$_c" == "0" ]] && _c=1
        [[ "$_t" == "0" ]] && _t=1
        smp="${cpus},cores=${_c},threads=${_t}"
    fi
    QEMU_ARGV+=(-smp "$smp" -m "$memory")

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
                # Finding 17: initialize to empty so the final [[ -r "$vars_src" ]]
                # test is well-defined if the for loop exhausts all candidates.
                local vars_src=""
                case "$arch" in
                    x86_64)
                        if [[ "${secure_boot:-false}" == "true" ]]; then
                            for vars_src in /usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd \
                                            /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
                                            /usr/share/OVMF/OVMF_VARS_4M.fd; do
                                [[ -r "$vars_src" ]] && break; vars_src=""
                            done
                        else
                            for vars_src in /usr/share/OVMF/OVMF_VARS.fd \
                                            /usr/share/OVMF/OVMF_VARS_4M.fd \
                                            /usr/share/edk2/ovmf/OVMF_VARS.fd; do
                                [[ -r "$vars_src" ]] && break; vars_src=""
                            done
                        fi
                        ;;
                    aarch64)
                        for vars_src in /usr/share/AAVMF/AAVMF_VARS.fd \
                                        /usr/share/qemu-efi-aarch64/QEMU_VARS.fd; do
                            [[ -r "$vars_src" ]] && break; vars_src=""
                        done
                        ;;
                esac
                [[ -n "$vars_src" ]] || log_warn "no OVMF/AAVMF VARS file found for $arch — UEFI variables will not persist across reboots"
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

    # Disk.  Three shapes:
    #   disk + install_target → two-disk BIOS PXE boot-loop (disk-image backend)
    #   install_target only   → pxe-install backend (UEFI network boot, no ROM disk)
    #   disk only             → ordinary disk-image / from-chroot VM
    if [[ -n "$disk" && -n "${install_target:-}" ]]; then
        # Two-disk boot-loop layout (BIOS PXE install):
        #   disk0 = blank install target (bootindex=0 — BIOS tries first,
        #           skips when empty, boots after the installer writes a loader)
        #   disk1 = iPXE ROM image (bootindex=1 — fallback on first boot)
        QEMU_ARGV+=(
            -drive  "file=${install_target},if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap"
            -device "virtio-blk-${virtio_suffix},drive=disk0,bootindex=0"
            -drive  "file=${disk},if=none,id=disk1,format=qcow2,cache=writeback"
            -device "virtio-blk-${virtio_suffix},drive=disk1,bootindex=1"
        )
    elif [[ -n "${install_target:-}" ]]; then
        # pxe-install backend: a blank target disk and NO iPXE ROM disk.  OVMF
        # network-boots (`-boot order=n`) into the installer over slirp TFTP,
        # which installs onto this disk; on later boots OVMF's boot manager finds
        # the EFI entry the installer registered and boots it.  No bootindex here
        # (it would conflict with `-boot order=n`); without this drive the guest
        # has nowhere to install — d-i/Anaconda fail with "no root file system".
        QEMU_ARGV+=(
            -drive  "file=${install_target},if=none,id=disk0,format=qcow2,cache=writeback,discard=unmap"
            -device "virtio-blk-${virtio_suffix},drive=disk0"
        )
    elif [[ -n "$disk" ]]; then
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

    # Network.  Default is user-mode slirp with a per-VM ssh hostfwd (rootless).
    # bridge/tap attach to host L2 (need root or a setuid qemu-bridge-helper +
    # /etc/qemu/bridge.conf allowing the bridge); the guest then gets a real
    # DHCP lease from your LAN instead of slirp's 10.0.2.x.

    # Finding 8: validate fields that are embedded in QEMU comma-separated option
    # strings; a comma in any of them would inject extra QEMU device options.
    if [[ -n "${mac:-}" ]]; then
        [[ "${mac}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] \
            || die "invalid MAC address '${mac}': expected xx:xx:xx:xx:xx:xx"
    fi
    if [[ -n "${bridge:-}" ]]; then
        [[ "${bridge}" =~ ^[a-zA-Z0-9._-]{1,15}$ ]] \
            || die "invalid bridge interface name '${bridge}': use only [a-zA-Z0-9._-], max 15 chars"
    fi
    if [[ -n "${tap:-}" ]]; then
        [[ "${tap}" =~ ^[a-zA-Z0-9._-]{1,15}$ ]] \
            || die "invalid tap interface name '${tap}': use only [a-zA-Z0-9._-], max 15 chars"
    fi
    if [[ -n "${pxe_dir:-}" && "${pxe_dir}" == *,* ]]; then
        die "pxe_dir must not contain commas (QEMU option string injection): ${pxe_dir}"
    fi

    local net_device="virtio-net-${virtio_suffix},netdev=net0"
    [[ -n "${mac:-}" ]] && net_device="${net_device},mac=${mac}"
    local netdev
    case "${network_mode:-user}" in
        bridge)
            netdev="bridge,id=net0,br=${bridge:-virbr0}"
            ;;
        tap)
            if [[ -n "${tap:-}" ]]; then
                netdev="tap,id=net0,ifname=${tap},script=no,downscript=no"
            else
                netdev="tap,id=net0,script=no,downscript=no"
            fi
            ;;
        *)  # user-mode (default)
            netdev="user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
            if [[ -n "${pxe_dir:-}" ]]; then
                netdev="${netdev},tftp=${pxe_dir},bootfile=/${pxe_bootfile:-ipxe.efi}"
            fi
            ;;
    esac
    QEMU_ARGV+=(-netdev "$netdev" -device "${net_device}")
    # Force network-first boot order when PXE TFTP is configured.
    [[ -n "${pxe_dir:-}" ]] && QEMU_ARGV+=(-boot "order=n,menu=on")

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
    # Finding 4: create the per-VM directory with mode 0700 so only the owning
    # user can read the QMP/serial/monitor sockets (which otherwise allow any
    # local user to attach to the VM console or issue arbitrary QMP commands).
    install -d -m 0700 "$(vm_dir "$name")"

    # Finding 10: validate the socket path length before building state — Unix
    # sockets have a 108-byte sun_path limit; QEMU silently fails to bind a
    # longer path leaving an unattachable console and no diagnostic.
    local _sock_path; _sock_path="$(vm_serial "$name")"
    [[ ${#_sock_path} -le 107 ]] \
        || die "VM name '$name' produces a socket path that is too long (${#_sock_path} chars, max 107): $_sock_path"

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
    local install_target_size mac
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
    install_target_size="$(spec_get "$spec" install_target)"
    mac="$(spec_get "$spec" mac)"
    [[ -z "$init_flavour" ]] && init_flavour="busybox"
    ssh_user="lab"  # default for cloud-init VMs

    # v0.2 knobs: cpu topology/pinning, network mode, image refresh.
    local cores threads cpu_pin network_mode bridge tap refresh_image secure_boot pxe_dir pxe_bootfile
    cores="$(spec_get "$spec" cores)";     [[ -z "$cores"   ]] && cores=0
    threads="$(spec_get "$spec" threads)"; [[ -z "$threads" ]] && threads=0
    cpu_pin="$(spec_get "$spec" cpu_pin)"
    network_mode="$(spec_get "$spec" network_mode)"; [[ -z "$network_mode" ]] && network_mode=user
    bridge="$(spec_get "$spec" bridge)"
    tap="$(spec_get "$spec" tap)"
    refresh_image="$(spec_get "$spec" refresh_image)"
    secure_boot="$(spec_get "$spec" secure_boot)"
    pxe_dir="$(spec_get "$spec" pxe_dir)"
    pxe_bootfile="$(spec_get "$spec" pxe_bootfile)"

    [[ "$ssh_port" == "0" || -z "$ssh_port" ]] && ssh_port="$(pick_ssh_port)"
    [[ -z "$pubkey" ]] && pubkey="$(default_pubkey || true)"

    # Build / acquire base disk + seed depending on backend.
    local disk; disk="$(vm_disk "$name")"
    local seed=""
    local install_target=""   # path to blank install-target disk (install_target spec field)

    case "$backend" in
        disk-image)
            require_cmd qemu-img
            local base
            if [[ -n "$image" ]]; then
                [[ -r "$image" ]] || die "image not readable: $image"
                base="$image"
            else
                base="$(cache_image "$distro" "$suite" "$arch" "$refresh_image")"
            fi
            log_info "creating overlay qcow2: $disk (backed by $base)"
            qemu-img create -f qcow2 -F qcow2 -b "$base" "$disk" >/dev/null
            # install_target: create a blank target disk for Anaconda to install onto.
            if [[ -n "$install_target_size" ]]; then
                install_target="$(vm_target "$name")"
                log_info "creating blank install target: $install_target ($install_target_size)"
                qemu-img create -f qcow2 "$install_target" "$install_target_size" >/dev/null
            fi
            # Kali's prebuilt QEMU images don't ship cloud-init, so a seed
            # ISO would be silently ignored.  Skip it and signal that
            # first-boot config is manual (console login as kali/kali).
            local cloud_init; cloud_init="$(spec_get "$spec" cloud_init)"
            if [[ "$distro" == "kali" ]]; then
                log_info "distro=kali: skipping cloud-init seed (image has no cloud-init)"
                ssh_user="kali"
            elif [[ "$cloud_init" == "false" ]]; then
                log_info "cloud_init=false: skipping cloud-init seed"
            else
                seed="$(vm_seed "$name")"
                log_info "generating cloud-init seed iso"
                make_seed_iso "$name" "$seed" "$pubkey" "$distro" \
                    "$(jq -c '.packages // []' <<<"$spec")" \
                    "$(jq -c '.runcmd   // []' <<<"$spec")" \
                    "$(spec_get "$spec" user_data)"
            fi
            ;;
        pxe-install)
            # UEFI PXE install: a blank target disk only — no iPXE ROM overlay.
            # OVMF network-boots directly via QEMU slirp TFTP (pxe_dir).
            # After Anaconda installs and reboots, OVMF boots the EFI partition.
            require_cmd qemu-img
            [[ -n "$install_target_size" ]] \
                || die "pxe-install backend requires install_target = \"<size>\" in the spec"
            [[ -n "${pxe_dir:-}" ]] \
                || die "pxe-install backend requires pxe_dir (or --pxe-dir CLI flag)"
            install_target="$(vm_target "$name")"
            log_info "creating blank install target: $install_target ($install_target_size)"
            qemu-img create -f qcow2 "$install_target" "$install_target_size" >/dev/null
            # disk stays empty — OVMF handles the boot via TFTP
            disk=""
            ;;
        from-chroot)
            require_cmd qemu-img
            local chroot_path; chroot_path="$(spec_get "$spec" chroot)"
            local disk_size;   disk_size="$(spec_get "$spec" disk_size)"
            [[ -z "$disk_size" ]] && disk_size="4G"
            # Produce the bootable qcow2 directly at the VM's disk path.
            # No overlay: the disk is self-contained; users who want
            # snapshots can `qemu-img create -b` on top later.
            backend_vm_from_chroot "$chroot_path" "$disk" "$disk_size"
            # No cloud-init seed — the chroot's existing root password /
            # SSH setup is whatever the user configured in Phase 1.
            ssh_user="root"
            ;;
        kernel+initrd)
            # Alpine microvm auto-build: if both kernel and initrd are empty
            # and distro=alpine, construct them from the minirootfs using the
            # feature flags (network, ssh, persist) in the spec.  ssh/persist
            # imply network.
            if [[ -z "$kernel" && -z "$initrd" ]]; then
                [[ "$distro" == "alpine" ]] \
                    || die "kernel+initrd auto-build only supported for distro=alpine"
                [[ -n "$suite" ]] || die "kernel+initrd auto-build needs suite (e.g. 3.19, or \"latest\")"
                if [[ "$suite" == "latest" ]]; then
                    suite="$(alpine_resolve_latest_suite)"
                    log_info "alpine microvm: suite=latest resolved to $suite"
                fi
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
            # Cloud-init seed for custom kernel+initrd images (e.g. full Debian initrd).
            # Opt-in only: set cloud_init=true in the TOML or --cloud-init on the CLI.
            # Alpine microvms use dropbear/custom init and never want a cloud-init seed.
            local cloud_init; cloud_init="$(spec_get "$spec" cloud_init)"
            if [[ "$cloud_init" == "true" && "$distro" != "alpine" ]]; then
                seed="$(vm_seed "$name")"
                log_info "generating cloud-init seed iso (cloud_init=true)"
                make_seed_iso "$name" "$seed" "$pubkey" "$distro"
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
    firmware="$(firmware_for "$arch" "$microvm" "${secure_boot:-false}")"

    # Persist manifest before first boot so partial-failure is visible.
    local lab_name; lab_name="$(spec_get "$spec" lab)"
    MF_BACKEND="$backend" MF_DISTRO="$distro" MF_SUITE="$suite" \
    MF_ARCH="$arch" MF_MEMORY="$memory" MF_CPUS="$cpus" MF_MICROVM="$microvm" \
    MF_ACCEL="$accel" MF_SSH_PORT="$ssh_port" MF_SEED="$seed" MF_DISK="$disk" \
    MF_INSTALL_TARGET="${install_target:-}" MF_MAC="${mac:-}" \
    MF_KERNEL="$kernel" MF_INITRD="$initrd" MF_APPEND="$append" \
    MF_SSH_USER="$ssh_user" MF_LAB="$lab_name" \
    MF_CORES="$cores" MF_THREADS="$threads" MF_CPU_PIN="$cpu_pin" \
    MF_NETWORK_MODE="$network_mode" MF_BRIDGE="$bridge" MF_TAP="$tap" \
    MF_SECURE_BOOT="$secure_boot" MF_PXE_DIR="$pxe_dir" MF_PXE_BOOTFILE="$pxe_bootfile" \
    write_vm_manifest "$name"
    [[ -n "$lab_name" ]] && log_info "lab: $lab_name"

    # Success — clear the cleanup-on-failure trap.
    trap - EXIT

    log_info "── VM '$name' provisioned (not started; run:  $LAB_PROG start $name) ──"
    if [[ "$distro" == "kali" ]]; then
        log_info "Kali prebuilt image has no cloud-init; first-boot config is manual."
        log_info "  1) $LAB_PROG start $name"
        log_info "  2) $LAB_PROG console $name   # login kali/kali"
        log_info "  3) (inside) sudo systemctl enable --now ssh"
        log_info "  4) (inside) mkdir -p ~/.ssh && echo '<your-pubkey>' >> ~/.ssh/authorized_keys"
        log_info "  5) $LAB_PROG ssh $name -- uname -a   # works thereafter"
        log_info "ssh port reserved: 127.0.0.1:$ssh_port → guest:22"
    elif [[ "$ssh_user" == "root" ]]; then
        log_info "ssh access after boot:  ssh -p $ssh_port root@127.0.0.1   (pubkey auth via dropbear)"
    else
        log_info "ssh access after boot:  ssh -p $ssh_port $ssh_user@127.0.0.1   (default password 'lab')"
    fi
}

cmd_create() {
    # Finding 9: hold an exclusive lock for the duration of create so concurrent
    # lab-vm.sh create invocations cannot both select the same SSH port (they
    # both read taken ports before either writes a manifest; the result is two
    # VMs with port 2222 that fail to start with a QEMU hostfwd bind error).
    state_init
    local _lockfile="$LAB_VM_STATE_DIR/.create.lock"
    local _lockfd
    exec {_lockfd}>>"$_lockfile"
    flock -x "$_lockfd" || die "could not acquire VM create lock (another create in progress?)"

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

    flock -u "$_lockfd"
    exec {_lockfd}>&-
}

# ─── Subcommand: start ─────────────────────────────────────────────────────
cmd_start() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG start <name>"
    validate_vm_name "$name"
    vm_exists "$name" || die "no VM named '$name' (try 'list')"
    if vm_running "$name"; then
        log_info "$name is already running (pid $(cat "$(vm_pidfile "$name")"))"
        return 0
    fi

    # Reload manifest into globals expected by build_qemu_argv.
    local arch microvm accel memory cpus ssh_port disk seed kernel initrd append firmware
    local install_target mac
    local cores threads cpu_pin network_mode bridge tap
    arch="$(read_manifest_field "$name" arch)"
    microvm="$(read_manifest_field "$name" microvm)"
    accel="$(read_manifest_field "$name" accel)"
    memory="$(read_manifest_field "$name" memory)"
    cpus="$(read_manifest_field "$name" cpus)"
    ssh_port="$(read_manifest_field "$name" ssh_port)"
    disk="$(read_manifest_field "$name" disk)"
    install_target="$(read_manifest_field "$name" install_target)"
    mac="$(read_manifest_field "$name" mac)"
    seed="$(read_manifest_field "$name" seed)"
    kernel="$(read_manifest_field "$name" kernel)"
    initrd="$(read_manifest_field "$name" initrd)"
    append="$(read_manifest_field "$name" append)"
    # v0.2 fields (empty on manifests written before this version → safe defaults).
    cores="$(read_manifest_field "$name" cores 2>/dev/null || true)"
    secure_boot="$(read_manifest_field "$name" secure_boot 2>/dev/null || true)"
    pxe_dir="$(read_manifest_field "$name" pxe_dir 2>/dev/null || true)"
    pxe_bootfile="$(read_manifest_field "$name" pxe_bootfile 2>/dev/null || true)"
    threads="$(read_manifest_field "$name" threads 2>/dev/null || true)"
    cpu_pin="$(read_manifest_field "$name" cpu_pin 2>/dev/null || true)"
    network_mode="$(read_manifest_field "$name" network_mode 2>/dev/null || true)"
    [[ -z "$network_mode" ]] && network_mode=user
    bridge="$(read_manifest_field "$name" bridge 2>/dev/null || true)"
    tap="$(read_manifest_field "$name" tap 2>/dev/null || true)"
    firmware="$(firmware_for "$arch" "$microvm" "${secure_boot:-false}")"

    # Clean up any stale unix sockets from a previous run.
    rm -f "$(vm_serial "$name")" "$(vm_monitor "$name")" "$(vm_qmp "$name")"

    build_qemu_argv

    # CPU pinning: taskset binds the QEMU process (and its vCPU threads inherit
    # the affinity) to the given host CPU list.  Pre-existing VMs (no cpu_pin)
    # launch exactly as before.
    local -a launch=()
    if [[ -n "${cpu_pin:-}" ]]; then
        require_cmd taskset
        launch=(taskset -c "$cpu_pin")
        log_info "pinning to host CPUs: $cpu_pin"
    fi

    log_info "starting $name (accel=$accel arch=$arch mem=$memory cpus=$cpus)"
    log_debug "argv: ${launch[*]:-} ${QEMU_ARGV[*]}"

    # Finding 20: create the log file explicitly with 0600 so QEMU's startup
    # output is not world-readable (the VM dir is 0700, but a subsequent chmod
    # or umask change could expose it; belt-and-suspenders).
    install -m 0600 /dev/null "$(vm_log "$name")"

    if "${launch[@]}" "${QEMU_ARGV[@]}" >>"$(vm_log "$name")" 2>&1; then
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
    validate_vm_name "$name"
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
    validate_vm_name "$name"
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
    validate_vm_name "$name"
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
        # Finding 13: use per-VM known_hosts + StrictHostKeyChecking=accept-new.
        # StrictHostKeyChecking=no silently accepted any host key on every
        # connection, enabling MITM by any local process that binds the port.
        # accept-new trusts on first connection, then verifies on subsequent ones.
        local known_hosts; known_hosts="$(vm_dir "$name")/known_hosts"
        ssh -p "$port" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$known_hosts" \
            "${user}@127.0.0.1" "$remote_cmd"
    else
        local known_hosts; known_hosts="$(vm_dir "$name")/known_hosts"
        ssh -p "$port" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile="$known_hosts" \
            "${user}@127.0.0.1"
    fi
}

# ─── Subcommand: destroy ───────────────────────────────────────────────────
_safe_rm_rf_vm() {
    local path="$1"
    [[ -n "$path" ]]    || die "destroy: VM dir path is empty — refusing rm -rf"
    [[ "$path" == /* ]] || die "destroy: VM dir path is not absolute: $path"
    [[ "$path" != "/" ]] || die "destroy: refusing rm -rf /"
    local depth; depth="$(awk -F/ '{print NF-1}' <<<"$path")"
    [[ "$depth" -ge 2 ]] \
        || die "destroy: VM dir path '$path' is too shallow (min /a/b required)"
    rm -rf -- "$path"
}

cmd_destroy() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG destroy <name> [--force] [--keep-disk]"
    validate_vm_name "$name"
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

    _safe_rm_rf_vm "$(vm_dir "$name")"
    log_info "destroyed: $name"
}

# ─── Subcommand: list ──────────────────────────────────────────────────────
# ─── Subcommand: inspect ────────────────────────────────────────────────────
# Single-VM detail report — pairs the static manifest with cheap live
# probes (qemu pid + RSS, disk + seed + kernel/initrd file stats, monitor
# socket presence, foreign-arch interpreter availability).
#
# Two output modes:
#   default      → human-readable [manifest] / [live] sections
#   --json       → one JSON document on stdout, schema_version=1
#
# Designed primarily as a machine-readable surface for Phase 6 (the TUI's
# VM detail panel).  CLI users get the same data but rendered.
cmd_inspect() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG inspect <name> [--json]"
    vm_exists "$name" || die "no VM named '$name' (try '$LAB_PROG list')"

    # --- manifest fields (each may be empty; |\| true so set -e doesn't
    # propagate read_manifest_field's rc out of the var=$() subshell —
    # bash 4.4+ propagates errexit through command substitution).
    local m_lab m_backend m_distro m_suite m_arch m_memory m_cpus
    local m_microvm m_accel m_ssh_port m_disk m_seed m_kernel m_initrd
    local m_append m_ssh_user m_created m_version
    m_lab="$(read_manifest_field      "$name" lab        2>/dev/null || true)"
    m_backend="$(read_manifest_field  "$name" backend    2>/dev/null || true)"
    m_distro="$(read_manifest_field   "$name" distro     2>/dev/null || true)"
    m_suite="$(read_manifest_field    "$name" suite      2>/dev/null || true)"
    m_arch="$(read_manifest_field     "$name" arch       2>/dev/null || true)"
    m_memory="$(read_manifest_field   "$name" memory     2>/dev/null || true)"
    m_cpus="$(read_manifest_field     "$name" cpus       2>/dev/null || true)"
    m_microvm="$(read_manifest_field  "$name" microvm    2>/dev/null || true)"
    m_accel="$(read_manifest_field    "$name" accel      2>/dev/null || true)"
    m_ssh_port="$(read_manifest_field "$name" ssh_port   2>/dev/null || true)"
    m_disk="$(read_manifest_field     "$name" disk       2>/dev/null || true)"
    m_seed="$(read_manifest_field     "$name" seed       2>/dev/null || true)"
    m_kernel="$(read_manifest_field   "$name" kernel     2>/dev/null || true)"
    m_initrd="$(read_manifest_field   "$name" initrd     2>/dev/null || true)"
    m_append="$(read_manifest_field   "$name" append     2>/dev/null || true)"
    m_ssh_user="$(read_manifest_field "$name" ssh_user   2>/dev/null || true)"
    m_created="$(read_manifest_field  "$name" created_at 2>/dev/null || true)"
    m_version="$(read_manifest_field  "$name" version    2>/dev/null || true)"

    # Numeric fields: default to JSON-safe values when the manifest is
    # silent (Phase 2 always writes them, but be defensive).
    [[ -z "$m_cpus" ]]     && m_cpus=0
    [[ -z "$m_ssh_port" ]] && m_ssh_port=0
    [[ "$m_microvm" == "true" || "$m_microvm" == "false" ]] || m_microvm=false

    # --- live: process state via vm_running + /proc/PID/{status,stat}
    local p_running=false p_pid=0 p_rss=0 p_threads=0 p_starttime=0
    if vm_running "$name"; then
        p_running=true
        p_pid="$(cat "$(vm_pidfile "$name")" 2>/dev/null || printf 0)"
        if [[ -r "/proc/$p_pid/status" ]]; then
            # VmRSS is in KB; convert to bytes for a stable unit.
            local rss_kb
            rss_kb="$(awk '/^VmRSS:/{print $2; exit}' "/proc/$p_pid/status" 2>/dev/null)"
            p_rss=$(( ${rss_kb:-0} * 1024 ))
            p_threads="$(awk '/^Threads:/{print $2; exit}' "/proc/$p_pid/status" 2>/dev/null || printf 0)"
        fi
        if [[ -r "/proc/$p_pid/stat" ]]; then
            # Field 22: starttime in clock ticks since boot.  Consumers
            # convert to wall time via /proc/uptime + sysconf(_SC_CLK_TCK).
            p_starttime="$(awk '{print $22}' "/proc/$p_pid/stat" 2>/dev/null || printf 0)"
        fi
    fi

    # --- live: file stats
    # Helper: emit "<exists>\t<size_bytes>" for a path (size 0 if missing).
    _file_stats() {
        local path="$1"
        if [[ -n "$path" && -e "$path" ]]; then
            local sz
            if sz="$(du -sb "$path" 2>/dev/null | awk '{print $1; exit}')"; then
                :
            else
                local sk; sk="$(du -sk "$path" 2>/dev/null | awk '{print $1; exit}')"
                sz=$(( ${sk:-0} * 1024 ))
            fi
            printf 'true\t%s\n' "${sz:-0}"
        else
            printf 'false\t0\n'
        fi
    }

    local f_disk_path; f_disk_path="$(vm_disk "$name")"
    local f_disk_exists f_disk_size
    IFS=$'\t' read -r f_disk_exists f_disk_size <<<"$(_file_stats "$f_disk_path")"
    # Virtual size is meaningful only if qemu-img is around AND the file
    # is a qcow2; report null otherwise.
    local f_disk_vsize="null"
    if [[ "$f_disk_exists" == "true" ]] && have qemu-img; then
        local vsz
        vsz="$(qemu-img info --output=json "$f_disk_path" 2>/dev/null \
             | jq -r '."virtual-size" // empty' 2>/dev/null)"
        [[ -n "$vsz" ]] && f_disk_vsize="$vsz"
    fi

    local f_seed_path; f_seed_path="$(vm_seed "$name")"
    local f_seed_exists f_seed_size
    IFS=$'\t' read -r f_seed_exists f_seed_size <<<"$(_file_stats "$f_seed_path")"

    local f_kernel_path="$m_kernel"
    local f_kernel_exists f_kernel_size
    IFS=$'\t' read -r f_kernel_exists f_kernel_size <<<"$(_file_stats "$f_kernel_path")"

    local f_initrd_path="$m_initrd"
    local f_initrd_exists f_initrd_size
    IFS=$'\t' read -r f_initrd_exists f_initrd_size <<<"$(_file_stats "$f_initrd_path")"

    local f_log_path; f_log_path="$(vm_log "$name")"
    local f_log_exists f_log_size
    IFS=$'\t' read -r f_log_exists f_log_size <<<"$(_file_stats "$f_log_path")"

    # --- live: sockets — exists is enough; if QEMU is up they are too,
    # if it's down stale ones may linger across an unclean stop.
    local s_serial_path s_monitor_path s_qmp_path
    s_serial_path="$(vm_serial "$name")"
    s_monitor_path="$(vm_monitor "$name")"
    s_qmp_path="$(vm_qmp "$name")"
    local s_serial_exists=false s_monitor_exists=false s_qmp_exists=false
    [[ -S "$s_serial_path"  ]] && s_serial_exists=true
    [[ -S "$s_monitor_path" ]] && s_monitor_exists=true
    [[ -S "$s_qmp_path"     ]] && s_qmp_exists=true

    # --- live: foreign-arch interpreter (when VM arch != host arch)
    local host_arch fa_qemu_bin fa_qemu_avail="null" fa_kvm_avail="null"
    host_arch="$(detect_host_arch)"
    if [[ -n "$m_arch" && "$m_arch" != "$host_arch" ]]; then
        local qsys
        if qsys="$(arch_map "$m_arch" qemu-system 2>/dev/null)" && [[ -n "$qsys" ]]; then
            fa_qemu_bin="qemu-system-${qsys}"
            if have "$fa_qemu_bin"; then fa_qemu_avail=true
            else                          fa_qemu_avail=false
            fi
        fi
        # Foreign-arch VMs cannot use KVM regardless of /dev/kvm.
        fa_kvm_avail=false
    elif [[ -n "$m_arch" ]]; then
        # Same-arch VM: KVM available iff /dev/kvm is readable.
        if [[ -r /dev/kvm ]]; then fa_kvm_avail=true
        else                       fa_kvm_avail=false
        fi
    fi

    # --- emit ------------------------------------------------------------
    if [[ -n "${OPT_JSON:-}" ]]; then
        require_cmd jq
        jq -n \
            --arg name        "$name" \
            --arg lab         "$m_lab" \
            --arg backend     "$m_backend" \
            --arg distro      "$m_distro" \
            --arg suite       "$m_suite" \
            --arg arch        "$m_arch" \
            --arg memory      "$m_memory" \
            --argjson cpus    "$m_cpus" \
            --argjson microvm "$m_microvm" \
            --arg accel       "$m_accel" \
            --argjson ssh_port "$m_ssh_port" \
            --arg disk        "$m_disk" \
            --arg seed        "$m_seed" \
            --arg kernel      "$m_kernel" \
            --arg initrd      "$m_initrd" \
            --arg append      "$m_append" \
            --arg ssh_user    "$m_ssh_user" \
            --arg created_at  "$m_created" \
            --arg version     "$m_version" \
            --argjson p_running "$p_running" \
            --argjson p_pid     "$p_pid" \
            --argjson p_rss     "$p_rss" \
            --argjson p_threads "$p_threads" \
            --argjson p_starttime "$p_starttime" \
            --arg     f_disk_path  "$f_disk_path" \
            --argjson f_disk_exists "$f_disk_exists" \
            --argjson f_disk_size   "$f_disk_size" \
            --argjson f_disk_vsize  "$f_disk_vsize" \
            --arg     f_seed_path  "$f_seed_path" \
            --argjson f_seed_exists "$f_seed_exists" \
            --argjson f_seed_size   "$f_seed_size" \
            --arg     f_kernel_path "$f_kernel_path" \
            --argjson f_kernel_exists "$f_kernel_exists" \
            --argjson f_kernel_size   "$f_kernel_size" \
            --arg     f_initrd_path "$f_initrd_path" \
            --argjson f_initrd_exists "$f_initrd_exists" \
            --argjson f_initrd_size   "$f_initrd_size" \
            --arg     f_log_path  "$f_log_path" \
            --argjson f_log_exists "$f_log_exists" \
            --argjson f_log_size   "$f_log_size" \
            --arg     s_serial_path  "$s_serial_path" \
            --argjson s_serial_exists "$s_serial_exists" \
            --arg     s_monitor_path "$s_monitor_path" \
            --argjson s_monitor_exists "$s_monitor_exists" \
            --arg     s_qmp_path     "$s_qmp_path" \
            --argjson s_qmp_exists   "$s_qmp_exists" \
            --arg     host_arch    "$host_arch" \
            --arg     fa_qemu_bin  "${fa_qemu_bin:-}" \
            --argjson fa_qemu_avail "$fa_qemu_avail" \
            --argjson fa_kvm_avail  "$fa_kvm_avail" \
            '{
                schema_version: 1,
                name: $name,
                manifest: {
                    name: $name,
                    lab: (if $lab == "" then null else $lab end),
                    backend: $backend, distro: $distro, suite: $suite,
                    arch: $arch, memory: $memory, cpus: $cpus,
                    microvm: $microvm, accel: $accel, ssh_port: $ssh_port,
                    disk: (if $disk == "" then null else $disk end),
                    seed: (if $seed == "" then null else $seed end),
                    kernel: (if $kernel == "" then null else $kernel end),
                    initrd: (if $initrd == "" then null else $initrd end),
                    append: (if $append == "" then null else $append end),
                    ssh_user: $ssh_user,
                    created_at: $created_at, version: $version
                },
                process: {
                    running: $p_running,
                    pid: (if $p_running then $p_pid else null end),
                    rss_bytes: (if $p_running then $p_rss else null end),
                    threads: (if $p_running then $p_threads else null end),
                    starttime_jiffies: (if $p_running then $p_starttime else null end)
                },
                files: {
                    disk: { path: $f_disk_path, exists: $f_disk_exists,
                            size_bytes: $f_disk_size,
                            virtual_size_bytes: $f_disk_vsize },
                    seed: { path: $f_seed_path, exists: $f_seed_exists,
                            size_bytes: $f_seed_size },
                    kernel: (if $f_kernel_path == "" then null
                             else { path: $f_kernel_path,
                                    exists: $f_kernel_exists,
                                    size_bytes: $f_kernel_size }
                             end),
                    initrd: (if $f_initrd_path == "" then null
                             else { path: $f_initrd_path,
                                    exists: $f_initrd_exists,
                                    size_bytes: $f_initrd_size }
                             end),
                    log: { path: $f_log_path, exists: $f_log_exists,
                           size_bytes: $f_log_size }
                },
                sockets: {
                    serial:  { path: $s_serial_path,  exists: $s_serial_exists  },
                    monitor: { path: $s_monitor_path, exists: $s_monitor_exists },
                    qmp:     { path: $s_qmp_path,     exists: $s_qmp_exists     }
                },
                network: {
                    ssh_port: $ssh_port,
                    ssh_user: $ssh_user
                },
                foreign_arch: (
                    if $arch == "" or $arch == $host_arch then
                        { host_arch: $host_arch, vm_arch: $arch,
                          qemu_system_binary: null,
                          qemu_available: null,
                          kvm_available: $fa_kvm_avail }
                    else
                        { host_arch: $host_arch, vm_arch: $arch,
                          qemu_system_binary: (if $fa_qemu_bin == "" then null else $fa_qemu_bin end),
                          qemu_available: $fa_qemu_avail,
                          kvm_available: $fa_kvm_avail }
                    end
                )
            }'
        return 0
    fi

    # Human-readable rendering — same data, indented two-section layout.
    printf '[manifest]\n'
    printf '  name        %s\n' "$name"
    [[ -n "$m_lab" ]]      && printf '  lab         %s\n' "$m_lab"
    [[ -n "$m_backend" ]]  && printf '  backend     %s\n' "$m_backend"
    [[ -n "$m_distro" ]]   && printf '  distro      %s\n' "$m_distro"
    [[ -n "$m_suite" ]]    && printf '  suite       %s\n' "$m_suite"
    [[ -n "$m_arch" ]]     && printf '  arch        %s\n' "$m_arch"
    [[ -n "$m_memory" ]]   && printf '  memory      %s\n' "$m_memory"
    printf '  cpus        %s\n' "$m_cpus"
    printf '  microvm     %s\n' "$m_microvm"
    [[ -n "$m_accel" ]]    && printf '  accel       %s\n' "$m_accel"
    printf '  ssh_port    %s\n' "$m_ssh_port"
    [[ -n "$m_ssh_user" ]] && printf '  ssh_user    %s\n' "$m_ssh_user"
    [[ -n "$m_created" ]]  && printf '  created_at  %s\n' "$m_created"

    printf '\n[live]\n'
    printf '  process.running     %s\n' "$p_running"
    if [[ "$p_running" == "true" ]]; then
        printf '  process.pid         %s\n' "$p_pid"
        printf '  process.rss_bytes   %s\n' "$p_rss"
        printf '  process.threads     %s\n' "$p_threads"
    fi
    printf '  files.disk          %s (exists=%s, size=%s%s)\n' \
        "$f_disk_path" "$f_disk_exists" "$f_disk_size" \
        "$([[ "$f_disk_vsize" != "null" ]] && printf ', virtual=%s' "$f_disk_vsize")"
    printf '  files.seed          %s (exists=%s, size=%s)\n' \
        "$f_seed_path" "$f_seed_exists" "$f_seed_size"
    [[ -n "$m_kernel" ]] && printf '  files.kernel        %s (exists=%s, size=%s)\n' \
        "$f_kernel_path" "$f_kernel_exists" "$f_kernel_size"
    [[ -n "$m_initrd" ]] && printf '  files.initrd        %s (exists=%s, size=%s)\n' \
        "$f_initrd_path" "$f_initrd_exists" "$f_initrd_size"
    printf '  files.log           %s (exists=%s, size=%s)\n' \
        "$f_log_path" "$f_log_exists" "$f_log_size"
    printf '  sockets.serial      %s (exists=%s)\n' "$s_serial_path"  "$s_serial_exists"
    printf '  sockets.monitor     %s (exists=%s)\n' "$s_monitor_path" "$s_monitor_exists"
    printf '  sockets.qmp         %s (exists=%s)\n' "$s_qmp_path"     "$s_qmp_exists"
    if [[ -n "$m_arch" && "$m_arch" != "$host_arch" ]]; then
        printf '  foreign_arch.host        %s\n' "$host_arch"
        printf '  foreign_arch.vm          %s\n' "$m_arch"
        [[ -n "$fa_qemu_bin" ]] && printf '  foreign_arch.qemu_bin    %s (available=%s)\n' \
            "$fa_qemu_bin" "$fa_qemu_avail"
        printf '  foreign_arch.kvm         %s\n' "$fa_kvm_avail"
    elif [[ -n "$m_arch" ]]; then
        printf '  foreign_arch.kvm         %s (host arch matches)\n' "$fa_kvm_avail"
    fi
}

cmd_list() {
    state_init
    local filter="${OPT_LAB-__ALL__}"
    [[ -n "${OPT_LAB:-}" ]] && printf '── lab: %s ──\n' "$OPT_LAB"
    printf '%-20s  %-14s  %-13s  %-10s  %-8s  %-8s  %-7s  %s\n' \
        NAME LAB BACKEND DISTRO ARCH STATUS SSHPORT MEMORY
    local n state port row_lab
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        row_lab="$(read_manifest_field "$n" lab 2>/dev/null || true)"
        if [[ "$filter" != "__ALL__" ]]; then
            [[ "$row_lab" == "$filter" ]] || continue
        fi
        if vm_running "$n"; then state="running"; else state="stopped"; fi
        port="$(read_manifest_field "$n" ssh_port)"
        printf '%-20s  %-14s  %-13s  %-10s  %-8s  %-8s  %-7s  %s\n' \
            "$n" \
            "${row_lab:-(none)}" \
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
  $LAB_PROG inspect  <name> [--json]
  $LAB_PROG snapshot {create|list|restore|delete} <name> [snap-name]   # offline qcow2 snapshots
  $LAB_PROG version | help

CREATE OPTIONS
  --name      <vm-name>                  (required)
  --backend   {disk-image|kernel+initrd|from-chroot|pxe-install}   (default: disk-image)
                                         from-chroot: turns a Phase-1 chroot tree (with a
                                         kernel installed inside) into a bootable qcow2.
                                         x86_64 BIOS only in v0.1.  Requires root.
  --distro    {debian|ubuntu|rocky|alpine|kali}        (disk-image)
  --suite     <release>                  e.g. bookworm | jammy | 9 | 3.23 | latest | kali-rolling
                                         (alpine: "latest" → resolves via dl-cdn.alpinelinux.org)
  --arch      {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x}  (default: host arch)
  --memory    <size>                     (default: 2G)
  --cpus      <n>                        (default: 2)
  --microvm                              (use the microvm machine type, x86_64/aarch64)
  --image     /path/to/qcow2|.img        (override the cached cloud image)
  --kernel    /path/to/vmlinuz           (kernel+initrd backend)
  --initrd    /path/to/initrd            (kernel+initrd backend)
  --append    "<cmdline>"                (kernel+initrd backend)
  --chroot    /path/to/phase1-tree       (from-chroot backend)
  --disk-size SIZE                       (from-chroot backend; default 4G)
  --ssh-port  <port>                     (default: auto-allocate from 2222)
  --pubkey    /path/to/id_rsa.pub        (default: invoking user's ~/.ssh/*.pub)
  --no-cloud-init                        (skip cloud-init NoCloud seeding; for bare/iPXE disk images)
  --refresh-image                        (re-download the cached cloud image, ignoring any cache)
  --cores     <n>                        (CPU topology: cores per socket; with --threads)
  --threads   <n>                        (CPU topology: threads per core; sockets derived)
  --cpu-pin   <cpu-list>                 (pin the VM to host CPUs via taskset, e.g. "0-3" or "0,2")
  --network-mode {user|bridge|tap}       (default user = slirp+hostfwd; bridge/tap need root)
  --bridge    <name>                     (bridge to attach for --network-mode bridge; default virbr0)
  --tap       <ifname>                   (tap device for --network-mode tap)
  --packages  "p1,p2,..."                (cloud-init: extra packages to install at first boot)
  --runcmd    "<cmd>"                    (cloud-init: first-boot command; repeatable)
  --user-data /path/to/user-data         (cloud-init: use this file verbatim — full override)
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
    OPT_LAB=""
    OPT_CHROOT="" OPT_DISK_SIZE=""
    OPT_JSON=""
    OPT_CLOUD_INIT="true"
    OPT_REFRESH_IMAGE="" OPT_CORES="" OPT_THREADS="" OPT_CPU_PIN=""
    OPT_NETWORK_MODE="" OPT_BRIDGE="" OPT_TAP=""
    OPT_PACKAGES="" OPT_USER_DATA="" OPT_RUNCMD=()
    OPT_NETBOOT_DIR="" OPT_KERNEL_NAME="" OPT_INITRD_NAME="" OPT_GENERATE_SCRIPT="" OPT_SERVER=""
    OPT_PXE_DIR="" OPT_PXE_BOOTFILE="" OPT_SECURE_BOOT=""

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
            --lab)          OPT_LAB="$2"; shift 2 ;;
            --chroot)       OPT_CHROOT="$2"; shift 2 ;;
            --disk-size)    OPT_DISK_SIZE="$2"; shift 2 ;;
            --no-cloud-init) OPT_CLOUD_INIT="false"; shift ;;
            --refresh-image) OPT_REFRESH_IMAGE="true"; shift ;;
            --cores)        OPT_CORES="$2"; shift 2 ;;
            --threads)      OPT_THREADS="$2"; shift 2 ;;
            --cpu-pin)      OPT_CPU_PIN="$2"; shift 2 ;;
            --network-mode) OPT_NETWORK_MODE="$2"; shift 2 ;;
            --bridge)       OPT_BRIDGE="$2"; shift 2 ;;
            --tap)          OPT_TAP="$2"; shift 2 ;;
            --packages)     OPT_PACKAGES="$2"; shift 2 ;;
            --runcmd)       OPT_RUNCMD+=("$2"); shift 2 ;;
            --user-data)    [[ -r "$2" ]] || die "user-data file not readable: $2"; OPT_USER_DATA="$2"; shift 2 ;;
            --json)         OPT_JSON=1; shift ;;
            --netboot-dir)  OPT_NETBOOT_DIR="$2"; shift 2 ;;
            --kernel-name)  OPT_KERNEL_NAME="$2"; shift 2 ;;
            --initrd-name)  OPT_INITRD_NAME="$2"; shift 2 ;;
            --generate-script) OPT_GENERATE_SCRIPT=1; shift ;;
            --server)       OPT_SERVER="$2"; shift 2 ;;
            --pxe-dir)      OPT_PXE_DIR="$2"; shift 2 ;;
            --pxe-bootfile) OPT_PXE_BOOTFILE="$2"; shift 2 ;;
            --secure-boot)  OPT_SECURE_BOOT=1; shift ;;
            -h|--help)      usage; exit 0 ;;
            -v|--version)   printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION"; exit 0 ;;
            -*)             die "unknown option: $1 (try --help)" ;;
            *)              POS_ARGS+=("$1"); shift ;;
        esac
    done
}

# ─── Subcommand: snapshot (offline qcow2 snapshots via qemu-img) ───────────
cmd_snapshot() {
    local action="${POS_ARGS[0]:-}" name="${POS_ARGS[1]:-}" snap="${POS_ARGS[2]:-}"
    [[ -n "$action" ]] || die "usage: $LAB_PROG snapshot {create|list|restore|delete} <vm> [snap-name]"
    [[ -n "$name"   ]] || die "snapshot $action: missing <vm> name"
    validate_vm_name "$name"
    vm_exists "$name" || die "no VM named '$name' (try '$LAB_PROG list')"
    require_cmd qemu-img
    local disk; disk="$(read_manifest_field "$name" disk)"
    [[ -n "$disk" && -r "$disk" ]] \
        || die "VM '$name' has no disk to snapshot (backend=$(read_manifest_field "$name" backend) has no qcow2)"
    qemu-img info "$disk" 2>/dev/null | grep -q 'file format: qcow2' \
        || die "snapshot needs a qcow2 disk; '$disk' is not qcow2"

    case "$action" in
        list)
            qemu-img snapshot -l "$disk"
            ;;
        create|restore|delete)
            [[ -n "$snap" ]] || die "snapshot $action: missing <snap-name>"
            # Finding 19: reject snap names starting with '-' — qemu-img would
            # parse them as flags (e.g. snap="-l" causes a list instead of create).
            [[ "$snap" != -* ]] || die "snapshot name cannot start with '-': $snap"
            # Mutating a disk under a live QEMU corrupts it — require the VM stopped.
            ! vm_running "$name" \
                || die "snapshot $action needs '$name' stopped (would corrupt a live disk).  Run: $LAB_PROG stop $name"
            case "$action" in
                # Note: qemu-img snapshot does not support -- as an option terminator;
                # dash-leading names are rejected by the validate above (Finding 19).
                create)  qemu-img snapshot -c "$snap" "$disk" || die "qemu-img snapshot create failed"
                         log_info "snapshot created: ${name}@${snap}" ;;
                restore) qemu-img snapshot -a "$snap" "$disk" || die "qemu-img snapshot restore failed (does '$snap' exist? try: $LAB_PROG snapshot list $name)"
                         log_info "snapshot restored: ${name}@${snap}" ;;
                delete)  qemu-img snapshot -d "$snap" "$disk" || die "qemu-img snapshot delete failed"
                         log_info "snapshot deleted: ${name}@${snap}" ;;
            esac
            ;;
        *) die "unknown snapshot action: $action (use create|list|restore|delete)" ;;
    esac
}

# ─── Subcommand: publish-netboot ───────────────────────────────────────────
# Copy a kernel+initrd VM's kernel and initrd files to a netboot directory so
# they can be served by the Phase 4 nginx container.  Works for both:
#   - Explicit kernel+initrd VMs (backend=kernel+initrd) whose manifest carries
#     absolute kernel/initrd paths.
#   - Alpine microvm VMs: same — the builder writes absolute paths into the manifest.
#
# Usage:
#   lab-vm.sh publish-netboot <name>
#               [--netboot-dir DIR]      (default: $LAB_NETBOOT_DIR or ~/netboot)
#               [--kernel-name NAME]     (default: kernel)
#               [--initrd-name NAME]     (default: initrd.gz)
#               [--generate-script]      re-write boot.ipxe in the output dir
#               [--server URL]           server base URL for --generate-script
cmd_publish_netboot() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG publish-netboot <name> [--netboot-dir DIR] ..."
    vm_exists "$name" || die "no VM named '$name' (try '$LAB_PROG list')"

    local backend; backend="$(read_manifest_field "$name" backend)"
    [[ "$backend" == "kernel+initrd" ]]         || die "publish-netboot only applies to kernel+initrd VMs; '$name' uses backend=$backend"

    local src_kernel; src_kernel="$(read_manifest_field "$name" kernel)"
    local src_initrd; src_initrd="$(read_manifest_field "$name" initrd)"
    [[ -r "$src_kernel" ]] || die "kernel file not readable: ${src_kernel:-<unset>}"
    [[ -r "$src_initrd" ]] || die "initrd file not readable: ${src_initrd:-<unset>}"

    local netboot_dir="${OPT_NETBOOT_DIR:-${LAB_NETBOOT_DIR:-$HOME/netboot}}"
    local kernel_name="${OPT_KERNEL_NAME:-kernel}"
    local initrd_name="${OPT_INITRD_NAME:-initrd.gz}"

    install -d -m 0755 "$netboot_dir"

    local dst_kernel="$netboot_dir/$kernel_name"
    local dst_initrd="$netboot_dir/$initrd_name"

    log_info "publishing kernel: $src_kernel → $dst_kernel"
    cp "$src_kernel" "$dst_kernel"
    log_info "publishing initrd: $src_initrd → $dst_initrd"
    cp "$src_initrd" "$dst_initrd"

    if [[ -n "${OPT_GENERATE_SCRIPT:-}" ]]; then
        local server="${OPT_SERVER:-http://10.0.2.2:8080}"
        local append; append="$(read_manifest_field "$name" append)"
        local boot_script="$netboot_dir/boot.ipxe"
        log_info "writing boot.ipxe → $boot_script (server=$server)"
        cat > "$boot_script" <<EOF
#!ipxe
dhcp
kernel ${server}/${kernel_name} ${append}
initrd ${server}/${initrd_name}
boot
EOF
        log_info "  kernel cmdline: ${append}"
    fi

    log_info "── publish-netboot done ──"
    log_info "  kernel : $dst_kernel"
    log_info "  initrd : $dst_initrd"
    if [[ -n "${OPT_GENERATE_SCRIPT:-}" ]]; then
        log_info "  script : $netboot_dir/boot.ipxe"
    fi
    log_info ""
    log_info "next: phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml"
}


main() {
    parse_args "$@"
    case "$SUBCMD" in
        create)   cmd_create   ;;
        start)    cmd_start    ;;
        stop)     cmd_stop     ;;
        console)  cmd_console  ;;
        ssh)      cmd_ssh      ;;
        destroy)  cmd_destroy  ;;
        list)     cmd_list     ;;
        inspect)  cmd_inspect  ;;
        snapshot)        cmd_snapshot        ;;
        publish-netboot) cmd_publish_netboot ;;
        help)     usage        ;;
        version)  printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)        usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

# Run main only when executed directly, not when sourced (e.g. by unit tests
# that exercise build_qemu_argv).  Same idiom as micro-linux/mlbuild.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
