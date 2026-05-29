#!/usr/bin/env bash
# fetch-almalinux-installer.sh — Download and verify the AlmaLinux PXE installer
#                                 kernel, initrd, and stage2 from an upstream mirror.
#
# Downloads vmlinuz + initrd.img (from images/pxeboot/) and the stage2 runtime
# images/install.img, verifying all three against the sha256 checksums in the os
# tree's productmd `.treeinfo`, then makes them world-readable for a rootless
# nginx container.
#
# ─── Why .treeinfo (not the per-dir CHECKSUM)? ───────────────────────────────
# images/pxeboot/CHECKSUM is not reliably published (it 404s on some mirrors) and
# does NOT cover images/install.img (the ~1 GB stage2, which lives one dir up).
# The os tree's `.treeinfo` is a productmd standard that lists sha256 for every
# image — vmlinuz, initrd.img AND install.img — and is the same source the Rocky
# fetcher uses.  Checksums move per point release (9 → 9.x), so we fetch it live.
#
# ─── Why fetch install.img at all? ───────────────────────────────────────────
# Serving the stage2 LOCALLY (nginx) lets the install boot param
# `inst.stage2=http://SERVER/` load it from /images/install.img instead of
# streaming ~1 GB from a remote mirror — that large transfer truncates over
# constrained links (e.g. QEMU slirp), which fails the install at dracut.
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
# Examples:
#   netboot/fetch-almalinux-installer.sh
#   netboot/fetch-almalinux-installer.sh --release 8 --arch x86_64
#   netboot/fetch-almalinux-installer.sh \
#       --mirror https://mirror.example.org/almalinux --out /srv/netboot

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
Usage: netboot/fetch-almalinux-installer.sh [OPTIONS]

Download the AlmaLinux PXE installer kernel, initrd, and stage2 install.img,
verify their sha256 checksums against the tree's .treeinfo, and make them
world-readable for rootless nginx.

Options:
  --mirror  URL   upstream AlmaLinux mirror base URL
                  (default: https://repo.almalinux.org/almalinux)
  --release NUM   AlmaLinux major release  (default: 9)
  --arch    ARCH  CPU architecture         (default: x86_64)
  --out     DIR   output directory         (default: ~/netboot)
  --help          show this help and exit

Files written to --out:
  vmlinuz             AlmaLinux installer kernel
  initrd.img          AlmaLinux installer initrd
  images/install.img  stage2 runtime (served locally via inst.stage2)
  .treeinfo           the parsed tree metadata (kept for reference)

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
command -v curl      &>/dev/null || die "curl is required but not found in PATH"
command -v sha256sum &>/dev/null || die "sha256sum is required but not found in PATH"

# ─── Derived values ──────────────────────────────────────────────────────────
os_url="${mirror}/${release}/BaseOS/${arch}/os"
pxeboot_url="${os_url}/images/pxeboot"
treeinfo_url="${os_url}/.treeinfo"

log_info "AlmaLinux ${release} ${arch}"
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
# .treeinfo [checksums] lines look like:  images/pxeboot/vmlinuz = sha256:1fd4...
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

    if [[ -f "$dest" ]]; then
        local have; have="$(sha256sum "$dest" | cut -d' ' -f1)"
        if [[ "$have" == "$want" ]]; then
            log_info "  ${name}: already present and verified (sha256 ${want:0:16}...)"
            return 0
        fi
        log_warn "  ${name}: present but checksum differs — re-downloading"
    fi

    log_info "  downloading ${name}..."
    curl -fSL --progress-bar -o "$dest" "${pxeboot_url}/${name}" \
        || die "download failed: ${pxeboot_url}/${name}"
    printf '%s  %s\n' "$want" "$name" | (cd "$out_dir" && sha256sum --check --strict -) \
        || die "CHECKSUM MISMATCH for ${name} — refusing to use a tampered/corrupt file"
    log_info "  ${name}: checksum OK"
}

# ─── Step 2: download + verify the boot images ───────────────────────────────
log_info "fetching + verifying installer files..."
fetch_and_verify vmlinuz    images/pxeboot/vmlinuz
fetch_and_verify initrd.img images/pxeboot/initrd.img

# ─── Stage2 runtime image (images/install.img, ~1 GB) — served LOCALLY ───────
# Kept under images/ so the boot param `inst.stage2=http://SERVER/` resolves it
# at /images/install.img.  Verified against .treeinfo like the boot images.
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

# ─── Step 3: permissions (world-readable so rootless nginx can serve them) ───
log_info "setting permissions (chmod 644)..."
chmod 644 "${out_dir}/vmlinuz" "${out_dir}/initrd.img" "$install_img_dest" "$treeinfo_dest"
if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" \
        "${out_dir}/vmlinuz" "${out_dir}/initrd.img" "$install_img_dest" "$treeinfo_dest"
    chown "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "${out_dir}/images" 2>/dev/null || true
    log_info "chowned to UID ${SUDO_UID}"
fi

# ─── Summary ────────────────────────────────────────────────────────────────
log_info "done — AlmaLinux ${release} installer artifacts ready in ${out_dir}:"
for f in vmlinuz initrd.img images/install.img; do
    fp="${out_dir}/${f}"
    [[ -f "$fp" ]] && log_info "  ${f}  ($(du -sh "$fp" 2>/dev/null | cut -f1))"
done
log_info ""
log_info "next steps:"
log_info "  Generate a per-host kickstart:"
log_info "    netboot/gen-almalinux-ks.sh --mac 52:54:00:a1:9a:01"
log_info "  Build iPXE (inst.stage2 = the LOCAL install.img):"
log_info "    netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\"
log_info "        --kernel-path /vmlinuz --initrd-path /initrd.img \\"
log_info "        --append 'inst.stage2=http://10.0.2.2:8181/ inst.repo=${os_url}/ inst.ks=http://10.0.2.2:8181/ks/{MAC}.ks inst.text console=ttyS0 ip=dhcp'"
log_info "  Start nginx to serve artifacts:"
log_info "    phase4-podman/lab-podman.sh up --config examples/podman-netboot-server.toml"
