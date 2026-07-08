#!/usr/bin/env bash
# lab-podman.sh — Phase 4 of LAB_CREATE_V2: rootless-first OCI containers.
#
# Runtime modes : plain    — ephemeral podman run
#                 pod      — N services share a podman pod (network/IPC/PID)
#                 quadlet  — systemd-user units written to ~/.config/containers/systemd/
# Backends      : image       — pull or use an existing image
#                 from-chroot — `podman import` a Phase-1 chroot as a single-layer image
#                 build       — `podman build --platform` (multi-arch via qemu-user-static)
# Arches        : x86_64 aarch64 armv7l ppc64le riscv64 s390x  (mapped to OCI platforms)
# Config        : CLI flags or TOML (--config FILE)
#
# Rootless-first: refuses to run as root without --allow-root.  Rootless
# plumbing probes (subuid, linger, SELinux, pasta/slirp, port<1024) fire
# at create-time with fix-it messages.
#
# [lab] is a cross-phase grouping concept (see PLAN.md Cross-phase concerns).
# Ownership labels:
#   lab-create.tool = lab-podman       (scoped separately from Phase 3's lab-docker)
#   lab-create.lab  = <lab-name>
#   lab-create.svc  = <service-name>  (or .pod= for pods)
#
# Self-contained per the per-phase rule: helpers are duplicated inline.

set -euo pipefail
shopt -s nullglob

readonly LAB_VERSION="0.1.0"
readonly LAB_PROG="${0##*/}"
readonly LAB_LABEL_TOOL="lab-create.tool=lab-podman"
readonly LAB_LABEL_LAB="lab-create.lab"
readonly LAB_LABEL_SVC="lab-create.svc"
readonly LAB_LABEL_POD="lab-create.pod"

# State dirs (match Phase 2 shape).
if [[ $EUID -eq 0 ]]; then
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-/var/lib/lab-create}"
else
    readonly LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
fi
readonly LAB_POD_STATE_DIR="${LAB_STATE_DIR}/podman"
readonly QUADLET_USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

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
    # Parse with awk — sourcing /etc/os-release executes shell code.
    if [[ -r /etc/os-release ]]; then
        awk -F= '/^ID=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
            /etc/os-release
    else
        printf 'unknown'
    fi
}

# validate_name NAME [CONTEXT]  — reject anything that could inject into
# label filters, trap strings, YAML keys, unit file fields, or paths
# (Findings 1, 3, 4, 16).
validate_name() {
    local n="$1" ctx="${2:-name}"
    [[ -n "$n" ]] || die "$ctx is empty"
    [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] \
        || die "invalid $ctx '$n': use only [a-zA-Z0-9._-], start with alphanumeric, max 63 chars"
}

# _in_set VALUE [MEMBER...] — true if VALUE equals one of the MEMBERs.  Used by
# the partial-'up' rollback to skip pre-existing resources (Review H4).
_in_set() {
    local v="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$v" ]] && return 0; done
    return 1
}

# validate_device SPEC — sanity-check a per-service `devices` entry before it
# becomes a `--device SPEC` argument.  A spec is either a host device path
# (/dev/foo[:/dev/bar[:rwm]]) or a CDI device name (vendor.com/class=name, e.g.
# nvidia.com/gpu=all for rootless-podman GPU passthrough).  podman validates
# the spec itself; we only defensively reject a newline and a leading '-' so a
# crafted TOML value can't smuggle in a second flag.
validate_device() {
    local d="$1"
    [[ "$d" != *$'\n'* ]] || die "device spec must not contain a newline: $d"
    [[ "$d" != -*       ]] || die "device spec must not start with '-': $d"
}

# sanitize_unit_value VALUE FIELD  — reject values with newlines that would
# inject extra directives into a systemd unit file (Finding 3).
sanitize_unit_value() {
    local v="$1" field="${2:-field}"
    [[ "$v" != *$'\n'* && "$v" != *$'\r'* ]] \
        || die "unit field '$field' contains a newline — rejected to prevent systemd unit injection"
    printf '%s' "$v"
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

is_known_arch() {
    case "$1" in
        x86_64|aarch64|armv7l|ppc64le|riscv64|s390x) return 0 ;;
        *) return 1 ;;
    esac
}

podman_platform() {
    case "$1" in
        x86_64)  printf 'linux/amd64' ;;
        aarch64) printf 'linux/arm64' ;;
        armv7l)  printf 'linux/arm/v7' ;;
        ppc64le) printf 'linux/ppc64le' ;;
        riscv64) printf 'linux/riscv64' ;;
        s390x)   printf 'linux/s390x' ;;
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
    have "$tool" || die "$tool not found.  Install with:  $(install_hint "$tool")"
}

# Podman version check.  Outputs MAJOR.MINOR on stdout.
podman_version() {
    podman version --format '{{.Client.Version}}' 2>/dev/null \
        | awk -F. '{ printf "%d.%d", $1, $2 }'
}

# Numeric compare: returns 0 if $1 >= $2 (both "MAJOR.MINOR").
version_ge() {
    local a="$1" b="$2"
    local a_maj="${a%.*}" a_min="${a#*.}"
    local b_maj="${b%.*}" b_min="${b#*.}"
    (( a_maj > b_maj )) && return 0
    (( a_maj < b_maj )) && return 1
    (( a_min >= b_min ))
}

require_podman() {
    require_cmd podman
    local v; v="$(podman_version)"
    [[ -n "$v" ]] || die "couldn't determine podman version (podman version --format failed)"
    if ! version_ge "$v" "4.0"; then
        die "podman >= 4.0 required (found $v).  Upgrade with:  $(install_hint podman)"
    fi
    log_debug "podman version $v detected"
}

require_podman_quadlet() {
    require_podman
    local v; v="$(podman_version)"
    if ! version_ge "$v" "4.4"; then
        die "quadlet mode requires podman >= 4.4 (found $v).  Use --manager=plain|pod on older podman,
  or upgrade podman: $(install_hint podman)"
    fi
}

# ─── Rootless gate + preflights ────────────────────────────────────────────
require_rootless() {
    # Refuse to run as root unless --allow-root was passed.  Matches the
    # PLAN.md "prefer rootless, escape hatch via --allow-root" resolution.
    if [[ $EUID -eq 0 && -z "${OPT_ALLOW_ROOT:-}" ]]; then
        die "$LAB_PROG is rootless-first; refusing to run as root.
  Either rerun as a non-root user (preferred), or pass --allow-root to override."
    fi
    if [[ $EUID -eq 0 ]]; then
        log_warn "running rootful (--allow-root).  Rootless preflights will be skipped."
    fi
}

check_subuid_subgid() {
    [[ $EUID -eq 0 ]] && return 0
    local user; user="$(id -un)"
    local subuid_ok=1 subgid_ok=1
    if [[ -r /etc/subuid ]]; then
        # Finding 11: use awk to compare field 1 as a literal string (not a BRE).
        # grep "^${user}:" treats '.' in usernames as "any char", giving false
        # positives (alice.bob would match aliceXbob).
        awk -F: -v u="$user" '$1==u{found=1;exit} END{exit !found}' /etc/subuid \
            || subuid_ok=0
    else
        subuid_ok=0
    fi
    if [[ -r /etc/subgid ]]; then
        awk -F: -v u="$user" '$1==u{found=1;exit} END{exit !found}' /etc/subgid \
            || subgid_ok=0
    else
        subgid_ok=0
    fi
    if (( subuid_ok == 0 || subgid_ok == 0 )); then
        die "rootless podman needs subuid/subgid entries for user '$user'.
  Fix with (as root):
      sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user
  or edit /etc/subuid and /etc/subgid directly, then run:
      podman system migrate"
    fi
}

check_linger_if_quadlet() {
    # Quadlet units die on logout unless lingering is enabled.  Only warn
    # (not fatal) — the user may genuinely want units that only run while
    # logged in.
    [[ $EUID -eq 0 ]] && return 0
    local user; user="$(id -un)"
    if have loginctl; then
        if ! loginctl show-user "$user" -p Linger 2>/dev/null | grep -q 'Linger=yes'; then
            log_warn "loginctl linger is not enabled for '$user'.  Quadlet units will stop on logout.
  Enable with:  loginctl enable-linger $user"
        fi
    fi
}

check_selinux_label() {
    # Return "z" if SELinux is enforcing, empty otherwise.  Used to auto-append
    # a relabel suffix to bind mounts so they work on Fedora/Rocky/Alma.
    # Review M3: default to ":z" (SHARED relabel), not ":Z" (PRIVATE, per-container
    # MCS category).  ":Z" recursively relabels the host tree with a category the
    # host itself can no longer access — mounting a large/shared dir like /usr or
    # /home could lock the host out of its own files.  ":z" is the safer default;
    # a user who truly needs private isolation can write ":Z" explicitly (it is
    # honored — see the `!= *:Z` guard at the call sites).
    if have getenforce; then
        local s; s="$(getenforce 2>/dev/null || true)"
        if [[ "$s" == "Enforcing" ]]; then
            printf 'z'
            return 0
        fi
    fi
    printf ''
}

check_ip_unprivileged_port_start() {
    local min="${1:-1024}"
    [[ $EUID -eq 0 ]] && return 0
    local cur
    if [[ -r /proc/sys/net/ipv4/ip_unprivileged_port_start ]]; then
        cur="$(</proc/sys/net/ipv4/ip_unprivileged_port_start)"
        if (( min < cur )); then
            log_warn "host port $min is below net.ipv4.ip_unprivileged_port_start=$cur;
  rootless podman will refuse to bind.  Lower it with:
      sudo sysctl net.ipv4.ip_unprivileged_port_start=$min"
        fi
    fi
}

detect_rootless_network() {
    # Print 'pasta', 'slirp4netns', or 'unknown' based on podman info.
    [[ $EUID -eq 0 ]] && { printf 'rootful'; return 0; }
    if have podman; then
        local s
        s="$(podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null || true)"
        case "$s" in
            netavark) :;;  # netavark picks pasta/slirp dynamically; probe further
            *) :;;
        esac
        # Alternative probe: look at rootlessNetworkCmd
        local rnc
        rnc="$(podman info --format '{{.Host.RootlessNetworkCmd}}' 2>/dev/null || true)"
        case "$rnc" in
            pasta)       printf 'pasta';       return 0 ;;
            slirp4netns) printf 'slirp4netns'; return 0 ;;
        esac
    fi
    printf 'unknown'
}

# ─── TOML parser abstraction ────────────────────────────────────────────────
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
        die "no TOML parser found.  Install one of:
        $(install_hint yq)        # mikefarah/yq, supports -p toml
   or   pipx install yq           # kislyuk/yq → tomlq
   or   install dasel from https://github.com/tomwright/dasel"
    fi
}

# ─── Naming helpers ────────────────────────────────────────────────────────
container_name_for() {
    # container_name_for LAB_NAME SERVICE_NAME
    printf 'lab-%s-%s' "$1" "$2"
}

pod_name_for() {
    # pod_name_for LAB_NAME POD_NAME
    printf 'lab-%s-pod-%s' "$1" "$2"
}

image_name_for() {
    # image_name_for LAB_NAME SERVICE_NAME  → image tag for auto-built services
    printf 'lab-%s-%s-img' "$1" "$2"
}

# Resolve "name" (ad-hoc, lab=adhoc) or "lab/service" → container name.
_resolve_container_name() {
    local t="$1"
    if [[ "$t" == */* ]]; then
        local lab="${t%%/*}" svc="${t##*/}"
        container_name_for "$lab" "$svc"
    else
        printf 'lab-%s' "$t"
    fi
}

# ─── State dir ─────────────────────────────────────────────────────────────
state_init() {
    install -d -m 0755 "$LAB_STATE_DIR" "$LAB_POD_STATE_DIR"
}

lab_dir() { printf '%s/%s' "$LAB_POD_STATE_DIR" "$1"; }

# Record-what-we-own: symlink a unit file we generated into the lab dir so
# destroy can reverse it.
track_quadlet_link() {
    # track_quadlet_link LAB_NAME UNIT_FILE_ABSPATH
    local lab="$1" unit="$2"
    local d; d="$(lab_dir "$lab")/quadlet-links"
    install -d -m 0755 "$d"
    ln -sfn "$unit" "$d/$(basename -- "$unit")"
}

# ─── Backend: from-chroot ──────────────────────────────────────────────────
backend_from_chroot() {
    # backend_from_chroot CHROOT_PATH IMAGE_TAG USERNS_MODE
    local chroot_path="$1" image_tag="$2" userns="${3:-keep-id}"
    [[ -d "$chroot_path" ]] || die "chroot not found: $chroot_path"
    require_cmd tar

    # Readability preflight: when a chroot was built by `sudo lab-chroot`,
    # it contains root-mode-600 files (/etc/shadow, /root/*, etc.) that
    # an unprivileged tar can't read.  The stream would complete with a
    # half-imported image and a partial-up, which is a nasty surprise.
    # Detect up front and point the user at the clean workaround:
    # lab-chroot export-tarball + the from_tarball service field.
    local unreadable; unreadable="$(
        find "$chroot_path" -xdev \
            -not -path "${chroot_path}/proc/*" \
            -not -path "${chroot_path}/sys/*" \
            -not -path "${chroot_path}/dev/*" \
            ! -type l \
            -not -readable -print -quit 2>/dev/null
    )"
    if [[ -n "$unreadable" ]]; then
        die "chroot '$chroot_path' contains files unreadable by this user
  (first offender: $unreadable).  This usually means the chroot was built
  via 'sudo lab-chroot create', leaving mode-600 root-owned files inside.

  Rootless workaround (recommended):
    sudo phase1-chroot/lab-chroot.sh export-tarball <name> --output /tmp/<name>.tar.gz
  Then reference that file from your TOML via from_tarball instead of
  from_chroot:
    [[service]]
    from_tarball = \"/tmp/<name>.tar.gz\"

  Or, for a quick-and-dirty manual prep:
    sudo tar -C $chroot_path -cpzf /tmp/chroot.tar.gz \\
        --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \\
        --exclude='./run/*'  --exclude='./tmp/*' .
    sudo chown \$(id -u):\$(id -g) /tmp/chroot.tar.gz"
    fi

    # UID-0-owned paths are legal (they'll map into rootless podman's
    # namespace per the userns setting) — just a heads-up.
    if find "$chroot_path" -xdev \
            -not -path "${chroot_path}/proc/*" \
            -not -path "${chroot_path}/sys/*" \
            -not -path "${chroot_path}/dev/*" \
            -uid 0 -print -quit 2>/dev/null | grep -q .; then
        log_warn "chroot contains UID-0-owned paths; rootless import maps these
  into your namespace per userns=$userns.  Adjust with
  --userns=auto-map|host|<raw-uidmap> if something behaves oddly."
    fi

    log_info "tar | podman import → $image_tag  (from $chroot_path, userns=$userns)"
    local tar_owner_flags=(--numeric-owner)
    if [[ "$userns" == "auto-map" ]]; then
        tar_owner_flags=(--owner=0 --group=0)
        log_debug "auto-map: forcing tarball ownership to 0:0"
    fi

    # Stream-on-failure cleanup: if the pipe errors mid-flight we do NOT
    # want a half-imported image lingering.  Remove on any failure path.
    if ! tar -C "$chroot_path" \
            --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
            --exclude='./run/*'  --exclude='./tmp/*' \
            --exclude='./.lab-chroot-mounts' \
            "${tar_owner_flags[@]}" -c . \
          | podman import - "$image_tag" >/dev/null; then
        podman image rm "$image_tag" >/dev/null 2>&1 || true
        die "from-chroot import failed; partial image removed."
    fi
    log_info "imported: $image_tag"
}

# ─── Backend: from-tarball ─────────────────────────────────────────────────
# Rootless-clean alternative to from_chroot: the user (or Phase 1's
# export-tarball helper) has already produced a self-contained,
# user-readable tarball — just import it directly.
backend_from_tarball() {
    # backend_from_tarball TARBALL_PATH IMAGE_TAG
    local tarball="$1" image_tag="$2"
    [[ -r "$tarball" ]] || die "tarball not readable: $tarball"
    log_info "podman import → $image_tag  (from $tarball)"
    if ! podman import "$tarball" "$image_tag" >/dev/null; then
        podman image rm "$image_tag" >/dev/null 2>&1 || true
        die "from-tarball import failed; partial image removed."
    fi
    log_info "imported: $image_tag"
}

# ─── Backend: build ────────────────────────────────────────────────────────
backend_build() {
    # backend_build CONTEXT_DIR IMAGE_TAG ARCH
    local context="$1" tag="$2" arch="$3"
    [[ -d "$context" ]] || die "build context not a directory: $context"
    [[ -r "$context/Containerfile" || -r "$context/Dockerfile" ]] \
        || die "no Containerfile or Dockerfile in $context"
    local platform; platform="$(podman_platform "$arch")"
    log_info "podman build: $tag for $platform"
    podman build --platform "$platform" -t "$tag" "$context"
}

# ─── Spec construction ─────────────────────────────────────────────────────
spec_get() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }

# Resolve userns field to its podman-run flag form, or empty if keep-id is
# the effective default for this image source.  Prints:
#   "--userns=keep-id"  for keep-id
#   "--userns=host"     for host
#   ""                   for auto-map (already baked into the image)
#   "--uidmap=... --gidmap=..."  for raw custom
resolve_userns_flags() {
    # resolve_userns_flags MODE ARRAY_NAME
    # Populates caller's ARRAY_NAME with the appropriate --userns/--uidmap
    # flags for MODE.  Uses a nameref so no word-splitting is needed at the
    # call site (Finding 2: the old string-return form let "keep-id --privileged"
    # inject --privileged into podman run via word-splitting).
    local mode="${1:-keep-id}"
    local -n _userns_out="$2"
    _userns_out=()
    case "$mode" in
        keep-id|'')  _userns_out=(--userns=keep-id) ;;
        auto-map)    _userns_out=() ;;
        host)        _userns_out=(--userns=host) ;;
        *)
            # Raw uidmap string: "U1:U2:U3,...". Validate each N:N:N segment
            # before use so an attacker cannot inject flags here (Finding 2).
            local s
            IFS=',' read -ra _parts <<<"$mode"
            for s in "${_parts[@]}"; do
                [[ "$s" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] \
                    || die "invalid uidmap segment '$s' in userns='$mode'; expected N:N:N (e.g. 0:100000:65536)"
                _userns_out+=(--uidmap="$s" --gidmap="$s")
            done
            ;;
    esac
}

# ─── Quadlet unit emission ─────────────────────────────────────────────────
# Write a .container (or .pod) unit to QUADLET_USER_DIR and symlink it into
# the lab's state dir so destroy knows to reverse it.

emit_pod_unit() {
    # emit_pod_unit LAB_NAME POD_NAME PUBLISH_LINES_JSONARRAY
    local lab="$1" pod_name="$2" publish_arr="$3"
    install -d -m 0755 "$QUADLET_USER_DIR"
    local unit="${QUADLET_USER_DIR}/$(pod_name_for "$lab" "$pod_name").pod"
    {
        printf '# Generated by %s %s for lab=%s pod=%s — do not edit by hand.\n' \
            "$LAB_PROG" "$LAB_VERSION" "$lab" "$pod_name"
        printf '[Unit]\nDescription=lab-podman pod %s/%s\n\n' "$lab" "$pod_name"
        printf '[Pod]\n'
        printf 'PodName=%s\n' "$(pod_name_for "$lab" "$pod_name")"
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Finding 3: reject newlines in port strings that would inject unit directives.
            printf 'PublishPort=%s\n' "$(sanitize_unit_value "$line" "PublishPort")"
        done < <(jq -r '.[]?' <<<"$publish_arr")
        printf '\n[Install]\nWantedBy=default.target\n'
    } > "$unit"
    track_quadlet_link "$lab" "$unit"
    printf '%s' "$unit"
}

emit_container_unit() {
    # emit_container_unit LAB_NAME SVC_JSON POD_UNIT_PATH_OR_EMPTY
    local lab="$1" svc="$2" pod_unit="${3:-}"
    local sname simage scmd
    sname="$(spec_get "$svc" name)"
    simage="$(spec_get "$svc" image)"
    scmd="$(spec_get "$svc" command)"
    [[ -n "$sname" ]] || die "quadlet: service missing name"
    [[ -n "$simage" ]] || die "quadlet: service '$sname' missing image (quadlet mode does not auto-build)"

    install -d -m 0755 "$QUADLET_USER_DIR"
    local unit="${QUADLET_USER_DIR}/$(container_name_for "$lab" "$sname").container"
    local selinux_suffix; selinux_suffix="$(check_selinux_label)"

    {
        printf '# Generated by %s %s for lab=%s svc=%s\n' \
            "$LAB_PROG" "$LAB_VERSION" "$lab" "$sname"
        printf '[Unit]\nDescription=lab-podman svc %s/%s\n\n' "$lab" "$sname"
        printf '[Container]\n'
        printf 'ContainerName=%s\n' "$(container_name_for "$lab" "$sname")"
        printf 'Image=%s\n' "$(sanitize_unit_value "$simage" "Image")"
        printf 'Label=%s\n' "$LAB_LABEL_TOOL"
        printf 'Label=%s=%s\n' "$LAB_LABEL_LAB" "$lab"
        printf 'Label=%s=%s\n' "$LAB_LABEL_SVC" "$sname"
        if [[ -n "$pod_unit" ]]; then
            printf 'Pod=%s\n' "$(basename -- "$pod_unit")"
        fi
        # PublishPort
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] && printf 'PublishPort=%s\n' "$(sanitize_unit_value "$p" "PublishPort")"
        done < <(jq -r '.ports[]?' <<<"$svc")
        # Volumes (with :Z appended if SELinux enforcing and no :Z/:z/:O already)
        local v
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            # Finding 10: only append :Z to bind-mount specs (those starting
            # with / ./ or ../). Named volumes (e.g. "mydata") have no colon,
            # so appending ":Z" makes podman interpret "Z" as the container
            # path, silently mounting the volume at /Z instead.
            case "$v" in
                /*|./*|../*)
                    if [[ -n "$selinux_suffix" && "$v" != *:Z && "$v" != *:z && "$v" != *:O ]]; then
                        log_warn "SELinux: relabeling '${v%%:*}' with ':${selinux_suffix}' (shared) so the bind mount works; add an explicit ':Z'/':z'/':O' to override"
                        v="${v}:${selinux_suffix}"
                    fi ;;
            esac
            printf 'Volume=%s\n' "$(sanitize_unit_value "$v" "Volume")"
        done < <(jq -r '.volumes[]?' <<<"$svc")
        # Env — Finding 3: sanitize key and value
        local kk vv
        while IFS=$'\t' read -r kk vv; do
            [[ -n "$kk" ]] && printf 'Environment=%s=%s\n' \
                "$(sanitize_unit_value "$kk" "Environment key")" \
                "$(sanitize_unit_value "$vv" "Environment value")"
        done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$svc")
        # Healthcheck
        local hc_cmd hc_interval
        hc_cmd="$(jq -r '.healthcheck.cmd // ""' <<<"$svc")"
        hc_interval="$(jq -r '.healthcheck.interval // ""' <<<"$svc")"
        [[ -n "$hc_cmd" ]] && printf 'HealthCmd=%s\n' "$(sanitize_unit_value "$hc_cmd" "HealthCmd")"
        [[ -n "$hc_interval" ]] && printf 'HealthInterval=%s\n' "$(sanitize_unit_value "$hc_interval" "HealthInterval")"
        # Auto-update
        local au; au="$(spec_get "$svc" autoupdate)"
        [[ -n "$au" ]] && printf 'AutoUpdate=%s\n' "$(sanitize_unit_value "$au" "AutoUpdate")"
        # Command
        if [[ -n "$scmd" ]]; then
            printf 'Exec=%s\n' "$(sanitize_unit_value "$scmd" "Exec")"
        fi
        printf '\n[Service]\nRestart=on-failure\n\n'
        printf '[Install]\nWantedBy=default.target\n'
    } > "$unit"
    track_quadlet_link "$lab" "$unit"
    printf '%s' "$unit"
}

# ─── Service lifecycle helpers ─────────────────────────────────────────────
# Start a service in plain mode (no pod).  Prints the container name.
start_service_plain() {
    local lab="$1" svc="$2"
    local sname simage; sname="$(spec_get "$svc" name)"; simage="$(spec_get "$svc" image)"
    [[ -n "$sname" ]] || die "service missing name"

    local cname; cname="$(container_name_for "$lab" "$sname")"

    # Idempotency: if the container already exists, leave it.
    if podman ps -a --format '{{.Names}}' | grep -qx "$cname"; then
        log_warn "service '$sname' container exists ($cname); leaving as-is"
        printf '%s' "$cname"
        return 0
    fi

    # Resolve image source (image | from_tarball | from_chroot | build).
    if [[ -z "$simage" ]]; then
        local tarball; tarball="$(spec_get "$svc" from_tarball)"
        local chroot;  chroot="$(spec_get "$svc" from_chroot)"
        local ctx;     ctx="$(spec_get "$svc" build)"
        if [[ -n "$tarball" && -n "$chroot" ]]; then
            die "service '$sname': from_tarball and from_chroot are mutually exclusive — pick one"
        fi
        if [[ -n "$tarball" ]]; then
            simage="$(image_name_for "$lab" "$sname")"
            backend_from_tarball "$tarball" "$simage"
        elif [[ -n "$chroot" ]]; then
            local un; un="$(spec_get "$svc" userns)"
            simage="$(image_name_for "$lab" "$sname")"
            backend_from_chroot "$chroot" "$simage" "${un:-keep-id}"
        elif [[ -n "$ctx" ]]; then
            simage="$(image_name_for "$lab" "$sname")"
            backend_build "$ctx" "$simage" "${OPT_ARCH:-$(detect_host_arch)}"
        else
            die "service '$sname': specify one of image | from_tarball | from_chroot | build"
        fi
    fi

    # Build the podman run argv.
    local -a args=(
        --detach
        --label "$LAB_LABEL_TOOL"
        --label "${LAB_LABEL_LAB}=${lab}"
        --label "${LAB_LABEL_SVC}=${sname}"
        --name "$cname"
        --hostname "$sname"
    )

    # userns handling for from-chroot services.
    local from_chroot; from_chroot="$(spec_get "$svc" from_chroot)"
    if [[ -n "$from_chroot" ]]; then
        local un; un="$(spec_get "$svc" userns)"
        local -a un_flags=()
        resolve_userns_flags "${un:-keep-id}" un_flags
        args+=("${un_flags[@]}")
    fi

    # Arch platform override
    local sarch; sarch="$(spec_get "$svc" arch)"
    [[ -z "$sarch" ]] && sarch="${OPT_ARCH:-}"
    [[ -n "$sarch" ]] && args+=(--platform "$(podman_platform "$sarch")")

    # Networks — Finding 7: mapfile array prevents word-split/glob on names.
    local -a svc_nets=()
    mapfile -t svc_nets < <(jq -r '.networks[]?' <<<"$svc")
    local nn n first_net=""
    for n in "${svc_nets[@]}"; do
        nn="lab-${lab}-${n}"
        if [[ -z "$first_net" ]]; then
            args+=(--network "$nn"); first_net="$nn"
        fi
    done

    # Ports, env, volumes
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && args+=(-p "$p")
    done < <(jq -r '.ports[]?' <<<"$svc")
    local kk vv
    while IFS=$'\t' read -r kk vv; do
        [[ -n "$kk" ]] && args+=(-e "${kk}=${vv}")
    done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$svc")
    local selinux_suffix; selinux_suffix="$(check_selinux_label)"
    local v
    while IFS= read -r v; do
        [[ -z "$v" ]] && continue
        if [[ -n "$selinux_suffix" && "$v" != *:Z && "$v" != *:z && "$v" != *:O ]]; then
            log_warn "SELinux: relabeling '${v%%:*}' with ':${selinux_suffix}' (shared) so the bind mount works; add an explicit ':Z'/':z'/':O' to override"
            v="${v}:${selinux_suffix}"
        fi
        args+=(-v "$v")
    done < <(jq -r '.volumes[]?' <<<"$svc")

    # Devices — each becomes `--device SPEC` (host /dev path or a CDI device
    # like nvidia.com/gpu=all for rootless-podman GPU passthrough).
    local dev
    while IFS= read -r dev; do
        [[ -z "$dev" ]] && continue
        validate_device "$dev"
        args+=(--device "$dev")
    done < <(jq -r '.devices[]?' <<<"$svc")

    # Command
    local -a cmd=()
    local cmdline; cmdline="$(jq -r '.command // empty' <<<"$svc")"
    if [[ -n "$cmdline" ]]; then
        read -ra cmd <<<"$cmdline"
    fi

    # Preflight ports
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        local host_port="${p%%:*}"
        [[ "$host_port" =~ ^[0-9]+$ ]] && check_ip_unprivileged_port_start "$host_port"
    done < <(jq -r '.ports[]?' <<<"$svc")

    log_info "starting (plain) service '$sname' as $cname (image=$simage)"
    # Finding 9: env vars may contain secrets; redact their values from debug log.
    log_debug "argv: podman run [${#args[@]} flags, env vars redacted] $simage ${cmd[*]:-}"
    # Finding 13: try-and-handle instead of pre-check to close the TOCTOU race.
    local _run_err
    if ! _run_err="$(podman run "${args[@]}" "$simage" "${cmd[@]}" 2>&1)"; then
        if [[ "$_run_err" == *"already in use"* ]] \
           || podman ps -a --format '{{.Names}}' | grep -qx "$cname"; then
            log_warn "service '$sname' container already exists ($cname); leaving as-is"
        else
            die "failed to start container '$cname': $_run_err"
        fi
    fi

    # Attach any extra networks after start.
    local idx=0
    for n in "${svc_nets[@]}"; do
        nn="lab-${lab}-${n}"
        (( idx > 0 )) && podman network connect "$nn" "$cname" >/dev/null
        idx=$((idx+1))
    done

    printf '%s' "$cname"
}

# Create a pod and start services attached to it.
start_services_in_pod() {
    # start_services_in_pod LAB CFG_JSON POD_JSON
    local lab="$1" cfg="$2" pod="$3"
    local pname; pname="$(spec_get "$pod" name)"
    [[ -n "$pname" ]] || die "pod missing name"
    local pod_cname; pod_cname="$(pod_name_for "$lab" "$pname")"

    # Create the pod if it doesn't exist.
    if podman pod exists "$pod_cname" 2>/dev/null; then
        log_warn "pod '$pname' exists ($pod_cname); leaving as-is"
    else
        local -a pod_args=(
            --label "$LAB_LABEL_TOOL"
            --label "${LAB_LABEL_LAB}=${lab}"
            --label "${LAB_LABEL_POD}=${pname}"
            --name "$pod_cname"
        )
        # Pod-level published ports.
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] && pod_args+=(-p "$p")
            [[ -n "$p" ]] && {
                local hp="${p%%:*}"
                [[ "$hp" =~ ^[0-9]+$ ]] && check_ip_unprivileged_port_start "$hp"
            }
        done < <(jq -r '.publish[]?' <<<"$pod")
        log_info "creating pod '$pname' as $pod_cname"
        podman pod create "${pod_args[@]}" >/dev/null
    fi

    # Start services that reference this pod.
    local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg")"
    local i svc sname cname simage
    for ((i=0; i<svc_count; i++)); do
        svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
        local svc_pod; svc_pod="$(spec_get "$svc" pod)"
        [[ "$svc_pod" != "$pname" ]] && continue
        sname="$(spec_get "$svc" name)"
        cname="$(container_name_for "$lab" "$sname")"
        if podman ps -a --format '{{.Names}}' | grep -qx "$cname"; then
            log_warn "pod service '$sname' exists ($cname); leaving as-is"
            continue
        fi
        simage="$(spec_get "$svc" image)"
        # Resolve image source (image | from_tarball | from_chroot | build) —
        # same logic as plain-mode start_one_service; pod mode was a v0.1 gap.
        if [[ -z "$simage" ]]; then
            local tarball; tarball="$(spec_get "$svc" from_tarball)"
            local chroot;  chroot="$(spec_get "$svc" from_chroot)"
            local ctx;     ctx="$(spec_get "$svc" build)"
            if [[ -n "$tarball" && -n "$chroot" ]]; then
                die "pod service '$sname': from_tarball and from_chroot are mutually exclusive"
            fi
            if [[ -n "$tarball" ]]; then
                simage="$(image_name_for "$lab" "$sname")"
                backend_from_tarball "$tarball" "$simage"
            elif [[ -n "$chroot" ]]; then
                local un; un="$(spec_get "$svc" userns)"
                simage="$(image_name_for "$lab" "$sname")"
                backend_from_chroot "$chroot" "$simage" "${un:-keep-id}"
            elif [[ -n "$ctx" ]]; then
                simage="$(image_name_for "$lab" "$sname")"
                backend_build "$ctx" "$simage" "${OPT_ARCH:-$(detect_host_arch)}"
            else
                die "pod service '$sname': specify one of image | from_tarball | from_chroot | build"
            fi
        fi

        local -a args=(
            --detach
            --pod "$pod_cname"
            --label "$LAB_LABEL_TOOL"
            --label "${LAB_LABEL_LAB}=${lab}"
            --label "${LAB_LABEL_SVC}=${sname}"
            --label "${LAB_LABEL_POD}=${pname}"
            --name "$cname"
        )
        local kk vv
        while IFS=$'\t' read -r kk vv; do
            [[ -n "$kk" ]] && args+=(-e "${kk}=${vv}")
        done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$svc")
        local selinux_suffix; selinux_suffix="$(check_selinux_label)"
        local v
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            # Finding 10: only append :Z to bind-mount specs (those starting
            # with / ./ or ../). Named volumes (e.g. "mydata") have no colon,
            # so appending ":Z" makes podman interpret "Z" as the container
            # path, silently mounting the volume at /Z instead.
            case "$v" in
                /*|./*|../*)
                    if [[ -n "$selinux_suffix" && "$v" != *:Z && "$v" != *:z && "$v" != *:O ]]; then
                        log_warn "SELinux: relabeling '${v%%:*}' with ':${selinux_suffix}' (shared) so the bind mount works; add an explicit ':Z'/':z'/':O' to override"
                        v="${v}:${selinux_suffix}"
                    fi ;;
            esac
            args+=(-v "$v")
        done < <(jq -r '.volumes[]?' <<<"$svc")
        # Devices — same as the plain path: --device per entry (CDI GPU etc.).
        local dev
        while IFS= read -r dev; do
            [[ -z "$dev" ]] && continue
            validate_device "$dev"
            args+=(--device "$dev")
        done < <(jq -r '.devices[]?' <<<"$svc")
        local -a cmd=()
        local cmdline; cmdline="$(jq -r '.command // empty' <<<"$svc")"
        [[ -n "$cmdline" ]] && read -ra cmd <<<"$cmdline"

        log_info "starting (pod=$pname) service '$sname' as $cname (image=$simage)"
        podman run "${args[@]}" "$simage" "${cmd[@]}" >/dev/null
    done
}

# Quadlet: emit units for a lab, reload systemd-user, enable+start services.
start_lab_quadlet() {
    # start_lab_quadlet LAB CFG_JSON
    local lab="$1" cfg="$2"
    require_podman_quadlet
    check_linger_if_quadlet
    require_cmd systemctl

    # Pods first (so container units can reference them).
    local pod_count; pod_count="$(jq -r '.pod // [] | length' <<<"$cfg")"
    local i pod pname pod_unit publish
    for ((i=0; i<pod_count; i++)); do
        pod="$(jq -c --argjson i "$i" '.pod[$i]' <<<"$cfg")"
        pname="$(spec_get "$pod" name)"
        publish="$(jq -c '.publish // []' <<<"$pod")"
        pod_unit="$(emit_pod_unit "$lab" "$pname" "$publish")"
        log_info "wrote $pod_unit"
    done

    # Services (container units).
    local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg")"
    local svc sname svc_pod pod_unit_path unit
    for ((i=0; i<svc_count; i++)); do
        svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
        sname="$(spec_get "$svc" name)"
        svc_pod="$(spec_get "$svc" pod)"
        pod_unit_path=""
        if [[ -n "$svc_pod" ]]; then
            pod_unit_path="${QUADLET_USER_DIR}/$(pod_name_for "$lab" "$svc_pod").pod"
        fi
        unit="$(emit_container_unit "$lab" "$svc" "$pod_unit_path")"
        log_info "wrote $unit"
    done

    log_info "reloading systemd-user"
    systemctl --user daemon-reload

    # Enable + start each container unit.  Quadlet generates <name>.service
    # from <name>.container.
    for ((i=0; i<svc_count; i++)); do
        svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
        sname="$(spec_get "$svc" name)"
        local svc_unit; svc_unit="$(container_name_for "$lab" "$sname").service"
        log_info "systemctl --user start $svc_unit"
        systemctl --user start "$svc_unit" \
            || log_warn "systemctl --user start $svc_unit returned non-zero (check: systemctl --user status $svc_unit)"
    done
}

# Quadlet stop: reverse of start.  Stops each unit, removes the .container
# / .pod files, reloads daemon.
stop_lab_quadlet() {
    local lab="$1"
    local d; d="$(lab_dir "$lab")/quadlet-links"
    [[ -d "$d" ]] || { log_debug "no quadlet links for $lab"; return 0; }

    # Resolve each tracked unit, stop its service, remove file.
    local link target base
    for link in "$d"/*.container; do
        [[ -L "$link" ]] || continue
        target="$(readlink -f "$link")"
        # Finding 15: only delete targets inside QUADLET_USER_DIR so a
        # replaced symlink cannot make 'down' delete arbitrary user files.
        if [[ "$target" != "$QUADLET_USER_DIR"/* ]]; then
            log_warn "refusing to rm unexpected quadlet target: $target (symlink: $link)"
            rm -f "$link"; continue
        fi
        base="$(basename -- "$link" .container)"
        log_info "systemctl --user stop ${base}.service"
        systemctl --user stop "${base}.service" 2>/dev/null || true
        rm -f "$target" "$link"
    done
    for link in "$d"/*.pod; do
        [[ -L "$link" ]] || continue
        target="$(readlink -f "$link")"
        if [[ "$target" != "$QUADLET_USER_DIR"/* ]]; then
            log_warn "refusing to rm unexpected quadlet target: $target (symlink: $link)"
            rm -f "$link"; continue
        fi
        base="$(basename -- "$link" .pod)"
        log_info "systemctl --user stop ${base}-pod.service"
        systemctl --user stop "${base}-pod.service" 2>/dev/null || true
        rm -f "$target" "$link"
    done

    if have systemctl; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    rmdir "$d" 2>/dev/null || true
}

# ─── Subcommand: build ─────────────────────────────────────────────────────
cmd_build() {
    local backend="${OPT_BACKEND:-build}"
    local tag="${OPT_TAG:-}"
    [[ -n "$tag" ]] || die "usage: $LAB_PROG build --tag IMG [--backend build|from-chroot|from-tarball] [--context DIR | --chroot PATH | --tarball FILE] [--arch A]"
    local arch="${OPT_ARCH:-$(detect_host_arch)}"
    is_known_arch "$arch" || die "unknown arch: $arch"

    case "$backend" in
        build|buildx)   backend="build" ;;
        from-chroot)    ;;
        from-tarball)   ;;
        *) die "unknown build backend: $backend" ;;
    esac
    if [[ "$backend" == "from-chroot" ]]; then
        [[ -n "${OPT_CHROOT:-}" ]] || die "--backend from-chroot requires --chroot PATH"
    fi
    if [[ "$backend" == "from-tarball" ]]; then
        [[ -n "${OPT_TARBALL:-}" ]] || die "--backend from-tarball requires --tarball FILE"
    fi

    require_rootless
    require_podman

    case "$backend" in
        build)
            local context="${OPT_CONTEXT:-.}"
            backend_build "$context" "$tag" "$arch"
            ;;
        from-chroot)
            backend_from_chroot "$OPT_CHROOT" "$tag" "${OPT_USERNS:-keep-id}"
            ;;
        from-tarball)
            backend_from_tarball "$OPT_TARBALL" "$tag"
            ;;
    esac
}

# ─── Subcommand: run (ad-hoc single container) ─────────────────────────────
cmd_run() {
    local image="${OPT_IMAGE:-}"
    local name="${OPT_NAME:-}"
    local manager="${OPT_MANAGER:-plain}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG run --name N [--image IMG | --chroot PATH | --tarball FILE | --context DIR] [--manager plain] [opts...]"
    if [[ -z "$image" && -z "${OPT_CHROOT:-}" && -z "${OPT_TARBALL:-}" && -z "${OPT_CONTEXT:-}" ]]; then
        die "need one of: --image IMG | --chroot PATH | --tarball FILE | --context DIR"
    fi
    case "$manager" in
        plain) ;;
        pod|quadlet) die "--manager=$manager is for topology 'up', not ad-hoc 'run'.  Use 'up --config FILE' instead." ;;
        *) die "unknown --manager: $manager (use plain)" ;;
    esac

    require_rootless
    check_subuid_subgid
    require_podman

    # Optional implicit build/import paths.
    if [[ -z "$image" ]]; then
        if [[ -n "${OPT_TARBALL:-}" ]]; then
            image="lab-from-tarball-${name}"
            backend_from_tarball "$OPT_TARBALL" "$image"
        elif [[ -n "${OPT_CHROOT:-}" ]]; then
            image="lab-from-chroot-${name}"
            backend_from_chroot "$OPT_CHROOT" "$image" "${OPT_USERNS:-keep-id}"
        elif [[ -n "${OPT_CONTEXT:-}" ]]; then
            image="lab-build-${name}"
            backend_build "$OPT_CONTEXT" "$image" "${OPT_ARCH:-$(detect_host_arch)}"
        fi
    fi

    local cname; cname="lab-${name}"

    if podman ps -a --format '{{.Names}}' | grep -qx "$cname"; then
        die "container '$cname' already exists.  Destroy it first:  $LAB_PROG destroy $name"
    fi

    local -a args=(
        --label "$LAB_LABEL_TOOL"
        --label "${LAB_LABEL_LAB}=adhoc"
        --label "${LAB_LABEL_SVC}=${name}"
        --name "$cname"
    )

    # userns handling for from-chroot runs
    if [[ -n "${OPT_CHROOT:-}" ]]; then
        local -a un_flags=()
        resolve_userns_flags "${OPT_USERNS:-keep-id}" un_flags
        args+=("${un_flags[@]}")
    fi

    [[ -n "${OPT_ARCH:-}" ]] && args+=(--platform "$(podman_platform "$OPT_ARCH")")
    [[ -n "${OPT_NETWORK:-}" ]] && args+=(--network "$OPT_NETWORK")
    [[ -n "${OPT_HOSTNAME:-}" ]] && args+=(--hostname "$OPT_HOSTNAME")

    local p
    if [[ -n "${OPT_PORTS:-}" ]]; then
        IFS=',' read -ra _ports <<<"$OPT_PORTS"
        for p in "${_ports[@]}"; do
            args+=(-p "$p")
            local hp="${p%%:*}"
            [[ "$hp" =~ ^[0-9]+$ ]] && check_ip_unprivileged_port_start "$hp"
        done
    fi
    local e
    if [[ -n "${OPT_ENV:-}" ]]; then
        # Finding 12: comma-split silently truncates values containing commas.
        # Document: use --env multiple times for values with embedded commas.
        IFS=',' read -ra _envs <<<"$OPT_ENV"
        for e in "${_envs[@]}"; do
            [[ "$e" == *=* ]] || log_warn "env entry '$e' has no '='; if this is part of a value with a comma, use --env multiple times"
            args+=(-e "$e")
        done
    fi
    local v
    if [[ -n "${OPT_VOLUMES:-}" ]]; then
        IFS=',' read -ra _vols <<<"$OPT_VOLUMES"
        local selinux_suffix; selinux_suffix="$(check_selinux_label)"
        for v in "${_vols[@]}"; do
            # Finding 10: only append :Z to bind-mount specs (those starting
            # with / ./ or ../). Named volumes (e.g. "mydata") have no colon,
            # so appending ":Z" makes podman interpret "Z" as the container
            # path, silently mounting the volume at /Z instead.
            case "$v" in
                /*|./*|../*)
                    if [[ -n "$selinux_suffix" && "$v" != *:Z && "$v" != *:z && "$v" != *:O ]]; then
                        log_warn "SELinux: relabeling '${v%%:*}' with ':${selinux_suffix}' (shared) so the bind mount works; add an explicit ':Z'/':z'/':O' to override"
                        v="${v}:${selinux_suffix}"
                    fi ;;
            esac
            args+=(-v "$v")
        done
    fi

    [[ -n "${OPT_DETACH:-}" ]] && args+=(-d)
    [[ -n "${OPT_RM:-}" ]]     && args+=(--rm)
    [[ -n "${OPT_TTY:-}" ]]    && args+=(-it)

    log_info "podman run $cname (image=$image)"
    log_debug "argv: podman run ${args[*]} $image ${EXTRA_ARGS[*]:-}"
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        podman run "${args[@]}" "$image" "${EXTRA_ARGS[@]}"
    else
        podman run "${args[@]}" "$image"
    fi
}

# ─── Subcommand: up (topology) ─────────────────────────────────────────────
cmd_up() {
    [[ -n "${OPT_CONFIG:-}" ]] || die "usage: $LAB_PROG up --config topology.toml"
    require_cmd jq
    require_rootless
    check_subuid_subgid
    require_podman
    state_init

    local cfg_json; cfg_json="$(toml_to_json "$OPT_CONFIG")"

    local lab_name
    lab_name="$(jq -r '.lab.name // ""' <<<"$cfg_json")"
    [[ -n "$lab_name" ]] || die "config missing [lab].name"
    # Finding 1, 4, 16: validate before trap/paths/labels to prevent injection.
    validate_name "$lab_name" "lab name"

    log_info "── bringing up lab '$lab_name' from $OPT_CONFIG ──"
    log_info "rootless network backend: $(detect_rootless_network)"

    install -d -m 0755 "$(lab_dir "$lab_name")"

    # Keep a canonicalized copy of the TOML for export / destroy / status.
    cp -f "$OPT_CONFIG" "$(lab_dir "$lab_name")/spec.toml"

    # Review H4: snapshot the pod/container/network IDs that ALREADY belong to
    # this lab, so the partial-'up' rollback removes ONLY what THIS run creates.
    # `up` is idempotent (existing services are "left as-is"), so an incremental
    # re-'up' that adds one service must NOT tear down the healthy pre-existing
    # instances if the new one fails.
    local -a _PRE_P=() _PRE_C=() _PRE_N=()
    mapfile -t _PRE_P < <(podman pod ls -q \
        --filter "label=${LAB_LABEL_LAB}=${lab_name}" --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
    mapfile -t _PRE_C < <(podman ps -aq \
        --filter "label=${LAB_LABEL_LAB}=${lab_name}" --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
    mapfile -t _PRE_N < <(podman network ls -q \
        --filter "label=${LAB_LABEL_LAB}=${lab_name}" --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
    local _PRE_TOTAL=$(( ${#_PRE_P[@]} + ${#_PRE_C[@]} + ${#_PRE_N[@]} ))

    # Finding 1: named function so lab_name is never eval'd as shell code when
    # the trap fires.  Finding 14: clean up partially-written quadlet units.
    # Review H4: if NOTHING pre-existed this was a fresh 'up' and a full rollback
    # is correct; otherwise (incremental re-'up') remove only the pods/containers/
    # networks that appeared THIS run so a healthy pre-existing lab survives.
    _partial_up_cleanup_4() {
        local _lab="$1" _id
        if (( _PRE_TOTAL == 0 )); then
            log_info "partial 'up' — fresh lab, rolling back '$_lab'"
            stop_lab_quadlet "$_lab" 2>/dev/null || true
            OPT_LAB="$_lab" OPT_CONFIG="" cmd_down 2>/dev/null || true
            return 0
        fi
        local -a _now_p=() _now_c=() _now_n=()
        mapfile -t _now_p < <(podman pod ls -q \
            --filter "label=${LAB_LABEL_LAB}=${_lab}" --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
        mapfile -t _now_c < <(podman ps -aq \
            --filter "label=${LAB_LABEL_LAB}=${_lab}" --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
        mapfile -t _now_n < <(podman network ls -q \
            --filter "label=${LAB_LABEL_LAB}=${_lab}" --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
        for _id in "${_now_p[@]}"; do
            _in_set "$_id" "${_PRE_P[@]}" && continue
            podman pod rm -f "$_id" >/dev/null 2>&1 || true
        done
        for _id in "${_now_c[@]}"; do
            _in_set "$_id" "${_PRE_C[@]}" && continue
            podman rm -f "$_id" >/dev/null 2>&1 || true
        done
        for _id in "${_now_n[@]}"; do
            _in_set "$_id" "${_PRE_N[@]}" && continue
            podman network rm -- "$_id" >/dev/null 2>&1 || true
        done
        log_info "partial 'up': rolled back new resources in lab '$_lab' (pre-existing left intact)"
    }
    trap "_partial_up_cleanup_4 '${lab_name}'" EXIT

    # --- Networks — Finding 7: mapfile array prevents word-split on names ---
    local -a nets=()
    mapfile -t nets < <(jq -r '.network // {} | keys[]?' <<<"$cfg_json")
    local net driver netname
    for net in "${nets[@]}"; do
        driver="$(jq -r --arg n "$net" '.network[$n].driver // "bridge"' <<<"$cfg_json")"
        netname="lab-${lab_name}-${net}"
        if podman network ls --format '{{.Name}}' | grep -qx "$netname"; then
            log_debug "network exists: $netname"
        else
            log_info "creating network: $netname (driver=$driver)"
            podman network create \
                --label "$LAB_LABEL_TOOL" \
                --label "${LAB_LABEL_LAB}=${lab_name}" \
                --driver "$driver" \
                "$netname" >/dev/null
        fi
    done

    # Decide the dominant mode for this lab.  Per-service manager overrides
    # take precedence; absent that, any [[pod]] block forces pod mode,
    # else plain.
    local lab_default_manager; lab_default_manager="$(jq -r '.lab.manager // ""' <<<"$cfg_json")"
    local has_pods; has_pods="$(jq -r '.pod // [] | length' <<<"$cfg_json")"

    # If lab.manager=quadlet or any service has manager=quadlet, take the quadlet path.
    local any_quadlet
    any_quadlet="$(jq -r '
        (.lab.manager // "") as $lab_m
        | [ (.service // [])[] | .manager // "" ] as $svc_ms
        | if $lab_m == "quadlet" or (any($svc_ms[]; . == "quadlet")) then "yes" else "no" end
    ' <<<"$cfg_json")"

    if [[ "$any_quadlet" == "yes" ]]; then
        start_lab_quadlet "$lab_name" "$cfg_json"
    else
        # --- Pods ---
        if (( has_pods > 0 )); then
            local i pod
            for ((i=0; i<has_pods; i++)); do
                pod="$(jq -c --argjson i "$i" '.pod[$i]' <<<"$cfg_json")"
                start_services_in_pod "$lab_name" "$cfg_json" "$pod"
            done
        fi

        # --- Plain services (no pod=) ---
        local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg_json")"
        local i svc svc_pod svc_engine svc_name skipped=0
        for ((i=0; i<svc_count; i++)); do
            svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg_json")"
            svc_pod="$(spec_get "$svc" pod)"
            [[ -n "$svc_pod" ]] && continue   # handled in pod loop above

            # Cross-phase routing: skip services claimed by Phase 3.
            svc_engine="$(spec_get "$svc" engine)"
            if [[ -n "$svc_engine" && "$svc_engine" != "podman" ]]; then
                svc_name="$(spec_get "$svc" name)"
                log_debug "skipping service '$svc_name' (engine=$svc_engine, not podman)"
                skipped=$((skipped+1))
                continue
            fi

            start_service_plain "$lab_name" "$svc" >/dev/null
        done
        (( skipped > 0 )) && log_info "skipped $skipped service(s) with engine != podman"
    fi

    trap - EXIT

    log_info "── lab '$lab_name' up ──"
    log_info "list:  $LAB_PROG list --lab $lab_name"
    log_info "down:  $LAB_PROG down --lab $lab_name"
}

# ─── Subcommand: down ──────────────────────────────────────────────────────
cmd_down() {
    local lab_name="${OPT_LAB:-}"
    if [[ -z "$lab_name" && -n "${OPT_CONFIG:-}" ]]; then
        require_cmd jq
        lab_name="$(toml_to_json "$OPT_CONFIG" | jq -r '.lab.name // ""')"
    fi
    [[ -n "$lab_name" ]] || die "usage: $LAB_PROG down --lab NAME | --config topology.toml (need a lab name)"
    validate_name "$lab_name" "lab name"
    require_rootless
    require_podman
    state_init

    log_info "── tearing down lab '$lab_name' ──"

    # Quadlet units first (if any).
    stop_lab_quadlet "$lab_name"

    # Pods — Finding 5: mapfile arrays for all ID/name lists.
    local -a pods=()
    mapfile -t pods < <(podman pod ls \
        --filter "label=${LAB_LABEL_LAB}=${lab_name}" \
        --filter "label=${LAB_LABEL_TOOL}" -q 2>/dev/null)
    if (( ${#pods[@]} > 0 )); then
        log_info "stopping/removing ${#pods[@]} pod(s)"
        podman pod stop "${pods[@]}" >/dev/null 2>&1 || true
        podman pod rm   "${pods[@]}" >/dev/null 2>&1 || true
    fi

    # Remaining containers (plain manager).
    local -a ids=()
    mapfile -t ids < <(podman ps -aq \
        --filter "label=${LAB_LABEL_LAB}=${lab_name}" \
        --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
    if (( ${#ids[@]} > 0 )); then
        log_info "stopping/removing ${#ids[@]} container(s)"
        podman stop "${ids[@]}" >/dev/null 2>&1 || true
        podman rm   "${ids[@]}" >/dev/null 2>&1 || true
    fi

    # Networks — network ls -q returns names (not hex IDs); use -- to prevent
    # flag injection from names starting with '-' (Finding 5).
    local -a nids=()
    mapfile -t nids < <(podman network ls -q \
        --filter "label=${LAB_LABEL_LAB}=${lab_name}" \
        --filter "label=${LAB_LABEL_TOOL}" 2>/dev/null)
    if (( ${#nids[@]} > 0 )); then
        log_info "removing ${#nids[@]} network(s)"
        podman network rm -- "${nids[@]}" >/dev/null 2>&1 || true
    fi

    # State dir — Finding 4: sanity-check path before rm -rf.
    local _lab_dir; _lab_dir="$(lab_dir "$lab_name")"
    if [[ -d "$_lab_dir" ]]; then
        local _expected_prefix="$LAB_POD_STATE_DIR"
        [[ "$_lab_dir" == "$_expected_prefix/"* ]] \
            || die "refusing rm -rf: lab dir '$_lab_dir' is outside $LAB_POD_STATE_DIR"
        rm -rf -- "$_lab_dir"
    fi

    log_info "── lab '$lab_name' torn down ──"
}

# ─── Subcommand: exec ──────────────────────────────────────────────────────
cmd_exec() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG exec <name|lab/service> [-- cmd args...]"
    require_rootless
    require_podman
    local cname; cname="$(_resolve_container_name "$target")"
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        podman exec -it "$cname" "${EXTRA_ARGS[@]}"
    else
        podman exec -it "$cname" /bin/sh -c '[ -x /bin/bash ] && exec /bin/bash || exec /bin/sh'
    fi
}

# ─── Subcommand: logs ──────────────────────────────────────────────────────
cmd_logs() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG logs <name|lab/service> [--follow]"
    require_rootless
    require_podman
    local cname; cname="$(_resolve_container_name "$target")"

    # Detect whether this container came from a quadlet unit — if so, logs
    # are in the journal, not podman's stream.  The heuristic: if
    # ${cname}.service exists in systemd-user, prefer journalctl.
    if [[ $EUID -ne 0 ]] && have systemctl \
       && systemctl --user list-unit-files "${cname}.service" --no-legend 2>/dev/null | grep -q .; then
        log_debug "routing logs via journalctl for quadlet unit ${cname}.service"
        if [[ -n "${OPT_FOLLOW:-}" ]]; then
            journalctl --user -u "${cname}.service" -f
        else
            journalctl --user -u "${cname}.service" -n 100
        fi
        return 0
    fi

    if [[ -n "${OPT_FOLLOW:-}" ]]; then
        podman logs -f "$cname"
    else
        podman logs --tail 100 "$cname"
    fi
}

# ─── Subcommand: status ────────────────────────────────────────────────────
cmd_status() {
    local target="${POS_ARGS[0]:-${OPT_LAB:-}}"
    require_rootless
    require_podman

    if [[ -z "$target" ]]; then
        # Dump the podman-side summary.
        printf '── podman info (summary) ──\n'
        podman info --format 'host.hostname: {{.Host.Hostname}}
host.arch:     {{.Host.Arch}}
host.os:       {{.Host.Os}}
network:       {{.Host.NetworkBackend}} / rootless={{.Host.RootlessNetworkCmd}}
storage:       {{.Store.GraphRoot}}' 2>/dev/null || podman info
        return 0
    fi

    # Lab-scoped summary.
    if [[ -d "$(lab_dir "$target")" ]]; then
        printf '── lab: %s ──\n' "$target"
        printf 'state dir: %s\n' "$(lab_dir "$target")"
        printf '\n[containers]\n'
        podman ps -a --filter "label=${LAB_LABEL_LAB}=${target}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}' 2>/dev/null || true
        printf '\n[pods]\n'
        podman pod ls --filter "label=${LAB_LABEL_LAB}=${target}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Name}}\t{{.Status}}\t{{.NumberOfContainers}}' 2>/dev/null || true
        local q; q="$(lab_dir "$target")/quadlet-links"
        if [[ -d "$q" ]]; then
            printf '\n[quadlet units]\n'
            ls -1 "$q" 2>/dev/null || true
        fi
    else
        # Container-scoped: target is a name or lab/svc
        local cname; cname="$(_resolve_container_name "$target")"
        podman ps -a --filter "name=^${cname}$" \
            --format 'Name:    {{.Names}}
Image:   {{.Image}}
Status:  {{.Status}}
Ports:   {{.Ports}}
Created: {{.CreatedAt}}' || die "no container '$cname'"
    fi
}

# ─── Subcommand: list ──────────────────────────────────────────────────────
cmd_list() {
    require_rootless
    require_podman
    if [[ -n "${OPT_LAB:-}" ]]; then
        printf '── lab: %s ──\n' "$OPT_LAB"
        podman ps -a --filter "label=${LAB_LABEL_LAB}=${OPT_LAB}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
        printf '\n[pods]\n'
        podman pod ls --filter "label=${LAB_LABEL_LAB}=${OPT_LAB}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Name}}\t{{.Status}}\t{{.NumberOfContainers}}' || true
        printf '\n[networks]\n'
        podman network ls --filter "label=${LAB_LABEL_LAB}=${OPT_LAB}" --filter "label=${LAB_LABEL_TOOL}" \
            --format 'table {{.Name}}\t{{.Driver}}' || true
        return
    fi
    printf '── all labs (lab-podman-managed only) ──\n'
    podman ps -a --filter "label=${LAB_LABEL_TOOL}" \
        --format 'table {{.Label "lab-create.lab"}}\t{{.Label "lab-create.svc"}}\t{{.Names}}\t{{.Image}}\t{{.Status}}'
    printf '\n[pods]\n'
    podman pod ls --filter "label=${LAB_LABEL_TOOL}" \
        --format 'table {{.Label "lab-create.lab"}}\t{{.Name}}\t{{.Status}}' || true
    printf '\n[networks]\n'
    podman network ls --filter "label=${LAB_LABEL_TOOL}" \
        --format 'table {{.Label "lab-create.lab"}}\t{{.Name}}\t{{.Driver}}' || true
}

# ─── Subcommand: inspect ────────────────────────────────────────────────────
# Single-resource detail report for a container OR a pod.  Folds the
# nested `podman inspect` / `podman pod inspect` output into a stable
# schema_version=1 surface, augmented with Phase 4's extras:
#   - userns mode (from HostConfig.IDMappings)
#   - pod membership (for containers in a pod)
#   - quadlet registration (scans $LAB_POD_STATE_DIR/*/quadlet-links/
#     for a symlink to this resource's .container / .pod unit)
#
# Two output modes:
#   default   → human-readable [labels]/[container|pod]/[state]/[network]/
#               [mounts]/[userns]/[quadlet] sections
#   --json    → one JSON document on stdout, schema_version=1
#
# The top-level `kind` field discriminates: "container" | "pod".  Phase
# 6's TUI branches on this so it doesn't need to guess.
#
# Name resolution mirrors Phase 3: literal name first, then
# `_resolve_container_name` (lab-<lab>-<svc>), then `pod_name_for`
# (lab-<lab>-pod-<name>).  Each form is tried against both container
# AND pod inspect so `demo/ctf-pod` resolves to the pod even if a
# container with that synthesized name doesn't exist.
cmd_inspect() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG inspect <name|lab/service> [--json]"
    require_rootless
    require_podman
    require_cmd jq

    # --- name resolution: try up to three forms × two kinds (container,
    # pod), first hit wins.  Store the resolved (kind, engine_name) pair.
    local kind="" engine_name=""
    local -a candidates=("$target")
    # Short-form rewrites (only add if they differ from the literal).
    local rewrite_c rewrite_p
    rewrite_c="$(_resolve_container_name "$target")"
    [[ "$rewrite_c" != "$target" ]] && candidates+=("$rewrite_c")
    if [[ "$target" == */* ]]; then
        local _lab="${target%%/*}" _name="${target##*/}"
        rewrite_p="$(pod_name_for "$_lab" "$_name")"
        [[ "$rewrite_p" != "$target" && "$rewrite_p" != "$rewrite_c" ]] \
            && candidates+=("$rewrite_p")
    fi

    local cand
    for cand in "${candidates[@]}"; do
        if podman container inspect "$cand" >/dev/null 2>&1; then
            kind=container; engine_name="$cand"; break
        fi
        if podman pod inspect "$cand" >/dev/null 2>&1; then
            kind=pod; engine_name="$cand"; break
        fi
    done
    if [[ -z "$kind" ]]; then
        die "no container or pod matches '$target' (tried: ${candidates[*]})"
    fi

    # --- quadlet detection: scan $LAB_POD_STATE_DIR/*/quadlet-links/
    # for a symlink named "$engine_name.container" or "$engine_name.pod"
    # pointing into $QUADLET_USER_DIR.
    local quadlet_managed=false quadlet_symlink="" quadlet_unit=""
    local ext; [[ "$kind" == "pod" ]] && ext=".pod" || ext=".container"
    if [[ -d "$LAB_POD_STATE_DIR" ]]; then
        local link
        for link in "$LAB_POD_STATE_DIR"/*/quadlet-links/"${engine_name}${ext}"; do
            [[ -L "$link" ]] || continue
            quadlet_managed=true
            quadlet_symlink="$link"
            quadlet_unit="$(readlink -f "$link" 2>/dev/null || printf '%s' "$link")"
            break
        done
    fi

    # --- render via jq ---
    local rendered
    if [[ "$kind" == "container" ]]; then
        rendered="$(podman container inspect "$engine_name" 2>/dev/null | jq -r --arg qm "$quadlet_managed" --arg qs "$quadlet_symlink" --arg qu "$quadlet_unit" '
            .[0] as $c |
            ($c.Config.Labels // {}) as $L |
            {
                schema_version: 1,
                kind: "container",
                name: ($c.Name | sub("^/"; "")),
                labels: {
                    lab:    $L["lab-create.lab"],
                    svc:    $L["lab-create.svc"],
                    pod:    $L["lab-create.pod"],
                    tool:   $L["lab-create.tool"],
                    _other: ($L | with_entries(select(.key | startswith("lab-create.") | not)))
                },
                container: {
                    id:         $c.Id,
                    image:      $c.ImageName,
                    image_id:   $c.Image,
                    command:    ($c.Config.Cmd // $c.Config.Entrypoint // []),
                    created_at: $c.Created
                },
                state: {
                    status:        $c.State.Status,
                    running:       $c.State.Running,
                    started_at:    $c.State.StartedAt,
                    finished_at:   ($c.State.FinishedAt // null),
                    exit_code:     (if $c.State.Running then null else ($c.State.ExitCode // 0) end),
                    restart_count: ($c.RestartCount // 0),
                    pid:           (if ($c.State.Pid // 0) > 0 then $c.State.Pid else null end),
                    health:        (($c.State.Health.Status // "") | if . == "" then null else . end)
                },
                network: {
                    ports: [
                        ($c.NetworkSettings.Ports // {}) | to_entries[]
                        | .key as $port_proto
                        | ($port_proto | split("/")) as $pp
                        | (.value // [])[]?
                        | { container_port: ($pp[0] | tonumber),
                            protocol:       $pp[1],
                            host_ip:        ((.HostIp // "") | if . == "" then null else . end),
                            host_port:      (.HostPort | tonumber) }
                    ],
                    networks: [($c.NetworkSettings.Networks // {}) | keys[]?],
                    ip_addresses: (
                        ($c.NetworkSettings.Networks // {})
                        | with_entries(.value = (.value.IPAddress // null))
                    )
                },
                mounts: [
                    ($c.Mounts // [])[] |
                    { source:      .Source,
                      destination: .Destination,
                      type:        .Type,
                      readonly:    ((.RW // true) | not) }
                ],
                userns: (
                    # podman exposes the userns mode in HostConfig.IDMappings
                    # (UIDMap / GIDMap / UIDMapUser).  When keep-id or
                    # auto-map is active there is an entry; when host-shared
                    # (sharing the host user namespace), both are null.
                    if ($c.HostConfig.IDMappings.UIDMapUser // "") != "" then
                        $c.HostConfig.IDMappings.UIDMapUser
                    elif ($c.HostConfig.IDMappings.UIDMap // []) | length > 0 then
                        "auto"
                    else
                        "host"
                    end
                ),
                pod: ($c.Pod // null | if . == "" then null else . end),
                quadlet: {
                    managed:    ($qm == "true"),
                    unit_path:  (if $qu == "" then null else $qu end),
                    symlink:    (if $qs == "" then null else $qs end)
                }
            }
        ')"
    else
        # Pod schema: no per-container state; aggregate container list.
        rendered="$(podman pod inspect "$engine_name" 2>/dev/null | jq -r --arg qm "$quadlet_managed" --arg qs "$quadlet_symlink" --arg qu "$quadlet_unit" '
            . as $p |
            ($p.Labels // {}) as $L |
            {
                schema_version: 1,
                kind: "pod",
                name: $p.Name,
                labels: {
                    lab:    $L["lab-create.lab"],
                    pod:    $L["lab-create.pod"],
                    tool:   $L["lab-create.tool"],
                    _other: ($L | with_entries(select(.key | startswith("lab-create.") | not)))
                },
                pod: {
                    id:                 $p.Id,
                    status:             $p.State,
                    created_at:         $p.Created,
                    num_containers:     ($p.Containers // [] | length),
                    infra_container_id: ($p.InfraContainerID // null),
                    cgroup_path:        ($p.CgroupPath // null)
                },
                containers: [
                    ($p.Containers // [])[] |
                    { id: .Id, name: .Name, state: .State }
                ],
                network: {
                    ports: [
                        ($p.InfraConfig.PortBindings // {}) | to_entries[]
                        | .key as $port_proto
                        | ($port_proto | split("/")) as $pp
                        | (.value // [])[]?
                        | { container_port: ($pp[0] | tonumber),
                            protocol:       $pp[1],
                            host_ip:        ((.HostIp // "") | if . == "" then null else . end),
                            host_port:      (.HostPort | tonumber) }
                    ],
                    networks: ($p.InfraConfig.Networks // [])
                },
                quadlet: {
                    managed:    ($qm == "true"),
                    unit_path:  (if $qu == "" then null else $qu end),
                    symlink:    (if $qs == "" then null else $qs end)
                }
            }
        ')"
    fi

    if [[ -n "${OPT_JSON:-}" ]]; then
        printf '%s\n' "$rendered"
        return 0
    fi

    # Human-readable rendering — derived from the JSON for consistency.
    printf '[labels]\n'
    printf '  lab            %s\n' "$(jq -r '.labels.lab  // "(none)"' <<<"$rendered")"
    if [[ "$kind" == "container" ]]; then
        printf '  svc            %s\n' "$(jq -r '.labels.svc  // "(none)"' <<<"$rendered")"
    fi
    printf '  pod            %s\n' "$(jq -r '.labels.pod  // "(none)"' <<<"$rendered")"
    printf '  tool           %s\n' "$(jq -r '.labels.tool // "(none)"' <<<"$rendered")"

    if [[ "$kind" == "container" ]]; then
        printf '\n[container]\n'
        printf '  name           %s\n' "$engine_name"
        printf '  id             %s\n' "$(jq -r '.container.id[0:12]' <<<"$rendered")"
        printf '  image          %s\n' "$(jq -r '.container.image' <<<"$rendered")"
        printf '  created_at     %s\n' "$(jq -r '.container.created_at' <<<"$rendered")"
        printf '  pod            %s\n' "$(jq -r '.pod // "—"' <<<"$rendered")"

        printf '\n[state]\n'
        printf '  status         %s\n' "$(jq -r '.state.status' <<<"$rendered")"
        printf '  running        %s\n' "$(jq -r '.state.running' <<<"$rendered")"
        printf '  started_at     %s\n' "$(jq -r '.state.started_at' <<<"$rendered")"
        printf '  finished_at    %s\n' "$(jq -r '.state.finished_at // "—"' <<<"$rendered")"
        printf '  exit_code      %s\n' "$(jq -r '.state.exit_code   // "—"' <<<"$rendered")"
        printf '  restart_count  %s\n' "$(jq -r '.state.restart_count' <<<"$rendered")"
        printf '  pid            %s\n' "$(jq -r '.state.pid    // "—"' <<<"$rendered")"
        printf '  health         %s\n' "$(jq -r '.state.health // "—"' <<<"$rendered")"

        printf '\n[userns]\n  %s\n' "$(jq -r '.userns' <<<"$rendered")"
    else
        printf '\n[pod]\n'
        printf '  name           %s\n' "$engine_name"
        printf '  id             %s\n' "$(jq -r '.pod.id[0:12]' <<<"$rendered")"
        printf '  status         %s\n' "$(jq -r '.pod.status' <<<"$rendered")"
        printf '  num_containers %s\n' "$(jq -r '.pod.num_containers' <<<"$rendered")"
        printf '  created_at     %s\n' "$(jq -r '.pod.created_at' <<<"$rendered")"
        printf '  infra_id       %s\n' "$(jq -r '.pod.infra_container_id[0:12] // "—"' <<<"$rendered")"

        printf '\n[containers in pod]\n'
        while IFS=$'\t' read -r cid cname cstate; do
            [[ -z "$cid" ]] && continue
            printf '  %s  %-30s  %s\n' "${cid:0:12}" "$cname" "$cstate"
        done < <(jq -r '.containers[]? | "\(.id)\t\(.name)\t\(.state)"' <<<"$rendered")
    fi

    printf '\n[network]\n'
    local nets; nets="$(jq -r '.network.networks | (if type == "array" then join(", ") else (. | keys | join(", ")) end)' <<<"$rendered")"
    [[ -n "$nets" ]] && printf '  networks       %s\n' "$nets"
    if [[ "$kind" == "container" ]]; then
        while IFS=$'\t' read -r net ip; do
            [[ -z "$net" ]] && continue
            printf '  ip[%s]        %s\n' "$net" "${ip:-—}"
        done < <(jq -r '.network.ip_addresses | to_entries[]? | "\(.key)\t\(.value // "—")"' <<<"$rendered")
    fi
    # jq emits "-" for empty host_ip so bash `read` doesn't collapse
    # adjacent tabs (tab is IFS whitespace → consecutive tabs merge).
    while IFS=$'\t' read -r cport proto hip hport; do
        [[ -z "$cport" ]] && continue
        [[ "$hip" == "-" ]] && hip="0.0.0.0"
        printf '  port           %s/%s → %s:%s\n' "$cport" "$proto" "$hip" "$hport"
    done < <(jq -r '.network.ports[]? | "\(.container_port)\t\(.protocol)\t\((.host_ip // "") | if . == "" or . == null then "-" else . end)\t\(.host_port)"' <<<"$rendered")

    if [[ "$kind" == "container" ]] && jq -e '.mounts | length > 0' <<<"$rendered" >/dev/null; then
        printf '\n[mounts]\n'
        local src dst type ro tag
        while IFS=$'\t' read -r src dst type ro; do
            [[ -z "$src" ]] && continue
            tag=""; [[ "$ro" == "true" ]] && tag=", ro"
            printf '  %s → %s (%s%s)\n' "$src" "$dst" "$type" "$tag"
        done < <(jq -r '.mounts[] | "\(.source)\t\(.destination)\t\(.type)\t\(.readonly)"' <<<"$rendered")
    fi

    if jq -e '.quadlet.managed' <<<"$rendered" >/dev/null; then
        printf '\n[quadlet]\n'
        printf '  unit_path      %s\n' "$(jq -r '.quadlet.unit_path' <<<"$rendered")"
        printf '  symlink        %s\n' "$(jq -r '.quadlet.symlink' <<<"$rendered")"
    fi
}

# ─── Subcommand: destroy ───────────────────────────────────────────────────
cmd_destroy() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG destroy <name|lab/service> [--force]"
    require_rootless
    require_podman

    if [[ -z "${OPT_FORCE:-}" ]]; then
        printf 'About to destroy: %s\nProceed? [y/N] ' "$target" >&2
        read -r ans </dev/tty || true
        case "$ans" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
    fi

    local cname; cname="$(_resolve_container_name "$target")"
    # Review M2: only destroy containers THIS tool manages (carry the
    # lab-create.tool label) — `down` is label-scoped, so `destroy` must be too.
    # Review L2: read owned names into a var (pipefail-safe) and match with
    # `grep -Fxq` so a '.' in a name is literal, not a regex wildcard.
    local _owned; _owned="$(podman ps -a --filter "label=${LAB_LABEL_TOOL}" \
        --format '{{.Names}}' 2>/dev/null || true)"
    if grep -Fxq "$cname" <<<"$_owned"; then
        log_info "stop+rm $cname"
        podman stop "$cname" >/dev/null 2>&1 || true
        podman rm   "$cname" >/dev/null 2>&1 || true
    elif podman container exists "$cname"; then
        die "refusing to destroy '$cname': not managed by $LAB_PROG (no ${LAB_LABEL_TOOL} label)"
    else
        die "no container named $cname"
    fi
    log_info "destroyed: $cname"
}

# ─── Subcommand: export ────────────────────────────────────────────────────
# _yaml_str VALUE — emit VALUE as a double-quoted YAML string with
# internal double-quotes escaped (Finding 8).
_yaml_str() { printf '"%s"' "${1//\"/\\\"}"; }

cmd_export() {
    local lab="${OPT_LAB:-${POS_ARGS[0]:-}}"
    local fmt="${OPT_FORMAT:-kube}"
    [[ -n "$lab" ]] || die "usage: $LAB_PROG export <lab> --format {kube|compose}"
    require_rootless
    require_podman

    case "$fmt" in
        kube)
            # Prefer generating from a pod if one exists; fall back to
            # running containers.
            local pod; pod="$(podman pod ls --filter "label=${LAB_LABEL_LAB}=${lab}" --filter "label=${LAB_LABEL_TOOL}" --format '{{.Name}}' | head -1)"
            if [[ -n "$pod" ]]; then
                log_debug "kube-generate from pod $pod"
                podman kube generate "$pod"
            else
                local ids
                ids="$(podman ps -aq --filter "label=${LAB_LABEL_LAB}=${lab}" --filter "label=${LAB_LABEL_TOOL}")"
                [[ -n "$ids" ]] || die "no resources found for lab '$lab'"
                # shellcheck disable=SC2086
                podman kube generate $ids
            fi
            ;;
        compose)
            # Synthesize compose YAML from the stored spec.toml.
            # Emits: services (image, container_name, ports, environment,
            # volumes, command, healthcheck, depends_on), networks, volumes.
            require_cmd jq
            local spec; spec="$(lab_dir "$lab")/spec.toml"
            [[ -r "$spec" ]] || die "no spec.toml for lab '$lab' (was it brought up via 'up --config'?)"
            local cfg; cfg="$(toml_to_json "$spec")"
            # Pass 1: collect named volumes for top-level declaration.
            local -A named_volumes=()
            local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg")"
            local i svc sname
            for ((i=0; i<svc_count; i++)); do
                svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
                local vol_src
                while IFS= read -r vol_src; do
                    [[ -z "$vol_src" ]] && continue
                    case "$vol_src" in /*|./*|../*) : ;; *) named_volumes["$vol_src"]=1 ;; esac
                done < <(jq -r '.volumes[]? | split(":")[0]' <<<"$svc")
            done
            printf 'version: "3.9"\n'
            printf 'services:\n'
            local simage
            for ((i=0; i<svc_count; i++)); do
                svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
                sname="$(spec_get "$svc" name)"
                simage="$(spec_get "$svc" image)"
                # Finding 8: quote YAML keys and values to prevent injection.
                printf '  %s:\n' "$(_yaml_str "$sname")"
                [[ -n "$simage" ]] && printf '    image: %s\n' "$simage"
                printf '    container_name: %s\n' "$(container_name_for "$lab" "$sname")"
                local p first=1
                while IFS= read -r p; do
                    [[ -z "$p" ]] && continue
                    if (( first )); then printf '    ports:\n'; first=0; fi
                    printf '      - "%s"\n' "$p"
                done < <(jq -r '.ports[]?' <<<"$svc")
                first=1
                local kk vv
                while IFS=$'\t' read -r kk vv; do
                    [[ -z "$kk" ]] && continue
                    if (( first )); then printf '    environment:\n'; first=0; fi
                    printf '      %s: "%s"\n' "$kk" "$vv"
                done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$svc")
                first=1
                local vol
                while IFS= read -r vol; do
                    [[ -z "$vol" ]] && continue
                    if (( first )); then printf '    volumes:\n'; first=0; fi
                    printf '      - "%s"\n' "$vol"
                done < <(jq -r '.volumes[]?' <<<"$svc")
                local cmdline; cmdline="$(jq -r '.command // empty' <<<"$svc")"
                [[ -n "$cmdline" ]] && printf '    command: %s\n' "$cmdline"
                # healthcheck — emitted when .healthcheck.cmd is set.
                local hc_cmd; hc_cmd="$(jq -r '.healthcheck.cmd // ""' <<<"$svc")"
                if [[ -n "$hc_cmd" ]]; then
                    printf '    healthcheck:\n'
                    # Use jq to JSON-escape the healthcheck string (Finding 8).
                    printf '      test: %s\n' "$(jq -n --arg t "$hc_cmd" '["CMD-SHELL",$t]')"
                    local hc_interval; hc_interval="$(jq -r '.healthcheck.interval // ""' <<<"$svc")"
                    local hc_timeout;  hc_timeout="$(jq -r  '.healthcheck.timeout  // ""' <<<"$svc")"
                    local hc_retries;  hc_retries="$(jq -r  '.healthcheck.retries  // ""' <<<"$svc")"
                    [[ -n "$hc_interval" ]] && printf '      interval: %s\n' "$hc_interval"
                    [[ -n "$hc_timeout"  ]] && printf '      timeout: %s\n'  "$hc_timeout"
                    [[ -n "$hc_retries"  ]] && printf '      retries: %s\n'  "$hc_retries"
                fi
                # depends_on — condition: service_healthy when dep has healthcheck.
                first=1
                local dep dep_hc
                while IFS= read -r dep; do
                    [[ -z "$dep" ]] && continue
                    if (( first )); then printf '    depends_on:\n'; first=0; fi
                    dep_hc="$(jq -r --arg d "$dep" \
                        '.service[]? | select(.name==$d) | .healthcheck.cmd // ""' <<<"$cfg")"
                    if [[ -n "$dep_hc" ]]; then
                        printf '      %s:\n        condition: service_healthy\n' "$(_yaml_str "$dep")"
                    else
                        printf '      %s:\n        condition: service_started\n' "$(_yaml_str "$dep")"
                    fi
                done < <(jq -r '.depends_on // [] | .[]?' <<<"$svc")
            done
            printf 'networks:\n'
            local -a exp_nets=()
            mapfile -t exp_nets < <(jq -r '.network // {} | keys[]?' <<<"$cfg")
            if (( ${#exp_nets[@]} == 0 )); then
                printf '  default:\n    driver: bridge\n'
            else
                local net
                for net in "${exp_nets[@]}"; do
                    local d; d="$(jq -r --arg n "$net" '.network[$n].driver // "bridge"' <<<"$cfg")"
                    printf '  %s:\n    driver: %s\n' "$(_yaml_str "$net")" "$d"
                done
            fi
            # Declare named volumes referenced by any service.
            if (( ${#named_volumes[@]} > 0 )); then
                printf 'volumes:\n'
                local vn
                for vn in "${!named_volumes[@]}"; do printf '  %s:\n' "$vn"; done
            fi
            ;;
        *)
            die "unknown export format: $fmt (use kube|compose)"
            ;;
    esac
}

# ─── Subcommand: generate (quadlet units, don't run) ───────────────────────
cmd_generate() {
    [[ -n "${OPT_CONFIG:-}" ]] || die "usage: $LAB_PROG generate --config topology.toml"
    require_cmd jq
    require_rootless
    require_podman_quadlet
    state_init

    local cfg; cfg="$(toml_to_json "$OPT_CONFIG")"
    local lab; lab="$(jq -r '.lab.name // ""' <<<"$cfg")"
    [[ -n "$lab" ]] || die "config missing [lab].name"

    install -d -m 0755 "$(lab_dir "$lab")"
    cp -f "$OPT_CONFIG" "$(lab_dir "$lab")/spec.toml"

    # Emit pods + container units (same as start_lab_quadlet minus the
    # systemctl start step).
    local pod_count; pod_count="$(jq -r '.pod // [] | length' <<<"$cfg")"
    local i pod pname publish pod_unit
    for ((i=0; i<pod_count; i++)); do
        pod="$(jq -c --argjson i "$i" '.pod[$i]' <<<"$cfg")"
        pname="$(spec_get "$pod" name)"
        publish="$(jq -c '.publish // []' <<<"$pod")"
        pod_unit="$(emit_pod_unit "$lab" "$pname" "$publish")"
        log_info "wrote $pod_unit"
    done

    local svc_count; svc_count="$(jq -r '.service // [] | length' <<<"$cfg")"
    local svc sname svc_pod pod_unit_path unit
    for ((i=0; i<svc_count; i++)); do
        svc="$(jq -c --argjson i "$i" '.service[$i]' <<<"$cfg")"
        sname="$(spec_get "$svc" name)"
        svc_pod="$(spec_get "$svc" pod)"
        pod_unit_path=""
        if [[ -n "$svc_pod" ]]; then
            pod_unit_path="${QUADLET_USER_DIR}/$(pod_name_for "$lab" "$svc_pod").pod"
        fi
        unit="$(emit_container_unit "$lab" "$svc" "$pod_unit_path")"
        log_info "wrote $unit"
    done

    log_info "── quadlet units generated for lab '$lab' ──"
    log_info "next: systemctl --user daemon-reload && systemctl --user start <unit>"
    log_info "   or: $LAB_PROG up --config $OPT_CONFIG   (to generate + start)"
}

# ─── CLI parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG $LAB_VERSION — rootless podman container & lab management (LAB_CREATE_V2 phase 4)

USAGE
  $LAB_PROG build    --tag IMG  [--backend build|from-chroot|from-tarball] [--context DIR | --chroot PATH | --tarball FILE] [--arch A]
  $LAB_PROG run      --name N   [--image IMG | --chroot PATH | --tarball FILE | --context DIR] [opts...]
  $LAB_PROG up       --config topology.toml
  $LAB_PROG down     --lab NAME | --config topology.toml
  $LAB_PROG exec     <name|lab/service> [-- cmd args...]
  $LAB_PROG logs     <name|lab/service> [--follow]      # routes to journalctl for quadlet mode
  $LAB_PROG status   [<name|lab>]
  $LAB_PROG list     [--lab NAME]
  $LAB_PROG inspect  <name|lab/service> [--json]
  $LAB_PROG destroy  <name|lab/service> [--force]
  $LAB_PROG export   <lab>  --format {kube|compose}
  $LAB_PROG generate --config topology.toml              # quadlet units, don't run
  $LAB_PROG version | help

BUILD / RUN OPTIONS
  --tag       IMAGE_TAG
  --backend   {build|from-chroot|from-tarball}
  --context   PATH                       # for --backend build
  --chroot    PATH                       # for --backend from-chroot (chroot must be readable!)
  --tarball   PATH                       # for --backend from-tarball (rootless-clean path)
  --userns    MODE                       # keep-id (default) | auto-map | host | "<uidmap-string>"
  --arch      {x86_64|aarch64|armv7l|ppc64le|riscv64|s390x}
  --image     IMAGE_TAG
  --name      CONTAINER_NAME
  --manager   {plain|pod|quadlet}        # run: plain only; up: all three
  --network   NET
  --hostname  H
  --ports     "8080:80,5432:5432"
  --env       "K1=V1,K2=V2"
  --volumes   "src:dst,src2:dst2"
  --detach                               (run: -d)
  --rm                                   (run: --rm)
  --tty                                  (run: -it)
  --follow                               (logs: -f)
  --lab       NAME
  --config    FILE
  --format    {kube|compose}             (export)
  --force                                (destroy)
  --allow-root                           rootless-first gate escape hatch

ENVIRONMENT
  LAB_LOG_LEVEL  debug|info|warn|error  (default: info)
  LAB_STATE_DIR  override the default state-dir location

EXAMPLES
  $LAB_PROG run  --name nginx1 --image docker.io/library/nginx:alpine --ports 8080:80 --detach
  $LAB_PROG up   --config examples/podman-examples/podman-pod-3svc.toml
  $LAB_PROG generate --config examples/podman-examples/podman-quadlet-service.toml
  $LAB_PROG export demo --format kube    > demo.yaml
  $LAB_PROG build --tag mykali --backend from-chroot --chroot /var/chroots/kali-amd64 --userns keep-id
EOF
}

POS_ARGS=()
EXTRA_ARGS=()

parse_args() {
    OPT_CONFIG=""
    OPT_TAG="" OPT_BACKEND="" OPT_CONTEXT="" OPT_CHROOT="" OPT_TARBALL="" OPT_USERNS=""
    OPT_NAME="" OPT_IMAGE="" OPT_ARCH=""
    OPT_MANAGER=""
    OPT_NETWORK="" OPT_HOSTNAME=""
    OPT_PORTS="" OPT_ENV="" OPT_VOLUMES=""
    OPT_DETACH="" OPT_RM="" OPT_TTY=""
    OPT_FOLLOW=""
    OPT_LAB=""
    OPT_FORCE=""
    OPT_FORMAT=""
    OPT_ALLOW_ROOT=""
    OPT_JSON=""

    [[ $# -eq 0 ]] && { usage; exit 0; }
    SUBCMD="$1"; shift

    local seen_doubledash=0
    while [[ $# -gt 0 ]]; do
        if (( seen_doubledash )); then EXTRA_ARGS+=("$1"); shift; continue; fi
        case "$1" in
            --)             seen_doubledash=1; shift ;;
            --config)       OPT_CONFIG="$2"; shift 2 ;;
            --tag)          OPT_TAG="$2"; shift 2 ;;
            --backend)      OPT_BACKEND="$2"; shift 2 ;;
            --context)      OPT_CONTEXT="$2"; shift 2 ;;
            --chroot)       OPT_CHROOT="$2"; shift 2 ;;
            --tarball)      OPT_TARBALL="$2"; shift 2 ;;
            --userns)       OPT_USERNS="$2"; shift 2 ;;
            --name)         OPT_NAME="$2"; shift 2 ;;
            --image)        OPT_IMAGE="$2"; shift 2 ;;
            --arch)         OPT_ARCH="$2"; shift 2 ;;
            --manager)      OPT_MANAGER="$2"; shift 2 ;;
            --network)      OPT_NETWORK="$2"; shift 2 ;;
            --hostname)     OPT_HOSTNAME="$2"; shift 2 ;;
            --ports)        OPT_PORTS="$2"; shift 2 ;;
            --env)          OPT_ENV="$2"; shift 2 ;;
            --volumes)      OPT_VOLUMES="$2"; shift 2 ;;
            --detach|-d)    OPT_DETACH=1; shift ;;
            --rm)           OPT_RM=1; shift ;;
            --tty|-t)       OPT_TTY=1; shift ;;
            --follow|-f)    OPT_FOLLOW=1; shift ;;
            --lab)          OPT_LAB="$2"; shift 2 ;;
            --force)        OPT_FORCE=1; shift ;;
            --format)       OPT_FORMAT="$2"; shift 2 ;;
            --json)         OPT_JSON=1; shift ;;
            --allow-root)   OPT_ALLOW_ROOT=1; shift ;;
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
        build)    cmd_build    ;;
        run)      cmd_run      ;;
        up)       cmd_up       ;;
        down)     cmd_down     ;;
        exec)     cmd_exec     ;;
        logs)     cmd_logs     ;;
        status)   cmd_status   ;;
        list)     cmd_list     ;;
        inspect)  cmd_inspect  ;;
        destroy)  cmd_destroy  ;;
        export)   cmd_export   ;;
        generate) cmd_generate ;;
        help)     usage        ;;
        version)  printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)        usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

# Run main only when executed directly, not when sourced (lets the unit tests
# source this file and exercise helpers like validate_device in isolation).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
