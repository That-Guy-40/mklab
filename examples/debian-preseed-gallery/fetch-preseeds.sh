#!/usr/bin/env bash
# fetch-preseeds.sh — Generate the Debian trixie preseed GALLERY and stage
#                     lab-ready copies for the QEMU pxe-install lab.
#
# Unlike the Kali gallery (which fetches a purpose-built upstream catalog of
# ~15 ready .cfg files), Debian ships exactly ONE official reference:
#   https://www.debian.org/releases/trixie/example-preseed.txt
# That single file documents every partitioning option INLINE as a commented
# alternative (method = regular | lvm | crypto ; recipe = atomic | home | multi).
# So the honest "gallery" for Debian is: take Debian's own reference and expose
# its documented variants as ready-to-boot preseeds.  This script does that —
# it stamps each variant's PARTITIONING block into base-preseed.cfg (the common
# lab body) and writes one complete preseed per variant.  Generation is OFFLINE
# and deterministic from base-preseed.cfg; the official example is fetched only
# as a side-by-side reference (skip with --no-refresh).
#
# ─── The variants (all traceable to the official example's own options) ──────
#   regular-atomic   regular partitions, all files in one partition   (simplest)
#   regular-home     regular partitions, separate /home
#   regular-multi    regular partitions, separate /home, /var, /tmp
#   lvm-atomic       LVM, one root logical volume
#   crypto-atomic    LVM inside an encrypted partition (passphrase 'labcrypto')
#   minimal          regular/atomic, but tasksel disabled (base system only)
#
# ─── Why the /dev/vda pin ────────────────────────────────────────────────────
# The lab VM has a single virtio disk, /dev/vda.  Every generated variant pins
# partman-auto/disk + grub-installer/bootdev to it so the install is fully
# unattended (no disk prompt) and never wanders.  On real hardware whose disk is
# /dev/sda, pass --disk /dev/sda.
#
# ─── Output layout (shares ~/netboot/ with the other PXE labs, no collision) ──
#   <out>/<variant>.cfg      lab-ready generated preseed (served at /debian-preseed/<variant>.cfg)
#   <out>/raw/example-preseed.txt   the official reference (for diffing; --no-refresh skips the fetch)
#   default <out> = ${LAB_NETBOOT_DIR:-~/netboot}/debian-preseed
#
# Usage:
#   examples/debian-preseed-gallery/fetch-preseeds.sh [OPTIONS]
#
# Options:
#   --out       <dir>   output directory (default: ~/netboot/debian-preseed)
#   --disk      <dev>   target disk to pin to (default: /dev/vda)
#   --only      <list>  comma-separated subset of variants (default: all)
#   --no-refresh        do not fetch the official example-preseed.txt reference
#   --passphrase <pw>   disk passphrase for the crypto variant (default: labcrypto)
#   --help              show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly BASE="${SCRIPT_DIR}/base-preseed.cfg"
readonly UPSTREAM_URL="https://www.debian.org/releases/trixie/example-preseed.txt"

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

usage() { sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ─── The full variant roster ──────────────────────────────────────────────────
readonly ALL_VARIANTS=(regular-atomic regular-home regular-multi lvm-atomic crypto-atomic minimal)

# ─── Defaults / args ──────────────────────────────────────────────────────────
out_dir=""
disk="/dev/vda"
only=""
refresh=1
passphrase="labcrypto"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)        shift; out_dir="${1:?--out requires a path}";        shift ;;
        --disk)       shift; disk="${1:?--disk requires a device}";        shift ;;
        --only)       shift; only="${1:?--only requires a list}";          shift ;;
        --passphrase) shift; passphrase="${1:?--passphrase requires a value}"; shift ;;
        --no-refresh) refresh=0; shift ;;
        --help|-h)    usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

[[ -n "$out_dir" ]] || out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/debian-preseed"
[[ "$disk" == /dev/* ]] || die "--disk must be a /dev path (got: $disk)"
[[ -f "$BASE" ]] || die "base template not found: $BASE"

# Resolve the variant list (validate --only against the roster).
declare -a variants=("${ALL_VARIANTS[@]}")
if [[ -n "$only" ]]; then
    IFS=',' read -r -a want <<<"$only"
    declare -a filtered=()
    for w in "${want[@]}"; do
        w="${w## }"; w="${w%% }"
        local_ok=0
        for v in "${ALL_VARIANTS[@]}"; do [[ "$v" == "$w" ]] && local_ok=1; done
        (( local_ok )) || die "--only: '$w' is not a known variant (one of: ${ALL_VARIANTS[*]})"
        filtered+=("$w")
    done
    variants=("${filtered[@]}")
fi

mkdir -p "${out_dir}/raw"

# ─── partman_block <variant> <disk>: emit the per-variant partitioning stanza ─
# Common confirmations apply to every variant; method/recipe (+ LVM/crypto
# extras) are the variant-specific part, straight from the official example's
# documented options.
partman_block() {
    local v="$1" d="$2"
    case "$v" in
        regular-atomic|minimal)
            printf 'd-i partman-auto/method              string regular\n'
            printf 'd-i partman-auto/choose_recipe       select atomic\n' ;;
        regular-home)
            printf 'd-i partman-auto/method              string regular\n'
            printf 'd-i partman-auto/choose_recipe       select home\n' ;;
        regular-multi)
            printf 'd-i partman-auto/method              string regular\n'
            printf 'd-i partman-auto/choose_recipe       select multi\n' ;;
        lvm-atomic)
            printf 'd-i partman-auto/method              string lvm\n'
            printf 'd-i partman-auto/choose_recipe       select atomic\n'
            printf 'd-i partman-auto-lvm/guided_size     string max\n' ;;
        crypto-atomic)
            printf 'd-i partman-auto/method              string crypto\n'
            printf 'd-i partman-auto/choose_recipe       select atomic\n'
            printf 'd-i partman-auto-lvm/guided_size     string max\n'
            printf 'd-i partman-crypto/passphrase        password %s\n' "$passphrase"
            printf 'd-i partman-crypto/passphrase-again  password %s\n' "$passphrase"
            # Skip the (very slow) secure erase of the disk before encrypting —
            # fine for a throwaway lab; drop this line for a real install.
            printf 'd-i partman-auto-crypto/erase_disks  boolean false\n' ;;
        *) die "internal: unknown variant '$v'" ;;
    esac
    # Common confirmations (all variants).
    cat <<EOF
d-i partman-auto/disk                string $d
d-i partman-lvm/device_remove_lvm    boolean true
d-i partman-md/device_remove_md      boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition         select finish
d-i partman/confirm                  boolean true
d-i partman/confirm_nooverwrite      boolean true
d-i partman-md/confirm               boolean true
d-i partman-lvm/confirm              boolean true
d-i partman-lvm/confirm_nooverwrite  boolean true
EOF
}

# ─── gen_variant <variant> <disk> <outfile>: stamp the block into base ───────
gen_variant() {
    local v="$1" d="$2" out="$3"
    {
        # everything before the BEGIN marker
        awk '/^# >>> BEGIN partman/{exit} {print}' "$BASE"
        printf '# >>> partman: %s — generated by %s (disk %s) >>>\n' "$v" "$LAB_PROG" "$d"
        partman_block "$v" "$d"
        printf '# <<< partman <<<\n'
        # everything after the END marker
        awk 'f{print} /^# <<< END partman/{f=1}' "$BASE"
    } > "${out}.tmp"

    # The `minimal` variant installs no tasksel tasks at all (base system only).
    if [[ "$v" == "minimal" ]]; then
        sed -i 's#^tasksel tasksel/first .*#d-i pkgsel/run_tasksel                boolean false#' "${out}.tmp"
    fi

    mv "${out}.tmp" "$out"

    # Fail closed: the generated preseed MUST pin the disk and carry the method.
    grep -q "partman-auto/disk[[:space:]]\+string ${d}$" "$out" \
        || die "sanity: ${v} did not pin partman-auto/disk to ${d}"
    grep -q "grub-installer/bootdev[[:space:]]\+string /dev/vda$" "$out" \
        || die "sanity: ${v} lost the grub-installer/bootdev pin"
    grep -q '^d-i partman-auto/method' "$out" \
        || die "sanity: ${v} has no partman-auto/method line"
    if [[ "$v" == "crypto-atomic" ]]; then
        grep -q '^d-i partman-crypto/passphrase' "$out" \
            || die "sanity: crypto-atomic has no passphrase"
    fi
    if [[ "$v" == "minimal" ]]; then
        grep -q '^d-i pkgsel/run_tasksel[[:space:]]\+boolean false' "$out" \
            || die "sanity: minimal did not disable tasksel"
    fi
}

# ─── Optionally refresh the vendored official reference ──────────────────────
if (( refresh )); then
    if command -v curl >/dev/null; then
        log_info "fetching the official reference → raw/example-preseed.txt"
        curl -fsSL -o "${out_dir}/raw/example-preseed.txt" "$UPSTREAM_URL" \
            || log_warn "could not fetch ${UPSTREAM_URL} (offline?) — skipping the reference copy"
    else
        log_warn "curl not found — skipping the official-reference fetch"
    fi
else
    log_info "--no-refresh: not fetching the official reference"
fi

# ─── Generate each requested variant ─────────────────────────────────────────
log_info "generating ${#variants[@]} variant(s) into ${out_dir} (disk ${disk})"
count=0
for v in "${variants[@]}"; do
    gen_variant "$v" "$disk" "${out_dir}/${v}.cfg"
    log_ok "  ${v}.cfg"
    count=$((count + 1))
done
chmod 0644 "${out_dir}"/*.cfg
[[ -f "${out_dir}/raw/example-preseed.txt" ]] && chmod 0644 "${out_dir}/raw/example-preseed.txt"

# chown back to the invoking user when run under sudo.
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$out_dir"
fi

log_ok "staged ${count} preseed variant(s) into ${out_dir}"
log_info "available variants:"
for v in "${variants[@]}"; do printf '    %s\n' "$v" >&2; done
cat >&2 <<EOF

next steps (see examples/debian-preseed-gallery/README.md):
  1. Fetch the trixie d-i kernel+initrd (reuses the debian-pxe-lab helper):
       examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64
  2. Pick a variant and build the iPXE boot program for it:
       examples/debian-preseed-gallery/select-preseed.sh lvm-atomic
  3. Serve + boot:
       phase4-podman/lab-podman.sh up     --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
       phase2-qemu-vm/lab-vm.sh    create --config examples/debian-preseed-gallery/debian-preseed-gallery.toml
       phase2-qemu-vm/lab-vm.sh    start  debian-preseed-install
EOF
