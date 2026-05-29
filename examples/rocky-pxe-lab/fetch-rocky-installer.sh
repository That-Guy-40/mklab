#!/usr/bin/env bash
# fetch-rocky-installer.sh — Download and verify the Rocky Linux PXE installer
#                            kernel and initrd from an upstream mirror.
#
# Downloads vmlinuz and initrd.img from the Rocky BaseOS images/pxeboot/ tree
# and verifies both against the sha256 checksums published in the tree's
# `.treeinfo` file, then makes them world-readable for a rootless nginx
# container to serve.
#
# ─── Why .treeinfo and not a CHECKSUM file? ──────────────────────────────────
# AlmaLinux ships a per-directory `CHECKSUM` inside images/pxeboot/, so its
# fetch helper (netboot/fetch-almalinux-installer.sh) reads that.  Rocky does
# NOT publish a CHECKSUM in pxeboot/ — requesting it returns 404.  Rocky's
# canonical integrity source for the boot images is the productmd `.treeinfo`
# file at the root of the BaseOS `os/` tree, whose `[checksums]` section lists:
#
#     images/pxeboot/initrd.img = sha256:<hex>
#     images/pxeboot/vmlinuz    = sha256:<hex>
#
# These checksums change with every point release (Rocky 9 currently resolves
# to 9.x), so we fetch `.treeinfo` live and parse it rather than hardcoding a
# hash.  (.treeinfo is a productmd standard and works for AlmaLinux too, so this
# parser is the more portable approach of the two.)
#
# Usage:
#   examples/rocky-pxe-lab/fetch-rocky-installer.sh [OPTIONS]
#
# Options:
#   --mirror  <url>   upstream Rocky mirror base URL
#                     (default: https://download.rockylinux.org/pub/rocky)
#   --release <num>   Rocky major release  (default: 9)
#   --arch    <arch>  CPU architecture     (default: x86_64)
#   --out     <dir>   output directory     (default: ~/netboot)
#   --help            show this help and exit
#
# Examples:
#   examples/rocky-pxe-lab/fetch-rocky-installer.sh
#   examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 8
#   examples/rocky-pxe-lab/fetch-rocky-installer.sh \
#       --mirror https://dl.rockylinux.org/pub/rocky --out /srv/netboot

set -euo pipefail


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
Usage: examples/rocky-pxe-lab/fetch-rocky-installer.sh [OPTIONS]

Download the Rocky Linux PXE installer kernel and initrd from an upstream
mirror, verify their sha256 checksums against the tree's .treeinfo, and make
them world-readable for rootless nginx.

Options:
  --mirror  URL   upstream Rocky mirror base URL
                  (default: https://download.rockylinux.org/pub/rocky)
  --release NUM   Rocky major release  (default: 9)
  --arch    ARCH  CPU architecture     (default: x86_64)
  --out     DIR   output directory     (default: ~/netboot)
  --help          show this help and exit

Files written to --out:
  vmlinuz     Rocky installer kernel
  initrd.img  Rocky installer initrd
  .treeinfo   the parsed tree metadata (kept for reference)

Examples:
  examples/rocky-pxe-lab/fetch-rocky-installer.sh
  examples/rocky-pxe-lab/fetch-rocky-installer.sh --release 8
  examples/rocky-pxe-lab/fetch-rocky-installer.sh --mirror https://dl.rockylinux.org/pub/rocky --out /srv/netboot
EOF
    exit 0
}

# ─── Defaults ───────────────────────────────────────────────────────────────
mirror="https://download.rockylinux.org/pub/rocky"
release="9"
arch="x86_64"
out_dir="${LAB_NETBOOT_DIR:-$HOME/netboot}"

# ─── Arg parsing ────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mirror)  shift; mirror="${1:?--mirror requires a URL}";       shift ;;
        --release) shift; release="${1:?--release requires a number}";  shift ;;
        --arch)    shift; arch="${1:?--arch requires an architecture}"; shift ;;
        --out)     shift; out_dir="${1:?--out requires a path}";        shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done

# ─── Pre-flight checks ──────────────────────────────────────────────────────
command -v curl      &>/dev/null || die "curl is required but not found in PATH"
command -v sha256sum &>/dev/null || die "sha256sum is required but not found in PATH"

# ─── Derived values ──────────────────────────────────────────────────────────
os_url="${mirror}/${release}/BaseOS/${arch}/os"
pxeboot_url="${os_url}/images/pxeboot"
treeinfo_url="${os_url}/.treeinfo"

log_info "Rocky ${release} ${arch}"
log_info "  pxeboot URL : ${pxeboot_url}"
log_info "  treeinfo    : ${treeinfo_url}"
log_info "  output dir  : ${out_dir}"

mkdir -p "$out_dir"

# ─── Step 1: download .treeinfo (always fresh — checksums move per release) ──
treeinfo_dest="${out_dir}/.treeinfo"
log_info "downloading .treeinfo..."
curl -fSL --progress-bar -o "$treeinfo_dest" "$treeinfo_url" \
    || die "could not fetch .treeinfo from ${treeinfo_url}"

# ─── Helper: pull the sha256 hex for an image key out of .treeinfo ───────────
# .treeinfo [checksums] lines look like:
#     images/pxeboot/vmlinuz = sha256:1fd4b7d710...
# We match the key exactly, strip the "sha256:" prefix, and trim whitespace.
treeinfo_sha256() {
    local treeinfo="$1" key="$2"
    awk -F' = ' -v k="$key" '
        $1 == k { v=$2; sub(/^sha256:/, "", v); gsub(/[[:space:]]/, "", v); print v; exit }
    ' "$treeinfo"
}

# ─── Helper: download a pxeboot file and verify it against .treeinfo ─────────
# Usage: fetch_and_verify <pxeboot-filename> <treeinfo-image-key>
fetch_and_verify() {
    local name="$1" key="$2"
    local dest="${out_dir}/${name}"

    local want
    want="$(treeinfo_sha256 "$treeinfo_dest" "$key")"
    [[ -n "$want" ]] || die "no '${key}' sha256 entry in .treeinfo — is the mirror/release correct?"

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
    curl -fSL --progress-bar -o "$dest" "${pxeboot_url}/${name}" \
        || die "download failed: ${pxeboot_url}/${name}"

    log_info "  verifying ${name} (sha256 ${want:0:16}...)..."
    printf '%s  %s\n' "$want" "$name" | (cd "$out_dir" && sha256sum --check --strict -) \
        || die "CHECKSUM MISMATCH for ${name} — refusing to use a tampered/corrupt file"
    log_info "  ${name}: checksum OK"
}

# ─── Step 2 + 3: download and verify the boot images ─────────────────────────
log_info "fetching + verifying installer files..."
fetch_and_verify vmlinuz    images/pxeboot/vmlinuz
fetch_and_verify initrd.img images/pxeboot/initrd.img

# ─── Stage2 runtime image (images/install.img, ~1 GB) ───────────────────────
# Served LOCALLY so Anaconda's dracut loads it from this nginx instead of
# streaming ~1 GB from a remote mirror — that large transfer truncates over
# constrained links (e.g. QEMU slirp).  Kept under images/ so the boot param
# `inst.stage2=http://SERVER/` resolves it at /images/install.img.  Verified
# against .treeinfo like the boot images.
log_info "fetching + verifying the stage2 install.img (large — served locally)..."
install_img_want="$(treeinfo_sha256 "$treeinfo_dest" images/install.img)"
[[ -n "$install_img_want" ]] || die "no 'images/install.img' sha256 entry in .treeinfo"
mkdir -p "${out_dir}/images"
install_img_dest="${out_dir}/images/install.img"
if [[ -f "$install_img_dest" && "$(sha256sum "$install_img_dest" | cut -d' ' -f1)" == "$install_img_want" ]]; then
    log_info "  images/install.img: already present and verified"
else
    log_info "  downloading images/install.img (this is the big one)..."
    # Resume (-C -) + retry: mirrors/CDNs often drop this ~1 GB transfer partway
    # (curl 18); resume continues from the partial file across retries.
    curl -fSL -C - --retry 8 --retry-delay 3 --retry-all-errors --progress-bar \
        -o "$install_img_dest" "${os_url}/images/install.img" \
        || die "download failed: ${os_url}/images/install.img"
    printf '%s  %s\n' "$install_img_want" "images/install.img" | (cd "$out_dir" && sha256sum --check --strict -) \
        || die "CHECKSUM MISMATCH for images/install.img — refusing to use a tampered/corrupt file"
    log_info "  images/install.img: checksum OK"
fi

# ─── Step 4: permissions (world-readable so rootless nginx can serve them) ───
log_info "setting permissions (chmod 644)..."
chmod 644 "${out_dir}/vmlinuz" "${out_dir}/initrd.img" "$install_img_dest" "$treeinfo_dest"

# If invoked under sudo, hand ownership back to the real user so the artifacts
# in their ~/netboot are not root-owned.
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" \
        "${out_dir}/vmlinuz" "${out_dir}/initrd.img" "$install_img_dest" "$treeinfo_dest"
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "${out_dir}/images" 2>/dev/null || true
    log_info "chowned to UID ${SUDO_UID}"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "done — Rocky ${release} installer artifacts ready in ${out_dir}:"
for f in vmlinuz initrd.img; do
    fp="${out_dir}/${f}"
    [[ -f "$fp" ]] && log_info "  ${f}  ($(du -sh "$fp" 2>/dev/null | cut -f1))"
done
log_info ""
log_info "next steps (see examples/rocky-pxe-lab/README.md):"
log_info "  1. Generate a per-host kickstart (reuses the generic copy helper):"
log_info "       netboot/gen-almalinux-ks.sh --mac 52:54:00:cc:09:09 \\"
log_info "           --template examples/rocky-pxe-lab/rocky9-zerotouch.ks"
log_info "  2. Build iPXE with Rocky boot params (inst.stage2 = the LOCAL install.img):"
log_info "       netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\"
log_info "           --kernel-path /vmlinuz --initrd-path /initrd.img \\"
log_info "           --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=${os_url}/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'"
log_info "  3. Serve + boot:"
log_info "       phase4-podman/lab-podman.sh up     --config examples/rocky-pxe-lab/rocky-pxe-lab.toml"
log_info "       phase2-qemu-vm/lab-vm.sh    create --config examples/rocky-pxe-lab/rocky-pxe-lab.toml"
log_info "       phase2-qemu-vm/lab-vm.sh    start  rocky-pxe-install"
