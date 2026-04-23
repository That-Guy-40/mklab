#!/usr/bin/env bash
# lab-lxd.sh — Phase 5 of LAB_CREATE_V2: LXD/Incus system containers + VMs.
#
# Engine    : auto-detect — prefer `incus` (active fork), fall back to `lxc` (LXD).
#             Both share the seven CLI verbs we care about (launch, exec, stop,
#             delete, image import, list, config show), so a single $LXC_CMD
#             binding drives both.
# Backends  : upstream     — pull from an upstream image server.  Versioned
#                            aliases (`images:alpine/3.23`) work directly;
#                            `images:alpine/latest` and bare `images:alpine`
#                            are rewritten to the highest stable X.Y at run
#                            time (LXD has no native "latest" alias).
#             from-chroot  — rebundle a Phase-1 chroot into LXD's unified
#                            tarball format (./metadata.yaml + ./rootfs/) and
#                            `image import` it. Container images only in v0.1.
#             from-tarball — same, but starting from Phase-1's `export-tarball`
#                            output (rootless-clean path).
#             from-qcow2   — wrap a prebuilt qcow2 as an LXD VM image
#                            (./metadata.yaml + ./rootfs.img) and import. The
#                            documented bridge for chroot → VM via Phase 2.
# Types     : container | vm  (LXD treats both as instances; --vm flag selects)
#
# Self-contained per the per-phase rule: helpers from earlier phases are
# duplicated inline. Do not source files from sibling phases.
#
# Lab ownership is tracked on instances via the user.* config namespace:
#   user.lab-create.tool = lab-lxd
#   user.lab-create.lab  = <lab-name>
#   user.lab-create.svc  = <instance-name>
# `down`/`destroy`/`list` operate by querying these — the cached spec.toml in
# $LAB_STATE_DIR is only consulted by `export`.

set -euo pipefail
shopt -s nullglob

readonly LAB_VERSION="0.1.0"
readonly LAB_PROG="${0##*/}"

# user. prefix is mandatory — LXD restricts free-form keys to the user.*
# namespace.  Storing the equals-form is convenient for `config get`/`set`
# composition; the value is split off when filtering.
readonly LAB_LABEL_TOOL_KEY="user.lab-create.tool"
readonly LAB_LABEL_TOOL_VAL="lab-lxd"
readonly LAB_LABEL_LAB_KEY="user.lab-create.lab"
readonly LAB_LABEL_SVC_KEY="user.lab-create.svc"

LAB_STATE_DIR="${LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create}"
readonly LAB_LXD_STATE_DIR="${LAB_STATE_DIR}/lxd"

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
    have "$tool" || die "$tool not found.  Install with:  $(install_hint "$tool")"
}

# ─── Engine dispatch (incus preferred, lxc fallback) ───────────────────────
LXC_CMD=""
LXC_ENGINE=""    # "incus" or "lxd"
LXC_GROUP=""     # group name to check membership against

probe_engine() {
    # Prefer Incus when it's both installed AND reachable; otherwise fall
    # back to LXD.  A bare `have incus` test isn't enough — many distros
    # ship the package but leave the daemon down or restrict the socket
    # to incus-admin.  Probe each candidate's `info` call to settle which
    # binary actually works for THIS user, NOW.
    local incus_status="" lxc_status=""
    if have incus; then
        if incus info >/dev/null 2>&1; then incus_status=ok
        else incus_status=fail
        fi
    fi
    if have lxc; then
        if lxc info >/dev/null 2>&1; then lxc_status=ok
        else lxc_status=fail
        fi
    fi

    if [[ "$incus_status" == "ok" ]]; then
        LXC_CMD="incus"; LXC_ENGINE="incus"; LXC_GROUP="incus-admin"
        log_debug "engine: incus (reachable)"
    elif [[ "$lxc_status" == "ok" ]]; then
        LXC_CMD="lxc"; LXC_ENGINE="lxd"; LXC_GROUP="lxd"
        if [[ "$incus_status" == "fail" ]]; then
            log_info "incus binary present but daemon not reachable; using lxc (LXD) instead"
        fi
        log_debug "engine: lxd (reachable)"
    elif [[ -z "$incus_status" && -z "$lxc_status" ]]; then
        die "neither 'incus' nor 'lxc' found on PATH.
        Install one of:
          $(install_hint incus)        # newer; preferred
          $(install_hint lxd-installer) # Ubuntu's wrapper for snap-based LXD"
    else
        # Both installed but neither reachable, OR exactly one installed
        # and unreachable.  Surface the actual error from each candidate.
        local msg="no reachable LXD/Incus daemon."
        if [[ "$incus_status" == "fail" ]]; then
            msg+="
        incus is installed but failed; underlying error:
          $(incus info 2>&1 | head -3 | sed 's/^/          /')
        Fix:  sudo systemctl start incus    AND    sudo usermod -aG incus-admin \$USER"
        fi
        if [[ "$lxc_status" == "fail" ]]; then
            msg+="
        lxc is installed but failed; underlying error:
          $(lxc info 2>&1 | head -3 | sed 's/^/          /')
        Fix:  sudo systemctl start snap.lxd.daemon    AND    sudo usermod -aG lxd \$USER"
        fi
        die "$msg"
    fi
}

require_lxd_or_incus() {
    [[ -n "$LXC_CMD" ]] || probe_engine
    # probe_engine already verified `info` works for the chosen binary, so
    # nothing else to validate here besides the group hint.
    check_group_membership
}

check_group_membership() {
    [[ $EUID -eq 0 ]] && return 0   # root sidesteps the group
    local groups; groups="$(id -Gn 2>/dev/null || true)"
    if ! grep -qw "$LXC_GROUP" <<<"$groups"; then
        log_warn "you are not in group '$LXC_GROUP'; LXD/Incus operations may fail.
        Fix once with:
          sudo usermod -aG $LXC_GROUP \$USER
          newgrp $LXC_GROUP    # or log out and back in"
    fi
}

# ─── State dir helpers ──────────────────────────────────────────────────────
state_init() {
    install -d -m 0755 "$LAB_LXD_STATE_DIR"
}
lab_dir() { printf '%s/%s' "$LAB_LXD_STATE_DIR" "$1"; }

# ─── TOML parser abstraction (same fallback chain as Phases 3/4) ───────────
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

# Single-key extractor on a JSON-encoded TOML object.
spec_get() { jq -r --arg k "$2" '.[$k] // ""' <<<"$1"; }

# ─── Naming helpers ─────────────────────────────────────────────────────────
instance_name_for() { printf 'lab-%s-%s' "$1" "$2"; }      # lab, svc
image_alias_for()   { printf 'lab-%s-%s-img' "$1" "$2"; }  # lab, svc

# Resolve "name" or "lab/svc" → instance name.
_resolve_instance_name() {
    local t="$1"
    if [[ "$t" == */* ]]; then
        local lab="${t%%/*}" svc="${t##*/}"
        printf 'lab-%s-%s' "$lab" "$svc"
    else
        printf 'lab-%s' "$t"
    fi
}

# ─── Image-source resolution ────────────────────────────────────────────────
# LXD's `images:` simplestreams remote does NOT publish a `latest` or
# `current` alias for Alpine — `images:alpine`, `images:alpine/latest`, and
# `images:alpine/current` all 404.  The closest thing is `images:alpine/edge`
# (rolling dev branch) or version-numbered aliases like `images:alpine/3.23`.
#
# To give users a "give me the newest stable" knob without pinning, Phase 5
# accepts the convention `images:alpine/latest` and rewrites it at run time
# to whichever stable `alpine/X.Y` alias is currently the highest semver on
# the simplestreams remote.  Same trick for `images:debian/latest`,
# `images:ubuntu/latest`, etc. — distro-agnostic.
#
# `images:alpine` (no slash) is also rewritten to the same target.
#
# resolve_image SRC → echoes the resolved image string; returns SRC unchanged
# if no resolution is needed.
resolve_image() {
    local src="$1"
    local distro=""
    case "$src" in
        images:*/latest)
            # images:alpine/latest → distro=alpine
            distro="${src#images:}"
            distro="${distro%/latest}"
            ;;
        images:*/*)
            # images:alpine/3.21 (or alpine/edge, alpine/3.21/cloud, …) —
            # already pinned to a specific alias, leave alone.
            printf '%s\n' "$src"; return 0
            ;;
        images:*)
            # bare `images:alpine` (no slash after the colon)
            distro="${src#images:}"
            ;;
        *)
            # Not an `images:` reference (e.g. local alias or a different
            # remote like `ubuntu:` — those have their own conventions).
            printf '%s\n' "$src"; return 0
            ;;
    esac
    local resolved
    resolved="$(_resolve_distro_latest "$distro")"
    if [[ -z "$resolved" ]]; then
        # Resolver couldn't pin a version; fall back to the original (the
        # subsequent `lxc launch` will 404 with a clear LXD error).
        printf '%s\n' "$src"; return 0
    fi
    log_info "resolved $src → images:${distro}/${resolved}"
    printf 'images:%s/%s\n' "$distro" "$resolved"
}

# Query the images: remote for the highest non-edge X.Y alias of <distro>.
# Returns just the version (e.g. "3.23"), empty string on error.
_resolve_distro_latest() {
    local distro="$1"
    [[ -n "$LXC_CMD" ]] || probe_engine
    "$LXC_CMD" image list "images:${distro}/" --format=json 2>/dev/null \
        | jq -r --arg d "$distro" '
            .[] | .aliases[]?.name
            | select(test("^" + $d + "/[0-9]+(\\.[0-9]+)?$"))
            | sub("^" + $d + "/"; "")
        ' 2>/dev/null \
        | sort -V \
        | tail -1
}

# ─── Engine filter (cross-phase) ───────────────────────────────────────────
# Returns 0 if the service spec belongs to Phase 5 (engine unset, "lxd", or
# "incus"); 1 otherwise.  Letting both names pass means recipes copied from
# either ecosystem work without rewriting.
engine_is_ours() {
    local engine="$1"
    case "$engine" in
        ""|lxd|incus) return 0 ;;
        *)            return 1 ;;
    esac
}

# ─── Image-rebundle helpers ────────────────────────────────────────────────
# LXD's `image import` accepts a unified tarball that has metadata.yaml AND
# rootfs/ (or rootfs.img for VMs) at the *top level*.  Phase 1's
# `export-tarball` produces a flat tree (./etc, ./usr, …) so Phase 5
# rebundles before importing.

# Emit a metadata.yaml string for a container image.
# args: arch_canonical (x86_64/aarch64/...) os release
emit_metadata_yaml_container() {
    local arch="$1" os="$2" release="$3"
    cat <<EOF
architecture: $arch
creation_date: $(date +%s)
properties:
  os: $os
  release: $release
  architecture: $arch
  description: $os $release $arch (lab-create import)
EOF
}

# Same for VM images.  LXD distinguishes via the `type` property and the
# rootfs.img filename rather than rootfs/ directory.
emit_metadata_yaml_vm() {
    local arch="$1" os="$2" release="$3"
    cat <<EOF
architecture: $arch
creation_date: $(date +%s)
properties:
  os: $os
  release: $release
  architecture: $arch
  description: $os $release $arch (lab-create VM import)
  type: virtual-machine
EOF
}

# ─── Backend: from-chroot (container image) ────────────────────────────────
# Build a unified tarball from a chroot tree and import.  The chroot must be
# readable by the invoking user — we run a readability preflight identical to
# Phase 3/4 so the failure is descriptive rather than a tar EACCES storm.
backend_from_chroot() {
    local chroot_path="$1" image_alias="$2"
    [[ -d "$chroot_path" ]] || die "from-chroot: not a directory: $chroot_path"

    log_info "preflight: scanning $chroot_path for unreadable files"
    local unreadable
    unreadable="$(
        find "$chroot_path" -xdev \
            -not -path "${chroot_path}/proc/*" \
            -not -path "${chroot_path}/sys/*" \
            -not -path "${chroot_path}/dev/*" \
            -not -readable -print -quit 2>/dev/null
    )"
    if [[ -n "$unreadable" ]]; then
        die "chroot '$chroot_path' contains files unreadable by this user
       (first hit: $unreadable).
       Phase 1 chroots built via 'sudo lab-chroot create' are root-owned;
       use the rootless-clean path instead:
         sudo phase1-chroot/lab-chroot.sh export-tarball <name> --output /tmp/<name>.tar.gz
       Then in your TOML use:  from_tarball = \"/tmp/<name>.tar.gz\""
    fi

    local arch; arch="$(detect_host_arch)"
    local distro; distro="$(_detect_chroot_distro "$chroot_path")"
    local release; release="$(_detect_chroot_release "$chroot_path")"

    local workdir; workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    emit_metadata_yaml_container "$arch" "$distro" "$release" > "$workdir/metadata.yaml"

    log_info "rebundling chroot → unified tarball"
    # rootfs/ is a symlink into the chroot so we don't double the disk usage.
    ln -s "$chroot_path" "$workdir/rootfs"
    local out="$workdir/image.tar.gz"
    # -h dereferences the rootfs symlink so its content lands as ./rootfs/
    # in the archive.  Excludes match Phase 1's export-tarball excludes.
    tar -C "$workdir" -h \
        --exclude='./rootfs/proc/*' --exclude='./rootfs/sys/*' \
        --exclude='./rootfs/dev/*'  --exclude='./rootfs/run/*' \
        --exclude='./rootfs/tmp/*'  --exclude='./rootfs/.lab-chroot-mounts' \
        --numeric-owner \
        -czpf "$out" metadata.yaml rootfs

    log_info "importing into $LXC_ENGINE as alias '$image_alias'"
    if ! "$LXC_CMD" image import "$out" --alias "$image_alias" >/dev/null; then
        # Cleanup partial: a half-imported alias would block re-runs.
        "$LXC_CMD" image delete "$image_alias" >/dev/null 2>&1 || true
        die "$LXC_CMD image import failed; partial alias removed"
    fi
    log_info "imported: $image_alias"
}

# ─── Backend: from-tarball (container image) ───────────────────────────────
# Same rebundle step as from-chroot; the input is just a tarball path.
backend_from_tarball() {
    local tarball="$1" image_alias="$2"
    [[ -r "$tarball" ]] || die "from-tarball: not readable: $tarball"

    local workdir; workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    log_info "extracting Phase 1 tarball into staging rootfs/"
    install -d "$workdir/rootfs"
    # Phase 1 tarballs are gzip; --auto-compress would pick the right decoder
    # for other formats too.
    tar -C "$workdir/rootfs" -xpf "$tarball" --numeric-owner

    local arch; arch="$(detect_host_arch)"
    local distro; distro="$(_detect_chroot_distro "$workdir/rootfs")"
    local release; release="$(_detect_chroot_release "$workdir/rootfs")"
    emit_metadata_yaml_container "$arch" "$distro" "$release" > "$workdir/metadata.yaml"

    local out="$workdir/image.tar.gz"
    log_info "rebundling → unified tarball"
    tar -C "$workdir" --numeric-owner -czpf "$out" metadata.yaml rootfs

    log_info "importing into $LXC_ENGINE as alias '$image_alias'"
    if ! "$LXC_CMD" image import "$out" --alias "$image_alias" >/dev/null; then
        "$LXC_CMD" image delete "$image_alias" >/dev/null 2>&1 || true
        die "$LXC_CMD image import failed; partial alias removed"
    fi
    log_info "imported: $image_alias"
}

# ─── Backend: from-qcow2 (VM image) ────────────────────────────────────────
# Wrap a prebuilt qcow2 as an LXD VM image.  The unified VM tarball format
# is metadata.yaml + rootfs.img at root.  This is the documented bridge for
# Phase 2 → Phase 5 (build a bootable qcow2 with `lab-vm from-chroot`, then
# import here as a VM).
backend_from_qcow2() {
    local qcow2="$1" image_alias="$2"
    [[ -r "$qcow2" ]] || die "from-qcow2: not readable: $qcow2"

    local workdir; workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN

    local arch; arch="$(detect_host_arch)"
    emit_metadata_yaml_vm "$arch" "Generic" "qcow2-import" > "$workdir/metadata.yaml"

    log_info "staging qcow2 as rootfs.img"
    cp -f --reflink=auto "$qcow2" "$workdir/rootfs.img"

    local out="$workdir/image.tar.gz"
    log_info "bundling VM image"
    tar -C "$workdir" --numeric-owner -czpf "$out" metadata.yaml rootfs.img

    log_info "importing as VM image alias '$image_alias'"
    if ! "$LXC_CMD" image import "$out" --alias "$image_alias" >/dev/null; then
        "$LXC_CMD" image delete "$image_alias" >/dev/null 2>&1 || true
        die "$LXC_CMD image import failed; partial alias removed"
    fi
    log_info "imported: $image_alias"
}

# Best-effort distro/release detection from a chroot's /etc/os-release.
# Falls back to "linux" / "unknown" — these only land in metadata.yaml's
# `properties` block, which is free-form display text.
_detect_chroot_distro() {
    local root="$1"
    if [[ -r "$root/etc/os-release" ]]; then
        ( . "$root/etc/os-release" 2>/dev/null && printf '%s' "${ID:-linux}" )
    else
        printf 'linux'
    fi
}
_detect_chroot_release() {
    local root="$1"
    if [[ -r "$root/etc/os-release" ]]; then
        ( . "$root/etc/os-release" 2>/dev/null && printf '%s' "${VERSION_CODENAME:-${VERSION_ID:-unknown}}" )
    else
        printf 'unknown'
    fi
}

# ─── Project / profile ensure helpers ──────────────────────────────────────
ensure_project() {
    local proj="$1"
    [[ -n "$proj" ]] || return 0
    if "$LXC_CMD" project show "$proj" >/dev/null 2>&1; then
        log_debug "project exists: $proj"
        return 0
    fi
    log_info "creating project: $proj"
    # Share the default project's profiles + storage volumes by default.
    # Without features.profiles=false, a new project gets its own empty
    # `default` profile and instances launched into it fail with "No root
    # device could be found".  Sharing keeps the root-disk wiring done by
    # `lxd init --auto` reachable from project-scoped instances.  Users
    # who want isolated profiles can still create them explicitly via
    # [[profile]] with project=<name>.
    "$LXC_CMD" project create "$proj" \
        -c features.profiles=false \
        -c features.storage.volumes=false \
        >/dev/null
    "$LXC_CMD" project set "$proj" "$LAB_LABEL_TOOL_KEY" "$LAB_LABEL_TOOL_VAL" >/dev/null
}

# args: profile_spec_json   (full [[profile]] table as a JSON object)
ensure_profile() {
    local prof_json="$1"
    local pname; pname="$(spec_get "$prof_json" name)"
    [[ -n "$pname" ]] || die "[[profile]] missing name"
    local pproj; pproj="$(spec_get "$prof_json" project)"

    local -a scope=()
    [[ -n "$pproj" ]] && scope=(--project "$pproj")

    if "$LXC_CMD" profile show "${scope[@]}" "$pname" >/dev/null 2>&1; then
        log_debug "profile exists: $pname"
        return 0
    fi

    log_info "creating profile: $pname${pproj:+ (project=$pproj)}"
    "$LXC_CMD" profile create "${scope[@]}" "$pname" >/dev/null

    # Apply config.* keys.
    local kk vv
    while IFS=$'\t' read -r kk vv; do
        [[ -z "$kk" ]] && continue
        "$LXC_CMD" profile set "${scope[@]}" "$pname" "$kk" "$vv" >/dev/null
    done < <(jq -r '.config // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$prof_json")

    # Apply devices.
    local dname dconf
    while IFS=$'\t' read -r dname dconf; do
        [[ -z "$dname" ]] && continue
        # dconf is a JSON object {type=..., source=..., …} — flatten to
        # `key=val key=val` for the CLI.
        local -a kvs=()
        local k v
        while IFS=$'\t' read -r k v; do
            [[ -z "$k" ]] && continue
            kvs+=("${k}=${v}")
        done < <(jq -r 'to_entries[]? | "\(.key)\t\(.value)"' <<<"$dconf")
        "$LXC_CMD" profile device add "${scope[@]}" "$pname" "$dname" "${kvs[@]}" >/dev/null
    done < <(jq -c '.devices // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$prof_json")
}

# ─── Subcommand: build ─────────────────────────────────────────────────────
# Standalone image build/import — no instance launch, just produces an
# alias.  For when you want to reuse an image across multiple labs or
# pre-seed a CI cache.
cmd_build() {
    local backend="${OPT_BACKEND:-}"
    local alias="${OPT_ALIAS:-${OPT_TAG:-}}"
    [[ -n "$alias" ]] || die "usage: $LAB_PROG build --alias TAG --backend {upstream|from-chroot|from-tarball|from-qcow2} [--image SRC|--chroot PATH|--tarball PATH|--qcow2 PATH]"

    # Validate enum + required source flag BEFORE touching the daemon — a
    # usage error shouldn't surface as "daemon unreachable".
    case "$backend" in
        upstream|"")
            [[ -n "${OPT_IMAGE:-}" ]] || die "build --backend upstream needs --image SRC (e.g. images:alpine/latest, images:alpine/3.23, images:debian/13)"
            ;;
        from-chroot)
            [[ -n "${OPT_CHROOT:-}" ]] || die "from-chroot needs --chroot PATH"
            ;;
        from-tarball)
            [[ -n "${OPT_TARBALL:-}" ]] || die "from-tarball needs --tarball PATH"
            ;;
        from-qcow2)
            [[ -n "${OPT_QCOW2:-}" ]] || die "from-qcow2 needs --qcow2 PATH"
            ;;
        *)
            die "unknown backend: $backend (use upstream|from-chroot|from-tarball|from-qcow2)"
            ;;
    esac

    require_lxd_or_incus

    case "$backend" in
        upstream|"")
            local resolved_src; resolved_src="$(resolve_image "$OPT_IMAGE")"
            log_info "copying upstream image $resolved_src → local alias $alias"
            "$LXC_CMD" image copy "$resolved_src" local: --alias "$alias" >/dev/null
            ;;
        from-chroot)  backend_from_chroot  "$OPT_CHROOT"  "$alias" ;;
        from-tarball) backend_from_tarball "$OPT_TARBALL" "$alias" ;;
        from-qcow2)   backend_from_qcow2   "$OPT_QCOW2"   "$alias" ;;
    esac
    log_info "── built alias: $alias ──"
}

# ─── Subcommand: run ───────────────────────────────────────────────────────
# Single-instance ad-hoc launch.  Always tagged with our lab labels even
# when [lab] isn't set (treat the bare instance name as a one-row "lab").
cmd_run() {
    local name="${OPT_NAME:-}"
    [[ -n "$name" ]] || die "usage: $LAB_PROG run --name N [--image I | --chroot PATH | --tarball PATH | --qcow2 PATH] [--type container|vm]"

    # Pre-validate: at least one image source must be set, before daemon probe.
    if [[ -z "${OPT_IMAGE:-}" && -z "${OPT_CHROOT:-}" && -z "${OPT_TARBALL:-}" && -z "${OPT_QCOW2:-}" ]]; then
        die "run: specify one of --image | --chroot | --tarball | --qcow2"
    fi

    require_lxd_or_incus

    local type="${OPT_TYPE:-container}"
    local iname; iname="$(instance_name_for "${OPT_LAB:-adhoc}" "$name")"

    local image="${OPT_IMAGE:-}"
    if [[ -z "$image" ]]; then
        local alias; alias="$(image_alias_for "${OPT_LAB:-adhoc}" "$name")"
        if [[ -n "${OPT_CHROOT:-}" ]]; then
            backend_from_chroot "$OPT_CHROOT" "$alias"
            image="$alias"
        elif [[ -n "${OPT_TARBALL:-}" ]]; then
            backend_from_tarball "$OPT_TARBALL" "$alias"
            image="$alias"
        elif [[ -n "${OPT_QCOW2:-}" ]]; then
            [[ "$type" == "vm" ]] || log_warn "from-qcow2 implies --type vm; overriding"
            type="vm"
            backend_from_qcow2 "$OPT_QCOW2" "$alias"
            image="$alias"
        fi
    else
        # Resolve `images:DISTRO/latest` and bare `images:DISTRO`.
        image="$(resolve_image "$image")"
    fi

    local -a launch_args=()
    [[ "$type" == "vm" ]] && launch_args+=(--vm)
    [[ -n "${OPT_PROJECT:-}" ]] && launch_args+=(--project "$OPT_PROJECT")
    [[ -n "${OPT_STORAGE:-}" ]] && launch_args+=(--storage "$OPT_STORAGE")
    [[ -n "${OPT_NETWORK:-}" ]] && launch_args+=(--network "$OPT_NETWORK")

    # Labels at launch time — see cmd_up for rationale.
    launch_args+=(-c "${LAB_LABEL_TOOL_KEY}=${LAB_LABEL_TOOL_VAL}")
    launch_args+=(-c "${LAB_LABEL_LAB_KEY}=${OPT_LAB:-adhoc}")
    launch_args+=(-c "${LAB_LABEL_SVC_KEY}=${name}")

    log_info "launching $type '$iname' (image=$image)"
    "$LXC_CMD" launch "${launch_args[@]}" "$image" "$iname" >/dev/null

    log_info "started: $iname"
}

# ─── Subcommand: up ────────────────────────────────────────────────────────
# Bring up a topology defined in TOML.  Reads [lab], [[project]],
# [[profile]], [[instance]] blocks; cross-engine services are skipped via
# the engine filter so a unified TOML can feed Phase 3 / 4 / 5 in any order.
cmd_up() {
    [[ -n "${OPT_CONFIG:-}" ]] || die "usage: $LAB_PROG up --config topology.toml"
    require_cmd jq
    require_lxd_or_incus
    state_init

    local cfg; cfg="$(toml_to_json "$OPT_CONFIG")"
    local lab_name; lab_name="$(jq -r '.lab.name // ""' <<<"$cfg")"
    [[ -n "$lab_name" ]] || die "config missing [lab].name"
    log_info "── bringing up lab '$lab_name' from $OPT_CONFIG ──"

    install -d -m 0755 "$(lab_dir "$lab_name")"
    cp -f "$OPT_CONFIG" "$(lab_dir "$lab_name")/spec.toml"

    # Partial-up safety net (matches Phase 3's pattern).
    trap "log_warn \"partial 'up' for lab '${lab_name}' — clean up with:  ${LAB_PROG} down --lab ${lab_name}\"" EXIT

    # --- Projects ---
    local proj_count; proj_count="$(jq -r '.project // [] | length' <<<"$cfg")"
    local i pname
    for ((i=0; i<proj_count; i++)); do
        pname="$(jq -r --argjson i "$i" '.project[$i].name // ""' <<<"$cfg")"
        [[ -n "$pname" ]] && ensure_project "$pname"
    done

    # --- Profiles ---
    local prof_count; prof_count="$(jq -r '.profile // [] | length' <<<"$cfg")"
    local prof_json
    for ((i=0; i<prof_count; i++)); do
        prof_json="$(jq -c --argjson i "$i" '.profile[$i]' <<<"$cfg")"
        ensure_profile "$prof_json"
    done

    # --- Instances ---
    local inst_count; inst_count="$(jq -r '.instance // [] | length' <<<"$cfg")"
    [[ "$inst_count" -gt 0 ]] || die "config has no [[instance]] entries"

    local skipped=0
    local handled=0
    for ((i=0; i<inst_count; i++)); do
        local inst; inst="$(jq -c --argjson i "$i" '.instance[$i]' <<<"$cfg")"
        local sname; sname="$(spec_get "$inst" name)"
        [[ -n "$sname" ]] || die "instance[$i] missing name"

        # Engine filter (cross-phase).
        local sengine; sengine="$(spec_get "$inst" engine)"
        if ! engine_is_ours "$sengine"; then
            log_debug "skipping instance '$sname' (engine=$sengine, not lxd/incus)"
            skipped=$((skipped+1))
            continue
        fi

        local iname; iname="$(instance_name_for "$lab_name" "$sname")"

        # Idempotency: leave existing instance alone.
        if "$LXC_CMD" info "$iname" >/dev/null 2>&1; then
            log_warn "instance '$sname' exists ($iname); leaving as-is"
            continue
        fi

        local type; type="$(spec_get "$inst" type)"
        [[ -z "$type" ]] && type="container"
        case "$type" in container|vm) ;; *) die "instance '$sname': unknown type '$type' (use container|vm)" ;; esac

        # Resolve image.
        local image; image="$(spec_get "$inst" image)"
        local from_chroot;  from_chroot="$(spec_get "$inst" from_chroot)"
        local from_tarball; from_tarball="$(spec_get "$inst" from_tarball)"
        local from_qcow2;   from_qcow2="$(spec_get "$inst" from_qcow2)"

        # Mutual exclusion check.
        local sources=0
        [[ -n "$image" ]]        && sources=$((sources+1))
        [[ -n "$from_chroot" ]]  && sources=$((sources+1))
        [[ -n "$from_tarball" ]] && sources=$((sources+1))
        [[ -n "$from_qcow2" ]]   && sources=$((sources+1))
        (( sources == 1 )) || die "instance '$sname': specify exactly one of image | from_chroot | from_tarball | from_qcow2 (got $sources)"

        if [[ -z "$image" ]]; then
            local alias; alias="$(image_alias_for "$lab_name" "$sname")"
            if [[ -n "$from_chroot" ]]; then
                [[ "$type" == "container" ]] || die "instance '$sname': from_chroot is container-only in v0.1 (build a qcow2 in Phase 2 then use from_qcow2 for VM)"
                backend_from_chroot "$from_chroot" "$alias"
            elif [[ -n "$from_tarball" ]]; then
                [[ "$type" == "container" ]] || die "instance '$sname': from_tarball is container-only in v0.1"
                backend_from_tarball "$from_tarball" "$alias"
            elif [[ -n "$from_qcow2" ]]; then
                [[ "$type" == "vm" ]] || die "instance '$sname': from_qcow2 implies type=vm"
                backend_from_qcow2 "$from_qcow2" "$alias"
            fi
            image="$alias"
        else
            # Resolve `images:DISTRO/latest` and bare `images:DISTRO`.
            image="$(resolve_image "$image")"
        fi

        # Build the launch command.
        local -a launch_args=()
        [[ "$type" == "vm" ]] && launch_args+=(--vm)

        local proj; proj="$(spec_get "$inst" project)"
        [[ -n "$proj" ]] && launch_args+=(--project "$proj")

        local storage; storage="$(spec_get "$inst" storage)"
        [[ -n "$storage" ]] && launch_args+=(--storage "$storage")

        # Profiles list — `--profile` may be repeated.
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] && launch_args+=(--profile "$p")
        done < <(jq -r '.profiles[]?' <<<"$inst")

        # Pass labels and per-instance config keys at LAUNCH time, not via
        # post-launch `config set`.  Two reasons:
        #   1. VMs reject incompatible images (e.g. unsigned-for-secureboot)
        #      during creation; setting `security.secureboot=false` after
        #      the fact is too late.
        #   2. Post-launch `config set` against an instance in a non-default
        #      project needs `--project <p>`, which is fiddly to thread.
        #      Launch absorbs `-c` keys correctly under any project scope.
        launch_args+=(-c "${LAB_LABEL_TOOL_KEY}=${LAB_LABEL_TOOL_VAL}")
        launch_args+=(-c "${LAB_LABEL_LAB_KEY}=${lab_name}")
        launch_args+=(-c "${LAB_LABEL_SVC_KEY}=${sname}")
        local kk vv
        while IFS=$'\t' read -r kk vv; do
            [[ -z "$kk" ]] && continue
            launch_args+=(-c "${kk}=${vv}")
        done < <(jq -r '.config // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$inst")

        # Devices via `-d name,key=val,key=val` at launch — same project-
        # scoping benefit as -c.
        local dname dconf
        while IFS=$'\t' read -r dname dconf; do
            [[ -z "$dname" ]] && continue
            local dspec="$dname"
            local k v
            while IFS=$'\t' read -r k v; do
                [[ -z "$k" ]] && continue
                dspec+=",${k}=${v}"
            done < <(jq -r 'to_entries[]? | "\(.key)\t\(.value)"' <<<"$dconf")
            launch_args+=(-d "$dspec")
        done < <(jq -c '.devices // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$inst")

        log_info "launching ${type} '$sname' as $iname (image=$image)"
        "$LXC_CMD" launch "${launch_args[@]}" "$image" "$iname" >/dev/null

        handled=$((handled+1))
    done

    trap - EXIT
    log_info "── lab '$lab_name' up (${handled} ${LXC_ENGINE} instance(s), ${skipped} skipped) ──"
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
    [[ -n "$lab_name" ]] || die "usage: $LAB_PROG down --lab NAME | --config topology.toml"
    require_lxd_or_incus

    log_info "── tearing down lab '$lab_name' ──"

    # Find every instance carrying our lab + tool labels (across all projects).
    local matching; matching="$(_instances_in_lab "$lab_name")"
    if [[ -n "$matching" ]]; then
        local proj iname
        while IFS=$'\t' read -r proj iname; do
            [[ -z "$iname" ]] && continue
            local -a scope=()
            [[ -n "$proj" && "$proj" != "default" ]] && scope=(--project "$proj")
            local proj_tag=""
            [[ -n "$proj" && "$proj" != "default" ]] && proj_tag=" (project=$proj)"
            log_info "stop+delete $iname$proj_tag"
            "$LXC_CMD" stop   "${scope[@]}" "$iname" --force >/dev/null 2>&1 || true
            "$LXC_CMD" delete "${scope[@]}" "$iname" --force >/dev/null 2>&1 || true
        done <<<"$matching"
    fi

    # Clean cached spec.toml; profiles/projects are intentionally left in
    # place (other labs may share them).
    rm -rf "$(lab_dir "$lab_name")"

    log_info "── lab '$lab_name' torn down ──"
}

# Helper: emit one instance per line for instances in $1's lab, formatted
# as `<project>\t<name>` so callers can re-scope `--project`.  Uses
# `--all-projects` so instances in user-defined projects (not just the
# default project) are visible.
_instances_in_lab() {
    local lab="$1"
    "$LXC_CMD" list --all-projects --format=json 2>/dev/null \
        | jq -r --arg lab "$lab" \
            --arg tk "$LAB_LABEL_TOOL_KEY" --arg tv "$LAB_LABEL_TOOL_VAL" \
            --arg lk "$LAB_LABEL_LAB_KEY" \
            '.[]
             | select(.config[$tk] == $tv and .config[$lk] == $lab)
             | "\(.project // "default")\t\(.name)"'
}

# ─── Subcommand: exec ──────────────────────────────────────────────────────
cmd_exec() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG exec <name|lab/service> [-- cmd args...]"
    require_lxd_or_incus
    local iname; iname="$(_resolve_instance_name "$target")"
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        "$LXC_CMD" exec "$iname" -- "${EXTRA_ARGS[@]}"
    else
        "$LXC_CMD" exec "$iname" -- /bin/sh -c '[ -x /bin/bash ] && exec /bin/bash || exec /bin/sh'
    fi
}

# ─── Subcommand: logs ──────────────────────────────────────────────────────
cmd_logs() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG logs <name|lab/service> [--follow]"
    require_lxd_or_incus
    local iname; iname="$(_resolve_instance_name "$target")"
    # `console --show-log` is the LXD/Incus equivalent of `docker logs`.
    if [[ -n "${OPT_FOLLOW:-}" ]]; then
        "$LXC_CMD" console "$iname" --show-log
    else
        # No "tail N lines" knob; show whatever's there.
        "$LXC_CMD" console "$iname" --show-log
    fi
}

# ─── Subcommand: status ────────────────────────────────────────────────────
# Three call shapes (mirrors Phase 3/4):
#   status                  → daemon/host summary
#   status <lab>            → instances + profiles + projects in lab
#   status <name|lab/svc>   → single-instance detail
cmd_status() {
    local target="${POS_ARGS[0]:-${OPT_LAB:-}}"
    require_lxd_or_incus

    if [[ -z "$target" ]]; then
        printf '── %s info (summary) ──\n' "$LXC_ENGINE"
        # Tolerant of consumer-side SIGPIPE under set -o pipefail.
        { "$LXC_CMD" info 2>/dev/null | head -20 || true; } || true
        return 0
    fi

    # Lab-scoped check first.
    local lab_hits; lab_hits="$(_instances_in_lab "$target")"
    local iname; iname="$(_resolve_instance_name "$target")"
    local instance_hit=0
    "$LXC_CMD" info "$iname" >/dev/null 2>&1 && instance_hit=1

    if [[ -n "$lab_hits" ]] && (( ! instance_hit )); then
        printf '── lab: %s ──\n' "$target"
        printf '\n[instances]\n'
        local proj iname
        while IFS=$'\t' read -r proj iname; do
            [[ -z "$iname" ]] && continue
            local -a scope=()
            [[ -n "$proj" && "$proj" != "default" ]] && scope=(--project "$proj")
            "$LXC_CMD" list "${scope[@]}" "$iname" --format=table -c ns4t 2>/dev/null \
                || true
        done <<<"$lab_hits"
        printf '\n[note] profiles and projects are LXD-wide; not filtered by lab\n'
        return 0
    fi

    if (( instance_hit )); then
        "$LXC_CMD" info "$iname"
        return 0
    fi

    die "no lab or instance matches '$target' (tried instance '$iname' and label $LAB_LABEL_LAB_KEY=$target)"
}

# ─── Subcommand: list ──────────────────────────────────────────────────────
cmd_list() {
    require_lxd_or_incus
    # Single code path for both --lab-scoped and all-labs views: grab all
    # tagged instances as JSON, jq-filter, re-table.  Avoids the clustered-
    # column gotcha (-c L only works on clustered LXD) and the row-arithmetic
    # fragility of `lxc list X --format=table | sed -n '2p'` (the data row
    # isn't always at a fixed line number).
    if [[ -n "${OPT_LAB:-}" ]]; then
        printf '── lab: %s ──\n' "$OPT_LAB"
    else
        printf '── all labs (lab-lxd-managed only) ──\n'
    fi
    local out
    out="$("$LXC_CMD" list --all-projects --format=json 2>/dev/null \
        | jq -r --arg tk "$LAB_LABEL_TOOL_KEY" --arg tv "$LAB_LABEL_TOOL_VAL" \
            --arg lk "$LAB_LABEL_LAB_KEY" --arg sk "$LAB_LABEL_SVC_KEY" \
            --arg lab "${OPT_LAB:-}" \
            '["LAB","SVC","NAME","PROJECT","TYPE","STATUS"],
             (.[]
              | select(.config[$tk] == $tv)
              | select($lab == "" or .config[$lk] == $lab)
              | [(.config[$lk] // "-"), (.config[$sk] // "-"),
                 .name, (.project // "default"), .type, .status])
             | @tsv' \
        | column -t -s $'\t' )"
    # Above always prints the header row.  If only the header came back,
    # there were no matches.
    local rows; rows="$(printf '%s\n' "$out" | tail -n +2 | grep -c .)"
    if (( rows == 0 )); then
        printf '(no matching instances)\n'
        return 0
    fi
    printf '%s\n' "$out"
}

# ─── Subcommand: destroy ───────────────────────────────────────────────────
cmd_destroy() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG destroy <name|lab/service> [--force]"
    require_lxd_or_incus

    if [[ -z "${OPT_FORCE:-}" ]]; then
        printf 'About to destroy: %s\nProceed? [y/N] ' "$target" >&2
        read -r ans </dev/tty || true
        case "$ans" in y|Y|yes|YES) ;; *) die "aborted" ;; esac
    fi

    local iname; iname="$(_resolve_instance_name "$target")"
    if "$LXC_CMD" info "$iname" >/dev/null 2>&1; then
        log_info "stop+delete $iname"
        "$LXC_CMD" stop   "$iname" --force >/dev/null 2>&1 || true
        "$LXC_CMD" delete "$iname" --force >/dev/null 2>&1 || true
    else
        die "no instance named $iname"
    fi
    log_info "destroyed: $iname"
}

# ─── Subcommand: export ────────────────────────────────────────────────────
# Dump `$LXC_CMD config show --expanded` for every instance in <lab>,
# concatenated with YAML document separators.  The output is feedable into
# `$LXC_CMD launch --yaml < file` to recreate identical instance config (LXD
# accepts a YAML config blob on stdin via --yaml mode).
cmd_export() {
    local lab="${OPT_LAB:-${POS_ARGS[0]:-}}"
    local fmt="${OPT_FORMAT:-lxc-yaml}"
    [[ -n "$lab" ]] || die "usage: $LAB_PROG export <lab> --format lxc-yaml"
    [[ "$fmt" == "lxc-yaml" ]] || die "unknown export format: $fmt (phase 5 supports: lxc-yaml)"
    require_lxd_or_incus

    local matching; matching="$(_instances_in_lab "$lab")"
    [[ -n "$matching" ]] || die "no instances found for lab '$lab'"

    printf '# generated by %s export from lab %s on %s\n' "$LAB_PROG" "$lab" "$(date -Iseconds)"
    printf '# feed back via: %s launch --yaml < this-file (per-document)\n' "$LXC_CMD"
    local first=1 proj iname
    while IFS=$'\t' read -r proj iname; do
        [[ -z "$iname" ]] && continue
        # bash's `printf` treats `--` as end-of-options, so the literal
        # YAML separator goes through %s rather than as a format string.
        if (( first )); then first=0; else printf '%s\n' '---'; fi
        local proj_tag=""
        [[ -n "$proj" && "$proj" != "default" ]] && proj_tag=" (project=$proj)"
        printf '# instance: %s%s\n' "$iname" "$proj_tag"
        local -a scope=()
        [[ -n "$proj" && "$proj" != "default" ]] && scope=(--project "$proj")
        "$LXC_CMD" config show --expanded "${scope[@]}" "$iname"
    done <<<"$matching"
}

# ─── CLI parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
$LAB_PROG $LAB_VERSION — LXD/Incus container & VM lab management (LAB_CREATE_V2 phase 5)

USAGE
  $LAB_PROG build    --alias TAG --backend {upstream|from-chroot|from-tarball|from-qcow2} [--image|--chroot|--tarball|--qcow2 SRC]
  $LAB_PROG run      --name N    [--image I | --chroot PATH | --tarball PATH | --qcow2 PATH] [--type container|vm]
  $LAB_PROG up       --config topology.toml
  $LAB_PROG down     --lab NAME | --config topology.toml
  $LAB_PROG exec     <name|lab/service> [-- cmd args...]
  $LAB_PROG logs     <name|lab/service> [--follow]
  $LAB_PROG status   [<name|lab>]
  $LAB_PROG list     [--lab NAME]
  $LAB_PROG destroy  <name|lab/service> [--force]
  $LAB_PROG export   <lab> --format lxc-yaml         # dump 'config show --expanded' per instance
  $LAB_PROG version | help

OPTIONS
  --alias     TAG                       (build target)
  --backend   {upstream|from-chroot|from-tarball|from-qcow2}
  --image     SRC                       (upstream image alias OR existing local alias)
  --chroot    PATH                      (Phase 1 chroot tree; must be user-readable)
  --tarball   PATH                      (Phase 1 export-tarball output)
  --qcow2     PATH                      (prebuilt VM disk; from-qcow2 implies --type vm)
  --type      {container|vm}            (default: container)
  --name      INSTANCE_NAME             (run: short name; instance becomes lab-<lab>-<name>)
  --project   P                         (LXD project; created if needed)
  --storage   POOL                      (LXD storage pool)
  --network   NET                       (attach to existing LXD network)
  --profile   PROF                      (single profile; for multiple use [[instance]] profiles=[...])
  --lab       NAME                      (list/down/status: scope to one lab)
  --config    FILE                      (up/down: topology TOML)
  --format    FMT                       (export: lxc-yaml — the only format)
  --follow                              (logs: -f)
  --force                               (destroy/down)

ENVIRONMENT
  LAB_LOG_LEVEL  debug|info|warn|error  (default: info)
  LAB_STATE_DIR  override the default state-dir location

EXAMPLES
  $LAB_PROG run --name a --image images:alpine/latest        # newest stable X.Y, resolved at run time
  $LAB_PROG run --name v --image images:alpine/latest --type vm
  $LAB_PROG run --name p --image images:alpine/3.23          # pin a specific version
  $LAB_PROG build --alias kali-rolling --backend from-chroot --chroot /var/chroots/kali
  $LAB_PROG up   --config examples/lxd-mixed-topology.toml
  $LAB_PROG list --lab demo-lxd
  $LAB_PROG export demo-lxd --format lxc-yaml > demo-lxd.yaml
  $LAB_PROG down --lab demo-lxd
EOF
}

POS_ARGS=()
EXTRA_ARGS=()

parse_args() {
    OPT_CONFIG=""
    OPT_TAG="" OPT_ALIAS="" OPT_BACKEND="" OPT_IMAGE="" OPT_CHROOT="" OPT_TARBALL="" OPT_QCOW2=""
    OPT_NAME="" OPT_TYPE="" OPT_PROJECT="" OPT_STORAGE="" OPT_NETWORK=""
    OPT_LAB="" OPT_FOLLOW="" OPT_FORCE="" OPT_FORMAT=""

    [[ $# -eq 0 ]] && { usage; exit 0; }
    SUBCMD="$1"; shift

    local seen_doubledash=0
    while [[ $# -gt 0 ]]; do
        if (( seen_doubledash )); then EXTRA_ARGS+=("$1"); shift; continue; fi
        case "$1" in
            --)             seen_doubledash=1; shift ;;
            --config)       OPT_CONFIG="$2"; shift 2 ;;
            --alias|--tag)  OPT_ALIAS="$2"; shift 2 ;;
            --backend)      OPT_BACKEND="$2"; shift 2 ;;
            --image)        OPT_IMAGE="$2"; shift 2 ;;
            --chroot)       OPT_CHROOT="$2"; shift 2 ;;
            --tarball)      OPT_TARBALL="$2"; shift 2 ;;
            --qcow2)        OPT_QCOW2="$2"; shift 2 ;;
            --name)         OPT_NAME="$2"; shift 2 ;;
            --type)         OPT_TYPE="$2"; shift 2 ;;
            --project)      OPT_PROJECT="$2"; shift 2 ;;
            --storage)      OPT_STORAGE="$2"; shift 2 ;;
            --network)      OPT_NETWORK="$2"; shift 2 ;;
            --lab)          OPT_LAB="$2"; shift 2 ;;
            --follow|-f)    OPT_FOLLOW=1; shift ;;
            --force)        OPT_FORCE=1; shift ;;
            --format)       OPT_FORMAT="$2"; shift 2 ;;
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
        build)   cmd_build   ;;
        run)     cmd_run     ;;
        up)      cmd_up      ;;
        down)    cmd_down    ;;
        exec)    cmd_exec    ;;
        logs)    cmd_logs    ;;
        status)  cmd_status  ;;
        list)    cmd_list    ;;
        destroy) cmd_destroy ;;
        export)  cmd_export  ;;
        help)    usage       ;;
        version) printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)       usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

main "$@"
