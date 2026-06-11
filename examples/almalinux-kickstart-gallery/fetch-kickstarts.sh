#!/usr/bin/env bash
# fetch-kickstarts.sh — Download AlmaLinux's official image-build kickstart catalog
#                       and stage lab-ready copies for the QEMU pxe-install lab.
#
# Upstream: https://github.com/AlmaLinux/cloud-images  (branch main)
#   AlmaLinux's Packer image-build kickstarts live under http/, named
#   `almalinux-<release>.<platform>-<arch>.ks` (gencloud, oci, gcp, azure,
#   vagrant; releases 8/9/10; x86_64/aarch64/ppc64le/s390x).  This is the
#   AlmaLinux counterpart of `rocky-linux/kickstarts` (the rocky-kickstart-gallery
#   source) — but AlmaLinux structures them differently (per-platform-per-arch
#   files under http/, not a flat `Rocky-9-*.ks` catalog), and they are written
#   for Packer's build VM, so the lab MUST patch the disk device (see below).
#
# This fetches the catalog for one release+arch (default 9 / x86_64), stores each
# matching file VERBATIM under <out>/raw/, then writes a lab-PATCHED copy into
# <out>/ (served by nginx at /almalinux-kickstart/<file>).  --verbatim skips
# patching (e.g. to reproduce the exact Packer behaviour).
#
# ─── Why patch (what these Packer kickstarts assume vs. our pxe-install VM) ────
# 1. DISK DEVICE — *required*, unlike the Rocky gallery where it's a no-op.  These
#    kickstarts partition **/dev/sda** in a `%pre` `parted` script and reference it
#    again as `--onpart=sdaN` in a generated `/tmp/partitions.ks`.  Packer's build
#    VM presents a SATA disk (sda); our QEMU pxe-install VM uses **virtio**
#    (`/dev/vda`), so an unpatched kickstart fails in `%pre` ("/dev/sda: unrecognised
#    disk label" / no such device).  The patch rewrites BOTH `/dev/sda`→`/dev/vda`
#    AND `onpart=sda`→`onpart=vda` (--disk picks the device).
# 2. TERMINAL ACTION — these end with `reboot --eject` already (good: our VM should
#    reboot into the install, not power off).  The patch normalises `--eject` away
#    (no CD on a netboot) and rewrites any stray `shutdown`/`poweroff`/`halt`→`reboot`.
# 3. ROOT LOGIN — AlmaLinux's cloud kickstarts UNLOCK root already
#    (`rootpw --plaintext almalinux`, plus `PermitRootLogin yes` in %post), so a
#    lab VM with no cloud datasource still has a usable console login.  The patch
#    just NORMALISES the password to a known value (--root-pw, default "lab",
#    matching the other mklab labs) and strips any %post line that re-locks root.
#    Throwaway-lab posture — never serve these on an untrusted network.
#    --no-unlock-root keeps the upstream password untouched.
#
# NOTE: the `gcp` variant partitions declaratively (no /dev/sda %pre); the patch is
# a no-op there.  GenericCloud (`gencloud`) is the lean, recommended first variant
# (the AlmaLinux equivalent of Rocky's GenericCloud-Base).
#
# ─── Output layout (shares ~/netboot/ with the other PXE labs, no collision) ──
#   <out>/raw/<file>.ks    verbatim upstream copy (reference; never patched)
#   <out>/<file>.ks        lab-patched copy (served at /almalinux-kickstart/<file>.ks)
#   default <out> = ${LAB_NETBOOT_DIR:-~/netboot}/almalinux-kickstart
#
# Usage:
#   examples/almalinux-kickstart-gallery/fetch-kickstarts.sh [OPTIONS]
#
# Options:
#   --out      <dir>   output directory (default: ~/netboot/almalinux-kickstart)
#   --ref      <ref>   git branch/tag to fetch (default: main)
#   --release  <n>     AlmaLinux major release to stage (default: 9)
#   --arch     <a>     architecture to stage (default: x86_64)
#   --disk     <dev>   target disk to rewrite /dev/sda + onpart=sda to (default: /dev/vda)
#   --root-pw  <pw>    plaintext root password to normalise root to (default: lab)
#   --no-unlock-root   leave the upstream rootpw untouched (do NOT normalise)
#   --verbatim         do NOT patch at all — stage the upstream files unchanged
#   --only     <list>  comma-separated subset of variants (e.g. gencloud,oci)
#   --help             show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"
readonly UPSTREAM="https://github.com/AlmaLinux/cloud-images.git"

# ─── Logging ──────────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local color="" reset=""
    if [[ -t 2 ]]; then
        case "$level" in
            info) color=$'\033[36m' ;; warn) color=$'\033[33m' ;;
            error) color=$'\033[31m' ;; ok) color=$'\033[32m' ;;
        esac
        reset=$'\033[0m'
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info() { _log info "$@"; }
log_warn() { _log warn "$@"; }
log_ok()   { _log ok   "$@"; }
die()      { _log error "$@"; exit 1; }

usage() { sed -n '2,63p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Defaults / args ──────────────────────────────────────────────────────────
out_dir=""
ref="main"
release="9"
arch="x86_64"
disk="/dev/vda"
root_pw="lab"
unlock_root=1
verbatim=0
only=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)            shift; out_dir="${1:?--out requires a path}";  shift ;;
        --ref)            shift; ref="${1:?--ref requires a ref}";       shift ;;
        --release)        shift; release="${1:?--release requires a number}"; shift ;;
        --arch)           shift; arch="${1:?--arch requires an arch}";   shift ;;
        --disk)           shift; disk="${1:?--disk requires a device}";  shift ;;
        --root-pw)        shift; root_pw="${1:?--root-pw requires a value}"; shift ;;
        --no-unlock-root) unlock_root=0; shift ;;
        --only)           shift; only="${1:?--only requires a list}";    shift ;;
        --verbatim)       verbatim=1; shift ;;
        --help|-h)        usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

[[ "$root_pw" != *[[:space:]]* ]] || die "--root-pw must not contain whitespace"
[[ -n "$out_dir" ]] || out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/almalinux-kickstart"
[[ "$disk" == /dev/* ]] || die "--disk must be a /dev path (got: $disk)"
# the bare-device form (vda) is what onpart= takes — derive it from --disk
disk_bare="${disk#/dev/}"

command -v git >/dev/null || die "git is required but not found in PATH"

# ─── Clone the upstream catalog (shallow) into a temp dir ────────────────────
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

log_info "cloning ${UPSTREAM} (ref=${ref}, shallow)…"
git clone --quiet --depth 1 --branch "$ref" "$UPSTREAM" "$tmp/src" \
    || die "git clone failed (network? bad --ref '${ref}'?)"

# Variants = the http/almalinux-<release>.<platform>-<arch>.ks products for the
# requested release+arch (incl. an optional _vN micro-arch suffix, e.g. _v2).
mapfile -t paths < <(cd "$tmp/src" && \
    ls http/almalinux-"${release}".*-"${arch}".ks http/almalinux-"${release}".*-"${arch}"_v*.ks 2>/dev/null | sort -u)
(( ${#paths[@]} > 0 )) || die "no http/almalinux-${release}.*-${arch}.ks found — check --release/--arch, or the upstream layout changed"

# variant() — strip the http/ dir, the almalinux-<rel>. prefix, and the -<arch> suffix
#             → the short name (gencloud, oci, gcp, azure, vagrant)
variant_of() { local b="${1##*/}"; b="${b#almalinux-${release}.}"; b="${b%.ks}"; printf '%s' "${b%-${arch}*}"; }

# Optional subset (--only gencloud,oci) — matches the short variant name
if [[ -n "$only" ]]; then
    IFS=',' read -r -a want <<<"$only"
    declare -a filtered=()
    for p in "${paths[@]}"; do
        v="$(variant_of "$p")"
        for w in "${want[@]}"; do w="${w## }"; w="${w%% }"; [[ "$v" == "$w" ]] && { filtered+=("$p"); break; }; done
    done
    (( ${#filtered[@]} > 0 )) || die "--only '$only' matched none of: $(for p in "${paths[@]}"; do printf '%s ' "$(variant_of "$p")"; done)"
    paths=("${filtered[@]}")
fi

log_info "${#paths[@]} variant(s) to stage into ${out_dir} (release ${release}, ${arch})"
mkdir -p "${out_dir}/raw"

# ─── patch_ks: stdin (verbatim .ks) → stdout (lab-patched .ks) ───────────────
# 1. /dev/sda → $disk  AND  onpart=sda → onpart=$disk_bare  (REQUIRED for AlmaLinux:
#    the %pre parted script + generated partitions.ks hardcode the Packer SATA disk).
# 2. terminal action: drop `--eject` and rewrite shutdown/poweroff/halt → reboot.
# 3. when $unlock: normalise every `rootpw …` to `rootpw --plaintext $pw`, and drop
#    %post lines that lock/clear root (defensive; AlmaLinux doesn't, but be safe).
patch_ks() {
    local d="$1" dbare="$2" pw="$3" unlock="$4"
    awk -v disk="$d" -v dbare="$dbare" -v rootpw="$pw" -v unlock="$unlock" '
        { gsub(/\/dev\/sda/, disk); gsub(/onpart=sda/, "onpart=" dbare) }
        unlock && /^rootpw[[:space:]]/ { print "rootpw --plaintext " rootpw; next }
        unlock && /^[[:space:]]*passwd[[:space:]]+(-l|-d|--lock|--delete)[[:space:]]+root([[:space:]]|$)/ { next }
        unlock && /^[[:space:]]*usermod[[:space:]]+(-L|--lock)[[:space:]]+root([[:space:]]|$)/ { next }
        /^[[:space:]]*reboot([[:space:]]|$)/ { print "reboot"; next }
        !rebooted && /^[[:space:]]*(shutdown|poweroff|halt)([[:space:]]|$)/ { print "reboot"; rebooted=1; next }
        { print }
    '
}

# ─── Stage each variant ───────────────────────────────────────────────────────
hdr="# >>> staged by ${LAB_PROG} for the QEMU pxe-install lab"
fetched=0
for p in "${paths[@]}"; do
    file="${p##*/}"
    raw="${out_dir}/raw/${file}"
    cp -- "$tmp/src/$p" "$raw"

    dst="${out_dir}/${file}"
    if (( verbatim )); then
        cp -- "$raw" "$dst"
    else
        unlock_note="rootpw untouched (upstream)"; (( unlock_root )) && unlock_note="root pw normalised to '${root_pw}'"
        { printf '%s — disk %s, terminal action reboot, %s <<<\n' "$hdr" "$disk" "$unlock_note"
          patch_ks "$disk" "$disk_bare" "$root_pw" "$unlock_root" <"$raw"; } >"$dst"
        # Fail closed: the disk device MUST be fully rewritten, or the %pre parted
        # aborts on the missing /dev/sda and the whole install fails.
        ! grep -qE '/dev/sda|onpart=sda' "$dst" \
            || die "patch sanity failed: /dev/sda or onpart=sda still present in ${file}"
        # A disk-installing variant MUST reboot (these have a terminal action).
        if grep -qE '^[[:space:]]*(reboot|shutdown|poweroff|halt)([[:space:]]|$)' "$raw"; then
            grep -qE '^reboot$' "$dst" \
                || die "patch sanity failed: terminal action not rewritten to reboot in ${file}"
        fi
        if (( unlock_root )); then
            grep -qE '^rootpw --plaintext ' "$dst" \
                || die "patch sanity failed: root pw not normalised (no plaintext rootpw) in ${file}"
        fi
    fi
    chmod 0644 "$raw" "$dst"
    fetched=$((fetched + 1))
done

# chown back to the invoking user when run under sudo.
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$out_dir"
fi

# ─── Summary + next steps ────────────────────────────────────────────────────
log_ok "staged ${fetched} kickstart variant(s) into ${out_dir}"
if (( verbatim )); then
    log_warn "VERBATIM mode: UNPATCHED — they partition /dev/sda (Packer's disk), which"
    log_warn "does NOT exist on the virtio pxe-install VM; the install will fail in %pre."
else
    log_info "each served copy partitions ${disk} and reboots into the install; verbatim under raw/"
    (( unlock_root )) && log_info "root pw normalised to '${root_pw}' (throwaway lab — never expose this)"
fi
log_info "available variants (release ${release}, ${arch}):"
for p in "${paths[@]}"; do printf '    %-10s (%s)\n' "$(variant_of "$p")" "${p##*/}" >&2; done
cat >&2 <<EOF

next steps (see examples/almalinux-kickstart-gallery/README.md):
  1. Fetch the AlmaLinux installer kernel+initrd+stage2 (reuses the almalinux-pxe-lab helper):
       examples/almalinux-pxe-lab/fetch-almalinux-installer.sh --release ${release} --arch ${arch}
  2. Pick a variant and build the iPXE boot script (boot.ipxe) for it:
       examples/almalinux-kickstart-gallery/select-kickstart.sh gencloud
  3. Serve + boot:
       phase4-podman/lab-podman.sh up     --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
       phase2-qemu-vm/lab-vm.sh    create --config examples/almalinux-kickstart-gallery/almalinux-kickstart-gallery.toml
       phase2-qemu-vm/lab-vm.sh    start  almalinux-kickstart-install
EOF
