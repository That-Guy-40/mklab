#!/usr/bin/env bash
# fetch-debian-installer.sh — Download and verify the Debian netboot
#                            (Debian-installer) kernel and initrd for trixie.
#
# Debian's network install uses the DEBIAN INSTALLER (d-i), the same installer
# family Kali is built on — driven by a *preseed* file, NOT Anaconda/kickstart
# like the Rocky/AlmaLinux labs.  The installer kernel ("linux") and initrd
# ("initrd.gz") live in Debian's netboot tree and are listed, with sha256
# checksums, in the images-tree SHA256SUMS:
#
#   https://deb.debian.org/debian/dists/${suite}/main/installer-${arch}/current/images/
#       SHA256SUMS
#       netboot/debian-installer/${arch}/linux
#       netboot/debian-installer/${arch}/initrd.gz
#
# This is the same artifact the netboot.tar.gz unpacks to — we fetch the two
# files directly (no tarball unpack) and verify both against SHA256SUMS.
#
# ─── Integrity note (stronger than the Kali fetch) ───────────────────────────
# Unlike Kali, Debian DOES publish a detached, GPG-signed SHA256SUMS.sign next
# to SHA256SUMS, signed by the Debian installer signing key.  This helper fetches
# SHA256SUMS over HTTPS and trusts it as-is (TLS to deb.debian.org is the trust
# boundary — the same posture as the Kali/Alma/Rocky fetch helpers).  For a
# stronger chain, pass --verify-sig: the SHA256SUMS.sign is fetched and checked
# with gpgv against the Debian keyring (needs the `debian-keyring` /
# `debian-installer` archive keys, or your own copy of the signing key).
# Packages installed *during* the d-i run are always GPG-verified by apt against
# the Debian archive key, which ships inside the netboot initrd.
#
# ─── Output layout (avoids collision with the Kali/Rocky/Alma labs) ──────────
# Writes to ~/netboot/debian/ by default — NOT ~/netboot/ — so its `linux` and
# `initrd.gz` don't clash with the Kali `~/netboot/kali/linux` or the
# AlmaLinux/Rocky `vmlinuz`/`initrd.img` in ~/netboot/.  nginx serves all of
# ~/netboot/, so these end up at http://SRV/debian/linux etc.
#
# Usage:
#   examples/debian-pxe-lab/fetch-debian-installer.sh [OPTIONS]
#
# Options:
#   --mirror  <url>   Debian mirror base URL
#                     (default: https://deb.debian.org/debian)
#   --suite   <name>  Debian suite   (default: trixie)   [trixie|bookworm|stable|testing]
#   --arch    <arch>  d-i architecture: amd64 | arm64 | i386  (default: amd64)
#   --out     <dir>   output directory (default: ~/netboot/debian)
#   --verify-sig      also GPG-verify SHA256SUMS.sign with gpgv (needs keyring)
#   --help            show this help and exit
#
# Examples:
#   examples/debian-pxe-lab/fetch-debian-installer.sh
#   examples/debian-pxe-lab/fetch-debian-installer.sh --arch arm64
#   examples/debian-pxe-lab/fetch-debian-installer.sh --suite bookworm

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
Usage: examples/debian-pxe-lab/fetch-debian-installer.sh [OPTIONS]

Download the Debian trixie netboot (Debian-installer) kernel + initrd, verify
both against the tree's SHA256SUMS, and make them world-readable for rootless
nginx.

Options:
  --mirror  URL   Debian mirror base URL  (default: https://deb.debian.org/debian)
  --suite   NAME  Debian suite            (default: trixie)
  --arch    ARCH  d-i arch: amd64|arm64|i386  (default: amd64)
  --out     DIR   output directory        (default: ~/netboot/debian)
  --verify-sig    GPG-verify SHA256SUMS.sign with gpgv (needs Debian keyring)
  --help          show this help and exit

Files written to --out:
  linux        Debian d-i installer kernel
  initrd.gz    Debian d-i installer initrd
  SHA256SUMS   upstream checksum file (kept for reference)

Examples:
  examples/debian-pxe-lab/fetch-debian-installer.sh
  examples/debian-pxe-lab/fetch-debian-installer.sh --out /srv/netboot/debian
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
mirror="https://deb.debian.org/debian"
suite="trixie"
arch="amd64"
out_dir=""
verify_sig=0

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror)     shift; mirror="${1:?--mirror requires a URL}";       shift ;;
        --suite)      shift; suite="${1:?--suite requires a name}";        shift ;;
        --arch)       shift; arch="${1:?--arch requires an architecture}"; shift ;;
        --out)        shift; out_dir="${1:?--out requires a path}";        shift ;;
        --verify-sig) verify_sig=1; shift ;;
        --help|-h)    usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# Default out dir uses LAB_NETBOOT_DIR if set, else ~/netboot, then /debian.
[[ -n "$out_dir" ]] || out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}/debian"

# ─── Pre-flight checks ──────────────────────────────────────────────────────
command -v curl      &>/dev/null || die "curl is required but not found in PATH"
command -v sha256sum &>/dev/null || die "sha256sum is required but not found in PATH"

# ─── Derived values ──────────────────────────────────────────────────────────
images_url="${mirror}/dists/${suite}/main/installer-${arch}/current/images"
sums_url="${images_url}/SHA256SUMS"
# Paths relative to the images tree root (these are how they appear in SHA256SUMS).
kernel_rel="./netboot/debian-installer/${arch}/linux"
initrd_rel="./netboot/debian-installer/${arch}/initrd.gz"

log_info "Debian ${suite} ${arch} (Debian-installer netboot)"
log_info "  images URL  : ${images_url}"
log_info "  output dir  : ${out_dir}"

mkdir -p "$out_dir"

# ─── Step 1: download SHA256SUMS ─────────────────────────────────────────────
sums_dest="${out_dir}/SHA256SUMS"
log_info "downloading SHA256SUMS..."
curl -fSL --progress-bar -o "$sums_dest" "$sums_url" \
    || die "could not fetch SHA256SUMS from ${sums_url}"

# ─── Optional: GPG-verify the checksum list against the Debian signing key ───
if (( verify_sig )); then
    command -v gpgv &>/dev/null || die "--verify-sig needs gpgv (apt install gpgv)"
    sign_dest="${out_dir}/SHA256SUMS.sign"
    log_info "downloading SHA256SUMS.sign + verifying with gpgv..."
    curl -fSL --progress-bar -o "$sign_dest" "${sums_url}.sign" \
        || die "could not fetch SHA256SUMS.sign (does this suite/arch publish one?)"
    # Prefer a system keyring that carries the d-i signing key; fall back to the
    # user keyring.  The exact keyring path varies by distro; try the usual ones.
    kr=""
    for k in /usr/share/keyrings/debian-role-keys.gpg \
             /usr/share/keyrings/debian-archive-keyring.gpg \
             "$HOME/.gnupg/trustedkeys.gpg"; do
        [[ -r "$k" ]] && { kr="$k"; break; }
    done
    [[ -n "$kr" ]] || die "no Debian keyring found — apt install debian-keyring, or import the d-i signing key into ~/.gnupg/trustedkeys.gpg"
    gpgv --keyring "$kr" "$sign_dest" "$sums_dest" \
        || die "GPG verification FAILED — refusing to trust SHA256SUMS"
    log_info "  SHA256SUMS.sign verified against ${kr}"
fi

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
    # -L: follow the mirror redirect (deb.debian.org fronts a CDN).
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
log_info "done — Debian ${suite} installer artifacts ready in ${out_dir}:"
for f in linux initrd.gz; do
    fp="${out_dir}/${f}"
    [[ -f "$fp" ]] && log_info "  ${f}  ($(du -sh "$fp" 2>/dev/null | cut -f1))"
done
log_info ""
log_info "next steps (see examples/debian-pxe-lab/README.md):"
log_info "  1. Stage the preseed into the served dir:"
log_info "       cp examples/debian-pxe-lab/debian-preseed.cfg ${out_dir}/"
log_info "  2. Build iPXE with the d-i boot params:"
log_info "       netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\"
log_info "           --kernel-path /debian/linux --initrd-path /debian/initrd.gz \\"
log_info "           --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/debian/debian-preseed.cfg DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'"
log_info "  3. Serve + boot:"
log_info "       phase4-podman/lab-podman.sh up     --config examples/debian-pxe-lab/debian-pxe-lab.toml"
log_info "       phase2-qemu-vm/lab-vm.sh    create --config examples/debian-pxe-lab/debian-pxe-lab.toml"
log_info "       phase2-qemu-vm/lab-vm.sh    start  debian-pxe-install"
