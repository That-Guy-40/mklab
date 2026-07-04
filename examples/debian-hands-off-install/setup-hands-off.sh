#!/usr/bin/env bash
# setup-hands-off.sh — Stage Philip Hands' Hands-Off framework into the served
#                      netboot dir, apply the lab `local/` overlay, and (option-
#                      ally) re-sign it with a throwaway lab key.
#
# Two integrity modes:
#
#   (default, no --sign)  The lab overlay changes preseed/local/, whose files are
#                         NOT in upstream's signed MD5SUMS, so you must boot with
#                         `hands-off/checksigs=false` (the framework's own switch)
#                         to skip signature checking.  Simplest; still exercises
#                         the full class-assembly machinery.
#
#   --sign                Regenerate MD5SUMS over the whole staged tree (now incl.
#                         our local/ overlay), sign it with a freshly-generated
#                         lab GPG key, and replace trustedkeys.gpg with a keyring
#                         holding ONLY that lab key.  Now the tree is internally
#                         consistent + signed, so you boot WITHOUT checksigs=false
#                         and the gpgv bootstrap in checksigs.sh passes — exactly
#                         the "mirror it, add your site config, re-sign with your
#                         key" workflow upstream documents.  (Throwaway lab key —
#                         NOT a trust anchor; the point is to demonstrate the
#                         mechanism, not to be secure.)
#
# Usage:
#   examples/debian-hands-off-install/setup-hands-off.sh [OPTIONS]
#
# Options:
#   --src     <dir>  hands-off checkout (default: ~/hands-off-src; from fetch-hands-off.sh)
#   --out     <dir>  served tree        (default: ~/netboot/hands-off/trixie)
#   --overlay <dir>  lab local/ overlay (default: this script's ../lab-overlay)
#   --sign           re-sign the staged tree with a throwaway lab key (see above)
#   --help           show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

_log() {
    local level="$1"; shift
    local color="" reset=""
    if [[ -t 2 ]]; then
        case "$level" in info) color=$'\033[36m';; warn) color=$'\033[33m';;
            error) color=$'\033[31m';; ok) color=$'\033[32m';; esac
        reset=$'\033[0m'
    fi
    printf '%s[%s]%s %s\n' "$color" "$level" "$reset" "$*" >&2
}
log_info(){ _log info "$@"; }; log_warn(){ _log warn "$@"; }
log_ok(){ _log ok "$@"; };     die(){ _log error "$@"; exit 1; }

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

src="" out="" overlay="" sign=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)     shift; src="${1:?--src requires a path}";         shift ;;
        --out)     shift; out="${1:?--out requires a path}";         shift ;;
        --overlay) shift; overlay="${1:?--overlay requires a path}"; shift ;;
        --sign)    sign=1; shift ;;
        --no-sign) sign=0; shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done
[[ -n "$src"     ]] || src="$HOME/hands-off-src"
[[ -n "$out"     ]] || out="${LAB_NETBOOT_DIR:-$HOME/netboot}/hands-off/trixie"
[[ -n "$overlay" ]] || overlay="${SCRIPT_DIR}/lab-overlay"

[[ -d "$src/trixie"        ]] || die "no trixie/ tree in ${src} — run fetch-hands-off.sh first"
[[ -d "$overlay/local"     ]] || die "lab overlay not found: ${overlay}/local"
command -v md5sum >/dev/null   || die "md5sum is required"

# ─── Stage a clean copy of the upstream trixie/ tree ─────────────────────────
# Upstream makes every codename dir (trixie, bookworm, …) a SYMLINK to one
# codename-agnostic `preseed/` tree; the codename is detected at runtime from
# d-i's auto-install/defaultroot, not the path.  So resolve the symlink and copy
# the real dir (preserving any symlinks INSIDE it).
real_src="$(readlink -f "$src/trixie")"
[[ -d "$real_src" ]] || die "trixie does not resolve to a directory (${real_src})"
log_info "staging ${real_src} (via ${src}/trixie) → ${out}"
rm -rf "$out"
mkdir -p "$(dirname "$out")"
cp -a "$real_src" "$out"

# ─── Apply the lab local/ overlay (replace upstream's example site data) ─────
log_info "applying lab overlay: ${overlay}/local → ${out}/local"
rm -rf "${out}/local"
cp -a "${overlay}/local" "${out}/local"

# ─── Optional: re-sign the whole tree with a throwaway lab key ───────────────
if (( sign )); then
    command -v gpg  >/dev/null || die "--sign needs gpg"
    command -v gpgv >/dev/null || die "--sign needs gpgv (to self-check)"
    log_info "re-signing the staged tree with a throwaway lab key…"
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME
    trap 'rm -rf "$GNUPGHOME"' EXIT
    gpg --batch --quiet --gen-key <<-'EOF'
		%no-protection
		Key-Type: eddsa
		Key-Curve: ed25519
		Name-Real: mklab hands-off lab (THROWAWAY)
		Name-Email: hands-off@lab.invalid
		Expire-Date: 0
		%commit
	EOF
    keyid="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
    [[ -n "$keyid" ]] || die "could not determine the generated lab key id"

    # Regenerate MD5SUMS exactly as upstream's generate_MD5SUMS does: every file
    # under the tree except MD5SUMS{,.sig}, paths relative to the tree root.
    ( cd "$out"
      find . ! -regex '\./MD5SUMS\(\|\.sig\)' -follow ! -type d -print0 \
        | sed -z -e 's,^\./,,' | LC_ALL=C sort -z | xargs -0 md5sum
    ) > "${out}/MD5SUMS"

    # Detached, armoured signature (gpgv accepts armoured), verified by
    # checksigs.sh as `gpgv --keyring trustedkeys.gpg MD5SUMS.sig MD5SUMS`.
    gpg --batch --yes --detach-sign --armour -o "${out}/MD5SUMS.sig" "${out}/MD5SUMS"

    # trustedkeys.gpg = a keyring holding ONLY the lab key (replaces Phil's).
    gpg --batch --yes --export "$keyid" > "${out}/trustedkeys.gpg"

    # Keep preseed.cfg's `preseed/run/checksum` for checksigs.sh honest: it is
    # the md5 of checksigs.sh (which we did NOT modify) — assert it still matches.
    want="$(md5sum "${out}/checksigs.sh" | cut -d' ' -f1)"
    if ! grep -q "preseed/run/checksum.*string.*${want}" "${out}/preseed.cfg"; then
        log_warn "patching preseed.cfg checksigs.sh checksum → ${want}"
        sed -i -E "\#preseed/run/checksum#s#(string[[:space:]]+)[[:alnum:]]+\$#\1${want}#" "${out}/preseed.cfg"
    fi

    # Self-check: the signature we just made must verify against our keyring.
    gpgv --keyring "${out}/trustedkeys.gpg" "${out}/MD5SUMS.sig" "${out}/MD5SUMS" 2>/dev/null \
        || die "self-check FAILED: the lab signature does not verify — aborting"
    log_ok "re-signed: MD5SUMS ($(wc -l <"${out}/MD5SUMS") files) signed by lab key ${keyid:0:16}…"
else
    # UNSIGNED path: with hands-off/checksigs=false the framework skips the gpgv
    # bootstrap AND never recomputes preseed/run/checksum — so on modern d-i
    # (which enforces checksums) the stale checksum from preseed.cfg (checksigs.sh's
    # md5) would be applied to start.sh and reject it ("file may be corrupt").
    # Strip that line so the run-scripts proceed unchecked, matching checksigs=false.
    if grep -q 'preseed/run/checksum' "${out}/preseed.cfg"; then
        sed -i '/preseed\/run\/checksum/d' "${out}/preseed.cfg"
        log_info "unsigned mode: stripped preseed/run/checksum from preseed.cfg (checksigs=false)"
    fi
fi

chmod -R u=rwX,go=rX "$out"

# ─── Some framework fetches are HOST-ABSOLUTE (resolved at the server root) ───
# The framework mixes relative and absolute fetch paths (verified from the
# installer syslog): the entry scripts + MD5SUMS + the class *filters* are
# fetched RELATIVE to preseed.cfg (so they work under hands-off/trixie/), but
# start.sh grabs `/files/…` and foreach_class grabs `/classes/…` (and `/local/…`)
# with a LEADING SLASH — which d-i resolves against the docroot, not the preseed
# dir.  Without an alias those 404 (e.g. `…:8181//classes/_/defaults/debian/preseed`)
# and the install aborts.  So symlink each fetchable top-level dir at the docroot.
# RELATIVE targets: the docroot is bind-mounted into the nginx container at a
# different absolute path (/usr/share/nginx/html), so an absolute target would
# dangle inside the container; relative resolves correctly on both sides.
netroot="$(dirname "$(dirname "$out")")"        # <docroot>/hands-off/trixie → <docroot>
subpath="$(basename "$(dirname "$out")")/$(basename "$out")"   # hands-off/trixie
for d in files classes local; do
    ln -sfn "${subpath}/${d}" "${netroot}/${d}"
done
log_info "linked ${netroot}/{files,classes,local} → ${subpath}/… (framework's absolute fetch paths)"

if [[ "${EUID}" -eq 0 && -n "${SUDO_UID:-}" ]]; then
    chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" "$(dirname "$out")"
fi

# ─── Print the boot params for the iPXE build ────────────────────────────────
served_url="http://10.0.2.2:8181/hands-off/trixie"
if (( sign )); then
    checkflag=""
    mode="SIGNED (gpgv bootstrap active — full integrity)"
else
    checkflag="hands-off/checksigs=false "
    mode="UNSIGNED (checksigs=false — the local overlay is not in upstream MD5SUMS)"
fi

log_ok "staged the Hands-Off framework at ${out}  [${mode}]"
cat >&2 <<EOF

next steps (see examples/debian-hands-off-install/README.md):
  1. Fetch the trixie d-i kernel+initrd (reuses the debian-pxe-lab helper):
       examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64
  2. Build iPXE pointed at the Hands-Off entry preseed + a class selection:
       netboot/build-ipxe.sh --server http://10.0.2.2:8181 \\
         --kernel-path /debian/linux --initrd-path /debian/initrd.gz \\
         --append 'auto=true priority=critical preseed/url=${served_url}/preseed.cfg auto-install/classes=partition/atomic ${checkflag}DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
  3. Serve + boot:
       phase4-podman/lab-podman.sh up     --config examples/debian-hands-off-install/debian-hands-off-lab.toml
       phase2-qemu-vm/lab-vm.sh    create --config examples/debian-hands-off-install/debian-hands-off-lab.toml
       phase2-qemu-vm/lab-vm.sh    start  debian-hands-off-install
EOF
