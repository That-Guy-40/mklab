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
#                            tarball format and `image import` it.
#                            type=container: rootless.
#                            type=vm: root-required (loop mounts + extlinux).
#             from-tarball — same, but starting from Phase-1's `export-tarball`
#                            output (rootless-clean for containers; root-required
#                            for VMs).
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
# L-3: validate LAB_STATE_DIR before use so an attacker-controlled env var
# cannot redirect rm -rf to an arbitrary directory.
[[ "$LAB_STATE_DIR" == /* ]] || { printf '%s: LAB_STATE_DIR must be absolute: %s\n' "$0" "$LAB_STATE_DIR" >&2; exit 1; }
[[ "$LAB_STATE_DIR" != *..* ]] || { printf '%s: LAB_STATE_DIR must not contain "..": %s\n' "$0" "$LAB_STATE_DIR" >&2; exit 1; }
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
    # Parse with awk — sourcing /etc/os-release executes shell code.
    if [[ -r /etc/os-release ]]; then
        awk -F= '/^ID=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
            /etc/os-release
    else
        printf 'unknown'
    fi
}

# validate_name NAME [CONTEXT]  — reject chars that could inject into paths,
# label filters, trap strings, or YAML keys (C-1, H-2, L-2).
validate_name() {
    local n="$1" ctx="${2:-name}"
    [[ -n "$n" ]] || die "$ctx is empty"
    [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ ]] \
        || die "invalid $ctx '$n': use only [a-zA-Z0-9._-], start with alphanumeric, max 63 chars"
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
    # M-2: check every argument, not just the first.
    local tool
    for tool in "$@"; do
        have "$tool" || die "$tool not found.  Install with:  $(install_hint "$tool")"
    done
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
#
# Implementation note: `image list images:DISTRO/` (with trailing slash) was
# the old query, but Incus's `images:` (linuxcontainers.org) returns 0 hits
# for that form — it interprets the argument as a literal alias rather than
# a prefix.  The portable filter is the bare positional `<substring>` form,
# which both incus and lxc treat as a substring match across alias names.
# Cache to avoid multiple network round-trips for the same distro (I-3).
declare -gA _DISTRO_LATEST_CACHE=() 2>/dev/null || declare -A _DISTRO_LATEST_CACHE=()

_resolve_distro_latest() {
    local distro="$1"
    # I-3: return memoized result if available.
    if [[ -n "${_DISTRO_LATEST_CACHE[$distro]+x}" ]]; then
        printf '%s' "${_DISTRO_LATEST_CACHE[$distro]}"
        return 0
    fi
    [[ -n "$LXC_CMD" ]] || probe_engine
    local result
    result="$("$LXC_CMD" image list "images:" "$distro" --format=json 2>/dev/null \
        | jq -r --arg d "$distro" '
            # M-4: use startswith/ltrimstr instead of building a regex from $d.
            # Concatenating user-supplied strings into test() is a jq regex
            # injection: "alp.ne" would match "alpXne/3.21" via the . wildcard.
            .[] | .aliases[]?.name
            | select(startswith($d + "/"))
            | ltrimstr($d + "/")
            | select(test("^[0-9]+(\\.[0-9]+)?$"))
        ' 2>/dev/null \
        | sort -V \
        | tail -1)"
    _DISTRO_LATEST_CACHE[$distro]="$result"
    printf '%s' "$result"
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
    # H-4, L-5: strip chars that would inject YAML structure — os/release come
    # from the chroot's os-release file which may be attacker-controlled.
    os="${os//[^a-zA-Z0-9._-]/}"
    release="${release//[^a-zA-Z0-9._-]/}"
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
    # H-4, L-5: same sanitization as container variant.
    os="${os//[^a-zA-Z0-9._-]/}"
    release="${release//[^a-zA-Z0-9._-]/}"
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
            ! -type l \
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

    # Review H3 + trap-shape: stage + import inside a subshell with an EXIT trap,
    # so the workdir is reclaimed on EVERY exit — including `die` (which is
    # `exit`, and would skip a RETURN trap, leaking the staging dir).  The trap
    # is subshell-local, so it cannot clobber cmd_up's EXIT trap (the partial-up
    # rollback).
    (
        local workdir; workdir="$(mktemp -d)"
        trap 'rm -rf "$workdir"' EXIT

        emit_metadata_yaml_container "$arch" "$distro" "$release" > "$workdir/metadata.yaml"

        log_info "rebundling chroot → unified tarball"
        local out="$workdir/image.tar.gz"
        # Review H3: tar the chroot DIRECTLY under a rootfs/ prefix (via
        # --transform).  We do NOT use `tar -h`: -h dereferences EVERY symlink in
        # the tree, which (a) bakes host files into the image through absolute
        # symlinks (host-content disclosure) and (b) aborts the build under
        # set -e on a dangling symlink such as a systemd chroot's
        # /etc/resolv.conf -> /run/... .  Preserving inner symlinks AS symlinks
        # is correct and safe.  Excludes mirror Phase 1's export-tarball excludes,
        # now expressed on chroot-relative paths.  The chroot -C comes first so a
        # relative chroot_path resolves against the original cwd.
        tar --numeric-owner -czpf "$out" \
            --transform='s,^\./,rootfs/,' \
            --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
            --exclude='./run/*'  --exclude='./tmp/*' \
            --exclude='./.lab-chroot-mounts' \
            -C "$chroot_path" . \
            -C "$workdir" metadata.yaml

        log_info "importing into $LXC_ENGINE as alias '$image_alias'"
        if ! "$LXC_CMD" image import "$out" --alias "$image_alias" >/dev/null; then
            # Cleanup partial: a half-imported alias would block re-runs.
            "$LXC_CMD" image delete "$image_alias" >/dev/null 2>&1 || true
            die "$LXC_CMD image import failed; partial alias removed"
        fi
    ) || die "from_chroot: image build/import failed"
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
    # H-3: --no-absolute-names prevents absolute-path members from writing
    # outside the target directory; without it a crafted tarball entry like
    # /etc/cron.d/evil would write to the host /etc/cron.d/evil.
    tar -C "$workdir/rootfs" -xpf "$tarball" --numeric-owner --no-absolute-names

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

# ─── Backend: from-chroot (VM image) ──────────────────────────────────────
# Create a bootable VM disk image from a Phase-1 chroot, then import as an LXD
# VM.  Mirrors the approach of Phase 2's backend_vm_from_chroot (MBR + ext4 +
# extlinux); requires root for loop mounts and mkfs.
#
# Limitations:
#   - Requires EUID=0 (loop-device mounts are root-only)
#   - x86_64 only: uses extlinux (BIOS MBR boot)
#   - Kernel must be pre-installed in the chroot (/boot/vmlinuz-*)
#   - aarch64 / VMs with UEFI boot need a different approach
backend_from_chroot_vm() {
    local chroot_path="$1" image_alias="$2"
    [[ -d "$chroot_path" ]] || die "from-chroot (VM): not a directory: $chroot_path"
    [[ $EUID -eq 0 ]] \
        || die "from-chroot for VMs requires root (loop mounts + mkfs + extlinux).  Re-run under sudo."
    require_cmd qemu-img parted mkfs.ext4 losetup extlinux rsync blkid dd

    # Locate kernel + initrd already installed in the chroot.
    local kernel initrd
    kernel="$(find "$chroot_path/boot" -maxdepth 1 -name 'vmlinuz-*' \
        -not -name '*.old' 2>/dev/null | sort -V | tail -1)"
    [[ -n "$kernel" ]] \
        || die "from-chroot (VM): no /boot/vmlinuz-* found.  Install a kernel in the chroot first:
  sudo lab-chroot.sh enter <name> -- apt-get install -y linux-image-amd64"
    initrd="$(find "$chroot_path/boot" -maxdepth 1 \
        \( -name 'initrd.img-*' -o -name 'initramfs-*' \) 2>/dev/null | sort -V | tail -1)"
    [[ -n "$initrd" ]] \
        || die "from-chroot (VM): no /boot/initrd.img-* found; try: update-initramfs -u -k all"

    # Locate the syslinux MBR blob.
    local mbr_bin=""
    local p
    for p in /usr/lib/syslinux/mbr/mbr.bin /usr/share/syslinux/mbr.bin \
              /usr/lib/syslinux/mbr.bin /usr/lib/extlinux/mbr.bin; do
        [[ -r "$p" ]] && { mbr_bin="$p"; break; }
    done
    [[ -n "$mbr_bin" ]] \
        || die "syslinux MBR binary not found.  Install: apt-get install -y syslinux-common"

    local workdir; workdir="$(mktemp -d)"
    # M-7: register cleanup on RETURN, EXIT, INT, and TERM so that loop
    # devices and mounts are released even when the caller is interrupted.
    # SIGKILL cannot be caught; on kill, manually run:
    #   losetup -a  # find leaked loop devices
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN EXIT INT TERM

    local raw_img="$workdir/disk.raw"
    log_info "creating 20G raw disk image for VM"
    qemu-img create -f raw "$raw_img" 20G >/dev/null

    log_info "partitioning (MBR + single bootable ext4 partition)"
    parted -s "$raw_img" mklabel msdos mkpart primary ext4 1MiB 100% set 1 boot on

    local lodev; lodev="$(losetup --find --partscan --show "$raw_img")"
    # shellcheck disable=SC2064
    trap "losetup -d '$lodev' 2>/dev/null || true; rm -rf '$workdir'" RETURN EXIT INT TERM

    mkfs.ext4 -q "${lodev}p1"
    local mnt="$workdir/mnt"; install -d "$mnt"
    mount "${lodev}p1" "$mnt"
    # shellcheck disable=SC2064
    trap "umount '$mnt' 2>/dev/null || true; losetup -d '$lodev' 2>/dev/null || true; rm -rf '$workdir'" RETURN EXIT INT TERM

    log_info "copying chroot → disk (rsync, preserving perms)"
    rsync -aHAX \
        --exclude=/proc --exclude=/sys --exclude=/dev \
        --exclude=/run  --exclude=/tmp --exclude='.lab-chroot-mounts' \
        "$chroot_path/" "$mnt/"

    # Write /etc/fstab with the root partition UUID.
    local uuid; uuid="$(blkid -s UUID -o value "${lodev}p1")"
    printf 'UUID=%s / ext4 defaults 0 1\n' "$uuid" > "$mnt/etc/fstab"

    # Install extlinux into /boot/extlinux/.
    install -d "$mnt/boot/extlinux"
    extlinux --install "$mnt/boot/extlinux" 2>/dev/null
    # M-3/I-1: removed the dead first extlinux.conf write that used the
    # broken literal pattern ${kernel##*/chroot_path/boot/} (not a variable
    # substitution — chroot_path is never expanded, producing the full kernel
    # path verbatim as the KERNEL line).  Only the correct write below remains.
    local kname; kname="${kernel##*/}"
    local iname_r; iname_r="${initrd##*/}"
    cat > "$mnt/boot/extlinux/extlinux.conf" <<EXTCFG
DEFAULT linux
LABEL linux
  KERNEL /boot/${kname}
  APPEND root=UUID=${uuid} ro console=ttyS0
  INITRD /boot/${iname_r}
EXTCFG

    umount "$mnt"
    dd if="$mbr_bin" of="$lodev" bs=440 count=1 conv=notrunc 2>/dev/null
    losetup -d "$lodev" 2>/dev/null || true
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN EXIT INT TERM   # clean up the rest

    local qcow2="$workdir/disk.qcow2"
    log_info "converting raw → qcow2"
    qemu-img convert -f raw -O qcow2 "$raw_img" "$qcow2" >/dev/null

    log_info "importing as LXD VM image alias '$image_alias'"
    backend_from_qcow2 "$qcow2" "$image_alias"
}

# from-tarball for VM: extract tarball then delegate to from-chroot-vm.
backend_from_tarball_vm() {
    local tarball="$1" image_alias="$2"
    [[ -r "$tarball" ]] || die "from-tarball (VM): not readable: $tarball"
    [[ $EUID -eq 0 ]] \
        || die "from-tarball for VMs requires root (loop mounts).  Re-run under sudo."
    local workdir; workdir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" RETURN
    install -d "$workdir/rootfs"
    log_info "extracting tarball for VM build"
    tar -C "$workdir/rootfs" -xpf "$tarball" --numeric-owner
    backend_from_chroot_vm "$workdir/rootfs" "$image_alias"
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
    # H-1: parse with awk — sourcing os-release from an untrusted chroot or
    # tarball executes arbitrary shell code inside a subshell.
    local root="$1"
    if [[ -r "$root/etc/os-release" ]]; then
        awk -F= '/^ID=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
            "$root/etc/os-release" 2>/dev/null || printf 'linux'
    else
        printf 'linux'
    fi
}
_detect_chroot_release() {
    # H-1: same no-source approach; try VERSION_CODENAME then VERSION_ID.
    local root="$1"
    if [[ -r "$root/etc/os-release" ]]; then
        local val
        val="$(awk -F= '/^VERSION_CODENAME=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
            "$root/etc/os-release" 2>/dev/null)"
        if [[ -z "$val" ]]; then
            val="$(awk -F= '/^VERSION_ID=/{v=$2; gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v); print v; exit}' \
                "$root/etc/os-release" 2>/dev/null)"
        fi
        printf '%s' "${val:-unknown}"
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

    # Apply devices.  dconf is a JSON object {type:..., key:val, …}.
    # `device add` takes the device TYPE positionally; the remaining keys are
    # key=value.  (Outer jq is -r so the name<TAB>value split survives; -c would
    # JSON-quote the whole line and the tab would be escaped, not a separator.)
    local dname dconf
    while IFS=$'\t' read -r dname dconf; do
        [[ -z "$dname" ]] && continue
        local dtype; dtype="$(jq -r '.type // ""' <<<"$dconf")"
        [[ -n "$dtype" ]] || die "profile '$pname' device '$dname': missing 'type'"
        local -a kvs=()
        local k v
        while IFS=$'\t' read -r k v; do
            [[ -z "$k" || "$k" == "type" ]] && continue
            kvs+=("${k}=${v}")
        done < <(jq -r 'to_entries[]? | "\(.key)\t\(.value)"' <<<"$dconf")
        "$LXC_CMD" profile device add "${scope[@]}" "$pname" "$dname" "$dtype" "${kvs[@]}" >/dev/null
    done < <(jq -r '.devices // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$prof_json")
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
    # C-1, H-2: validate before embedding in trap/paths/labels.
    validate_name "$lab_name" "lab name"
    log_info "── bringing up lab '$lab_name' from $OPT_CONFIG ──"

    install -d -m 0755 "$(lab_dir "$lab_name")"
    cp -f "$OPT_CONFIG" "$(lab_dir "$lab_name")/spec.toml"

    # Review H4: snapshot the instances that ALREADY belong to this lab (as
    # `project\tname` lines, across all projects) so the partial-'up' rollback
    # removes ONLY instances THIS run creates.  `up` is idempotent (existing
    # instances are "left as-is"), so an incremental re-'up' that adds one
    # instance must NOT force-delete the healthy pre-existing ones if the new
    # one fails to come up.
    local _PRE_INST; _PRE_INST="$(_instances_in_lab "$lab_name")"

    # C-1: named function so lab_name is never eval'd as shell code when the EXIT
    # trap fires; validate_name above ensures no metacharacters.
    _partial_up_cleanup_5() {
        local _lab="$1"
        local _now; _now="$(_instances_in_lab "$_lab")"
        [[ -n "$_now" ]] || return 0
        local proj iname
        while IFS=$'\t' read -r proj iname; do
            [[ -z "$iname" ]] && continue
            # Skip instances that pre-existed this run (transactional rollback).
            grep -qxF "${proj}"$'\t'"${iname}" <<<"$_PRE_INST" && continue
            local -a scope=()
            [[ -n "$proj" && "$proj" != "default" ]] && scope=(--project "$proj")
            log_info "partial 'up': removing new instance $iname"
            "$LXC_CMD" stop   "${scope[@]}" "$iname" --force >/dev/null 2>&1 || true
            "$LXC_CMD" delete "${scope[@]}" "$iname" --force >/dev/null 2>&1 || true
        done <<<"$_now"
        log_info "partial 'up': new instances rolled back in lab '$_lab' (pre-existing left intact)"
    }
    trap "_partial_up_cleanup_5 '${lab_name}'" EXIT

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
        # L-2: validate before using in instance names, labels, and device specs.
        validate_name "$sname" "instance name"

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
                if [[ "$type" == "vm" ]]; then
                    backend_from_chroot_vm "$from_chroot" "$alias"
                else
                    backend_from_chroot "$from_chroot" "$alias"
                fi
            elif [[ -n "$from_tarball" ]]; then
                if [[ "$type" == "vm" ]]; then
                    backend_from_tarball_vm "$from_tarball" "$alias"
                else
                    backend_from_tarball "$from_tarball" "$alias"
                fi
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

        # NOTE: devices are attached AFTER launch (below), not via `launch -d`.
        # LXD/Incus `launch -d` only *overrides* a device inherited from a
        # profile — it can't add a brand-new one — so new devices go on with
        # `config device add` once the instance exists.

        log_info "launching ${type} '$sname' as $iname (image=$image)"
        # L-4: try-and-handle instead of pre-check to close the TOCTOU race
        # between the earlier `lxc info` idempotency check and the launch.
        local _launch_err
        if ! _launch_err="$("$LXC_CMD" launch "${launch_args[@]}" "$image" "$iname" 2>&1)"; then
            if "$LXC_CMD" info "$iname" >/dev/null 2>&1; then
                log_warn "instance '$iname' appeared concurrently; skipping"
            else
                die "launch of '$iname' failed: $_launch_err"
            fi
        fi

        # Attach devices now that the instance exists.  `device add` takes the
        # device TYPE positionally; the remaining keys are key=value.  A device
        # already present (inherited from a profile, or added on a prior run) is
        # left as-is, so `up` stays idempotent.  (To OVERRIDE an inherited
        # device, attach it through a [[profile]] instead.)
        local -a pscope=(); [[ -n "$proj" ]] && pscope=(--project "$proj")
        local dname dconf
        while IFS=$'\t' read -r dname dconf; do
            [[ -z "$dname" ]] && continue
            if "$LXC_CMD" config device list "${pscope[@]}" "$iname" 2>/dev/null | grep -qx "$dname"; then
                log_debug "instance '$sname': device '$dname' already present; leaving as-is"
                continue
            fi
            local dtype; dtype="$(jq -r '.type // ""' <<<"$dconf")"
            [[ -n "$dtype" ]] || die "instance '$sname' device '$dname': missing 'type'"
            local -a kvs=(); local k v
            while IFS=$'\t' read -r k v; do
                [[ -z "$k" || "$k" == "type" ]] && continue
                kvs+=("${k}=${v}")
            done < <(jq -r 'to_entries[]? | "\(.key)\t\(.value)"' <<<"$dconf")
            "$LXC_CMD" config device add "${pscope[@]}" "$iname" "$dname" "$dtype" "${kvs[@]}" >/dev/null \
                || die "instance '$sname': failed to add device '$dname'"
            log_debug "instance '$sname': added device '$dname' ($dtype)"
        done < <(jq -r '.devices // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$inst")

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
    # H-2, L-2: validate before use in paths and label filters.
    validate_name "$lab_name" "lab name"
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
    # H-2: sanity-check the resolved path stays inside LAB_LXD_STATE_DIR
    # before rm -rf (a traversal in lab_name like ../../home could otherwise
    # delete an arbitrary directory).
    local _lab_dir; _lab_dir="$(realpath -m "$(lab_dir "$lab_name")")"
    [[ "$_lab_dir" == "$LAB_LXD_STATE_DIR"/* ]] \
        || die "refusing rm -rf: '$_lab_dir' is outside $LAB_LXD_STATE_DIR"
    rm -rf -- "$_lab_dir"

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
    # On an interactive session, force a TERM the guest actually has a terminfo
    # entry for. lxc/incus exec propagates the *client's* $TERM, which is often
    # an exotic value (xterm-ghostty, alacritty, kitty, …) the container's
    # terminfo DB doesn't know — which breaks less/vim/man/clear/tput inside.
    # A classic, near-universally-present entry avoids that. Override with
    # LAB_TERM (e.g. LAB_TERM=xterm-256color). Gated on a TTY so the many
    # non-interactive `exec … -- sh -c …` callers (setup scripts, tests) are
    # unaffected.
    local -a env_args=()
    [[ -t 0 ]] && env_args=(--env "TERM=${LAB_TERM:-xterm}")
    if (( ${#EXTRA_ARGS[@]} > 0 )); then
        "$LXC_CMD" exec "${env_args[@]}" "$iname" -- "${EXTRA_ARGS[@]}"
    else
        "$LXC_CMD" exec "${env_args[@]}" "$iname" -- /bin/sh -c '[ -x /bin/bash ] && exec /bin/bash || exec /bin/sh'
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

# ─── Subcommand: inspect ────────────────────────────────────────────────────
# Single-instance detail report — folds `lxc/incus list <name> --all-projects
# --format=json` (which carries the full state, expanded devices, snapshots,
# and network interface details) into a stable schema_version=1 surface.
#
# Two output modes:
#   default   → human-readable [labels]/[instance]/[image]/[state]/[network]/
#               [devices]/[snapshots] sections
#   --json    → one JSON document on stdout, schema_version=1
#
# v0.1 covers `kind: "instance"` only.  Profile and project inspect can
# share the schema (with a discriminator) in a follow-up; the field is
# already in place so future expansion doesn't break the
# schema_version=1 contract.
#
# Name resolution mirrors Phase 3/4: try the literal name first (the
# TUI passes `lab-<lab>-<svc>` directly), then `_resolve_instance_name`
# (which produces the same).  Search across ALL projects via
# `--all-projects` since instances may live outside `default`.
cmd_inspect() {
    local target="${POS_ARGS[0]:-}"
    [[ -n "$target" ]] || die "usage: $LAB_PROG inspect <name|lab/service> [--json]"
    # M-1: reject targets starting with '-' which would be parsed as flags
    # by lxc/incus list/profile show/project show.
    [[ "$target" != -* ]] || die "inspect target must not start with '-': $target"
    require_lxd_or_incus
    require_cmd jq

    # --- name resolution: try the literal first, then the rewrite.
    # M-1: validate_name above rejects targets starting with '-'; lxc list
    # does not support '--' before mixed positional+flag arguments so we
    # rely on the earlier validation rather than adding '--' here.
    local iname=""
    local raw=""
    raw="$("$LXC_CMD" list "$target" --all-projects --format=json 2>/dev/null)"
    if [[ -n "$raw" ]] && [[ "$(jq 'length' <<<"$raw")" -gt 0 ]]; then
        iname="$target"
    else
        local rewrite; rewrite="$(_resolve_instance_name "$target")"
        raw="$("$LXC_CMD" list "$rewrite" --all-projects --format=json 2>/dev/null)"
        if [[ -n "$raw" ]] && [[ "$(jq 'length' <<<"$raw")" -gt 0 ]]; then
            iname="$rewrite"
        fi
    fi
    # --- if no instance matched, try profile then project ---
    if [[ -z "$iname" ]]; then
        # Profile inspect: kind: "profile"
        local prof_yaml; prof_yaml="$("$LXC_CMD" profile show -- "$target" 2>/dev/null || true)"
        if [[ -n "$prof_yaml" ]]; then
            local prof_json; prof_json="$(printf '%s' "$prof_yaml" | \
                if have yq && yq --version 2>&1 | grep -qi mikefarah; then
                    yq -o json
                elif have python3; then
                    python3 -c "import sys,json; import yaml; print(json.dumps(yaml.safe_load(sys.stdin)))" 2>/dev/null
                else
                    echo "{}"
                fi)"
            local rendered_prof; rendered_prof="$(jq -r --arg engine "$LXC_ENGINE" --arg name "$target" '
                {
                    schema_version: 1,
                    kind:           "profile",
                    engine:         $engine,
                    name:           ($name),
                    description:    (.description // ""),
                    config:         (.config     // {}),
                    devices:        (.devices    // {})
                }' <<<"$prof_json")"
            if [[ -n "${OPT_JSON:-}" ]]; then
                printf '%s\n' "$rendered_prof"; return 0
            fi
            printf '[profile]\n'
            printf '  name         %s\n' "$target"
            printf '  description  %s\n' "$(jq -r '.description // "(none)"' <<<"$rendered_prof")"
            local cfg_keys; cfg_keys="$(jq -r '.config | keys[]?' <<<"$rendered_prof")"
            if [[ -n "$cfg_keys" ]]; then
                printf '\n[config]\n'
                while IFS= read -r k; do
                    printf '  %-30s %s\n' "$k" "$(jq -r --arg k "$k" '.config[$k]' <<<"$rendered_prof")"
                done <<<"$cfg_keys"
            fi
            local dev_keys; dev_keys="$(jq -r '.devices | keys[]?' <<<"$rendered_prof")"
            if [[ -n "$dev_keys" ]]; then
                printf '\n[devices]\n'
                while IFS= read -r d; do
                    printf '  %-12s %s\n' "$d" "$(jq -r --arg d "$d" '.devices[$d].type // "—"' <<<"$rendered_prof")"
                done <<<"$dev_keys"
            fi
            return 0
        fi

        # Project inspect: kind: "project"
        local proj_yaml; proj_yaml="$("$LXC_CMD" project show -- "$target" 2>/dev/null || true)"
        if [[ -n "$proj_yaml" ]]; then
            local proj_json; proj_json="$(printf '%s' "$proj_yaml" | \
                if have yq && yq --version 2>&1 | grep -qi mikefarah; then
                    yq -o json
                elif have python3; then
                    python3 -c "import sys,json; import yaml; print(json.dumps(yaml.safe_load(sys.stdin)))" 2>/dev/null
                else
                    echo "{}"
                fi)"
            local rendered_proj; rendered_proj="$(jq -r --arg engine "$LXC_ENGINE" --arg name "$target" '
                {
                    schema_version: 1,
                    kind:           "project",
                    engine:         $engine,
                    name:           ($name),
                    description:    (.description // ""),
                    config:         (.config     // {})
                }' <<<"$proj_json")"
            if [[ -n "${OPT_JSON:-}" ]]; then
                printf '%s\n' "$rendered_proj"; return 0
            fi
            printf '[project]\n'
            printf '  name         %s\n' "$target"
            printf '  description  %s\n' "$(jq -r '.description // "(none)"' <<<"$rendered_proj")"
            local pcfg_keys; pcfg_keys="$(jq -r '.config | keys[]?' <<<"$rendered_proj")"
            if [[ -n "$pcfg_keys" ]]; then
                printf '\n[config]\n'
                while IFS= read -r k; do
                    printf '  %-30s %s\n' "$k" "$(jq -r --arg k "$k" '.config[$k]' <<<"$rendered_proj")"
                done <<<"$pcfg_keys"
            fi
            return 0
        fi

        die "no instance, profile, or project matches '$target'"
    fi

    # --- jq schema transform.  The `lxc/incus list` shape is rich:
    # .architecture, .config (with image.* + user.* + volatile.*),
    # .devices (instance-only), .expanded_devices (merged from profiles),
    # .profiles, .project, .state.{status,pid,processes,memory,network,...},
    # .snapshots, .type, etc.  We project the useful subset.
    local rendered
    rendered="$(jq -r --arg engine "$LXC_ENGINE" '
        .[0] as $i |
        ($i.config // {}) as $C |
        # Split user.* config into the lab-create.* triple + an `_other` bucket
        # of any other user.* keys (e.g. user.network.host_name).  Strip the
        # "user." prefix from _other for readability.
        ($C | with_entries(select(.key | startswith("user."))) ) as $userkeys |
        {
            schema_version: 1,
            kind: "instance",
            name: $i.name,
            engine: $engine,
            labels: {
                lab:    $C["user.lab-create.lab"],
                svc:    $C["user.lab-create.svc"],
                tool:   $C["user.lab-create.tool"],
                _other: ($userkeys
                         | with_entries(select(.key | startswith("user.lab-create.") | not))
                         | with_entries(.key |= sub("^user\\."; "")))
            },
            instance: {
                type:         $i.type,
                architecture: $i.architecture,
                project:      ($i.project // "default"),
                ephemeral:    $i.ephemeral,
                stateful:     $i.stateful,
                profiles:     ($i.profiles // []),
                created_at:   $i.created_at,
                last_used_at: $i.last_used_at
            },
            image: (
                # Image metadata lives in config under `image.*` keys.
                # If none are present (e.g. a from_chroot import without
                # those properties), the whole image block is null.
                if ($C | with_entries(select(.key | startswith("image.")))) | length > 0 then
                    {
                        fingerprint: ($C["volatile.base_image"] // null),
                        os:          ($C["image.os"]          // null),
                        release:     ($C["image.release"]     // null),
                        variant:     ($C["image.variant"]     // null),
                        description: ($C["image.description"] // null)
                    }
                else null end
            ),
            state: (
                if $i.state == null then null
                else {
                    status:      $i.state.status,
                    running:     ($i.state.status == "Running"),
                    pid:         (if ($i.state.pid // 0) > 0 then $i.state.pid else null end),
                    processes:   (if ($i.state.processes // 0) > 0 then $i.state.processes else null end),
                    started_at:  ($i.state.started_at // null),
                    memory: {
                        usage_bytes:           (($i.state.memory.usage // 0)),
                        usage_peak_bytes:      (($i.state.memory.usage_peak // 0)),
                        swap_usage_bytes:      (($i.state.memory.swap_usage // 0)),
                        swap_usage_peak_bytes: (($i.state.memory.swap_usage_peak // 0)),
                        total_bytes:           (($i.state.memory.total // 0))
                    }
                }
                end
            ),
            network: {
                interfaces: (
                    if $i.state == null or $i.state.network == null then []
                    else
                        [ $i.state.network | to_entries[]
                          | { name:        .key,
                              type:        .value.type,
                              mac_address: ((.value.hwaddr // "") | if . == "" then null else . end),
                              addresses: [
                                  (.value.addresses // [])[]
                                  | { family:  .family,
                                      address: .address,
                                      netmask: .netmask,
                                      scope:   .scope }
                              ]
                            }
                        ]
                    end
                )
            },
            devices: ($i.expanded_devices // {}),
            snapshots: [
                ($i.snapshots // [])[] |
                { name:          .name,
                  created_at:    .created_at,
                  stateful:      (.stateful // false),
                  expires_at:    (.expires_at // null) }
            ]
        }
    ' <<<"$raw")"

    if [[ -n "${OPT_JSON:-}" ]]; then
        printf '%s\n' "$rendered"
        return 0
    fi

    # Human-readable rendering — derived from the JSON for consistency.
    printf '[labels]\n'
    printf '  lab            %s\n' "$(jq -r '.labels.lab  // "(none)"' <<<"$rendered")"
    printf '  svc            %s\n' "$(jq -r '.labels.svc  // "(none)"' <<<"$rendered")"
    printf '  tool           %s\n' "$(jq -r '.labels.tool // "(none)"' <<<"$rendered")"

    printf '\n[instance]\n'
    printf '  name           %s\n' "$iname"
    printf '  type           %s\n' "$(jq -r '.instance.type'         <<<"$rendered")"
    printf '  architecture   %s\n' "$(jq -r '.instance.architecture' <<<"$rendered")"
    printf '  project        %s\n' "$(jq -r '.instance.project'      <<<"$rendered")"
    printf '  ephemeral      %s\n' "$(jq -r '.instance.ephemeral'    <<<"$rendered")"
    printf '  stateful       %s\n' "$(jq -r '.instance.stateful'     <<<"$rendered")"
    printf '  profiles       %s\n' "$(jq -r '.instance.profiles | join(", ")' <<<"$rendered")"
    printf '  created_at     %s\n' "$(jq -r '.instance.created_at'   <<<"$rendered")"

    if jq -e '.image != null' <<<"$rendered" >/dev/null; then
        printf '\n[image]\n'
        printf '  os             %s\n' "$(jq -r '.image.os          // "—"' <<<"$rendered")"
        printf '  release        %s\n' "$(jq -r '.image.release     // "—"' <<<"$rendered")"
        printf '  variant        %s\n' "$(jq -r '.image.variant     // "—"' <<<"$rendered")"
        printf '  fingerprint    %s\n' "$(jq -r '.image.fingerprint // "—"' <<<"$rendered")"
    fi

    if jq -e '.state != null' <<<"$rendered" >/dev/null; then
        printf '\n[state]\n'
        printf '  status         %s\n' "$(jq -r '.state.status'    <<<"$rendered")"
        printf '  running        %s\n' "$(jq -r '.state.running'   <<<"$rendered")"
        printf '  pid            %s\n' "$(jq -r '.state.pid       // "—"' <<<"$rendered")"
        printf '  processes      %s\n' "$(jq -r '.state.processes // "—"' <<<"$rendered")"
        printf '  memory.usage   %s bytes\n' "$(jq -r '.state.memory.usage_bytes' <<<"$rendered")"
        printf '  memory.peak    %s bytes\n' "$(jq -r '.state.memory.usage_peak_bytes' <<<"$rendered")"
    fi

    if jq -e '.network.interfaces | length > 0' <<<"$rendered" >/dev/null; then
        printf '\n[network]\n'
        local n_name n_type n_mac
        # Per-interface header, then one line per address.
        while IFS=$'\t' read -r n_name n_type n_mac; do
            [[ -z "$n_name" ]] && continue
            [[ "$n_mac" == "-" ]] && n_mac="(none)"
            printf '  %s (%s)  mac=%s\n' "$n_name" "$n_type" "$n_mac"
        done < <(jq -r '.network.interfaces[] | "\(.name)\t\(.type)\t\((.mac_address // "") | if . == "" then "-" else . end)"' <<<"$rendered")
        # Then a flat list of addresses, prefixed with their interface name.
        local a_iface a_fam a_addr a_scope
        while IFS=$'\t' read -r a_iface a_fam a_addr a_scope; do
            [[ -z "$a_iface" ]] && continue
            printf '    addr[%s/%s]  %s (%s)\n' "$a_iface" "$a_fam" "$a_addr" "$a_scope"
        done < <(jq -r '.network.interfaces[] as $iface | $iface.addresses[]? | "\($iface.name)\t\(.family)\t\(.address)\t\(.scope)"' <<<"$rendered")
    fi

    if jq -e '.devices | length > 0' <<<"$rendered" >/dev/null; then
        printf '\n[devices (expanded)]\n'
        local d_name d_type
        while IFS=$'\t' read -r d_name d_type; do
            [[ -z "$d_name" ]] && continue
            printf '  %-12s %s\n' "$d_name" "$d_type"
        done < <(jq -r '.devices | to_entries[] | "\(.key)\t\(.value.type // "—")"' <<<"$rendered")
    fi

    if jq -e '.snapshots | length > 0' <<<"$rendered" >/dev/null; then
        printf '\n[snapshots]\n'
        local s_name s_when
        while IFS=$'\t' read -r s_name s_when; do
            [[ -z "$s_name" ]] && continue
            printf '  %s  (%s)\n' "$s_name" "$s_when"
        done < <(jq -r '.snapshots[] | "\(.name)\t\(.created_at)"' <<<"$rendered")
    fi
}

# ─── Subcommand: export ────────────────────────────────────────────────────
# Dump `$LXC_CMD config show --expanded` for every instance in <lab>,
# concatenated with YAML document separators.  The output is feedable into
# `$LXC_CMD launch --yaml < file` to recreate identical instance config (LXD
# accepts a YAML config blob on stdin via --yaml mode).
# _yaml_str VALUE — emit VALUE as a double-quoted YAML string with internal
# double-quotes escaped (M-6, I-5).
_yaml_str() { printf '"%s"' "${1//\"/\\\"}"; }

cmd_export() {
    local lab="${OPT_LAB:-${POS_ARGS[0]:-}}"
    local fmt="${OPT_FORMAT:-lxc-yaml}"
    [[ -n "$lab" ]] || die "usage: $LAB_PROG export <lab> --format {lxc-yaml|compose}"
    case "$fmt" in lxc-yaml|compose) ;; *) die "unknown export format: $fmt (phase 5 supports: lxc-yaml|compose)" ;; esac
    require_lxd_or_incus

    # --- compose format: synthesize from spec.toml (same approach as Phase 3/4)
    if [[ "$fmt" == "compose" ]]; then
        require_cmd jq
        local spec; spec="$(lab_dir "$lab")/spec.toml"
        [[ -r "$spec" ]] || die "no spec.toml for lab '$lab' (was it brought up via 'up --config'?)"
        local cfg; cfg="$(toml_to_json "$spec")"
        # Pass 1: named volumes.
        local -A named_volumes=()
        local inst_count; inst_count="$(jq -r '.instance // [] | length' <<<"$cfg")"
        local i inst itype vol_src
        for ((i=0; i<inst_count; i++)); do
            inst="$(jq -c --argjson i "$i" '.instance[$i]' <<<"$cfg")"
            itype="$(spec_get "$inst" type)"; [[ -z "$itype" ]] && itype="container"
            [[ "$itype" == "vm" ]] && continue   # VMs not representable in compose
            while IFS= read -r vol_src; do
                [[ -z "$vol_src" ]] && continue
                case "$vol_src" in /*|./*|../*) : ;; *) named_volumes["$vol_src"]=1 ;; esac
            done < <(jq -r '.volumes[]? | split(":")[0]' <<<"$inst")
        done
        printf 'version: "3.9"\n'
        printf '# Generated by %s export --format compose from lab %s\n' "$LAB_PROG" "$lab"
        printf '# Note: LXD-specific fields (profiles, project, storage) are not representable\n'
        printf '# in compose YAML and are omitted.  VMs are skipped entirely.\n'
        printf 'services:\n'
        local sname simage
        for ((i=0; i<inst_count; i++)); do
            inst="$(jq -c --argjson i "$i" '.instance[$i]' <<<"$cfg")"
            itype="$(spec_get "$inst" type)"; [[ -z "$itype" ]] && itype="container"
            [[ "$itype" == "vm" ]] && { printf '  # (skipped: %s is type=vm, not representable in compose)\n' "$(spec_get "$inst" name)"; continue; }
            sname="$(spec_get "$inst" name)"
            simage="$(spec_get "$inst" image)"
            # M-6, I-5: quote service names as YAML keys to prevent injection.
            printf '  %s:\n' "$(_yaml_str "$sname")"
            [[ -n "$simage" ]] && printf '    image: %s\n' "$simage"
            printf '    container_name: %s\n' "$(instance_name_for "$lab" "$sname")"
            local p first=1
            while IFS= read -r p; do
                [[ -z "$p" ]] && continue
                if (( first )); then printf '    ports:\n'; first=0; fi
                printf '      - "%s"\n' "$p"
            done < <(jq -r '.ports[]?' <<<"$inst")
            first=1
            local kk vv
            while IFS=$'\t' read -r kk vv; do
                [[ -z "$kk" ]] && continue
                if (( first )); then printf '    environment:\n'; first=0; fi
                printf '      %s: "%s"\n' "$kk" "$vv"
            done < <(jq -r '.environment // {} | to_entries[]? | "\(.key)\t\(.value)"' <<<"$inst")
            first=1
            local vol
            while IFS= read -r vol; do
                [[ -z "$vol" ]] && continue
                if (( first )); then printf '    volumes:\n'; first=0; fi
                printf '      - "%s"\n' "$vol"
            done < <(jq -r '.volumes[]?' <<<"$inst")
            local cmdline; cmdline="$(jq -r '.command // empty' <<<"$inst")"
            [[ -n "$cmdline" ]] && printf '    command: %s\n' "$cmdline"
        done
        printf 'networks:\n'
        # L-1: mapfile array prevents word-split/glob on network names.
        # M-6: quote network names as YAML keys.
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
        if (( ${#named_volumes[@]} > 0 )); then
            printf 'volumes:\n'
            local vn; for vn in "${!named_volumes[@]}"; do printf '  %s:\n' "$vn"; done
        fi
        return 0
    fi

    # --- lxc-yaml format (original) ---
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
  $LAB_PROG inspect  <name|lab/service> [--json]
  $LAB_PROG export   <lab> --format {lxc-yaml|compose} # lxc-yaml: config show --expanded; compose: Compose YAML
  $LAB_PROG version | help

OPTIONS
  --alias, --tag TAG                    (build target; --tag is an alias of --alias)
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
  --format    FMT                       (export: lxc-yaml | compose)
  --follow                              (logs: -f)
  --force                               (destroy/down)

ENVIRONMENT
  LAB_LOG_LEVEL  debug|info|warn|error  (default: info)
  LAB_STATE_DIR  override the default state-dir location
  LAB_TERM       TERM to set for interactive exec sessions (default: xterm);
                 avoids exotic client TERMs (xterm-ghostty, …) the guest lacks

EXAMPLES
  $LAB_PROG run --name a --image images:alpine/latest        # newest stable X.Y, resolved at run time
  $LAB_PROG run --name v --image images:alpine/latest --type vm
  $LAB_PROG run --name p --image images:alpine/3.23          # pin a specific version
  $LAB_PROG build --alias kali-rolling --backend from-chroot --chroot /var/chroots/kali
  $LAB_PROG up   --config examples/lxd-examples/lxd-mixed-topology.toml
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
    OPT_JSON=""

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
            --json)         OPT_JSON=1; shift ;;
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
        inspect) cmd_inspect ;;
        export)  cmd_export  ;;
        help)    usage       ;;
        version) printf '%s %s\n' "$LAB_PROG" "$LAB_VERSION" ;;
        *)       usage; die "unknown subcommand: $SUBCMD" ;;
    esac
}

# Guard so `source`-ing this script (unit tests) defines functions without
# running main — matches phase1/2/3/4's source guard.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
