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
                # microvm machine boots without UEFI; use direct kernel boot.
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
disk        = "$(vm_disk "$name")"
seed        = "${MF_SEED:-}"
kernel      = "${MF_KERNEL:-}"
initrd      = "${MF_INITRD:-}"
append      = "${MF_APPEND:-}"
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
    # make_seed_iso NAME OUT_PATH PUBKEY_OPTIONAL
    # Note: we use a subshell + EXIT trap rather than a function-level RETURN
    # trap, because RETURN traps in bash are global and fire for every later
    # function return — they cannot reference now-out-of-scope locals.
    local name="$1" out="$2" pubkey="${3:-}"
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
        printf '    sudo: ALL=(ALL) NOPASSWD:ALL\n'
        printf '    groups: [sudo, wheel]\n'
        printf '    shell: /bin/bash\n'
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
        '{name:$name, backend:$backend, distro:$distro, suite:$suite, arch:$arch,
          memory:$memory, cpus:($cpus|tonumber), microvm:($microvm=="true"),
          image:$image, kernel:$kernel, initrd:$initrd, append:$append,
          ssh_port:($ssh_port|tonumber), pubkey:$pubkey}'
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
            pubkey:  (.pubkey  // "") }
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
            local kernel initrd
            kernel="$(spec_get "$spec" kernel)"
            initrd="$(spec_get "$spec" initrd)"
            [[ -r "$kernel" ]] || die "spec ($name) kernel not readable: $kernel"
            [[ -r "$initrd" ]] || die "spec ($name) initrd not readable: $initrd"
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
    fi
}

# ─── Port allocation ───────────────────────────────────────────────────────
pick_ssh_port() {
    # Find a free TCP port starting from 2222. Prints the chosen port.
    local p
    for p in $(seq 2222 2400); do
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${p}\$"; then
            printf '%s' "$p"; return 0
        fi
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

    # Direct kernel boot (kernel+initrd backend, OR microvm with cloud image
    # extraction — left to user for now)
    if [[ -n "$kernel" ]]; then
        QEMU_ARGV+=(-kernel "$kernel")
        [[ -n "$initrd" ]] && QEMU_ARGV+=(-initrd "$initrd")
        [[ -n "$append" ]] && QEMU_ARGV+=(-append "$append")
    fi

    # Disk
    if [[ -n "$disk" ]]; then
        QEMU_ARGV+=(-drive "file=${disk},if=virtio,format=qcow2,cache=writeback,discard=unmap")
    fi

    # cloud-init seed
    if [[ -n "$seed" ]]; then
        QEMU_ARGV+=(-drive "file=${seed},if=virtio,format=raw,readonly=on")
    fi

    # Network: user-mode with hostfwd for ssh
    QEMU_ARGV+=(
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
        -device "virtio-net-pci,netdev=net0"
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
            make_seed_iso "$name" "$seed" "$pubkey"
            ;;
        kernel+initrd)
            # Optional disk: if user supplies --image, use it; else no disk.
            if [[ -n "$image" ]]; then
                require_cmd qemu-img
                qemu-img create -f qcow2 -F qcow2 -b "$image" "$disk" >/dev/null
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
    MF_ACCEL="$accel" MF_SSH_PORT="$ssh_port" MF_SEED="$seed" \
    MF_KERNEL="$kernel" MF_INITRD="$initrd" MF_APPEND="$append" \
    write_vm_manifest "$name"

    # Success — clear the cleanup-on-failure trap.
    trap - EXIT

    log_info "── VM '$name' provisioned (not started; run:  $LAB_PROG start $name) ──"
    log_info "ssh access after boot:  ssh -p $ssh_port lab@127.0.0.1   (default password 'lab')"
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
}

# ─── Subcommand: console ───────────────────────────────────────────────────
cmd_console() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG console <name>"
    vm_exists "$name" || die "no VM named '$name'"
    vm_running "$name" || die "$name is not running"
    require_cmd socat
    log_info "attaching to serial console (Ctrl-] to detach)"
    socat -,raw,echo=0,escape=0x1d "UNIX-CONNECT:$(vm_serial "$name")"
}

# ─── Subcommand: ssh ───────────────────────────────────────────────────────
cmd_ssh() {
    local name="${POS_ARGS[0]:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG ssh <name> [-- cmd args...]"
    vm_exists "$name" || die "no VM named '$name'"
    vm_running "$name" || die "$name is not running (try '$LAB_PROG start $name')"
    local port; port="$(read_manifest_field "$name" ssh_port)"
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        # ssh concatenates argv with spaces and re-parses on the remote side,
        # which destroys the local shell's quoting (e.g. `grep -E '^(a|b)='`
        # arrives unquoted and bash chokes on the parens).  Shell-quote each
        # arg with printf %q so the remote shell sees the original words.
        local remote_cmd
        remote_cmd="$(printf '%q ' "${EXTRA_ARGS[@]}")"
        ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            lab@127.0.0.1 "$remote_cmd"
    else
        ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            lab@127.0.0.1
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
