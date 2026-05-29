#!/usr/bin/env bash
# fetch-almalinux-installer.sh — Download and verify the AlmaLinux PXE installer
#                                 kernel and initrd from an upstream mirror.
#
# Downloads vmlinuz and initrd.img from the AlmaLinux images/pxeboot/ tree,
# verifies both files against the published CHECKSUM file, and sets permissions
# so a rootless nginx container can serve them.
#
# Usage:
#   netboot/fetch-almalinux-installer.sh [OPTIONS]
#
# Options:
#   --mirror  <url>   upstream AlmaLinux mirror base URL
#                     (default: https://repo.almalinux.org/almalinux)
#   --release <num>   AlmaLinux major release  (default: 9)
#   --arch    <arch>  CPU architecture         (default: x86_64)
#   --out     <dir>   output directory         (default: ~/netboot)
#   --help            show this help and exit
#
# Behaviour:
#   - Constructs the pxeboot URL:
#       ${mirror}/${release}/BaseOS/${arch}/os/images/pxeboot/
#   - Downloads vmlinuz, initrd.img, and CHECKSUM from that URL.
#   - Verifies sha256 checksums for both files; aborts on mismatch.
#   - Safe to re-run: skips any file whose checksum already matches.
#   - Sets files world-readable (chmod 644) so rootless nginx can serve them.
#
# Examples:
#   netboot/fetch-almalinux-installer.sh
#   netboot/fetch-almalinux-installer.sh --release 8 --arch x86_64
#   netboot/fetch-almalinux-installer.sh \
#       --mirror https://mirror.example.org/almalinux --out /srv/netboot

set -euo pipefail

readonly LAB_PROG="${0##*/}"

# ─── Logging ────────────────────────────────────────────────────────────────
_log() {
    local level="$1"; shift
    local color reset
    if [[ -t 2 ]]; then
        case "$level" in
            info)  color=$'\033[36m' ;;
            warn)  color=$'\033[33m' ;;
            error) color=$'\033[31m' ;;
            *)     color='' ;;
        esac
        reset=$'\033[0m'
    else
        color=""; reset=""
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info()  { _log info  "$@"; }
log_warn()  { _log warn  "$@"; }
log_error() { _log error "$@"; }
die()       { _log error "$@"; exit 1; }

# ─── Usage ──────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: netboot/fetch-almalinux-installer.sh [OPTIONS]

Download the AlmaLinux PXE installer kernel and initrd from an upstream mirror,
verify their sha256 checksums, and make them world-readable for rootless nginx.

Options:
  --mirror  URL   upstream AlmaLinux mirror base URL
                  (default: https://repo.almalinux.org/almalinux)
  --release NUM   AlmaLinux major release  (default: 9)
  --arch    ARCH  CPU architecture         (default: x86_64)
  --out     DIR   output directory         (default: ~/netboot)
  --help          show this help and exit

Files written to --out:
  vmlinuz     AlmaLinux installer kernel
  initrd.img  AlmaLinux installer initrd
  CHECKSUM    upstream checksum file (kept for reference)

Examples:
  netboot/fetch-almalinux-installer.sh
  netboot/fetch-almalinux-installer.sh --release 8
  netboot/fetch-almalinux-installer.sh --mirror https://mirror.example.org/almalinux --out /srv/netboot
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
mirror="https://repo.almalinux.org/almalinux"
release="9"
arch="x86_64"
out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror)  shift; mirror="${1:?--mirror requires a URL}";    shift ;;
        --release) shift; release="${1:?--release requires a number}"; shift ;;
        --arch)    shift; arch="${1:?--arch requires an architecture}"; shift ;;
        --out)     shift; out_dir="${1:?--out requires a path}";     shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Pre-flight checks ──────────────────────────────────────────────────────
if ! command -v curl &>/dev/null; then
    die "curl is required but not found in PATH"
fi
if ! command -v sha256sum &>/dev/null; then
    die "sha256sum is required but not found in PATH"
fi

# ─── Derived values ──────────────────────────────────────────────────────────
pxeboot_url="${mirror}/${release}/BaseOS/${arch}/os/images/pxeboot"

log_info "AlmaLinux ${release} ${arch} pxeboot URL: ${pxeboot_url}"
log_info "output directory: ${out_dir}"

mkdir -p "$out_dir"

# ─── Helper: download one file (skip if already present and verified) ────────
# Usage: fetch_file <remote-url> <local-dest>
fetch_file() {
    local url="$1"
    local dest="$2"
    local name="${dest##*/}"

    if [[ -f "$dest" ]]; then
        log_info "  ${name}: already present (will verify below)"
    else
        log_info "  downloading ${name}..."
        curl -fSL --progress-bar -o "$dest" "$url"
        log_info "  ${name}: downloaded"
    fi
}

# ─── Helper: verify a file against lines from the CHECKSUM file ─────────────
# Usage: verify_file <checksum-file> <local-path>
# Filters the CHECKSUM file to the single line for the target filename,
# then pipes it to sha256sum --check.  AlmaLinux CHECKSUM lines use the form:
#   SHA256 (vmlinuz) = <hex>
# which is NOT the two-column sha256sum format.  We normalise it ourselves.
verify_file() {
    local checksum_file="$1"
    local file_path="$2"
    local name="${file_path##*/}"
    local dir
    dir="$(dirname "$file_path")"

    # Extract the sha256 hex for this filename.
    # AlmaLinux CHECKSUM format: "SHA256 (filename) = <hex>"
    local hex
    hex=$(grep -i "^SHA256 (${name})" "$checksum_file" \
              | sed 's/.*= *//' \
              | tr -d '[:space:]')

    if [[ -z "$hex" ]]; then
        die "no SHA256 entry for '${name}' found in CHECKSUM file"
    fi

    log_info "  verifying ${name} (sha256: ${hex:0:16}...)..."
    # Build a two-column sha256sum input and check from the file's directory
    # so the relative path in the manifest matches.
    printf '%s  %s\n' "$hex" "$name" | (cd "$dir" && sha256sum --check --strict -)
    log_info "  ${name}: checksum OK"
}

# ─── Step 1: Download CHECKSUM ───────────────────────────────────────────────
checksum_dest="${out_dir}/CHECKSUM"
log_info "downloading CHECKSUM..."
# Always re-download the CHECKSUM file so we always have the latest signature.
curl -fSL --progress-bar -o "$checksum_dest" "${pxeboot_url}/CHECKSUM"
log_info "CHECKSUM downloaded"

# ─── Step 2: Download vmlinuz and initrd.img ─────────────────────────────────
log_info "fetching installer files..."
fetch_file "${pxeboot_url}/vmlinuz"    "${out_dir}/vmlinuz"
fetch_file "${pxeboot_url}/initrd.img" "${out_dir}/initrd.img"

# ─── Step 3: Verify checksums ────────────────────────────────────────────────
log_info "verifying checksums..."
verify_file "$checksum_dest" "${out_dir}/vmlinuz"
verify_file "$checksum_dest" "${out_dir}/initrd.img"

# ─── Step 4: Set permissions ─────────────────────────────────────────────────
# world-readable so a rootless nginx container can serve them without needing
# to run as the owning UID.
log_info "setting permissions (chmod 644)..."
chmod 644 "${out_dir}/vmlinuz" "${out_dir}/initrd.img" "${out_dir}/CHECKSUM"

# If running as root (e.g., inside a setup wrapper), chown back to the real
# invoking user so the files don't end up root-owned in the user's home dir.
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" \
        "${out_dir}/vmlinuz" "${out_dir}/initrd.img" "${out_dir}/CHECKSUM"
    log_info "chowned to UID ${SUDO_UID}"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "done — installer artifacts ready in ${out_dir}:"
for f in vmlinuz initrd.img CHECKSUM; do
    fp="${out_dir}/${f}"
    if [[ -f "$fp" ]]; then
        size=$(du -sh "$fp" 2>/dev/null | cut -f1)
        log_info "  ${f}  (${size})"
    fi
done
log_info ""
log_info "next steps:"
log_info "  Generate a per-host kickstart:"
log_info "    netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01"
log_info "  Build iPXE with the AlmaLinux boot parameters:"
log_info "    netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\"
log_info "        --kernel-path /vmlinuz --initrd-path /initrd.img \\"
log_info "        --append 'inst.repo=https://repo.almalinux.org/almalinux/${release}/BaseOS/${arch}/os/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'"
log_info "  Start nginx to serve artifacts:"
log_info "    phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml"
