#!/usr/bin/env bash
# fetch-kali-installer.sh — Download and verify the Kali Linux netboot
#                           (Debian-installer) kernel and initrd.
#
# Kali's network install uses the DEBIAN INSTALLER (d-i), not Anaconda.  The
# installer kernel ("linux") and initrd ("initrd.gz") live in Kali's netboot
# tree and are listed, with sha256 checksums, in the images-tree SHA256SUMS:
#
#   https://http.kali.org/kali/dists/kali-rolling/main/installer-${arch}/current/images/
#       SHA256SUMS
#       netboot/debian-installer/${arch}/linux
#       netboot/debian-installer/${arch}/initrd.gz
#
# This is the same artifact the Kali docs' netboot.tar.gz unpacks to — we fetch
# the two files directly (no tarball unpack) and verify both against SHA256SUMS.
#
# ─── Integrity note ──────────────────────────────────────────────────────────
# SHA256SUMS is fetched over HTTPS and trusted as-is: Kali does not publish a
# detached SHA256SUMS.sign at this path (404), so there is no in-band GPG step
# here.  TLS to http.kali.org is the trust boundary for the boot images — the
# same posture as the AlmaLinux/Rocky fetch helpers.  (Packages installed
# *during* the d-i run are still GPG-verified by apt against Kali's archive key,
# which ships inside the netboot initrd.)
#
# ─── Output layout (avoids collision with the Rocky/Alma labs) ───────────────
# Writes to ~/netboot/kali/ by default — NOT ~/netboot/ — so its `linux` and
# `initrd.gz` don't clash with the AlmaLinux/Rocky `vmlinuz`/`initrd.img` that
# the other PXE labs drop directly in ~/netboot/.  nginx serves all of ~/netboot/,
# so these end up at http://SRV/kali/linux etc.
#
# Usage:
#   examples/kali-pxe-lab/fetch-kali-installer.sh [OPTIONS]
#
# Options:
#   --mirror  <url>   Kali mirror base URL
#                     (default: https://http.kali.org/kali)
#   --suite   <name>  Kali suite      (default: kali-rolling)
#   --arch    <arch>  d-i architecture: amd64 | i386 | arm64  (default: amd64)
#   --out     <dir>   output directory (default: ~/netboot/kali)
#   --help            show this help and exit
#
# Examples:
#   examples/kali-pxe-lab/fetch-kali-installer.sh
#   examples/kali-pxe-lab/fetch-kali-installer.sh --arch arm64
#   examples/kali-pxe-lab/fetch-kali-installer.sh --out /srv/netboot/kali

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
Usage: examples/kali-pxe-lab/fetch-kali-installer.sh [OPTIONS]

Download the Kali Linux netboot (Debian-installer) kernel + initrd, verify
both against the tree's SHA256SUMS, and make them world-readable for rootless
nginx.

Options:
  --mirror  URL   Kali mirror base URL  (default: https://http.kali.org/kali)
  --suite   NAME  Kali suite            (default: kali-rolling)
  --arch    ARCH  d-i arch: amd64|i386|arm64  (default: amd64)
  --out     DIR   output directory      (default: ~/netboot/kali)
  --help          show this help and exit

Files written to --out:
  linux        Kali d-i installer kernel
  initrd.gz    Kali d-i installer initrd
  SHA256SUMS   upstream checksum file (kept for reference)

Examples:
  examples/kali-pxe-lab/fetch-kali-installer.sh
  examples/kali-pxe-lab/fetch-kali-installer.sh --out /srv/netboot/kali
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
mirror="https://http.kali.org/kali"
suite="kali-rolling"
arch="amd64"
out_dir=""

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror)  shift; mirror="${1:?--mirror requires a URL}";       shift ;;
        --suite)   shift; suite="${1:?--suite requires a name}";        shift ;;
        --arch)    shift; arch="${1:?--arch requires an architecture}"; shift ;;
        --out)     shift; out_dir="${1:?--out requires a path}";        shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# Default out dir uses LAB_NETBOOT_DIR if set, else ~/netboot, then /kali.
[[ -n "$out_dir" ]] || out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/kali"

# ─── Pre-flight checks ──────────────────────────────────────────────────────
command -v curl      &>/dev/null || die "curl is required but not found in PATH"
command -v sha256sum &>/dev/null || die "sha256sum is required but not found in PATH"

# ─── Derived values ──────────────────────────────────────────────────────────
images_url="${mirror}/dists/${suite}/main/installer-${arch}/current/images"
sums_url="${images_url}/SHA256SUMS"
# Paths relative to the images tree root (these are how they appear in SHA256SUMS).
kernel_rel="./netboot/debian-installer/${arch}/linux"
initrd_rel="./netboot/debian-installer/${arch}/initrd.gz"

log_info "Kali ${suite} ${arch} (Debian-installer netboot)"
log_info "  images URL  : ${images_url}"
log_info "  output dir  : ${out_dir}"

mkdir -p "$out_dir"

# ─── Step 1: download SHA256SUMS (always fresh — Kali rolling moves daily) ───
sums_dest="${out_dir}/SHA256SUMS"
log_info "downloading SHA256SUMS..."
curl -fSL --progress-bar -o "$sums_dest" "$sums_url" \
    || die "could not fetch SHA256SUMS from ${sums_url}"

# ─── Helper: pull the sha256 hex for a tree-relative path out of SHA256SUMS ──
# SHA256SUMS is the standard two-column format:  <hex>  ./path
sums_sha256() {
    local sums="$1" relpath="$2"
    awk -v p="$relpath" '$2 == p { print $1; exit }' "$sums"
}

# ─── Helper: download a file and verify it against SHA256SUMS ────────────────
# Usage: fetch_and_verify <local-name> <tree-relative-path>
fetch_and_verify() {
    local name="$1" relpath="$2"
    local dest="${out_dir}/${name}"

    local want
    want="$(sums_sha256 "$sums_dest" "$relpath")"
    [[ -n "$want" ]] || die "no '${relpath}' entry in SHA256SUMS — is the mirror/suite/arch correct?"

    # Re-use an already-correct local copy (safe to re-run).
    if [[ -f "$dest" ]]; then
        local have
        have="$(sha256sum "$dest" | cut -d' ' -f1)"
        if [[ "$have" == "$want" ]]; then
            log_info "  ${name}: already present and verified (sha256 ${want:0:16}...)"
            return 0
        fi
        log_warn "  ${name}: present but checksum differs — re-downloading"
    fi

    log_info "  downloading ${name}..."
    # -L: follow the mirror redirect (http.kali.org 302s to a CDN/mirror).
    curl -fSL --progress-bar -o "$dest" "${images_url}/${relpath#./}" \
        || die "download failed: ${images_url}/${relpath#./}"

    log_info "  verifying ${name} (sha256 ${want:0:16}...)..."
    printf '%s  %s\n' "$want" "$name" | (cd "$out_dir" && sha256sum --check --strict -) \
        || die "CHECKSUM MISMATCH for ${name} — refusing to use a tampered/corrupt file"
    log_info "  ${name}: checksum OK"
}

# ─── Step 2 + 3: download and verify the d-i kernel + initrd ─────────────────
log_info "fetching + verifying installer files..."
fetch_and_verify linux     "$kernel_rel"
fetch_and_verify initrd.gz "$initrd_rel"

# ─── Step 4: permissions (world-readable so rootless nginx can serve them) ───
log_info "setting permissions (chmod 644)..."
chmod 644 "${out_dir}/linux" "${out_dir}/initrd.gz" "$sums_dest"

if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" \
        "${out_dir}/linux" "${out_dir}/initrd.gz" "$sums_dest"
    log_info "chowned to UID ${SUDO_UID}"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "done — Kali ${suite} installer artifacts ready in ${out_dir}:"
for f in linux initrd.gz; do
    fp="${out_dir}/${f}"
    [[ -f "$fp" ]] && log_info "  ${f}  ($(du -sh "$fp" 2>/dev/null | cut -f1))"
done
log_info ""
log_info "next steps (see examples/kali-pxe-lab/README.md):"
log_info "  1. Stage the preseed into the served dir:"
log_info "       cp examples/kali-pxe-lab/kali-preseed.cfg ${out_dir}/"
log_info "  2. Build iPXE with the d-i boot params:"
log_info "       netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\"
log_info "           --kernel-path /kali/linux --initrd-path /kali/initrd.gz \\"
log_info "           --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/kali/kali-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'"
log_info "  3. Serve + boot:"
log_info "       phase4-podman/lab-podman.sh up     --config examples/kali-pxe-lab/kali-pxe-lab.toml"
log_info "       phase2-qemu-vm/lab-vm.sh    create --config examples/kali-pxe-lab/kali-pxe-lab.toml"
log_info "       phase2-qemu-vm/lab-vm.sh    start  kali-pxe-install"
