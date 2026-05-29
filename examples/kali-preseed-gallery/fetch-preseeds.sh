#!/usr/bin/env bash
# fetch-preseeds.sh — Download the upstream Kali preseed-examples catalog and
#                     stage lab-ready copies for the QEMU two-disk PXE lab.
#
# Upstream: https://gitlab.com/kalilinux/recipes/kali-preseed-examples
#   A catalog of complete, standalone Debian-installer (d-i) preseed files:
#   a matrix of desktop environment (xfce/kde/gnome/headless) x partitioning
#   (regular/lvm/crypto, with -large/-multi/skip-wipe variants) + packer-preseed.
#
# This fetches the WHOLE catalog so you can experiment with any variant.  It
# downloads each file VERBATIM into <out>/raw/, then writes a lab-PATCHED copy
# into <out>/ (served by nginx).  The only patch is the disk pinning the QEMU
# two-disk boot-loop requires — see "Why patch" below.  Use --verbatim to skip
# patching (e.g. for real hardware whose disk really is /dev/sda).
#
# ─── Why patch (the one genuinely install-breaking issue) ─────────────────────
# Every upstream variant hardcodes `grub-installer/bootdev string /dev/sda` and
# sets NO `partman-auto/disk`.  The lab boots the installer from an iPXE ROM on a
# SECOND virtio disk (the two-disk boot-loop): disks are /dev/vda (blank target)
# and /dev/vdb (iPXE ROM).  So unpatched:
#   * /dev/sda does not exist on a virtio bus → grub-install fails, no boot-loop;
#   * with no partman-auto/disk and two disks present, guided partitioning would
#     prompt (breaking "unattended") or could even partition /dev/vdb and DESTROY
#     the iPXE ROM.
# The patch pins both to /dev/vda — exactly what examples/kali-pxe-lab's
# hand-written preseed bakes in.  On real hardware with a single SATA/NVMe disk
# (Path B), the upstream /dev/sda is usually correct: use --verbatim there.
#
# ─── Output layout (shares ~/netboot/ with the other PXE labs, no collision) ──
#   <out>/raw/<variant>      verbatim upstream copy (reference; never served-patched)
#   <out>/<variant>          lab-patched copy (served at /kali-preseed/<variant>)
#   default <out> = ${LAB_NETBOOT_DIR:-~/netboot}/kali-preseed
#
# Usage:
#   examples/kali-preseed-gallery/fetch-preseeds.sh [OPTIONS]
#
# Options:
#   --out      <dir>   output directory (default: ~/netboot/kali-preseed)
#   --ref      <ref>   git ref/branch/tag to fetch (default: main)
#   --disk     <dev>   target disk to pin to    (default: /dev/vda)
#   --verbatim         do NOT patch — stage the upstream files unchanged
#   --only     <list>  comma-separated subset of variants (default: all)
#   --help             show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"

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

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Defaults / args ──────────────────────────────────────────────────────────
out_dir=""
ref="main"
disk="/dev/vda"
verbatim=0
only=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)      shift; out_dir="${1:?--out requires a path}";  shift ;;
        --ref)      shift; ref="${1:?--ref requires a ref}";       shift ;;
        --disk)     shift; disk="${1:?--disk requires a device}";  shift ;;
        --only)     shift; only="${1:?--only requires a list}";    shift ;;
        --verbatim) verbatim=1; shift ;;
        --help|-h)  usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

[[ -n "$out_dir" ]] || out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/kali-preseed"

# Pinning a device that isn't a plausible block device is almost certainly a typo.
[[ "$disk" == /dev/* ]] || die "--disk must be a /dev path (got: $disk)"

command -v curl >/dev/null || die "curl is required but not found in PATH"
command -v jq   >/dev/null || die "jq is required but not found in PATH"

# ─── Resolve the catalog file list from the GitLab API ───────────────────────
# Project path URL-encoded; /repository/tree lists blobs at the repo root.
readonly PROJECT="kalilinux%2Frecipes%2Fkali-preseed-examples"
readonly API="https://gitlab.com/api/v4/projects/${PROJECT}/repository"

log_info "listing the upstream catalog (ref=${ref})…"
tree_json="$(curl -fsSL "${API}/tree?ref=${ref}&per_page=100")" \
    || die "could not list the repository tree (network? bad --ref '${ref}'?)"

# Preseed files = every blob ending in .cfg, plus the extension-less
# 'headless-default'.  README.md / LICENSE are excluded by this filter.
mapfile -t variants < <(
    jq -r '.[] | select(.type=="blob") | .name
           | select(endswith(".cfg") or . == "headless-default")' <<<"$tree_json"
)
(( ${#variants[@]} > 0 )) || die "no preseed files found in the tree — did the upstream layout change?"

# Optional subset (--only a,b,c) — validated against what the tree actually has.
if [[ -n "$only" ]]; then
    IFS=',' read -r -a want <<<"$only"
    declare -a filtered=()
    for w in "${want[@]}"; do
        w="${w## }"; w="${w%% }"
        local_match=""
        for v in "${variants[@]}"; do [[ "$v" == "$w" || "$v" == "${w}.cfg" ]] && local_match="$v"; done
        [[ -n "$local_match" ]] || die "--only: '$w' is not a known variant (run without --only to list them)"
        filtered+=("$local_match")
    done
    variants=("${filtered[@]}")
fi

log_info "${#variants[@]} variant(s) to fetch into ${out_dir}"
mkdir -p "${out_dir}/raw"

# ─── patch_preseed: stdin (verbatim cfg) → stdout (lab-patched cfg) ──────────
# 1. rewrite grub-installer/bootdev /dev/sda → $disk
# 2. ensure exactly one `d-i partman-auto/disk string $disk` line exists
#    (upstream omits it; packer-preseed has it commented). Insert it right after
#    the partman-auto/method line so the install is confined to $disk.
patch_preseed() {
    local d="$1"
    awk -v disk="$d" '
        BEGIN { have_disk = 0 }
        # normalize any grub bootdev to the lab disk
        /^d-i[ \t]+grub-installer\/bootdev[ \t]+string/ {
            print "d-i grub-installer/bootdev           string " disk; next
        }
        # an existing (possibly commented) partman-auto/disk → canonical, once
        /^#?d-i[ \t]+partman-auto\/disk[ \t]+string/ {
            if (!have_disk) { print "d-i partman-auto/disk                string " disk; have_disk = 1 }
            next
        }
        { print }
        # after the method line, if we never saw a disk line, add one
        /^d-i[ \t]+partman-auto\/method[ \t]+string/ {
            if (!have_disk) { print "d-i partman-auto/disk                string " disk; have_disk = 1 }
        }
    '
}

# ─── Download + stage each variant ────────────────────────────────────────────
hdr="# >>> staged by ${LAB_PROG} for the QEMU two-disk PXE lab — disk pinned to"
fetched=0
for v in "${variants[@]}"; do
    raw="${out_dir}/raw/${v}"
    enc="${v// /%20}"   # names have no spaces, but be safe for the URL
    log_info "  ${v}"
    curl -fsSL -o "$raw" "${API}/files/${enc}/raw?ref=${ref}" \
        || die "download failed for ${v}"

    dst="${out_dir}/${v}"
    if (( verbatim )); then
        cp -- "$raw" "$dst"
    else
        { printf '%s %s <<<\n' "$hdr" "$disk"; patch_preseed "$disk" <"$raw"; } >"$dst"
        # Fail closed: the patched copy MUST pin the lab disk, or the install breaks.
        grep -q "grub-installer/bootdev[[:space:]]\+string ${disk}$" "$dst" \
            || die "patch sanity failed: grub bootdev not pinned to ${disk} in ${v}"
        grep -q "partman-auto/disk[[:space:]]\+string ${disk}$" "$dst" \
            || die "patch sanity failed: partman-auto/disk not pinned to ${disk} in ${v}"
    fi
    chmod 0644 "$raw" "$dst"
    fetched=$((fetched + 1))
done

# chown back to the invoking user when run under sudo.
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$out_dir"
fi

# ─── Summary + next steps ────────────────────────────────────────────────────
log_ok "staged ${fetched} preseed variant(s) into ${out_dir}"
if (( verbatim )); then
    log_warn "VERBATIM mode: files are UNPATCHED — they pin /dev/sda. Use only on"
    log_warn "real hardware whose disk is /dev/sda, NOT the QEMU two-disk lab."
else
    log_info "each served copy is pinned to ${disk}; verbatim upstream is under raw/"
fi
log_info "available variants:"
for v in "${variants[@]}"; do printf '    %s\n' "$v" >&2; done
cat >&2 <<EOF

next steps (see examples/kali-preseed-gallery/README.md):
  1. Fetch the d-i kernel+initrd (reuses the kali-pxe-lab helper):
       examples/kali-pxe-lab/fetch-kali-installer.sh --arch amd64
  2. Pick a variant and build the iPXE ROM pointed at it:
       examples/kali-preseed-gallery/select-preseed.sh xfce-default
  3. Serve + boot:
       phase4-podman/lab-podman.sh up     --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
       phase2-qemu-vm/lab-vm.sh    create --config examples/kali-preseed-gallery/kali-preseed-gallery.toml
       phase2-qemu-vm/lab-vm.sh    start  kali-preseed-install
EOF
