#!/usr/bin/env bash
# lab-chroot.sh — Phase 1 of LAB_CREATE_V2: chroot creation and management.
#
# Backends : debootstrap (Debian/Ubuntu/Kali) | dnf (Rocky) | host-copy
# Managers : none (bare chroot) | schroot | systemd-nspawn      (all optional)
# Arches   : x86_64 aarch64 armv7l ppc64le riscv64 s390x
# Foreign  : via qemu-user-static + binfmt_misc
# Config   : CLI flags  or  TOML file (--config FILE)
#
# Self-contained per the per-phase rule: any helpers this script needs are
# defined inline. Do not source files from sibling phases.

set -euo pipefail
shopt -s nullglob

readonly LAB_VERSION="0.1.0"
readonly LAB_PROG="${0##*/}"

# ─── State / cache locations ────────────────────────────────────────────────
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-/var/lib/lab-create}"
    readonly LAB_CACHE_DIR="/var/cache/lab-create"
else
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
    readonly LAB_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/lab-create"
fi
readonly LAB_CHROOT_STATE_DIR="${LAB_STATE_DIR}/chroots"

# ─── Logging ────────────────────────────────────────────────────────────────
LAB_LOG_LEVEL="${LAB_LOG_LEVEL:-info}"

_log() {
    local level="$1"; shift
    local prio
    case "$level" in
        debug) prio=0 ;;
        info)  prio=1 ;;
        warn)  prio=2 ;;
        error) prio=3 ;;
    esac
    local cur
    case "$LAB_LOG_LEVEL" in
        debug) cur=0 ;;
        info)  cur=1 ;;
        warn)  cur=2 ;;
        error) cur=3 ;;
        *)     cur=1 ;;
    esac
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
    # Parse with awk — consistent with the no-source rule applied to chroot
    # os-release files; /etc/os-release is root-owned and trusted but sourcing
    # it executes shell code (Finding 16).
    if [[ -r /etc/os-release ]]; then
        awk -F= '/^ID=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
            /etc/os-release
    else
        printf 'unknown'
    fi
}

detect_host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)            printf 'x86_64' ;;
        aarch64|arm64)           printf 'aarch64' ;;
        armv7l|armv7|armhf)      printf 'armv7l' ;;
        ppc64le|powerpc64le)     printf 'ppc64le' ;;
        riscv64)                 printf 'riscv64' ;;
        s390x)                   printf 's390x' ;;
        *)                       printf 'unknown' ;;
    esac
}

# arch_map CANONICAL COLUMN  →  prints mapped value, returns 1 if unmapped.
# Columns: debian | rpm | qemu-user | qemu-system | rocky_supported
arch_map() {
    local c="$1" col="$2"
    case "${c}:${col}" in
        x86_64:debian)            printf 'amd64'   ;;
        x86_64:rpm)               printf 'x86_64'  ;;
        x86_64:qemu-user)         printf 'x86_64'  ;;
        x86_64:qemu-system)       printf 'x86_64'  ;;
        x86_64:rocky_supported)   printf 'yes'     ;;

        aarch64:debian)           printf 'arm64'   ;;
        aarch64:rpm)              printf 'aarch64' ;;
        aarch64:qemu-user)        printf 'aarch64' ;;
        aarch64:qemu-system)      printf 'aarch64' ;;
        aarch64:rocky_supported)  printf 'yes'     ;;

        armv7l:debian)            printf 'armhf'   ;;
        armv7l:rpm)               printf 'armv7hl' ;;
        armv7l:qemu-user)         printf 'arm'     ;;
        armv7l:qemu-system)       printf 'arm'     ;;
        armv7l:rocky_supported)   printf 'no'      ;;

        ppc64le:debian)           printf 'ppc64el' ;;
        ppc64le:rpm)              printf 'ppc64le' ;;
        ppc64le:qemu-user)        printf 'ppc64le' ;;
        ppc64le:qemu-system)      printf 'ppc64'   ;;
        ppc64le:rocky_supported)  printf 'yes'     ;;

        riscv64:debian)           printf 'riscv64' ;;
        riscv64:rpm)              printf 'riscv64' ;;
        riscv64:qemu-user)        printf 'riscv64' ;;
        riscv64:qemu-system)      printf 'riscv64' ;;
        riscv64:rocky_supported)  printf 'yes'     ;;  # Rocky 10 / SIG

        s390x:debian)             printf 's390x'   ;;
        s390x:rpm)                printf 's390x'   ;;
        s390x:qemu-user)          printf 's390x'   ;;
        s390x:qemu-system)        printf 's390x'   ;;
        s390x:rocky_supported)    printf 'yes'     ;;

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
    # install_hint TOOL [pkg-overrides...]   pkg-overrides like  debian=foo  rpm=bar
    local tool="$1"; shift
    local host
    host="$(detect_host_distro)"
    local pkg="$tool"
    local arg
    for arg in "$@"; do
        case "$host:${arg%%=*}" in
            debian:debian|ubuntu:debian|kali:debian) pkg="${arg#*=}" ;;
            rocky:rpm|rhel:rpm|fedora:rpm|almalinux:rpm) pkg="${arg#*=}" ;;
        esac
    done
    case "$host" in
        debian|ubuntu|kali) printf 'sudo apt-get install -y %s' "$pkg" ;;
        rocky|rhel|fedora|almalinux) printf 'sudo dnf install -y %s' "$pkg" ;;
        *) printf '(install %q via your package manager)' "$pkg" ;;
    esac
}

require_cmd() {
    # require_cmd TOOL [pkg-overrides...]
    local tool="$1"; shift
    if ! have "$tool"; then
        die "$tool not found. Install with:  $(install_hint "$tool" "$@")"
    fi
}

# ─── TOML parser abstraction ────────────────────────────────────────────────
# Strategy: convert TOML → JSON once (any of tomlq | yq -p toml | dasel),
# then use jq for everything. jq is required either way (tomlq depends on it).

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
        die "no TOML parser found. Install one with:
        $(install_hint yq debian=yq rpm=yq)        # mikefarah/yq, supports -p toml
   or   $(install_hint python3-tomlkit debian=python3-tomlkit rpm=python3-tomlkit) and pipx install yq   # kislyuk/yq → tomlq
   or   install dasel from https://github.com/tomwright/dasel"
    fi
}

# ─── binfmt_misc helpers ────────────────────────────────────────────────────
binfmt_registered() {
    # binfmt_registered QEMU_USER_NAME   (e.g. "aarch64", "ppc64le")
    local q="$1"
    [[ -e "/proc/sys/fs/binfmt_misc/qemu-${q}" ]] && \
        grep -q '^enabled' "/proc/sys/fs/binfmt_misc/qemu-${q}" 2>/dev/null
}

ensure_binfmt() {
    local q="$1"
    if binfmt_registered "$q"; then
        log_debug "binfmt qemu-${q} already registered"
        return 0
    fi
    log_info "registering binfmt for qemu-${q}"
    if have update-binfmts; then
        update-binfmts --enable "qemu-${q}" \
            || die "update-binfmts --enable qemu-${q} failed.  Check that the qemu-user-static package is installed."
    elif have systemctl && systemctl list-unit-files | grep -q '^systemd-binfmt'; then
        systemctl restart systemd-binfmt.service \
            || die "systemd-binfmt restart failed"
    else
        die "no binfmt registration tool found (need binfmt-support's update-binfmts or systemd-binfmt)"
    fi
    binfmt_registered "$q" || die "qemu-${q} still not registered after enable attempt"
}

qemu_user_binary_for() {
    # Locate qemu-<arch>-static; static is what we copy into the chroot.
    local q="$1" path
    for path in "/usr/bin/qemu-${q}-static" "/usr/local/bin/qemu-${q}-static"; do
        [[ -x "$path" ]] && { printf '%s' "$path"; return 0; }
    done
    if path="$(command -v "qemu-${q}-static" 2>/dev/null)"; then
        printf '%s' "$path"; return 0
    fi
    return 1
}

# ─── State / manifest management ────────────────────────────────────────────
state_init() {
    mkdir -p "$LAB_CHROOT_STATE_DIR" "$LAB_CACHE_DIR"
}

manifest_path() {
    printf '%s/%s.toml' "$LAB_CHROOT_STATE_DIR" "$1"
}

write_manifest() {
    # write_manifest NAME TARGET BACKEND DISTRO SUITE ARCH MANAGER [LAB]
    # LAB is the optional cross-phase grouping name (from TOML [lab].name
    # or --lab on the CLI).  Stored in the manifest so `list --lab` and
    # Phase 6's topology view can correlate across phases.
    state_init
    local name="$1" target="$2" backend="$3" distro="$4" suite="$5" arch="$6" manager="$7"
    local lab="${8:-}"
    local mp; mp="$(manifest_path "$name")"
    local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Escape embedded double-quotes in free-text fields (target path, lab name)
    # so the heredoc always produces valid TOML (Finding 13).  The enum-validated
    # fields (backend/distro/suite/arch/manager) and name (regex-validated) cannot
    # contain quotes so they need no escaping here.
    local etarget="${target//\"/\\\"}"
    local elab="${lab//\"/\\\"}"
    cat > "$mp" <<EOF
# lab-chroot manifest — do not edit by hand
name       = "${name}"
target     = "${etarget}"
backend    = "${backend}"
distro     = "${distro}"
suite      = "${suite}"
arch       = "${arch}"
manager    = "${manager}"
lab        = "${elab}"
created_at = "${now}"
version    = "${LAB_VERSION}"
EOF
    log_debug "wrote manifest $mp"
}

read_manifest_field_at() {
    # read_manifest_field_at MANIFEST_PATH FIELD
    # Like read_manifest_field but takes an explicit manifest path, so read-only
    # callers (e.g. `list --system`) can read manifests from a registry other
    # than the active LAB_CHROOT_STATE_DIR without touching manifest_path().
    local mp="$1"
    [[ -r "$mp" ]] || return 1
    awk -v k="$2" '
        /^[[:space:]]*#/ { next }
        $1 == k { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$mp"
}

read_manifest_field() {
    # read_manifest_field NAME FIELD
    read_manifest_field_at "$(manifest_path "$1")" "$2"
}

remove_manifest() {
    rm -f "$(manifest_path "$1")"
}

list_manifests() {
    state_init
    local mp name
    for mp in "$LAB_CHROOT_STATE_DIR"/*.toml; do
        name="${mp##*/}"; name="${name%.toml}"
        printf '%s\n' "$name"
    done
}

# Append a `key = "value"` (quoted scalar) line to an existing manifest, for
# fields written after the base write_manifest (rootless flag + nspawn scalars).
append_manifest_field() {
    local name="$1" key="$2" value="$3"
    printf '%s = "%s"\n' "$key" "${value//\"/\\\"}" >> "$(manifest_path "$name")"
}

# Append a `key = <raw>` line (no surrounding quotes) — used for compact JSON
# arrays (nspawn bind_ro / capabilities).  A compact JSON array like
# ["/a","/b"] is itself valid TOML, and read_manifest_field returns it verbatim
# (it only strips a *surrounding* pair of quotes), so jq can parse it back.
append_manifest_raw() {
    local name="$1" key="$2" raw="$3"
    printf '%s = %s\n' "$key" "$raw" >> "$(manifest_path "$name")"
}

# ─── Rootless (fakechroot + fakeroot) helpers ───────────────────────────────
# ROOTLESS (global, "1" or "") gates the rootless code paths.  CREATE sets it
# from OPT_ROOTLESS; ENTER/DESTROY set it from the chroot's manifest `rootless`
# field.  The pattern follows muxup.com: debootstrap --variant=fakechroot built
# and entered under `fakechroot fakeroot`, so no real uid 0 and no mounts.
#
# Security boundary (Finding 18): fakechroot is a CONVENIENCE wrapper, not a
# security sandbox.  It works via LD_PRELOAD, which has well-known escape vectors:
#   - statically-linked binaries bypass LD_PRELOAD entirely
#   - direct syscalls (syscall(2), inline asm) bypass LD_PRELOAD
#   - /proc/self/root still resolves to the real host root
#   - openat(AT_FDCWD, ...) and execveat escapes
# A process that escapes the fakechroot jail runs with the INVOKING USER's
# privileges — not root — so there is no privilege escalation.  The rootless
# mode is safe in the sense that a break-out can't do more than the user already
# could; it is NOT safe in the sense that the chroot boundary is reliable.
# Do not use --rootless to sandbox untrusted code.
require_rootless_deps() {
    require_cmd fakechroot fakeroot
}

# Run a command inside the chroot — wrapped in fakechroot+fakeroot when ROOTLESS,
# a plain chroot otherwise (byte-identical to the previous behavior when not
# rootless).  Used by every `chroot "$target" …` call site.
chroot_exec() {
    local target="$1"; shift
    if [[ -n "${ROOTLESS:-}" ]]; then
        fakechroot fakeroot chroot "$target" "$@"
    else
        chroot "$target" "$@"
    fi
}

# ─── Spec construction (CLI args → JSON, or config file → JSON array) ──────
# A "spec" is a JSON object describing one chroot. The create flow takes a
# spec and runs it. CLI mode produces one spec; config-file mode may produce
# many. Using JSON internally keeps both code paths uniform.

spec_from_cli() {
    # All CLI variables are passed via the OPT_* globals set by parse_args.
    require_cmd jq
    local include_json='[]' binaries_json='[]' extras_json='[]' groups_json='[]'
    [[ -n "${OPT_INCLUDE:-}" ]]  && include_json=$(printf '%s\n' "$OPT_INCLUDE"  | tr ',' '\n' | jq -R . | jq -s .)
    [[ -n "${OPT_BINARIES:-}" ]] && binaries_json=$(printf '%s\n' "$OPT_BINARIES" | tr ',' '\n' | jq -R . | jq -s .)
    [[ -n "${OPT_EXTRAS:-}" ]]   && extras_json=$(printf '%s\n' "$OPT_EXTRAS"   | tr ',' '\n' | jq -R . | jq -s .)
    [[ -n "${OPT_GROUPS:-}" ]]   && groups_json=$(printf '%s\n' "$OPT_GROUPS"   | tr ',' '\n' | jq -R . | jq -s .)

    local post_commands_json='[]' users_json='[]'
    if [[ ${#OPT_POST_COMMANDS[@]} -gt 0 ]]; then
        post_commands_json=$(printf '%s\n' "${OPT_POST_COMMANDS[@]}" | jq -R . | jq -s .)
    fi
    if [[ ${#OPT_USERS[@]} -gt 0 ]]; then
        users_json=$(for u in "${OPT_USERS[@]}"; do
            IFS=: read -r uname upass <<< "$u"
            jq -n --arg n "$uname" --arg p "$upass" \
                '{name:$n, password:$p, groups:"", shell:"/bin/bash"}'
        done | jq -s .)
    fi

    jq -n \
        --arg name        "${OPT_NAME:-}" \
        --arg backend     "${OPT_BACKEND:-}" \
        --arg distro      "${OPT_DISTRO:-}" \
        --arg suite       "${OPT_SUITE:-}" \
        --arg arch        "${OPT_ARCH:-}" \
        --arg target      "${OPT_TARGET:-}" \
        --arg mirror      "${OPT_MIRROR:-}" \
        --arg variant     "${OPT_VARIANT:-}" \
        --arg manager     "${OPT_MANAGER:-none}" \
        --arg lab         "${OPT_LAB:-}" \
        --arg hostname    "${OPT_HOSTNAME:-}" \
        --arg init_script "${OPT_INIT_SCRIPT:-}" \
        --argjson include       "$include_json" \
        --argjson binaries      "$binaries_json" \
        --argjson extras        "$extras_json" \
        --argjson groups        "$groups_json" \
        --argjson post_commands "$post_commands_json" \
        --argjson users         "$users_json" \
        '{name:$name, backend:$backend, distro:$distro, suite:$suite, arch:$arch,
          target:$target, mirror:$mirror, variant:$variant, manager:$manager, lab:$lab,
          hostname:$hostname, init_script:$init_script,
          include:$include, binaries:$binaries, extras:$extras, groups:$groups,
          post_commands:$post_commands, users:$users, write_files:[]}'
}

specs_from_config() {
    # Emits one JSON object per line (NDJSON).
    local file="$1"
    require_cmd jq
    local json
    json="$(toml_to_json "$file")"
    # Accept either a top-level [[chroot]] array or a single inline table.
    # Propagate top-level [lab].name into each spec so unified lab.toml
    # files (that also carry [[vm]] / [[service]] for other phases) work
    # out-of-the-box.  --lab on the CLI overrides if both are present.
    printf '%s' "$json" | jq -c --arg cli_lab "${OPT_LAB:-}" '
        . as $root
        | if .chroot? then
            (.chroot | if type=="array" then .[] else . end)
          else . end
        | { name:    (.name    // ""),
            backend: (.backend // ""),
            distro:  (.distro  // ""),
            suite:   (.suite   // ""),
            arch:    (.arch    // ""),
            target:  (.target  // ""),
            mirror:  (.mirror  // ""),
            variant: (.variant // ""),
            manager: (.manager // "none"),
            lab:     ( if $cli_lab != "" then $cli_lab
                       else ($root.lab.name // "") end ),
            include:     (.include     // []),
            binaries:    (.binaries    // []),
            extras:      (.extras      // []),
            groups:      (.groups      // []),
            hostname:      (.hostname      // ""),
            init_script:   (.init_script   // ""),
            post_commands: (.post_commands // []),
            users:         (.users         // []),
            schroot:       (.schroot       // {}),
            write_files:   (.write_files   // []),
            nspawn:        (.nspawn        // {}) }
    '
}

spec_get() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }
spec_get_arr() { jq -r --arg k "$2" '.[$k][]?' <<<"$1"; }
spec_get_obj() { jq -c --arg k "$2" '.[$k] // {}' <<<"$1"; }

# ─── Validation ─────────────────────────────────────────────────────────────
validate_spec() {
    local spec="$1"
    local name backend distro arch target manager
    name="$(spec_get "$spec" name)"
    backend="$(spec_get "$spec" backend)"
    distro="$(spec_get "$spec" distro)"
    arch="$(spec_get "$spec" arch)"
    target="$(spec_get "$spec" target)"
    manager="$(spec_get "$spec" manager)"

    [[ -n "$name"    ]] || die "spec missing required field: name"
    # Reject names that could traverse paths in manifest_path(), schroot_conf_path(),
    # or nspawn_machines_link() — all of which embed $name directly in file paths.
    [[ "$name" =~ ^[a-zA-Z0-9_.-]+$ ]] \
        || die "spec: name must match [a-zA-Z0-9_.-]+ (no slashes or special chars) — got: $name"
    [[ "$name" != .* ]] || die "spec: name must not start with a dot — got: $name"
    [[ -n "$backend" ]] || die "spec ($name) missing required field: backend"
    [[ -n "$target"  ]] || die "spec ($name) missing required field: target"

    case "$backend" in
        debootstrap)
            [[ -n "$distro" ]] || die "spec ($name) backend=debootstrap requires distro"
            case "$distro" in debian|ubuntu|kali) ;;
                *) die "spec ($name) distro=$distro is not a debootstrap distro (use debian|ubuntu|kali)" ;;
            esac
            [[ -n "$(spec_get "$spec" suite)" ]] || die "spec ($name) backend=debootstrap requires suite"
            [[ -n "$arch" ]] || die "spec ($name) backend=debootstrap requires arch"
            is_known_arch "$arch" || die "spec ($name) unknown arch: $arch"
            ;;
        dnf|yum)
            [[ "$distro" == "rocky" ]] || die "spec ($name) backend=dnf currently supports distro=rocky only"
            [[ -n "$(spec_get "$spec" suite)" ]] || die "spec ($name) backend=dnf requires suite (e.g. \"9\")"
            # Validate suite is a bare version number so it cannot inject newlines
            # into the repo file built by dnf_bootstrap_repo() (Finding 5).
            local _suite; _suite="$(spec_get "$spec" suite)"
            [[ "$_suite" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
                || die "spec ($name) backend=dnf suite must be a version number like '9' or '9.3' (got: $_suite)"
            [[ -n "$arch" ]] || die "spec ($name) backend=dnf requires arch"
            is_known_arch "$arch" || die "spec ($name) unknown arch: $arch"
            [[ "$(arch_map "$arch" rocky_supported)" == "yes" ]] \
                || die "spec ($name) Rocky Linux does not publish builds for arch=$arch.  Aborting before producing a broken tree."
            ;;
        host-copy)
            [[ -n "$(jq -r '.binaries[]?' <<<"$spec")" ]] \
                || die "spec ($name) backend=host-copy requires binaries"
            [[ -z "$arch" || "$arch" == "$(detect_host_arch)" ]] \
                || die "spec ($name) backend=host-copy can only produce host-arch chroots ($(detect_host_arch))"
            ;;
        *) die "spec ($name) unknown backend: $backend" ;;
    esac

    case "$manager" in
        none|schroot|nspawn) ;;
        *) die "spec ($name) unknown manager: $manager (use none|schroot|nspawn)" ;;
    esac
}

# ─── Backend: debootstrap ───────────────────────────────────────────────────
debootstrap_default_mirror() {
    local distro="$1" arch="$2"
    case "$distro" in
        debian) printf 'http://deb.debian.org/debian' ;;
        ubuntu)
            if [[ "$arch" == "x86_64" ]]; then
                printf 'http://archive.ubuntu.com/ubuntu'
            else
                printf 'http://ports.ubuntu.com/ubuntu-ports'
            fi
            ;;
        kali) printf 'http://http.kali.org/kali' ;;
    esac
}

debootstrap_keyring_for() {
    local distro="$1" path
    case "$distro" in
        debian) path=/usr/share/keyrings/debian-archive-keyring.gpg ;;
        ubuntu) path=/usr/share/keyrings/ubuntu-archive-keyring.gpg ;;
        kali)   path=/usr/share/keyrings/kali-archive-keyring.gpg ;;
    esac
    if [[ ! -r "$path" ]]; then
        case "$distro" in
            debian) die "missing $path.  Install with:  $(install_hint debian-archive-keyring)" ;;
            ubuntu) die "missing $path.  Install with:  $(install_hint ubuntu-keyring debian=ubuntu-keyring rpm=ubuntu-keyring)" ;;
            kali)   die "missing $path.  The kali-archive-keyring package must be present on the host (we will not embed or download the key).  See https://www.kali.org/docs/general-use/kali-linux-faq/" ;;
        esac
    fi
    printf '%s' "$path"
}

backend_debootstrap_create() {
    local spec="$1"
    require_cmd debootstrap

    local name suite arch target distro mirror variant
    name="$(spec_get "$spec" name)"
    suite="$(spec_get "$spec" suite)"
    arch="$(spec_get "$spec" arch)"
    target="$(spec_get "$spec" target)"
    distro="$(spec_get "$spec" distro)"
    mirror="$(spec_get "$spec" mirror)"
    variant="$(spec_get "$spec" variant)"
    [[ -n "$mirror"  ]] || mirror="$(debootstrap_default_mirror "$distro" "$arch")"
    # Rootless debootstrap uses the fakechroot variant (the muxup.com pattern):
    # it avoids every operation that needs real uid 0 (mknod, chroot, chown).
    [[ -n "${ROOTLESS:-}" ]] && variant=fakechroot

    local debian_arch qemu_user host_arch
    debian_arch="$(arch_map "$arch" debian)" || die "no debian-arch mapping for $arch"
    qemu_user="$(arch_map "$arch" qemu-user)"
    host_arch="$(detect_host_arch)"

    local keyring
    keyring="$(debootstrap_keyring_for "$distro")"

    local include
    include="$(jq -r '.include | join(",")' <<<"$spec")"

    local -a deboot_args=(--arch="$debian_arch" --keyring="$keyring")
    [[ -n "$variant" ]] && deboot_args+=(--variant="$variant")
    [[ -n "$include" ]] && deboot_args+=(--include="$include")
    # --keep-cache: reuse a persistent .deb download cache across builds.
    if [[ -n "${OPT_KEEP_CACHE:-}" ]]; then
        local dcache="$LAB_CACHE_DIR/debootstrap"; mkdir -p "$dcache"
        deboot_args+=(--cache-dir="$dcache")
        log_info "keep-cache: debootstrap --cache-dir=$dcache"
    fi

    if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
        die "$target already exists and is not empty"
    fi
    mkdir -p "$target"

    if [[ "$arch" == "$host_arch" ]]; then
        log_info "debootstrap (native): $distro/$suite arch=$arch → $target"
        if [[ -n "${ROOTLESS:-}" ]]; then
            fakechroot fakeroot debootstrap "${deboot_args[@]}" "$suite" "$target" "$mirror"
        else
            debootstrap "${deboot_args[@]}" "$suite" "$target" "$mirror"
        fi
    else
        log_info "debootstrap (foreign first stage): $distro/$suite arch=$arch → $target"
        ensure_binfmt "$qemu_user"
        local qemu_bin
        qemu_bin="$(qemu_user_binary_for "$qemu_user")" \
            || die "qemu-${qemu_user}-static not found.  Install with:  $(install_hint qemu-user-static debian=qemu-user-static rpm=qemu-user-static)"
        debootstrap --foreign "${deboot_args[@]}" "$suite" "$target" "$mirror"
        log_debug "copying qemu-${qemu_user}-static into chroot"
        install -D -m 0755 "$qemu_bin" "${target}/usr/bin/qemu-${qemu_user}-static"
        log_info "debootstrap (foreign second stage)"
        chroot_exec "$target" /debootstrap/debootstrap --second-stage
    fi

    # Useful defaults a freshly-bootstrapped chroot doesn't get otherwise.
    install -D -m 0644 /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true
    log_info "debootstrap complete: $name → $target"
}

# ─── Backend: dnf (Rocky) ───────────────────────────────────────────────────
dnf_bootstrap_repo() {
    # Emit a temporary repo file with Rocky's BaseOS + AppStream for the given
    # release. Stdout = path to a tempfile the caller is responsible for cleaning.
    #
    # Trust model (Finding 17): the gpgkey URL is fetched by DNF over HTTPS and
    # imported on first use — Trust-On-First-Use (TOFU).  Packages are then
    # verified against that key (gpgcheck=1), so the only attack window is the
    # key download itself.  The HTTPS transport (Cloudflare CDN) provides strong
    # practical protection; a successful attack would require compromising Rocky's
    # CDN origin or a BGP prefix hijack (detectable, nation-state level).  This is
    # the same model used by virtually every RPM-based bootstrap script.  For a
    # higher-assurance environment, pre-import the key with a known fingerprint and
    # set gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-<ver> instead.
    local releasever="$1" arch_rpm="$2"
    local f; f="$(mktemp --suffix=.repo)"
    cat > "$f" <<EOF
[lab-baseos]
name=Rocky Linux \$releasever - BaseOS (lab-chroot bootstrap)
baseurl=https://download.rockylinux.org/pub/rocky/${releasever}/BaseOS/${arch_rpm}/os/
enabled=1
gpgcheck=1
gpgkey=https://download.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-${releasever}

[lab-appstream]
name=Rocky Linux \$releasever - AppStream (lab-chroot bootstrap)
baseurl=https://download.rockylinux.org/pub/rocky/${releasever}/AppStream/${arch_rpm}/os/
enabled=1
gpgcheck=1
gpgkey=https://download.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-${releasever}
EOF
    printf '%s' "$f"
}

backend_dnf_create() {
    local spec="$1"
    local pm
    if   have dnf; then pm=dnf
    elif have yum; then pm=yum
    else die "neither dnf nor yum present.  Install dnf with:  $(install_hint dnf debian=dnf rpm=dnf)"
    fi

    # dnf shells out to `rpmkeys` (from the `rpm` package) to verify GPG
    # signatures on every downloaded package.  On Debian/Ubuntu hosts the
    # default `dnf` install pulls `rpm-common` (config + man pages) but NOT
    # the full `rpm` binary, so dnf gets as far as downloading every RPM
    # and then fails at "GPG check FAILED" with a wall of "Cannot find
    # rpmkeys executable to verify signatures." messages.  Catch that here
    # rather than letting the user wait for the download to complete.
    have rpmkeys || die "rpmkeys not found (provided by the 'rpm' package); install with:  $(install_hint rpm debian=rpm ubuntu=rpm)
  Required because dnf invokes rpmkeys to verify package signatures.
  Without it, dnf will download everything successfully and then fail
  with 'Cannot find rpmkeys executable to verify signatures.'"

    local name suite arch target host_arch
    name="$(spec_get "$spec" name)"
    suite="$(spec_get "$spec" suite)"
    arch="$(spec_get "$spec" arch)"
    target="$(spec_get "$spec" target)"
    host_arch="$(detect_host_arch)"

    local arch_rpm
    arch_rpm="$(arch_map "$arch" rpm)" || die "no rpm-arch mapping for $arch"

    if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
        die "$target already exists and is not empty"
    fi
    mkdir -p "$target"

    # Note: do NOT use a RETURN trap here — bash RETURN traps are global, fire
    # for every later function return, and reference now-out-of-scope locals
    # (manifests as "$var: unbound variable" much later).  Use an EXIT trap
    # scoped to this function instead: set it after mktemp, clear it on normal
    # exit (Finding 6: repo file not cleaned up on error paths).
    local repo_file
    repo_file="$(dnf_bootstrap_repo "$suite" "$arch_rpm")"
    trap 'rm -f "$repo_file"' EXIT

    # Default seed: distro identity packages plus the `rpm` and `dnf` CLIs.
    # Without `rpm`, `rpm-libs` is still pulled in transitively (gives you
    # /usr/lib/rpm) but the `rpm` binary itself is missing — surprising for
    # an RPM-based tree.  Without `dnf`, you can't install anything more from
    # inside the chroot at all (only /etc/dnf, /var/lib/dnf, /var/cache/dnf
    # exist, populated as side effects of the host's dnf --installroot run).
    # Both are small and make the chroot self-introspectable and self-extensible
    # out of the box.
    local -a packages=(rocky-release rocky-repos rocky-gpg-keys rpm dnf)
    local extra
    while IFS= read -r extra; do
        [[ -n "$extra" ]] && packages+=("$extra")
    done < <(jq -r '.include[]?' <<<"$spec")

    local -a groups=()
    while IFS= read -r grp; do
        [[ -n "$grp" ]] && groups+=("$grp")
    done < <(jq -r '.groups[]?' <<<"$spec")

    local -a forcearch=()
    if [[ "$arch" != "$host_arch" ]]; then
        log_warn "dnf foreign-arch is experimental; install scriptlets may fail under qemu-user-static"
        local qemu_user; qemu_user="$(arch_map "$arch" qemu-user)"
        ensure_binfmt "$qemu_user"
        forcearch=(--forcearch="$arch_rpm")
        # Place qemu binary so post-install scripts can run.
        local qemu_bin
        qemu_bin="$(qemu_user_binary_for "$qemu_user")" \
            || die "qemu-${qemu_user}-static not found"
        install -D -m 0755 "$qemu_bin" "${target}/usr/bin/qemu-${qemu_user}-static"
    fi

    # Pre-create the rpmdb path layout that EL9 expects, so the host's dnf
    # writes the database where the chroot's rpm will read it.
    #
    # Background: EL9 uses `_dbpath = /usr/lib/sysimage/rpm`, with
    # `/var/lib/rpm` as a compat *symlink* to it.  Debian/Ubuntu's rpm uses
    # `_dbpath = /var/lib/rpm` as a real directory.  When we run the host's
    # dnf with --installroot, it writes the rpmdb at *its* `_dbpath`
    # (`/var/lib/rpm`) as a real directory inside the tree.  The chroot's
    # rpm then queries `/usr/lib/sysimage/rpm` (or follows the symlink it
    # expects to find at `/var/lib/rpm` and gets a different result),
    # finds nothing, and reports every package as "not installed" — even
    # though the files are on disk.
    #
    # By pre-creating /usr/lib/sysimage/rpm and symlinking /var/lib/rpm to
    # it, the host's writes land at EL9's expected location from the
    # outset.  Combined with the `rpm --rebuilddb` from inside the chroot
    # later, this makes both `rpm -qa` and `dnf install` see the full
    # package set without any reinstall step.
    mkdir -p "${target}/usr/lib/sysimage/rpm" "${target}/var/lib"
    ln -sfn ../../usr/lib/sysimage/rpm "${target}/var/lib/rpm"

    # --keep-cache: persist downloaded rpms in a shared cache (outside the
    # installroot, so it survives the build and stays out of the chroot tree).
    local -a cacheopt=()
    if [[ -n "${OPT_KEEP_CACHE:-}" ]]; then
        local dcache="$LAB_CACHE_DIR/dnf"; mkdir -p "$dcache"
        cacheopt=(--setopt=cachedir="$dcache" --setopt=keepcache=1)
        log_info "keep-cache: dnf cachedir=$dcache (keepcache=1)"
    fi

    log_info "$pm install ($suite/$arch_rpm) → $target"
    "$pm" --setopt=reposdir= -c "$repo_file" \
          --installroot="$target" --releasever="$suite" \
          "${forcearch[@]}" "${cacheopt[@]}" \
          --assumeyes install "${packages[@]}"

    if (( ${#groups[@]} > 0 )); then
        log_info "$pm groupinstall: ${groups[*]}"
        "$pm" --setopt=reposdir= -c "$repo_file" \
              --installroot="$target" --releasever="$suite" \
              "${forcearch[@]}" "${cacheopt[@]}" \
              --assumeyes groupinstall "${groups[@]}"
    fi

    install -D -m 0644 /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true
    rm -f "$repo_file"
    trap - EXIT   # repo_file cleaned up; clear the EXIT trap

    # Rebuild the rpmdb from inside the chroot so it lives at the chroot's
    # own `_dbpath` (EL9: /usr/lib/sysimage/rpm; with /var/lib/rpm as a
    # compat symlink) and in the chroot's own rpm backend (sqlite on EL9).
    # The host's dnf wrote the db using *its* macros — typically Debian's
    # `_dbpath = /var/lib/rpm`, which leaves the chroot's `rpm -q` querying
    # an empty location.  After --rebuilddb the chroot is queryable
    # ("rpm -qa") and self-extensible ("dnf install ...") from inside.
    # Foreign-arch trees have qemu-<arch>-static placed above, so chroot()
    # works there too.
    if [[ -x "${target}/usr/bin/rpm" || -x "${target}/bin/rpm" ]]; then
        log_info "rebuilding rpmdb inside chroot (host vs chroot _dbpath/backend reconciliation)"
        chroot "$target" /usr/bin/rpm --rebuilddb 2>/dev/null \
            || chroot "$target" /bin/rpm --rebuilddb 2>/dev/null \
            || log_warn "rpm --rebuilddb inside chroot failed; rpm -q may not see installed packages"
    fi

    log_info "dnf complete: $name → $target"
}

# ─── Backend: host-copy ─────────────────────────────────────────────────────
# Walk ldd output for each requested binary, copy binary + libraries +
# dynamic loader into the target preserving paths.
host_copy_resolve_libs() {
    # Prints one absolute path per line: the binary + every lib it needs +
    # the dynamic loader. Skips linux-vdso (kernel-provided, virtual).
    #
    # Important: ldd exits non-zero on statically-linked binaries (prints
    # "not a dynamic executable" and returns 1).  For us that's not an
    # error — a static binary just needs zero libs copied — but with
    # `set -o pipefail` a non-zero ldd would kill the enclosing command
    # substitution and (via `set -e`) exit the script silently.  Swallow
    # ldd's exit status explicitly; awk's exit status still propagates.
    local bin="$1"
    [[ -x "$bin" ]] || die "binary not executable: $bin"
    printf '%s\n' "$bin"
    { ldd "$bin" 2>/dev/null || true; } | awk '
        /linux-vdso/  { next }
        /not a dynamic/ { next }
        /statically linked/ { next }
        $2 == "=>" && $3 ~ /^\// { print $3; next }
        $1 ~ /^\//                { print $1; next }
    '
}

backend_host_copy_create() {
    local spec="$1"
    require_cmd ldd

    local name target
    name="$(spec_get "$spec" name)"
    target="$(spec_get "$spec" target)"

    if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
        die "$target already exists and is not empty"
    fi
    mkdir -p "$target"

    local -a binaries=() extras=()
    local b
    while IFS= read -r b; do [[ -n "$b" ]] && binaries+=("$b"); done < <(jq -r '.binaries[]?' <<<"$spec")
    while IFS= read -r b; do [[ -n "$b" ]] && extras+=("$b");   done < <(jq -r '.extras[]?'   <<<"$spec")

    (( ${#binaries[@]} > 0 )) || die "host-copy: no binaries listed"

    log_info "host-copy: resolving deps for ${#binaries[@]} binaries"
    local all
    all="$(
        for b in "${binaries[@]}"; do host_copy_resolve_libs "$b"; done | sort -u
    )"

    local count=0
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        log_debug "  cp $path"
        # cp --parents preserves the leading directory tree under target
        cp --parents -L --preserve=mode,timestamps "$path" "$target/"
        count=$((count + 1))
    done <<<"$all"
    log_info "host-copy: copied $count files (binaries + libs + loader)"

    for ex in "${extras[@]}"; do
        if [[ -e "$ex" ]]; then
            log_debug "  cp extra $ex"
            cp --parents -L --preserve=mode,timestamps "$ex" "$target/"
        else
            log_warn "extra not found: $ex"
        fi
    done

    # Standard skeleton.  /usr is listed explicitly because systemd-nspawn
    # checks for it as its "does this look like an OS tree?" heuristic and
    # refuses to spawn the container if it's missing, even when nspawn is
    # only being used as a non-booting namespace wrapper.  An empty /usr
    # satisfies the check.
    mkdir -p "$target"/{proc,sys,dev,tmp,run,etc,usr,usr/bin,usr/lib}
    chmod 1777 "$target/tmp"

    # If busybox was copied and there's no shell yet, give the tree a
    # /bin/sh symlinking to busybox.  Most chroot managers (schroot's setup
    # hooks, systemd-nspawn's spawn helpers) expect /bin/sh to exist; busybox
    # provides an `sh` applet so this is a free win for the busybox case.
    # For non-busybox host-copy chroots, the user should add `/bin/sh` (or
    # equivalent) to --binaries explicitly.
    if [[ ! -e "$target/bin/sh" ]]; then
        local bb=""
        for cand in "$target/bin/busybox" "$target/usr/bin/busybox"; do
            [[ -x "$cand" ]] && { bb="${cand#$target}"; break; }
        done
        if [[ -n "$bb" ]]; then
            log_info "creating /bin/sh → ${bb} (busybox sh applet) for manager compatibility"
            ln -s "$bb" "$target/bin/sh"
        fi
    fi

    log_info "host-copy complete: $name → $target"
}

# ─── Manager: none (bare chroot) ────────────────────────────────────────────
mounts_record() { printf '%s\n' "$1" >> "${2}/.lab-chroot-mounts"; }

bind_essentials() {
    # Bind-mount /proc /sys /dev /dev/pts /run into the chroot, recording
    # everything in <target>/.lab-chroot-mounts so destroy can reverse it.
    local target="$1"

    # Finding 10: remove any symlink before truncating so an attacker-planted
    # symlink (e.g. .lab-chroot-mounts -> /etc/fstab) does not truncate a host
    # file when this runs as root.
    [[ -L "${target}/.lab-chroot-mounts" ]] && rm -f "${target}/.lab-chroot-mounts"
    : > "${target}/.lab-chroot-mounts"

    # Finding 8: set the EXIT trap HERE, before the first mount, so that any
    # mid-loop mount failure leaves a cleanup handler in place.  Previously the
    # trap was set by callers *after* bind_essentials returned, leaving a window
    # where a failed mount had no cleanup path.
    # Double-quote the trap string so $target expands NOW (its literal path is
    # embedded); at trap-fire time this is out-of-scope and `set -u` would fail.
    trap "unbind_essentials '$target'" EXIT

    local m src
    for m in proc sys dev dev/pts run; do
        src="/$m"
        mkdir -p "${target}/${m}"
        case "$m" in
            proc)    mount -t proc  proc "${target}/${m}" ;;
            sys)     mount -t sysfs sys  "${target}/${m}" ;;
            dev)     mount --bind   "$src" "${target}/${m}" ;;
            dev/pts) mount --bind   "$src" "${target}/${m}" ;;
            run)     mount -t tmpfs tmpfs "${target}/${m}" ;;
        esac
        mounts_record "${target}/${m}" "$target"
    done
}

unbind_essentials() {
    local target="$1"
    local f="${target}/.lab-chroot-mounts"
    [[ -r "$f" ]] || return 0
    # Reverse order, ignore failures (already unmounted is fine).
    tac "$f" | while IFS= read -r mp; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -l "$mp" || log_warn "umount failed: $mp"
        fi
    done
    rm -f "$f"
}

manager_none_register() {
    : # Nothing to do — the bare-chroot tree IS the manager-independent state.
}

manager_none_enter() {
    local target="$1"; shift
    # Rootless: enter under fakechroot+fakeroot, no root and no bind-mounts.
    if [[ -n "${ROOTLESS:-}" ]]; then
        require_rootless_deps
        local rc=0
        if (( $# > 0 )); then
            fakechroot fakeroot chroot "$target" "$@" || rc=$?
        else
            fakechroot fakeroot chroot "$target" /bin/bash -l || true
        fi
        return "$rc"
    fi
    [[ $EUID -eq 0 ]] || die "entering a chroot requires root (or recreate it with --rootless)"
    bind_essentials "$target"
    # EXIT trap is now set inside bind_essentials (before the first mount).
    local rc=0
    if (( $# > 0 )); then
        chroot "$target" "$@" || rc=$?
    else
        chroot "$target" /bin/bash -l || true
    fi
    # Clean up explicitly on the success path and clear the now-stale trap so
    # it doesn't fire spuriously at script exit.
    unbind_essentials "$target"
    trap - EXIT
    return "$rc"
}

# _safe_rm_rf PATH — sanity-check PATH before rm -rf (Finding 14).
# Protects against operator-tampered manifests or empty/short target fields
# that could wipe the wrong directory.
_safe_rm_rf() {
    local path="$1"
    [[ -n "$path" ]]   || die "destroy: target path is empty — refusing rm -rf"
    [[ "$path" == /* ]] || die "destroy: target path is not absolute: $path"
    [[ "$path" != "/" ]] || die "destroy: refusing rm -rf /"
    # Require at least 3 path components: /a/b is too short to be a real chroot.
    local depth; depth="$(awk -F/ '{print NF-1}' <<<"$path")"
    [[ "$depth" -ge 2 ]] \
        || die "destroy: target path '$path' is too shallow to be a chroot (at least /a/b required)"
    rm -rf -- "$path"
}

manager_none_destroy() {
    local target="$1"
    unbind_essentials "$target"
    _safe_rm_rf "$target"
}

# ─── Manager: schroot ───────────────────────────────────────────────────────
schroot_conf_path() { printf '/etc/schroot/chroot.d/%s.conf' "$1"; }

manager_schroot_register() {
    local spec="$1"
    require_cmd schroot
    local name target conf
    name="$(spec_get "$spec" name)"
    target="$(spec_get "$spec" target)"
    conf="$(schroot_conf_path "$name")"

    local stype; stype="$(jq -r '.schroot.type    // "directory"'  <<<"$spec")"
    local sgrps; sgrps="$(jq -r '.schroot.groups | (.//[]) | join(",")' <<<"$spec")"
    local susrs; susrs="$(jq -r '.schroot.users  | (.//[]) | join(",")' <<<"$spec")"
    # Strip newlines from schroot fields — a newline would inject extra stanzas
    # into /etc/schroot/chroot.d/<name>.conf, potentially granting unintended
    # users access to the chroot (Finding 4).
    stype="${stype//$'\n'/}"
    sgrps="${sgrps//$'\n'/}"
    susrs="${susrs//$'\n'/}"
    # schroot type must be a known value; reject anything else.
    case "$stype" in directory|file|loopback|block|btrfs) ;;
        *) die "schroot.type must be directory|file|loopback|block|btrfs (got: $stype)" ;;
    esac

    log_info "schroot: writing $conf"
    {
        printf '[%s]\n' "$name"
        printf 'type=%s\n' "$stype"
        printf 'directory=%s\n' "$target"
        [[ -n "$sgrps" ]] && printf 'groups=%s\n' "$sgrps"
        [[ -n "$susrs" ]] && printf 'users=%s\n' "$susrs"
        printf 'profile=default\n'
    } > "$conf"
}

manager_schroot_enter() {
    local name="$1"; shift
    require_cmd schroot
    # schroot defaults to chdir'ing into the host's current working directory
    # inside the chroot, which usually doesn't exist there and aborts with a
    # confusing "Failed to change to directory ..." error. Default to / and
    # let the user override by passing --directory|-d themselves (they end
    # up in EXTRA_ARGS, so the explicit --directory in `args` wins only if
    # we put it first — which is intentional, schroot accepts later args
    # overriding earlier ones for the same key, but we keep it simple by
    # defaulting and letting the user know via docs).
    local -a args=(-c "$name" --directory /)
    if (( $# > 0 )); then
        schroot "${args[@]}" -- "$@"
    else
        schroot "${args[@]}"
    fi
}

manager_schroot_destroy() {
    local name="$1" target="$2"
    rm -f "$(schroot_conf_path "$name")"
    _safe_rm_rf "$target"
}

# ─── Manager: systemd-nspawn ────────────────────────────────────────────────
nspawn_machines_link() { printf '/var/lib/machines/%s' "$1"; }

manager_nspawn_register() {
    local spec="$1"
    require_cmd systemd-nspawn
    local name target backend register
    name="$(spec_get "$spec"   name)"
    target="$(spec_get "$spec" target)"
    backend="$(spec_get "$spec" backend)"
    register="$(jq -r '.nspawn.register // true' <<<"$spec")"
    local boot; boot="$(jq -r '.nspawn.boot // false' <<<"$spec")"

    if [[ "$boot" == "true" && "$backend" == "host-copy" ]]; then
        die "nspawn boot=true is not valid for backend=host-copy (no init system in tree)"
    fi

    if [[ "$register" == "true" ]]; then
        local link; link="$(nspawn_machines_link "$name")"
        if [[ -e "$link" || -L "$link" ]]; then
            log_warn "machinectl image already exists at $link — leaving as-is"
        else
            mkdir -p /var/lib/machines
            ln -s "$target" "$link"
            log_info "nspawn: registered as machinectl image: $link → $target"
        fi
    fi
}

# Build the systemd-nspawn argv into the global NSPAWN_ARGS array from the
# create-time settings.  Pure (no nspawn invocation) so it's unit-testable
# without root.  Mapping:
#   network: ""/host → share the host net (no flag); veth → --network-veth;
#            none/private → --private-network; anything else → bridge name
#            (--network-bridge=NAME).
#   bind_ro / capabilities: compact JSON arrays (as stored in the manifest) →
#            one --bind-ro=PATH each; a single --capability=CAP1,CAP2,….
build_nspawn_args() {
    local target="$1" boot="$2" network="${3:-}" bind_ro_json="${4:-[]}" caps_json="${5:-[]}"
    NSPAWN_ARGS=(-D "$target")
    [[ "$boot" == "true" ]] && NSPAWN_ARGS+=(-b)
    case "$network" in
        ""|host)      : ;;
        veth)         NSPAWN_ARGS+=(--network-veth) ;;
        none|private) NSPAWN_ARGS+=(--private-network) ;;
        *)            NSPAWN_ARGS+=(--network-bridge="$network") ;;
    esac
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && NSPAWN_ARGS+=(--bind-ro="$p")
    done < <(jq -r '.[]?' <<<"$bind_ro_json" 2>/dev/null)
    local caps
    caps="$(jq -r 'if length>0 then join(",") else empty end' <<<"$caps_json" 2>/dev/null)"
    [[ -n "$caps" ]] && NSPAWN_ARGS+=(--capability="$caps")
    return 0   # never let a falsy final test become the function's exit (set -e)
}

manager_nspawn_enter() {
    local name="$1"; shift
    require_cmd systemd-nspawn
    local target
    target="$(read_manifest_field "$name" target)" || die "no manifest for $name"
    # Reproduce the create-time nspawn config from the manifest.  LAB_NSPAWN_BOOT
    # still overrides boot for ad-hoc use; older manifests (missing the new
    # fields) read empty → host network, no extra binds/caps (prior behavior).
    local boot network bind_ro caps
    boot="${LAB_NSPAWN_BOOT:-$(read_manifest_field "$name" nspawn_boot 2>/dev/null || echo false)}"
    network="$(read_manifest_field "$name" nspawn_network      2>/dev/null || true)"
    bind_ro="$(read_manifest_field "$name" nspawn_bind_ro      2>/dev/null || true)"
    caps="$(read_manifest_field    "$name" nspawn_capabilities 2>/dev/null || true)"
    build_nspawn_args "$target" "$boot" "$network" "${bind_ro:-[]}" "${caps:-[]}"

    if (( $# > 0 )); then
        systemd-nspawn "${NSPAWN_ARGS[@]}" -- "$@"
    else
        systemd-nspawn "${NSPAWN_ARGS[@]}"
    fi
}

manager_nspawn_destroy() {
    local name="$1" target="$2"
    local link; link="$(nspawn_machines_link "$name")"
    [[ -L "$link" ]] && rm -f "$link"
    _safe_rm_rf "$target"
}

# ─── Subcommand: create ─────────────────────────────────────────────────────
create_one() {
    local spec="$1"
    validate_spec "$spec"

    local name backend target manager
    name="$(spec_get "$spec" name)"
    backend="$(spec_get "$spec" backend)"
    target="$(spec_get "$spec" target)"
    manager="$(spec_get "$spec" manager)"

    # Root, or rootless via fakechroot+fakeroot.  ROOTLESS (global) gates every
    # chroot/mount call site for the rest of this create.
    if [[ -n "${OPT_ROOTLESS:-}" ]]; then
        ROOTLESS=1
        # Validate the rootless constraints first (clear config errors before we
        # probe for the fakechroot/fakeroot tools).
        case "$backend" in
            debootstrap|host-copy) ;;
            *) die "--rootless supports backend=debootstrap or host-copy (got '$backend'; dnf needs root)" ;;
        esac
        [[ "$manager" == "none" ]] \
            || die "--rootless requires manager=none (schroot/nspawn need root)"
        local _rarch; _rarch="$(spec_get "$spec" arch)"
        [[ -z "$_rarch" || "$_rarch" == "$(detect_host_arch)" ]] \
            || die "--rootless is native-arch only (got arch='$_rarch', host=$(detect_host_arch)); foreign-arch needs root + qemu-user-static"
        require_rootless_deps
        log_info "rootless mode: fakechroot + fakeroot (no root, no bind-mounts; LD_PRELOAD jail — not a security sandbox)"
    else
        ROOTLESS=""
        [[ $EUID -eq 0 ]] || die "create requires root (or use --rootless — needs fakechroot + fakeroot)"
    fi

    if [[ -e "$(manifest_path "$name")" ]]; then
        die "chroot named '$name' already exists in state — destroy it first or pick a new name"
    fi

    log_info "── creating chroot '$name' (backend=$backend, manager=$manager) ──"

    case "$backend" in
        debootstrap) backend_debootstrap_create "$spec" ;;
        dnf|yum)     backend_dnf_create        "$spec" ;;
        host-copy)   backend_host_copy_create  "$spec" ;;
        *) die "unknown backend $backend" ;;
    esac

    case "$manager" in
        none)    manager_none_register             ;;
        schroot) manager_schroot_register "$spec"  ;;
        nspawn)  manager_nspawn_register  "$spec"  ;;
    esac

    apply_hostname      "$spec" "$target"
    apply_init_script   "$spec" "$target"
    apply_write_files   "$spec" "$target"
    apply_users         "$spec" "$target"

    # Finding 9: write the manifest BEFORE apply_post_commands so that if a
    # post-command fails (set -e exits the script), the tree is still findable
    # by name and `destroy <name>` can clean it up.  Previously the manifest
    # was written after post_commands, leaving an orphaned tree with no manifest.
    write_manifest "$name" "$target" "$backend" \
        "$(spec_get "$spec" distro)" "$(spec_get "$spec" suite)" \
        "$(spec_get "$spec" arch)" "$manager" \
        "$(spec_get "$spec" lab)"

    # Persist settings the base manifest doesn't carry, so enter/destroy
    # reproduce them: the rootless flag, and (for nspawn) the advanced config.
    append_manifest_field "$name" rootless "$([[ -n "${ROOTLESS:-}" ]] && echo true || echo false)"
    if [[ "$manager" == "nspawn" ]]; then
        append_manifest_field "$name" nspawn_boot    "$(jq -r '.nspawn.boot    // false' <<<"$spec")"
        append_manifest_field "$name" nspawn_network "$(jq -r '.nspawn.network // ""'    <<<"$spec")"
        append_manifest_raw   "$name" nspawn_bind_ro      "$(jq -c '.nspawn.bind_ro      // []' <<<"$spec")"
        append_manifest_raw   "$name" nspawn_capabilities "$(jq -c '.nspawn.capabilities // []' <<<"$spec")"
    fi

    apply_post_commands "$spec" "$target"

    local _created_lab; _created_lab="$(spec_get "$spec" lab)"
    [[ -n "$_created_lab" ]] && log_info "lab: $_created_lab"
    log_info "── done: $name ──"
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

# ─── Subcommand: enter ──────────────────────────────────────────────────────
resolve_target_and_manager() {
    # Argument can be a name (looked up in state) or an absolute path.
    local arg="$1"
    if [[ "$arg" == /* ]]; then
        # path mode: scan manifests looking for a matching target
        local mp name target
        for mp in "$LAB_CHROOT_STATE_DIR"/*.toml; do
            name="${mp##*/}"; name="${name%.toml}"
            target="$(read_manifest_field "$name" target)"
            if [[ "$target" == "$arg" ]]; then
                printf '%s\t%s\t%s\n' "$name" "$target" "$(read_manifest_field "$name" manager)"
                return 0
            fi
        done
        # No manifest — assume bare chroot, manager=none.  Synthesize a
        # name from the target's basename so callers always have a
        # non-empty leading field; if we left it empty, `IFS=$'\t' read`
        # would silently strip the leading tab (tab is whitespace) and
        # shift target into the name slot, breaking all callers.
        [[ -d "$arg" ]] || die "no such chroot path: $arg"
        printf '%s\t%s\t%s\n' "${arg##*/}" "$arg" "none"
    else
        local target manager
        target="$(read_manifest_field "$arg" target)" \
            || die "no chroot named '$arg' (try 'lab-chroot.sh list')"
        manager="$(read_manifest_field "$arg" manager)"
        printf '%s\t%s\t%s\n' "$arg" "$target" "$manager"
    fi
}

cmd_enter() {
    local arg="${POS_ARGS[0]:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG enter <name|path> [-- cmd args...]"
    local name target manager
    IFS=$'\t' read -r name target manager < <(resolve_target_and_manager "$arg")

    # Reproduce the create-time rootless mode from the manifest (empty for a
    # bare path with no manifest).  Gates manager_none_enter's chroot path.
    [[ "$(read_manifest_field "$name" rootless 2>/dev/null)" == "true" ]] && ROOTLESS=1 || ROOTLESS=""

    log_debug "enter: name=$name target=$target manager=$manager rootless=${ROOTLESS:-0}"

    case "$manager" in
        none)    manager_none_enter    "$target" "${EXTRA_ARGS[@]}" ;;
        schroot) manager_schroot_enter "$name"   "${EXTRA_ARGS[@]}" ;;
        nspawn)  manager_nspawn_enter  "$name"   "${EXTRA_ARGS[@]}" ;;
        *) die "unknown manager: $manager" ;;
    esac
}

# ─── Subcommand: destroy ────────────────────────────────────────────────────
cmd_destroy() {
    local arg="${POS_ARGS[0]:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG destroy <name|path> [--force]"
    local name target manager
    IFS=$'\t' read -r name target manager < <(resolve_target_and_manager "$arg")

    # A rootless chroot is owned by the invoking user and has no mounts — tear
    # it down without root.  Root is required only for root-created trees.
    [[ "$(read_manifest_field "$name" rootless 2>/dev/null)" == "true" ]] && ROOTLESS=1 || ROOTLESS=""
    if [[ -z "${ROOTLESS:-}" ]]; then
        [[ $EUID -eq 0 ]] || die "destroy requires root (rootless chroots can be destroyed as your user)"
    fi

    if [[ -z "${OPT_FORCE:-}" ]]; then
        printf 'About to destroy:\n  name:    %s\n  target:  %s\n  manager: %s\nProceed? [y/N] ' \
            "${name:-<unmanaged>}" "$target" "$manager" >&2
        read -r ans </dev/tty || true
        case "$ans" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
    fi

    case "$manager" in
        none)    manager_none_destroy    "$target" ;;
        schroot) manager_schroot_destroy "$name" "$target" ;;
        nspawn)  manager_nspawn_destroy  "$name" "$target" ;;
        *) die "unknown manager: $manager" ;;
    esac
    [[ -n "$name" ]] && remove_manifest "$name"
    log_info "destroyed: ${name:-$target}"
}

# ─── Subcommand: list ───────────────────────────────────────────────────────
cmd_list() {
    state_init
    local found=0
    # --lab NAME filters to chroots in that lab.  --lab '' (explicit empty)
    # is taken as a literal "show ungrouped only" request; omitting the
    # flag shows everything.  (parse_args always inits OPT_LAB="", so we key
    # off OPT_LAB_SET — whether --lab was actually given — to tell them apart.)
    local filter="__ALL__"
    [[ -n "${OPT_LAB_SET:-}" ]] && filter="$OPT_LAB"

    # Registries to scan, as "dir|owner" pairs.  Always the active one.  With
    # --system, also fold in root's registry (/var/lib/lab-create) so chroots
    # built under sudo are visible from an unprivileged `list` — read-only, no
    # sudo needed (the manifests are world-readable).  Skipped when already root
    # (the active registry is already root's) or when the dirs coincide.
    local -a regs=("$LAB_CHROOT_STATE_DIR|$(id -un)")
    # The system registry root chroots are recorded in.  Overridable via
    # LAB_SYSTEM_STATE_DIR for tests; defaults to the standard root state dir.
    local sys_reg="${LAB_SYSTEM_STATE_DIR:-/var/lib/lab-create}/chroots"
    if [[ -n "${OPT_SYSTEM:-}" && ${EUID:-$(id -u)} -ne 0 \
          && "$LAB_CHROOT_STATE_DIR" != "$sys_reg" && -d "$sys_reg" ]]; then
        regs+=("$sys_reg|root")
    fi

    # --json: a machine-readable array of the script-managed chroots (the
    # schroot/machinectl cross-checks are human-only).  schema_version matches
    # `inspect --json`.  Honors --lab filtering.  With --system each row also
    # carries an "owner" key (the registry it came from); default output is
    # unchanged.
    if [[ -n "${OPT_JSON:-}" ]]; then
        local reg dir owner mp name row_lab
        local -A seen=()
        local with_owner=false; [[ -n "${OPT_SYSTEM:-}" ]] && with_owner=true
        for reg in "${regs[@]}"; do
            dir="${reg%|*}"; owner="${reg##*|}"
            for mp in "$dir"/*.toml; do
                [[ -e "$mp" ]] || continue
                name="${mp##*/}"; name="${name%.toml}"
                [[ -n "${seen[$name]:-}" ]] && continue
                seen[$name]=1
                row_lab="$(read_manifest_field_at "$mp" lab)"
                if [[ "$filter" != "__ALL__" ]]; then
                    [[ "$row_lab" == "$filter" ]] || continue
                fi
                jq -n \
                    --arg name       "$name" \
                    --arg lab        "$row_lab" \
                    --arg backend    "$(read_manifest_field_at "$mp" backend)" \
                    --arg distro     "$(read_manifest_field_at "$mp" distro)" \
                    --arg suite      "$(read_manifest_field_at "$mp" suite)" \
                    --arg arch       "$(read_manifest_field_at "$mp" arch)" \
                    --arg manager    "$(read_manifest_field_at "$mp" manager)" \
                    --arg target     "$(read_manifest_field_at "$mp" target)" \
                    --arg rootless   "$(read_manifest_field_at "$mp" rootless)" \
                    --arg created_at "$(read_manifest_field_at "$mp" created_at)" \
                    --arg owner      "$owner" \
                    --argjson with_owner "$with_owner" \
                    '{name:$name, lab:$lab, backend:$backend, distro:$distro, suite:$suite,
                      arch:$arch, manager:$manager, target:$target,
                      rootless: ($rootless=="true"), created_at:$created_at}
                     + (if $with_owner then {owner:$owner} else {} end)'
            done
        done | jq -s '{schema_version:1, chroots: .}'
        return 0
    fi

    if [[ -n "${OPT_LAB:-}" ]]; then
        printf '── lab: %s ──\n' "$OPT_LAB"
    fi
    if [[ -n "${OPT_SYSTEM:-}" ]]; then
        printf '%-20s  %-14s  %-12s  %-10s  %-8s  %-8s  %-8s  %s\n' \
            NAME LAB BACKEND DISTRO ARCH MANAGER OWNER TARGET
    else
        printf '%-20s  %-14s  %-12s  %-10s  %-8s  %-8s  %s\n' \
            NAME LAB BACKEND DISTRO ARCH MANAGER TARGET
    fi
    local reg dir owner mp name row_lab
    local -A seen=()
    for reg in "${regs[@]}"; do
        dir="${reg%|*}"; owner="${reg##*|}"
        for mp in "$dir"/*.toml; do
            [[ -e "$mp" ]] || continue
            name="${mp##*/}"; name="${name%.toml}"
            [[ -n "${seen[$name]:-}" ]] && continue
            seen[$name]=1
            row_lab="$(read_manifest_field_at "$mp" lab)"
            if [[ "$filter" != "__ALL__" ]]; then
                [[ "$row_lab" == "$filter" ]] || continue
            fi
            if [[ -n "${OPT_SYSTEM:-}" ]]; then
                printf '%-20s  %-14s  %-12s  %-10s  %-8s  %-8s  %-8s  %s\n' \
                    "$name" "${row_lab:-(none)}" \
                    "$(read_manifest_field_at "$mp" backend)" \
                    "$(read_manifest_field_at "$mp" distro)" \
                    "$(read_manifest_field_at "$mp" arch)" \
                    "$(read_manifest_field_at "$mp" manager)" \
                    "$owner" \
                    "$(read_manifest_field_at "$mp" target)"
            else
                printf '%-20s  %-14s  %-12s  %-10s  %-8s  %-8s  %s\n' \
                    "$name" "${row_lab:-(none)}" \
                    "$(read_manifest_field_at "$mp" backend)" \
                    "$(read_manifest_field_at "$mp" distro)" \
                    "$(read_manifest_field_at "$mp" arch)" \
                    "$(read_manifest_field_at "$mp" manager)" \
                    "$(read_manifest_field_at "$mp" target)"
            fi
            found=$((found+1))
        done
    done
    if have schroot; then
        printf '\n[schroot -l]\n'
        schroot -l 2>/dev/null || true
    fi
    if have machinectl; then
        printf '\n[machinectl list-images]\n'
        machinectl list-images --no-pager 2>/dev/null || true
    fi
    # Use an `if` (not `&&`) so a non-empty list doesn't leave cmd_list with the
    # test's exit status 1 — `list` should exit 0 on success.
    if [[ $found -eq 0 ]]; then
        log_info "(no script-managed chroots)"
    fi
}

# ─── init_script helpers ────────────────────────────────────────────────────
_write_init_preset() {
    local flavor="$1" target="$2"
    case "$flavor" in
        busybox)
            cat > "$target/init" <<'BUSYBOX_INIT'
#!/bin/busybox sh
/bin/busybox --install -s
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
export TERM=linux
ip link set eth0 up
udhcpc -i eth0 -t 5 -n || true
exec /bin/sh
BUSYBOX_INIT
            chmod 0755 "$target/init"
            log_info "init_script: wrote busybox /init"
            ;;
        systemd)
            cat > "$target/init" <<'SYSTEMD_INIT'
#!/bin/sh
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev
exec /sbin/init
SYSTEMD_INIT
            chmod 0755 "$target/init"
            # agetty on a serial line does not auto-set TERM (unlike virtual
            # consoles).  The default serial-getty unit passes $TERM as the
            # terminal-type argument to agetty, so setting it here is enough.
            mkdir -p "$target/etc/systemd/system/serial-getty@ttyS0.service.d"
            printf '[Service]\nEnvironment=TERM=linux\n' \
                > "$target/etc/systemd/system/serial-getty@ttyS0.service.d/term.conf"
            # SSH clients forward their own $TERM (e.g. xterm-ghostty), which
            # may not exist in this VM's terminfo database.  Fall back to
            # xterm-256color so interactive tools (less, vi, …) work without
            # manual TERM overrides.  No-op when $TERM is already known.
            cat > "$target/etc/profile.d/term-fallback.sh" << 'TERM_FALLBACK'
#!/bin/sh
[ -n "${TERM:-}" ] && ! infocmp "$TERM" >/dev/null 2>&1 && export TERM=xterm-256color
TERM_FALLBACK
            chmod 644 "$target/etc/profile.d/term-fallback.sh"
            log_info "init_script: wrote systemd /init"
            ;;
        *)
            die "unknown init_script flavor: $flavor (use busybox|systemd|/path/to/file)"
            ;;
    esac
}

# apply_init_script SPEC TARGET
# Write /init into TARGET based on init_script field or --init-flavor flag.
# Values: "busybox" | "systemd" | "/host/path/to/custom.sh"
# Writes /init and sets chmod 755. No-op if value is empty.
apply_init_script() {
    local spec="$1" target="$2"
    local flavor; flavor="$(spec_get "$spec" init_script)"
    [[ -z "$flavor" ]] && flavor="${OPT_INIT_FLAVOR:-}"
    [[ -z "$flavor" ]] && return 0   # nothing requested at create time

    if [[ "$flavor" == /* ]]; then
        # host path — copy verbatim.
        [[ -r "$flavor" ]] || die "init_script: file not readable: $flavor"
        # Denylist sensitive host directories (Finding 15): a crafted TOML setting
        # init_script = "/etc/shadow" would copy that file into the chroot as a
        # world-readable /init, and export-initrd would then expose it to the
        # invoking user.  Custom init scripts should live under /usr/local, ~/,
        # or an explicit scripts directory — not inside system-managed trees.
        case "$flavor" in
            /etc/*|/root/*|/var/*|/proc/*|/sys/*|/boot/*|/lib/*|/lib64/*|/usr/lib/*)
                die "init_script: path '$flavor' is inside a sensitive host directory; place custom init scripts under /usr/local or your home directory" ;;
        esac
        [[ -f "$flavor" ]] || die "init_script: not a regular file: $flavor"
        install -m 0755 "$flavor" "$target/init"
        log_info "init_script: installed custom /init from $flavor"
    else
        _write_init_preset "$flavor" "$target"
    fi
}

# apply_users SPEC TARGET
# Create OS users inside TARGET chroot from the spec's users[] array.
# Each entry: {name, password, groups (comma-sep string), shell}.
apply_users() {
    local spec="$1" target="$2"
    local user_json uname upass ugroups ushell
    while IFS= read -r user_json; do
        [[ -z "$user_json" ]] && continue
        uname="$(jq -r  '.name'             <<<"$user_json")"
        upass="$(jq -r  '.password  // ""'  <<<"$user_json")"
        ugroups="$(jq -r '.groups   // ""'  <<<"$user_json")"
        ushell="$(jq -r  '.shell // "/bin/bash"' <<<"$user_json")"
        [[ -z "$uname" ]] && continue
        log_info "users: creating '$uname'"
        chroot_exec "$target" useradd -m -s "$ushell" "$uname" 2>/dev/null \
            || log_warn "users: useradd '$uname' returned non-zero (already exists?)"
        # Strip newlines from password — a literal newline would inject a second
        # "user:pass" line into chpasswd's stdin, setting passwords for unintended
        # chroot accounts (Finding 12).
        upass="${upass//$'\n'/}"
        [[ -n "$upass"   ]] && printf '%s:%s\n' "$uname" "$upass" \
                                    | chroot_exec "$target" chpasswd
        [[ -n "$ugroups" ]] && chroot_exec "$target" usermod -aG "$ugroups" "$uname"
    done < <(jq -c '.users[]?' <<<"$spec")
}

# apply_hostname SPEC TARGET
# Write /etc/hostname and /etc/hosts inside TARGET.
# Uses the 'hostname' spec field; auto-generates <host-short>-<4rand> if empty.
apply_hostname() {
    local spec="$1" target="$2"
    local hn
    hn="$(spec_get "$spec" hostname)"
    if [[ -z "$hn" ]]; then
        local short rand
        short="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-12)"
        rand="$(mktemp -u XXXX | tr '[:upper:]' '[:lower:]')"
        hn="${short:-lab}-${rand}"
    fi
    printf '%s\n' "$hn" > "$target/etc/hostname"
    {
        printf '127.0.0.1\tlocalhost\n'
        printf '127.0.1.1\t%s\n' "$hn"
        printf '::1\t\tlocalhost ip6-localhost ip6-loopback\n'
        printf 'ff02::1\t\tip6-allnodes\n'
        printf 'ff02::2\t\tip6-allrouters\n'
    } > "$target/etc/hosts"
    log_info "hostname: $hn"
}

# apply_write_files SPEC TARGET
# Write files from the write_files[] spec array directly into TARGET on the
# host (no chroot exec).  Each entry must have a "path" key (relative to the
# chroot root, e.g. "/init").  Optional keys: "content" (file body), "mode"
# (octal string, default "0644"), "executable" (bool, shorthand for "0755").
# TOML example:
#   [[chroot.write_files]]
#   path    = "/init"
#   mode    = "0755"
#   content = '''
#   #!/bin/busybox sh
#   exec /bin/sh
#   '''
apply_write_files() {
    local spec="$1" target="$2"
    local count
    count="$(jq '.write_files | length' <<<"$spec")"
    [[ "$count" -eq 0 ]] && return 0
    # Iterate by index so multi-line content is fetched cleanly per entry
    # rather than trying to split it via a line-by-line pipe.
    local i total
    total="$(jq '.write_files | length' <<<"$spec")"
    for (( i=0; i<total; i++ )); do
        local path mode executable content fmode dest
        path="$(       jq -r --argjson i "$i" '.write_files[$i].path       // ""'    <<<"$spec")"
        mode="$(       jq -r --argjson i "$i" '.write_files[$i].mode       // ""'    <<<"$spec")"
        executable="$( jq -r --argjson i "$i" '.write_files[$i].executable // false' <<<"$spec")"
        content="$(    jq -r --argjson i "$i" '.write_files[$i].content    // ""'    <<<"$spec")"
        [[ -z "$path" ]] && continue
        # Resolve the destination and jail-check it — a path containing ../
        # sequences could escape the chroot root and write to arbitrary host
        # paths as root (Finding 1: path traversal → host RCE).
        dest="$(realpath -m "$target/$path")"
        [[ "$dest" == "$target/"* ]] \
            || die "write_files[$((i+1))]: path '$path' escapes chroot root — refusing"
        # Validate mode is numeric octal to prevent chmod flag injection
        # (e.g. --reference=/etc/shadow) (Finding 7).
        fmode="0644"
        if [[ "$executable" == "true" ]]; then
            fmode="0755"
        elif [[ -n "$mode" ]]; then
            [[ "$mode" =~ ^0?[0-7]{3,4}$ ]] \
                || die "write_files[$((i+1))]: mode must be octal (e.g. 0644), got: $mode"
            fmode="$mode"
        fi
        install -d -m 0755 "$(dirname "$dest")"
        printf '%s' "$content" > "$dest"
        chmod "$fmode" "$dest"
        log_info "write_files[$((i+1))]: $path  (mode $fmode)"
    done
}

# apply_post_commands SPEC TARGET
# Run each string in post_commands[] as a bash -c command inside TARGET.
# Binds /proc /sys /dev into the chroot first so apt-get and post-install
# scripts work; unmounts on success or EXIT.
apply_post_commands() {
    local spec="$1" target="$2"
    local count
    count="$(jq '.post_commands | length' <<<"$spec")"
    [[ "$count" -eq 0 ]] && return 0

    # Rootless: fakechroot intercepts path resolution, so there are no real
    # bind-mounts to set up (and we couldn't mount as non-root anyway).
    if [[ -z "${ROOTLESS:-}" ]]; then
        bind_essentials "$target"
        # EXIT trap is set inside bind_essentials.
    fi
    local i=0 cmd
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        i=$(( i + 1 ))
        log_info "post_command[$i]: $cmd"
        DEBIAN_FRONTEND=noninteractive LC_ALL=C chroot_exec "$target" bash -c "$cmd"
    done < <(jq -r '.post_commands[]?' <<<"$spec")
    if [[ -z "${ROOTLESS:-}" ]]; then
        unbind_essentials "$target"
        trap - EXIT
    fi
}

# ─── Subcommand: export-initrd ──────────────────────────────────────────────
# Package a chroot tree as a gzipped cpio archive (initrd) and extract its
# kernel binary. Designed for HTTP-netboot pipelines: the resulting kernel +
# initrd.gz can be served over HTTP and loaded by iPXE or QEMU -kernel/-initrd.
#
# If $target/init does not exist, a sensible default is auto-written based on
# whether /bin/busybox is present in the chroot (busybox preset) or not
# (systemd preset). Use --init-script or --init-flavor to override.
cmd_export_initrd() {
    local arg="${POS_ARGS[0]:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG export-initrd <name|path> --kernel PATH --output PATH"

    local name target manager
    IFS=$'\t' read -r name target manager < <(resolve_target_and_manager "$arg")
    [[ -d "$target" ]] || die "target is not a directory: $target"

    local out="${OPT_OUTPUT:-/tmp/${name:-chroot}-initrd.gz}"
    local kernel_out="${OPT_KERNEL_OUT:-/tmp/${name:-chroot}-vmlinuz}"

    # Find the kernel binary in the chroot's /boot/
    local kernel_src
    kernel_src="$(find "$target/boot" -maxdepth 1 -name 'vmlinuz-*' \
        -not -name '*.old' -not -name '*.bak' 2>/dev/null | sort -V | tail -1)"
    [[ -n "$kernel_src" ]] || die "no /boot/vmlinuz-* found in $target — install a kernel first:
  sudo lab-chroot.sh enter $name -- apt-get install -y linux-image-amd64   # Debian
  sudo lab-chroot.sh enter $name -- dnf install -y kernel                  # Rocky/Fedora"

    # Ensure /init exists, writing a default if needed
    if [[ -f "$target/init" ]]; then
        log_info "using existing $target/init"
    elif [[ -n "${OPT_INIT_SCRIPT:-}" ]]; then
        if [[ "$OPT_INIT_SCRIPT" == /* ]]; then
            install -m 0755 "$OPT_INIT_SCRIPT" "$target/init"
            log_info "init: installed from $OPT_INIT_SCRIPT"
        else
            _write_init_preset "$OPT_INIT_SCRIPT" "$target"
        fi
    elif [[ -n "${OPT_INIT_FLAVOR:-}" ]]; then
        _write_init_preset "$OPT_INIT_FLAVOR" "$target"
    else
        # Auto-detect
        if [[ -x "$target/bin/busybox" || -x "$target/usr/bin/busybox" ]]; then
            log_warn "no /init in chroot; auto-writing busybox default"
            _write_init_preset busybox "$target"
        else
            log_warn "no /init in chroot; auto-writing systemd default"
            _write_init_preset systemd "$target"
        fi
    fi

    local invoker_uid invoker_gid
    invoker_uid="${SUDO_UID:-$(id -u)}"
    invoker_gid="${SUDO_GID:-$(id -g)}"

    # Copy kernel
    log_info "copying kernel $kernel_src → $kernel_out"
    install -m 0644 "$kernel_src" "$kernel_out"
    chown "${invoker_uid}:${invoker_gid}" "$kernel_out" 2>/dev/null || true

    # Build exclusion list for find (using -not -path predicates)
    local -a find_excludes
    find_excludes=(
        -not -path './proc/*' -not -path './sys/*' -not -path './dev/*'
        -not -path './run/*'  -not -path './tmp/*'
        -not -path './.lab-chroot-mounts'
    )
    [[ -n "${OPT_STRIP_MODULES:-}" ]] && find_excludes+=(-not -path './lib/modules/*')

    # Package as cpio.gz
    log_info "packaging $target → $out (strip-modules=${OPT_STRIP_MODULES:-no})"
    require_cmd cpio gzip find

    ( cd "$target" && find . "${find_excludes[@]}" -print0 \
        | cpio --null -H newc -o 2>/dev/null \
        | gzip -9 -n > "$out" ) \
        || die "cpio/gzip failed writing $out"

    chown "${invoker_uid}:${invoker_gid}" "$out" 2>/dev/null || true
    chmod 0644 "$out" 2>/dev/null || true

    local ksz isz
    ksz="$(du -h "$kernel_out" 2>/dev/null | awk '{print $1}')"
    isz="$(du -h "$out"        2>/dev/null | awk '{print $1}')"
    log_info "kernel:  $kernel_out (${ksz:-?})"
    log_info "initrd:  $out (${isz:-?})"
    log_info "boot it: lab-vm.sh create --backend kernel+initrd --kernel $kernel_out --initrd $out"
}

# ─── Subcommand: export-tarball ─────────────────────────────────────────────
# Emit a gzipped tarball of a chroot tree, rootless-friendly.  Intended as
# the bridge to Phase 4 (`lab-podman ... from_tarball = "..."`) — chroots
# built via `sudo lab-chroot create` contain root-mode-600 files that an
# unprivileged tar can't read, so we run as root and chown the output so
# the invoking user can consume it.  Works fine for non-root-owned
# chroots too (e.g. host-copy backend).
cmd_export_tarball() {
    local arg="${POS_ARGS[0]:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG export-tarball <name|path> [--output PATH]"

    local name target manager
    IFS=$'\t' read -r name target manager < <(resolve_target_and_manager "$arg")
    [[ -d "$target" ]] || die "target is not a directory: $target"

    local out="${OPT_OUTPUT:-/tmp/${name:-chroot}.tar.gz}"
    # If the user didn't pass --output but the target is interesting,
    # suggest the name we chose.
    log_info "exporting $target → $out"

    # Tar + gzip.  --numeric-owner keeps UIDs as-is (podman import will
    # respect them).  No --owner rewrite here — that's a Phase 4 concern
    # (userns=auto-map handles it on the import side).
    require_cmd tar

    # Give the output file writable by the invoking user, not just root.
    local invoker_uid invoker_gid
    invoker_uid="${SUDO_UID:-$(id -u)}"
    invoker_gid="${SUDO_GID:-$(id -g)}"

    tar -C "$target" \
        --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
        --exclude='./run/*'  --exclude='./tmp/*' \
        --exclude='./.lab-chroot-mounts' \
        --numeric-owner -czpf "$out" . \
        || die "tar failed writing $out"

    # Make the output consumable by the invoking (non-root) user.
    chown "${invoker_uid}:${invoker_gid}" "$out" 2>/dev/null || true
    chmod 0644 "$out" 2>/dev/null || true

    local sz; sz="$(du -h "$out" 2>/dev/null | awk '{print $1}')"
    log_info "wrote $out (${sz:-?})"
    printf '%s\n' "$out"
}

# ─── Subcommand: verify ─────────────────────────────────────────────────────
cmd_verify() {
    local arg="${POS_ARGS[0]:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG verify <name|path>"
    local name target manager
    IFS=$'\t' read -r name target manager < <(resolve_target_and_manager "$arg")

    [[ -d "$target" ]] || die "target is not a directory: $target"
    printf 'target:    %s\n' "$target"
    if [[ -r "$target/etc/os-release" ]]; then
        # Parse with awk — never source the chroot's os-release, which could
        # contain arbitrary shell code and runs as root (Finding 2; same rule
        # documented at cmd_inspect line ~1683).
        local _osr_name _osr_ver
        _osr_name="$(awk -F= '/^NAME=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
                         "$target/etc/os-release" 2>/dev/null)"
        _osr_ver="$( awk -F= '/^VERSION=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
                         "$target/etc/os-release" 2>/dev/null)"
        printf 'os:        %s %s\n' "${_osr_name:-?}" "${_osr_ver:-?}"
    else
        printf 'os:        (no /etc/os-release)\n'
    fi
    # arch test: probe via uname inside (works under qemu-user-static if needed)
    if [[ $EUID -eq 0 ]]; then
        if [[ -x "$target/bin/uname" || -x "$target/usr/bin/uname" ]]; then
            local inside
            inside="$(chroot "$target" /usr/bin/env uname -m 2>/dev/null \
                  || chroot "$target" uname -m 2>/dev/null \
                  || printf 'unknown')"
            printf 'uname -m:  %s\n' "$inside"
        else
            printf 'uname -m:  (no uname in tree)\n'
        fi
    else
        printf 'uname -m:  (skipped — not root)\n'
    fi
    # Smoke test: try to exec ls or busybox.
    if [[ $EUID -eq 0 ]]; then
        local probe
        for probe in /bin/ls /bin/busybox /usr/bin/ls; do
            if [[ -x "${target}${probe}" ]]; then
                if chroot "$target" "$probe" / >/dev/null 2>&1 \
                || chroot "$target" "$probe" 2>/dev/null | head -n1 >/dev/null; then
                    printf 'exec test: %s OK\n' "$probe"
                    return 0
                fi
            fi
        done
        printf 'exec test: no probe binary found\n'
    fi
}

# ─── Subcommand: inspect ────────────────────────────────────────────────────
# Single-chroot detail report — pairs the static manifest with cheap live
# probes (target dir size/owner, /etc/os-release, package count, manager
# registration, foreign-arch interpreter availability).
#
# Two output modes:
#   default      → human-readable [manifest] / [live] sections
#   --json       → one JSON document on stdout, schema_version=1
#
# Designed primarily as a machine-readable surface for Phase 6 (the TUI's
# chroot detail panel).  CLI users get the same data but rendered.
#
# IMPORTANT: never `source` the chroot's /etc/os-release — that file
# could carry arbitrary shell.  Parse it with awk instead.
cmd_inspect() {
    local arg="${POS_ARGS[0]:-}"
    [[ -n "$arg" ]] || die "usage: $LAB_PROG inspect <name|path> [--json]"
    local name target manager
    IFS=$'\t' read -r name target manager < <(resolve_target_and_manager "$arg")

    # --- manifest fields.  Bare path-mode chroots with no manifest get
    # a synthesized name from `resolve_target_and_manager` (basename),
    # so read_manifest_field will return 1 on every call — wrap each in
    # `|| true` so set -e doesn't propagate the missing-manifest signal
    # out of the var=$() subshell.
    local m_distro m_suite m_arch m_backend m_lab m_created m_version
    m_distro="$(read_manifest_field "$name" distro     2>/dev/null || true)"
    m_suite="$(read_manifest_field   "$name" suite      2>/dev/null || true)"
    m_arch="$(read_manifest_field    "$name" arch       2>/dev/null || true)"
    m_backend="$(read_manifest_field "$name" backend    2>/dev/null || true)"
    m_lab="$(read_manifest_field     "$name" lab        2>/dev/null || true)"
    m_created="$(read_manifest_field "$name" created_at 2>/dev/null || true)"
    m_version="$(read_manifest_field "$name" version    2>/dev/null || true)"

    # --- live: target dir
    local t_exists=false t_size_bytes=0 t_owner=""
    if [[ -d "$target" ]]; then
        t_exists=true
        # `du -sb` is GNU-specific; fall back to `du -sk` * 1024 elsewhere.
        if t_size_bytes="$(du -sb "$target" 2>/dev/null | awk '{print $1; exit}')"; then
            :
        else
            local sk; sk="$(du -sk "$target" 2>/dev/null | awk '{print $1; exit}')"
            t_size_bytes=$(( ${sk:-0} * 1024 ))
        fi
        t_owner="$(stat -c '%U:%G' "$target" 2>/dev/null || printf '?:?')"
    fi

    # --- live: os-release (parse, don't source).  Fields we surface match
    # what TUI detail panels actually want to render.
    local osr_id="" osr_version_id="" osr_codename="" osr_pretty=""
    if [[ -r "$target/etc/os-release" ]]; then
        # awk extractor — handles `KEY=value` and `KEY="value"` forms.
        local _osr
        _osr="$(awk -F= '
            /^[A-Z_]+=/ {
                k=$1; sub(/^[^=]*=/,"",$0); v=$0;
                gsub(/^"|"$/, "", v);
                vals[k]=v;
            }
            END {
                printf "%s\t%s\t%s\t%s\n",
                    vals["ID"], vals["VERSION_ID"],
                    vals["VERSION_CODENAME"], vals["PRETTY_NAME"];
            }
        ' "$target/etc/os-release" 2>/dev/null)"
        IFS=$'\t' read -r osr_id osr_version_id osr_codename osr_pretty <<<"$_osr"
    fi

    # --- live: package count.  Cheap heuristic — count files in the
    # respective package db.  Skip if the chroot doesn't have one.
    local pkg_manager="" pkg_count="null"
    if [[ -r "$target/var/lib/dpkg/status" ]]; then
        pkg_manager="dpkg"
        # One Package: header per installed package.
        pkg_count="$(grep -c '^Package: ' "$target/var/lib/dpkg/status" 2>/dev/null || printf 0)"
    elif [[ -d "$target/var/lib/rpm" ]]; then
        pkg_manager="rpm"
        # Counting *.rpm db files isn't meaningful; rpm -qa --root works
        # but is slow.  Leave count=null for rpm to avoid the spawn cost.
    fi

    # --- live: manager registration
    local mgr_kind="$manager" mgr_registered=false mgr_active=""
    case "$manager" in
        schroot)
            if have schroot && schroot -l 2>/dev/null | grep -qx "chroot:${name}"; then
                mgr_registered=true
            fi
            ;;
        nspawn)
            # machinectl shows nspawn-launched containers AND `list-images`
            # shows registered images.  An nspawn-managed chroot is
            # "registered" if machinectl knows about it.
            if have machinectl && machinectl show-image "$name" >/dev/null 2>&1; then
                mgr_registered=true
                mgr_active="$(machinectl show "$name" --property=State 2>/dev/null \
                    | awk -F= '/^State=/{print $2; exit}')"
            fi
            ;;
        none|"")
            mgr_kind="${mgr_kind:-none}"
            mgr_registered=true   # bare chroot is its own registration
            ;;
    esac

    # --- live: foreign-arch interpreter (when chroot arch != host arch)
    local host_arch fa_chroot_arch fa_qemu_user fa_qemu_available="null"
    host_arch="$(detect_host_arch)"
    fa_chroot_arch="${m_arch:-unknown}"
    if [[ -n "$m_arch" && "$m_arch" != "$host_arch" ]]; then
        if fa_qemu_user="$(arch_map "$m_arch" qemu-user 2>/dev/null)" && [[ -n "$fa_qemu_user" ]]; then
            if have "qemu-${fa_qemu_user}-static"; then
                fa_qemu_available=true
            else
                fa_qemu_available=false
            fi
        fi
    fi

    # --- emit ------------------------------------------------------------
    if [[ -n "${OPT_JSON:-}" ]]; then
        require_cmd jq
        jq -n \
            --arg name        "$name" \
            --arg target      "$target" \
            --arg backend     "$m_backend" \
            --arg distro      "$m_distro" \
            --arg suite       "$m_suite" \
            --arg arch        "$m_arch" \
            --arg manager     "$mgr_kind" \
            --arg lab         "$m_lab" \
            --arg created_at  "$m_created" \
            --arg version     "$m_version" \
            --argjson t_exists  "$t_exists" \
            --argjson t_size    "$t_size_bytes" \
            --arg t_owner     "$t_owner" \
            --arg osr_id      "$osr_id" \
            --arg osr_version "$osr_version_id" \
            --arg osr_codename "$osr_codename" \
            --arg osr_pretty  "$osr_pretty" \
            --arg pkg_manager "$pkg_manager" \
            --argjson pkg_count "$pkg_count" \
            --arg mgr_kind    "$mgr_kind" \
            --argjson mgr_registered "$mgr_registered" \
            --arg mgr_active  "$mgr_active" \
            --arg host_arch   "$host_arch" \
            --arg fa_chroot   "$fa_chroot_arch" \
            --argjson fa_qemu_avail "$fa_qemu_available" \
            '{
                schema_version: 1,
                name: $name,
                manifest: {
                    name: $name, target: $target, backend: $backend,
                    distro: $distro, suite: $suite, arch: $arch,
                    manager: $manager, lab: (if $lab == "" then null else $lab end),
                    created_at: $created_at, version: $version
                },
                target: {
                    path: $target, exists: $t_exists,
                    size_bytes: $t_size, owner: (if $t_owner == "" then null else $t_owner end)
                },
                os_release: (
                    if $osr_id == "" then null
                    else { id: $osr_id, version_id: $osr_version,
                           version_codename: $osr_codename,
                           pretty_name: $osr_pretty }
                    end
                ),
                packages: (
                    if $pkg_manager == "" then null
                    else { manager: $pkg_manager, count: $pkg_count }
                    end
                ),
                manager_state: {
                    kind: $mgr_kind,
                    registered: $mgr_registered,
                    active_state: (if $mgr_active == "" then null else $mgr_active end)
                },
                foreign_arch: (
                    if $fa_chroot == $host_arch or $fa_chroot == "unknown" then null
                    else { host_arch: $host_arch, chroot_arch: $fa_chroot,
                           qemu_user_static_available: $fa_qemu_avail }
                    end
                )
            }'
        return 0
    fi

    # Human-readable rendering — same data, indented two-section layout.
    printf '[manifest]\n'
    printf '  name        %s\n' "${name:-(no manifest)}"
    printf '  target      %s\n' "$target"
    [[ -n "$m_backend" ]]  && printf '  backend     %s\n' "$m_backend"
    [[ -n "$m_distro" ]]   && printf '  distro      %s\n' "$m_distro"
    [[ -n "$m_suite" ]]    && printf '  suite       %s\n' "$m_suite"
    [[ -n "$m_arch" ]]     && printf '  arch        %s\n' "$m_arch"
    [[ -n "$mgr_kind" ]]   && printf '  manager     %s\n' "$mgr_kind"
    [[ -n "$m_lab" ]]      && printf '  lab         %s\n' "$m_lab"
    [[ -n "$m_created" ]]  && printf '  created_at  %s\n' "$m_created"
    [[ -n "$m_version" ]]  && printf '  version     %s\n' "$m_version"

    printf '\n[live]\n'
    printf '  target.exists       %s\n' "$t_exists"
    if [[ "$t_exists" == "true" ]]; then
        printf '  target.size_bytes   %s\n' "$t_size_bytes"
        printf '  target.owner        %s\n' "$t_owner"
    fi
    if [[ -n "$osr_pretty" ]]; then
        printf '  os_release.pretty   %s\n' "$osr_pretty"
        [[ -n "$osr_id" ]]         && printf '  os_release.id       %s\n' "$osr_id"
        [[ -n "$osr_version_id" ]] && printf '  os_release.version  %s\n' "$osr_version_id"
        [[ -n "$osr_codename" ]]   && printf '  os_release.codename %s\n' "$osr_codename"
    fi
    if [[ -n "$pkg_manager" ]]; then
        printf '  packages.manager    %s\n' "$pkg_manager"
        [[ "$pkg_count" != "null" ]] && printf '  packages.count      %s\n' "$pkg_count"
    fi
    printf '  manager.kind        %s\n' "$mgr_kind"
    printf '  manager.registered  %s\n' "$mgr_registered"
    [[ -n "$mgr_active" ]] && printf '  manager.active      %s\n' "$mgr_active"
    if [[ -n "$m_arch" && "$m_arch" != "$host_arch" ]]; then
        printf '  foreign_arch.host         %s\n' "$host_arch"
        printf '  foreign_arch.chroot       %s\n' "$m_arch"
        printf '  foreign_arch.qemu_static  %s\n' "$fa_qemu_available"
    fi
}

# ─── CLI parsing ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG $LAB_VERSION — chroot creation & management (LAB_CREATE_V2 phase 1)

USAGE
  $LAB_PROG create   [--config FILE | --backend B --distro D --suite S --arch A --target PATH ...]
  $LAB_PROG enter    <name|path> [-- cmd args...]
  $LAB_PROG destroy  <name|path> [--force]
  $LAB_PROG list     [--lab NAME] [--system] [--json]
                     (--system: also show sudo-built chroots from root's registry)
  $LAB_PROG verify   <name|path>
  $LAB_PROG inspect  <name|path> [--json]
  $LAB_PROG export-tarball <name|path> [--output /tmp/x.tar.gz]
  $LAB_PROG export-initrd <name|path> --kernel PATH --output PATH [--init-script FLAVOR|PATH] [--strip-modules]
  $LAB_PROG version | help

CREATE OPTIONS
  --backend  {debootstrap|dnf|host-copy}
  --distro   {debian|ubuntu|kali|rocky}    (debootstrap/dnf only)
  --suite    <release-codename-or-version> (e.g. bookworm | jammy | kali-rolling | 9)
  --arch     {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x}
  --target   /path/to/chroot
  --name     <short-name>                  (defaults to basename of target)
  --hostname <name>                        (auto: <host-short>-<4rand> if omitted)
  --mirror   URL                           (backend default if omitted)
  --variant  minbase|buildd|fakechroot     (debootstrap only)
  --include  pkg,pkg,...
  --groups   group,group,...               (dnf only)
  --binaries /path/to/bin,/path/to/bin     (host-copy only)
  --extras   /etc/foo,/etc/bar             (host-copy: extra files to copy in)
  --manager  {none|schroot|nspawn}         (default: none)
  --rootless                               build + enter without root via fakechroot+fakeroot
                                           (debootstrap/host-copy, native arch, manager=none)
  --keep-cache                             reuse a persistent package download cache under
                                           \$LAB_CACHE_DIR (debootstrap --cache-dir / dnf cachedir)
  --config   /path/to/chroot.toml          (declarative form; overrides flags)
  --init-script FLAVOR|PATH  write /init at create time: 'busybox', 'systemd', or /host/path
  --init-flavor FLAVOR       same as --init-script for use with export-initrd auto-detect
  --user        name:pass    create OS user with password (repeatable; groups/shell via TOML)
  --post-command CMD         run CMD inside the chroot after build (repeatable)

EXPORT-INITRD OPTIONS
  --kernel   PATH    destination for extracted vmlinuz (default: /tmp/<name>-vmlinuz)
  --output   PATH    destination for initrd.gz (default: /tmp/<name>-initrd.gz)
  --init-script FLAVOR|PATH  write /init: 'busybox', 'systemd', or /host/path
  --strip-modules    exclude /lib/modules/ from the initrd (reduces size ~100-300 MB)

ENVIRONMENT
  LAB_LOG_LEVEL  debug|info|warn|error  (default: info)

EXAMPLES
  sudo $LAB_PROG create --backend debootstrap --distro debian --suite bookworm \\
        --arch x86_64 --target /var/chroots/bookworm-amd64

  sudo $LAB_PROG create --config examples/chroot-rocky9-vsftpd.toml

  sudo $LAB_PROG enter /var/chroots/bookworm-amd64 -- apt-get update
EOF
}

POS_ARGS=()
EXTRA_ARGS=()
OPT_POST_COMMANDS=()
OPT_USERS=()

parse_args() {
    OPT_CONFIG=""
    OPT_BACKEND="" OPT_DISTRO="" OPT_SUITE="" OPT_ARCH="" OPT_TARGET=""
    OPT_NAME="" OPT_MIRROR="" OPT_VARIANT="" OPT_HOSTNAME=""
    OPT_INCLUDE="" OPT_GROUPS="" OPT_BINARIES="" OPT_EXTRAS=""
    OPT_MANAGER="none" OPT_FORCE=""
    OPT_LAB=""
    OPT_OUTPUT=""
    OPT_JSON=""
    OPT_SYSTEM=""    # list: also surface root's registry (/var/lib/lab-create) when run unprivileged
    OPT_ROOTLESS="" OPT_KEEP_CACHE=""
    OPT_LAB_SET=""   # distinguishes "--lab omitted" (show all) from "--lab ''" (ungrouped only)
    OPT_INIT_SCRIPT="" OPT_INIT_FLAVOR="" OPT_STRIP_MODULES=""
    OPT_KERNEL_OUT=""
    OPT_POST_COMMANDS=()
    OPT_USERS=()

    [[ $# -eq 0 ]] && { usage; exit 0; }

    SUBCMD="$1"; shift

    local seen_doubledash=0
    while [[ $# -gt 0 ]]; do
        if (( seen_doubledash )); then
            EXTRA_ARGS+=("$1"); shift; continue
        fi
        case "$1" in
            --)              seen_doubledash=1; shift ;;
            --config)        OPT_CONFIG="$2"; shift 2 ;;
            --backend)       OPT_BACKEND="$2"; shift 2 ;;
            --distro)        OPT_DISTRO="$2"; shift 2 ;;
            --suite)         OPT_SUITE="$2"; shift 2 ;;
            --arch)          OPT_ARCH="$2"; shift 2 ;;
            --target)        OPT_TARGET="$2"; shift 2 ;;
            --name)          OPT_NAME="$2"; shift 2 ;;
            --mirror)        OPT_MIRROR="$2"; shift 2 ;;
            --variant)       OPT_VARIANT="$2"; shift 2 ;;
            --include)       OPT_INCLUDE="$2"; shift 2 ;;
            --groups)        OPT_GROUPS="$2"; shift 2 ;;
            --binaries)      OPT_BINARIES="$2"; shift 2 ;;
            --extras)        OPT_EXTRAS="$2"; shift 2 ;;
            --hostname)      OPT_HOSTNAME="$2"; shift 2 ;;
            --manager)       OPT_MANAGER="$2"; shift 2 ;;
            --lab)           OPT_LAB="$2"; OPT_LAB_SET=1; shift 2 ;;
            --output|-o)     OPT_OUTPUT="$2"; shift 2 ;;
            --json)          OPT_JSON=1; shift ;;
            --system)        OPT_SYSTEM=1; shift ;;
            --force|-f)      OPT_FORCE=1; shift ;;
            --rootless)      OPT_ROOTLESS=1; shift ;;
            --keep-cache)    OPT_KEEP_CACHE=1; shift ;;
            --init-script)   OPT_INIT_SCRIPT="$2"; shift 2 ;;
            --init-flavor)   OPT_INIT_FLAVOR="$2"; shift 2 ;;
            --strip-modules) OPT_STRIP_MODULES=1; shift ;;
            --kernel)        OPT_KERNEL_OUT="$2"; shift 2 ;;
            --post-command)  OPT_POST_COMMANDS+=("${2:?--post-command requires a shell command}"); shift 2 ;;
            --user)          OPT_USERS+=("${2:?--user requires name:password}"); shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            -v|--version)    printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION"; exit 0 ;;
            -*)              die "unknown option: $1 (try --help)" ;;
            *)               POS_ARGS+=("$1"); shift ;;
        esac
    done

    # Default name from target basename if creating from CLI without --name.
    if [[ "$SUBCMD" == "create" && -z "$OPT_CONFIG" && -z "$OPT_NAME" && -n "$OPT_TARGET" ]]; then
        OPT_NAME="${OPT_TARGET##*/}"
    fi
}

main() {
    parse_args "$@"
    case "$SUBCMD" in
        create)  cmd_create  ;;
        enter)   cmd_enter   ;;
        destroy) cmd_destroy ;;
        list)    cmd_list    ;;
        verify)  cmd_verify  ;;
        inspect) cmd_inspect ;;
        export-tarball) cmd_export_tarball ;;
        export-initrd)  cmd_export_initrd ;;
        help)    usage       ;;
        version) printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)       usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

# Run main only when executed directly, not when sourced by unit tests (which
# exercise helpers like build_nspawn_args / list-json rendering in isolation).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
