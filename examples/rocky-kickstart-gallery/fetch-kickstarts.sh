#!/usr/bin/env bash
# fetch-kickstarts.sh — Download the upstream Rocky Linux 9 kickstart catalog and
#                       stage lab-ready copies for the QEMU pxe-install lab.
#
# Upstream: https://github.com/rocky-linux/kickstarts (branch r9)
#   The official image-builder kickstarts Rocky uses to produce its cloud,
#   container, vagrant, workstation (KDE/XFCE/MATE/Cinnamon), EC2/Azure, OCP and
#   RPI images.  Each top-level `Rocky-9-*.ks` is a complete, self-contained
#   kickstart (none use %include).
#
# This fetches the WHOLE catalog so you can experiment with any variant.  It
# stores each file VERBATIM under <out>/raw/, then writes a lab-PATCHED copy into
# <out>/ (served by nginx at /rocky-kickstart/<variant>.ks).  Use --verbatim to
# skip patching (e.g. to reproduce the exact image-build behaviour).
#
# ─── Why patch (what these image-build kickstarts assume vs. an interactive VM) ─
# 1. TERMINAL ACTION.  Every variant ends with `shutdown` (or `poweroff`/`halt`)
#    so the image-build tool can snapshot the finished disk.  In an interactive
#    pxe-install VM you instead want it to REBOOT into the freshly installed
#    system, so the patch rewrites the terminal action to `reboot`.  (The blank
#    install target carries bootindex=0, so on that reboot SeaBIOS boots the disk
#    and the netboot loop terminates — see the gallery README.)
# 2. DISK DEVICE.  Defensive only: any `/dev/sda` is normalised to --disk.  The
#    Rocky kickstarts already target `/dev/vda` (virtio) throughout, so this is a
#    no-op today — but it keeps the patch honest if upstream ever changes, and
#    mirrors what the Kali preseed gallery has to do for real.
# 3. ROOT LOGIN.  Most variants LOCK root (`rootpw --lock` / `--iscrypted locked`),
#    and the cloud ones ALSO re-lock it in %post (`passwd -d root; passwd -l root`).
#    That's right for an image you log into via cloud-init / injected SSH keys, but
#    a lab VM has no datasource — you'd reach a login prompt you can't use.  The
#    patch rewrites every `rootpw` to a known plaintext password (--root-pw,
#    default "lab", matching the other mklab labs) AND strips the %post lines that
#    re-lock root.  Throwaway-lab posture — never serve these on an untrusted
#    network.  Use --no-unlock-root to keep the upstream locked behaviour.
#
# NOTE on non-bootable variants: `Rocky-9-Container-*` use autopart and target a
# container rootfs with no bootloader — they are staged for completeness but will
# NOT produce a bootable VM.  Pick a disk-installing variant (GenericCloud, EC2,
# Vagrant, Workstation, KDE/XFCE/MATE/Cinnamon, …) for the pxe-install lab.
#
# ─── Output layout (shares ~/netboot/ with the other PXE labs, no collision) ──
#   <out>/raw/<variant>.ks    verbatim upstream copy (reference; never patched)
#   <out>/<variant>.ks        lab-patched copy (served at /rocky-kickstart/<v>.ks)
#   default <out> = ${LAB_NETBOOT_DIR:-~/netboot}/rocky-kickstart
#
# Usage:
#   examples/rocky-kickstart-gallery/fetch-kickstarts.sh [OPTIONS]
#
# Options:
#   --out      <dir>   output directory (default: ~/netboot/rocky-kickstart)
#   --ref      <ref>   git branch/tag to fetch (default: r9)
#   --disk     <dev>   target disk to normalise /dev/sda to (default: /dev/vda)
#   --root-pw  <pw>    plaintext root password to unlock root with (default: lab)
#   --no-unlock-root   keep the upstream locked root (do NOT unlock — see patch #3)
#   --verbatim         do NOT patch at all — stage the upstream files unchanged
#   --only     <list>  comma-separated subset of variants (default: all)
#   --help             show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"
readonly UPSTREAM="https://github.com/rocky-linux/kickstarts.git"

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

usage() { sed -n '2,57p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── Defaults / args ──────────────────────────────────────────────────────────
out_dir=""
ref="r9"
disk="/dev/vda"
root_pw="lab"
unlock_root=1
verbatim=0
only=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)            shift; out_dir="${1:?--out requires a path}";  shift ;;
        --ref)            shift; ref="${1:?--ref requires a ref}";       shift ;;
        --disk)           shift; disk="${1:?--disk requires a device}";  shift ;;
        --root-pw)        shift; root_pw="${1:?--root-pw requires a value}"; shift ;;
        --no-unlock-root) unlock_root=0; shift ;;
        --only)           shift; only="${1:?--only requires a list}";    shift ;;
        --verbatim)       verbatim=1; shift ;;
        --help|-h)        usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# A root password with whitespace would break the single-line `rootpw` rewrite.
[[ "$root_pw" != *[[:space:]]* ]] || die "--root-pw must not contain whitespace"

[[ -n "$out_dir" ]] || out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/rocky-kickstart"

# Pinning a device that isn't a plausible block device is almost certainly a typo.
[[ "$disk" == /dev/* ]] || die "--disk must be a /dev path (got: $disk)"

command -v git >/dev/null || die "git is required but not found in PATH"

# ─── Clone the upstream catalog (shallow) into a temp dir ────────────────────
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

log_info "cloning ${UPSTREAM} (ref=${ref}, shallow)…"
git clone --quiet --depth 1 --branch "$ref" "$UPSTREAM" "$tmp/src" \
    || die "git clone failed (network? bad --ref '${ref}'?)"

# Variants = the top-level Rocky-9-*.ks products (self-contained; the modular
# fragments under cloud/ container/ vagrant/ live/ are NOT standalone installs).
mapfile -t variants < <(cd "$tmp/src" && ls Rocky-9-*.ks 2>/dev/null | sort)
(( ${#variants[@]} > 0 )) || die "no Rocky-9-*.ks found at the repo root — did the upstream layout change?"

# Optional subset (--only a,b,c) — accepts names with or without the .ks suffix
# and with or without the Rocky-9- prefix (e.g. 'GenericCloud-Base').
resolve_name() {
    local w="$1" v
    for v in "${variants[@]}"; do
        [[ "$v" == "$w" || "$v" == "${w}.ks" \
            || "$v" == "Rocky-9-${w}" || "$v" == "Rocky-9-${w}.ks" ]] && { printf '%s' "$v"; return 0; }
    done
    return 1
}
if [[ -n "$only" ]]; then
    IFS=',' read -r -a want <<<"$only"
    declare -a filtered=()
    for w in "${want[@]}"; do
        w="${w## }"; w="${w%% }"
        m="$(resolve_name "$w")" || die "--only: '$w' is not a known variant (run without --only to list them)"
        filtered+=("$m")
    done
    variants=("${filtered[@]}")
fi

log_info "${#variants[@]} variant(s) to stage into ${out_dir}"
mkdir -p "${out_dir}/raw"

# ─── patch_ks: stdin (verbatim .ks) → stdout (lab-patched .ks) ───────────────
# 1. normalise any /dev/sda → $disk (defensive; upstream already uses /dev/vda)
# 2. rewrite the FIRST standalone terminal action (shutdown|poweroff|halt) to
#    `reboot` so the VM boots the installed system instead of powering off.
#    The terminal action lives in the command section, which precedes the first
#    %pre/%packages/%post, so the first such standalone line is the right one.
# 3. when $unlock: rewrite every `rootpw …` to `rootpw --plaintext $pw`, and drop
#    the %post/%pre lines that clear or lock root (passwd -d/-l/--delete/--lock
#    root, usermod -L root) so root stays loginable.
patch_ks() {
    local d="$1" pw="$2" unlock="$3"
    awk -v disk="$d" -v rootpw="$pw" -v unlock="$unlock" '
        { gsub(/\/dev\/sda/, disk) }
        unlock && /^rootpw[[:space:]]/ { print "rootpw --plaintext " rootpw; next }
        unlock && /^[[:space:]]*passwd[[:space:]]+(-l|-d|--lock|--delete)[[:space:]]+root([[:space:]]|$)/ { next }
        unlock && /^[[:space:]]*usermod[[:space:]]+(-L|--lock)[[:space:]]+root([[:space:]]|$)/ { next }
        !rebooted && /^[[:space:]]*(shutdown|poweroff|halt)[[:space:]]*$/ {
            print "reboot"; rebooted = 1; next
        }
        { print }
    '
}

# ─── Stage each variant ───────────────────────────────────────────────────────
hdr="# >>> staged by ${LAB_PROG} for the QEMU pxe-install lab"
fetched=0
for v in "${variants[@]}"; do
    raw="${out_dir}/raw/${v}"
    cp -- "$tmp/src/$v" "$raw"

    dst="${out_dir}/${v}"
    if (( verbatim )); then
        cp -- "$raw" "$dst"
    else
        unlock_note="root locked (upstream)"; (( unlock_root )) && unlock_note="root unlocked (pw '${root_pw}')"
        { printf '%s — disk %s, terminal action reboot, %s <<<\n' "$hdr" "$disk" "$unlock_note"
          patch_ks "$disk" "$root_pw" "$unlock_root" <"$raw"; } >"$dst"
        # Fail closed: a disk-installing variant MUST reboot (not shut down) or
        # the lab "boots into the installed system" promise silently breaks.
        # Container variants legitimately have no terminal action — skip them.
        if grep -qE '^[[:space:]]*(shutdown|poweroff|halt)[[:space:]]*$' "$raw"; then
            grep -qE '^reboot$' "$dst" \
                || die "patch sanity failed: terminal action not rewritten to reboot in ${v}"
        fi
        # Defensive: no /dev/sda should survive the patch.
        ! grep -q '/dev/sda' "$dst" \
            || die "patch sanity failed: /dev/sda still present in ${v}"
        # Unlock sanity: root must be set plaintext and NOT re-locked in %post.
        if (( unlock_root )); then
            grep -qE '^rootpw --plaintext ' "$dst" \
                || die "patch sanity failed: root not unlocked (no plaintext rootpw) in ${v}"
            ! grep -qE '^[[:space:]]*passwd[[:space:]]+-[ld][[:space:]]+root([[:space:]]|$)' "$dst" \
                || die "patch sanity failed: %post still locks/clears root in ${v}"
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
    log_warn "VERBATIM mode: files are UNPATCHED — they end with 'shutdown', so the"
    log_warn "VM powers off after install instead of booting the installed system."
else
    log_info "each served copy reboots into the install; verbatim upstream is under raw/"
    if (( unlock_root )); then
        log_info "root is UNLOCKED with password '${root_pw}' (throwaway lab — never expose this)"
    else
        log_warn "--no-unlock-root: root stays LOCKED (upstream) — you may not be able to log in"
    fi
fi
log_info "available variants (Container-* are NOT VM-bootable — no bootloader):"
for v in "${variants[@]}"; do printf '    %s\n' "${v%.ks}" >&2; done
cat >&2 <<EOF

next steps (see examples/rocky-kickstart-gallery/README.md):
  1. Fetch the Rocky installer kernel+initrd+stage2 (reuses the rocky-pxe-lab helper):
       examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 9 --arch x86_64
  2. Pick a variant and build the iPXE boot script (boot.ipxe) for it:
       examples/rocky-kickstart-gallery/select-kickstart.sh GenericCloud-Base
  3. Serve + boot:
       phase4-podman/lab-podman.sh up     --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
       phase2-qemu-vm/lab-vm.sh    create --config examples/rocky-kickstart-gallery/rocky-kickstart-gallery.toml
       phase2-qemu-vm/lab-vm.sh    start  rocky-kickstart-install
EOF
