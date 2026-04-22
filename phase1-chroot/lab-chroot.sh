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
    readonly LAB_STATE_DIR="/var/lib/lab-create"
    readonly LAB_CACHE_DIR="/var/cache/lab-create"
else
    readonly LAB_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create"
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
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s' "${ID:-unknown}" )
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
    cat > "$mp" <<EOF
# lab-chroot manifest — do not edit by hand
name       = "${name}"
target     = "${target}"
backend    = "${backend}"
distro     = "${distro}"
suite      = "${suite}"
arch       = "${arch}"
manager    = "${manager}"
lab        = "${lab}"
created_at = "${now}"
version    = "${LAB_VERSION}"
EOF
    log_debug "wrote manifest $mp"
}

read_manifest_field() {
    # read_manifest_field NAME FIELD
    local mp; mp="$(manifest_path "$1")"
    [[ -r "$mp" ]] || return 1
    awk -v k="$2" '
        /^[[:space:]]*#/ { next }
        $1 == k { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit }
    ' "$mp"
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

    jq -n \
        --arg name     "${OPT_NAME:-}" \
        --arg backend  "${OPT_BACKEND:-}" \
        --arg distro   "${OPT_DISTRO:-}" \
        --arg suite    "${OPT_SUITE:-}" \
        --arg arch     "${OPT_ARCH:-}" \
        --arg target   "${OPT_TARGET:-}" \
        --arg mirror   "${OPT_MIRROR:-}" \
        --arg variant  "${OPT_VARIANT:-}" \
        --arg manager  "${OPT_MANAGER:-none}" \
        --arg lab      "${OPT_LAB:-}" \
        --argjson include  "$include_json" \
        --argjson binaries "$binaries_json" \
        --argjson extras   "$extras_json" \
        --argjson groups   "$groups_json" \
        '{name:$name, backend:$backend, distro:$distro, suite:$suite, arch:$arch,
          target:$target, mirror:$mirror, variant:$variant, manager:$manager, lab:$lab,
          include:$include, binaries:$binaries, extras:$extras, groups:$groups}'
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
            include: (.include // []),
            binaries:(.binaries// []),
            extras:  (.extras  // []),
            groups:  (.groups  // []),
            schroot: (.schroot // {}),
            nspawn:  (.nspawn  // {}) }
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

    if [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null || true)" ]]; then
        die "$target already exists and is not empty"
    fi
    mkdir -p "$target"

    if [[ "$arch" == "$host_arch" ]]; then
        log_info "debootstrap (native): $distro/$suite arch=$arch → $target"
        debootstrap "${deboot_args[@]}" "$suite" "$target" "$mirror"
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
        chroot "$target" /debootstrap/debootstrap --second-stage
    fi

    # Useful defaults a freshly-bootstrapped chroot doesn't get otherwise.
    install -D -m 0644 /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true
    log_info "debootstrap complete: $name → $target"
}

# ─── Backend: dnf (Rocky) ───────────────────────────────────────────────────
dnf_bootstrap_repo() {
    # Emit a temporary repo file with Rocky's BaseOS + AppStream for the given
    # release. Stdout = path to a tempfile the caller is responsible for cleaning.
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
    # (manifests as "$var: unbound variable" much later). Clean up explicitly
    # at end of function and on the error paths instead.
    local repo_file
    repo_file="$(dnf_bootstrap_repo "$suite" "$arch_rpm")"

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

    log_info "$pm install ($suite/$arch_rpm) → $target"
    "$pm" --setopt=reposdir= -c "$repo_file" \
          --installroot="$target" --releasever="$suite" \
          "${forcearch[@]}" \
          --assumeyes install "${packages[@]}"

    if (( ${#groups[@]} > 0 )); then
        log_info "$pm groupinstall: ${groups[*]}"
        "$pm" --setopt=reposdir= -c "$repo_file" \
              --installroot="$target" --releasever="$suite" \
              "${forcearch[@]}" \
              --assumeyes groupinstall "${groups[@]}"
    fi

    install -D -m 0644 /etc/resolv.conf "${target}/etc/resolv.conf" 2>/dev/null || true
    rm -f "$repo_file"

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
    : > "${target}/.lab-chroot-mounts"
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
    [[ $EUID -eq 0 ]] || die "entering a chroot requires root"
    bind_essentials "$target"
    # IMPORTANT: traps set inside a function persist past function return and
    # fire when the *script* exits.  If we use single quotes here, $target is
    # looked up at trap-fire time — by then the local is gone, and `set -u`
    # raises "$target: unbound variable" before unbind_essentials runs.
    # Use double quotes so $target expands NOW, embedding the literal path
    # into the trap string.
    trap "unbind_essentials '$target'" EXIT
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

manager_none_destroy() {
    local target="$1"
    unbind_essentials "$target"
    rm -rf -- "$target"
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
    rm -rf -- "$target"
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

manager_nspawn_enter() {
    local name="$1"; shift
    require_cmd systemd-nspawn
    local target boot
    target="$(read_manifest_field "$name" target)" || die "no manifest for $name"
    # Re-read the spec-time settings from machinectl link if needed.
    boot="${LAB_NSPAWN_BOOT:-false}"

    local -a args=(-D "$target")
    [[ "$boot" == "true" ]] && args+=(-b)

    if (( $# > 0 )); then
        systemd-nspawn "${args[@]}" -- "$@"
    else
        systemd-nspawn "${args[@]}"
    fi
}

manager_nspawn_destroy() {
    local name="$1" target="$2"
    local link; link="$(nspawn_machines_link "$name")"
    [[ -L "$link" ]] && rm -f "$link"
    rm -rf -- "$target"
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

    [[ $EUID -eq 0 ]] || die "create requires root (rootless mode is not yet implemented)"

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

    write_manifest "$name" "$target" "$backend" \
        "$(spec_get "$spec" distro)" "$(spec_get "$spec" suite)" \
        "$(spec_get "$spec" arch)" "$manager" \
        "$(spec_get "$spec" lab)"

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
        # No manifest — assume bare chroot, manager=none.
        [[ -d "$arg" ]] || die "no such chroot path: $arg"
        printf '\t%s\t%s\n' "$arg" "none"
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

    log_debug "enter: name=$name target=$target manager=$manager"

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

    [[ $EUID -eq 0 ]] || die "destroy requires root"

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
    # flag shows everything.
    local filter="${OPT_LAB-__ALL__}"
    if [[ -n "${OPT_LAB:-}" ]]; then
        printf '── lab: %s ──\n' "$OPT_LAB"
    fi
    printf '%-20s  %-14s  %-12s  %-10s  %-8s  %-8s  %s\n' \
        NAME LAB BACKEND DISTRO ARCH MANAGER TARGET
    local mp name row_lab
    for mp in "$LAB_CHROOT_STATE_DIR"/*.toml; do
        name="${mp##*/}"; name="${name%.toml}"
        row_lab="$(read_manifest_field "$name" lab)"
        if [[ "$filter" != "__ALL__" ]]; then
            [[ "$row_lab" == "$filter" ]] || continue
        fi
        printf '%-20s  %-14s  %-12s  %-10s  %-8s  %-8s  %s\n' \
            "$name" \
            "${row_lab:-(none)}" \
            "$(read_manifest_field "$name" backend)" \
            "$(read_manifest_field "$name" distro)" \
            "$(read_manifest_field "$name" arch)" \
            "$(read_manifest_field "$name" manager)" \
            "$(read_manifest_field "$name" target)"
        found=$((found+1))
    done
    if have schroot; then
        printf '\n[schroot -l]\n'
        schroot -l 2>/dev/null || true
    fi
    if have machinectl; then
        printf '\n[machinectl list-images]\n'
        machinectl list-images --no-pager 2>/dev/null || true
    fi
    [[ $found -eq 0 ]] && log_info "(no script-managed chroots)"
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
        # shellcheck disable=SC1090,SC1091
        ( . "$target/etc/os-release"; printf 'os:        %s %s\n' "${NAME:-?}" "${VERSION:-?}" )
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

# ─── CLI parsing ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG $LAB_VERSION — chroot creation & management (LAB_CREATE_V2 phase 1)

USAGE
  $LAB_PROG create   [--config FILE | --backend B --distro D --suite S --arch A --target PATH ...]
  $LAB_PROG enter    <name|path> [-- cmd args...]
  $LAB_PROG destroy  <name|path> [--force]
  $LAB_PROG list     [--lab NAME]
  $LAB_PROG verify   <name|path>
  $LAB_PROG export-tarball <name|path> [--output /tmp/x.tar.gz]
  $LAB_PROG version | help

CREATE OPTIONS
  --backend  {debootstrap|dnf|host-copy}
  --distro   {debian|ubuntu|kali|rocky}    (debootstrap/dnf only)
  --suite    <release-codename-or-version> (e.g. bookworm | jammy | kali-rolling | 9)
  --arch     {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x}
  --target   /path/to/chroot
  --name     <short-name>                  (defaults to basename of target)
  --mirror   URL                           (backend default if omitted)
  --variant  minbase|buildd|fakechroot     (debootstrap only)
  --include  pkg,pkg,...
  --groups   group,group,...               (dnf only)
  --binaries /path/to/bin,/path/to/bin     (host-copy only)
  --extras   /etc/foo,/etc/bar             (host-copy: extra files to copy in)
  --manager  {none|schroot|nspawn}         (default: none)
  --config   /path/to/chroot.toml          (declarative form; overrides flags)

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

parse_args() {
    OPT_CONFIG=""
    OPT_BACKEND="" OPT_DISTRO="" OPT_SUITE="" OPT_ARCH="" OPT_TARGET=""
    OPT_NAME="" OPT_MIRROR="" OPT_VARIANT=""
    OPT_INCLUDE="" OPT_GROUPS="" OPT_BINARIES="" OPT_EXTRAS=""
    OPT_MANAGER="none" OPT_FORCE=""
    OPT_LAB=""
    OPT_OUTPUT=""

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
            --manager)       OPT_MANAGER="$2"; shift 2 ;;
            --lab)           OPT_LAB="$2"; shift 2 ;;
            --output|-o)     OPT_OUTPUT="$2"; shift 2 ;;
            --force|-f)      OPT_FORCE=1; shift ;;
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
        export-tarball) cmd_export_tarball ;;
        help)    usage       ;;
        version) printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)       usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

main "$@"
