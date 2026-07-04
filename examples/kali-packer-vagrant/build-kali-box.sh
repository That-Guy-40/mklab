#!/usr/bin/env bash
# build-kali-box.sh — drive HashiCorp Packer to build a Kali *Vagrant box* the
#                     way Kali used to, BEFORE it switched to debos.
#
# What Packer does here (very different from the debos factories):
#   1. boots the real Kali INSTALLER ISO in a throwaway QEMU VM,
#   2. types a scripted `boot_command` at the ISO boot menu (over VNC) that points
#      the Debian installer at a preseed served over Packer's own HTTP server
#      (upstream's http/preseed.cfg),
#   3. the installer runs fully unattended (user vagrant/vagrant, ssh enabled),
#   4. Packer SSHes in and runs the provisioners (scripts/vagrant.sh installs the
#      Vagrant insecure key + passwordless sudo; scripts/minimize.sh zero-fills
#      free space so the image compresses),
#   5. the `vagrant` post-processor packages the QCOW2 into a `.box`.
# It automates the *human install experience*; debos assembles a rootfs directly.
#
# This wrapper: resolves the current Kali installer ISO + checksum, runs
# `packer init` then `packer build` for the QEMU builder only (never uploads),
# and points you at run-graphical.sh.  Upstream config/preseed/scripts are used
# UNMODIFIED from the pinned checkout (fetch-kali-packer.sh) — this is a driver.
#
#   ⚠️  Authorized use only — builds a full Kali system (offensive tooling).
#       vagrant/vagrant is a throwaway lab credential; never ship it.
#
# Usage:
#   examples/kali-packer-vagrant/build-kali-box.sh [options]
#
# Common options:
#   --validate-only   `packer init` + `packer validate` + `packer fmt -check` only
#                     (no VM, no download) — the fast "is the config sane?" check.
#   --accel A         kvm | tcg | none   (default: kvm if /dev/kvm else tcg)
#                     tcg has no HW accel — a build takes HOURS, not ~30 min.
#   --headless BOOL   true (default) = no QEMU window; false = watch it install.
#   --only TARGET     Packer source to build (default: qemu.kalirolling).
#                     Others (virtualbox-iso/vmware-iso/hyperv-iso.kalirolling)
#                     need that hypervisor installed; run-graphical.sh boots QEMU.
#   --iso-url URL     installer ISO   (default: resolved from kali.download/current)
#   --iso-checksum C  checksum spec   (default: file:…/current/SHA256SUMS)
#   --ssh-timeout T   how long to wait for the install (default: 60m; 120m for tcg)
#   --workdir DIR     checkout + box live here (default: $KALI_PACKER_DIR or
#                     $HOME/kali-packer-build). Needs ~15 GB free (ISO + box + scratch).
#   --packer BIN      packer binary to use (default: packer on PATH, else
#                     <workdir>/bin/packer if you ran --install-packer)
#   --install-packer  fetch a pinned static packer binary into <workdir>/bin and
#                     use it (verifies the SHA256). For hosts without packer.
#   --ref REF         upstream git ref to build from (passed to fetch-kali-packer.sh)
#   --force           pass -force to packer build (overwrite a previous output)
#   --help            show this help and exit
#
# Output:  <workdir>/kali-packer/packer_kalirolling_libvirt_amd64.box
#          (boot it with run-graphical.sh)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PACKER_VERSION="1.13.1"        # pinned; --install-packer fetches this

WORKDIR="${KALI_PACKER_DIR:-$HOME/kali-packer-build}"
ACCEL=""            # auto below
HEADLESS="true"
ONLY="qemu.kalirolling"
ISO_URL=""          # auto-resolved below
ISO_CHECKSUM="file:https://kali.download/base-images/current/SHA256SUMS"
SSH_TIMEOUT=""      # auto below
PACKER_BIN=""
INSTALL_PACKER=0
REF="main"
VALIDATE_ONLY=0
FORCE=0

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[build]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[build] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[build] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
have()  { command -v "$1" >/dev/null 2>&1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --validate-only) VALIDATE_ONLY=1; shift ;;
        --accel)     ACCEL="${2:?}"; shift 2 ;;
        --headless)  HEADLESS="${2:?}"; shift 2 ;;
        --only)      ONLY="${2:?}"; shift 2 ;;
        --iso-url)   ISO_URL="${2:?}"; shift 2 ;;
        --iso-checksum) ISO_CHECKSUM="${2:?}"; shift 2 ;;
        --ssh-timeout)  SSH_TIMEOUT="${2:?}"; shift 2 ;;
        --workdir)   WORKDIR="${2:?}"; shift 2 ;;
        --packer)    PACKER_BIN="${2:?}"; shift 2 ;;
        --install-packer) INSTALL_PACKER=1; shift ;;
        --ref)       REF="${2:?}"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        --help|-h)   usage 0 ;;
        *)           die "unknown argument: $1  (try --help)" ;;
    esac
done
case "$HEADLESS" in true|false) ;; *) die "--headless must be true|false" ;; esac

# ── Accelerator + ssh timeout defaults ───────────────────────────────────────
if [ -z "$ACCEL" ]; then
    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL="kvm"; else ACCEL="tcg"; fi
fi
case "$ACCEL" in
    kvm)  [ -w /dev/kvm ] || warn "--accel kvm but /dev/kvm not writable (sudo adduser \$USER kvm; re-login)" ;;
    tcg|none) warn "accel=$ACCEL has NO hardware acceleration — a full Kali install can take HOURS" ;;
    *)    die "invalid --accel '$ACCEL' (kvm|tcg|none)" ;;
esac
[ -n "$SSH_TIMEOUT" ] || { [ "$ACCEL" = kvm ] && SSH_TIMEOUT="60m" || SSH_TIMEOUT="120m"; }

mkdir -p "$WORKDIR"

# ── Ensure the pinned upstream checkout exists ───────────────────────────────
CHECKOUT="$WORKDIR/kali-packer"
if [ ! -e "$CHECKOUT/config.pkr.hcl" ]; then
    log "no checkout yet — fetching upstream kali-packer"
    "$SCRIPT_DIR/fetch-kali-packer.sh" --workdir "$WORKDIR" --ref "$REF" >/dev/null
fi
[ -e "$CHECKOUT/config.pkr.hcl" ] || die "checkout missing config.pkr.hcl at $CHECKOUT"

# ── Locate (or install) packer ───────────────────────────────────────────────
if [ -z "$PACKER_BIN" ]; then
    if have packer; then PACKER_BIN="$(command -v packer)"
    elif [ -x "$WORKDIR/bin/packer" ]; then PACKER_BIN="$WORKDIR/bin/packer"; fi
fi
if [ "$INSTALL_PACKER" -eq 1 ] || { [ -z "$PACKER_BIN" ] && [ ! -x "$WORKDIR/bin/packer" ]; }; then
    if [ "$INSTALL_PACKER" -ne 1 ] && [ -z "$PACKER_BIN" ]; then
        die "packer not found. Install it (see README 'Getting packer'), or re-run with --install-packer to fetch a pinned static binary into $WORKDIR/bin."
    fi
    have curl  || die "--install-packer needs curl";  have unzip || die "--install-packer needs unzip (sudo apt install -y unzip)"
    base="https://releases.hashicorp.com/packer/${PACKER_VERSION}"
    zip="packer_${PACKER_VERSION}_linux_amd64.zip"
    log "installing packer $PACKER_VERSION → $WORKDIR/bin/packer"
    mkdir -p "$WORKDIR/bin" "$WORKDIR/.dl"
    curl -fsSL "$base/$zip" -o "$WORKDIR/.dl/$zip"
    curl -fsSL "$base/packer_${PACKER_VERSION}_SHA256SUMS" -o "$WORKDIR/.dl/SHA256SUMS"
    ( cd "$WORKDIR/.dl" && grep " $zip\$" SHA256SUMS | sha256sum -c - ) || die "packer checksum mismatch — refusing to use it"
    unzip -o -d "$WORKDIR/bin" "$WORKDIR/.dl/$zip" packer >/dev/null
    PACKER_BIN="$WORKDIR/bin/packer"
fi
[ -x "$PACKER_BIN" ] || die "packer binary not usable: $PACKER_BIN"
log "packer: $PACKER_BIN ($("$PACKER_BIN" version | head -1))"

# ── packer init (installs the plugins the config declares) ───────────────────
log "packer init (downloads the qemu/virtualbox/vmware/hyperv/vagrant plugins)"
( cd "$CHECKOUT" && "$PACKER_BIN" init . )

# ── Resolve the current ISO URL if not supplied.  BOTH validate and build need a
#    real filename: packer resolves the `file:` checksum by matching the ISO
#    URL's *basename* against the SHA256SUMS list, so a placeholder name would
#    fail even a no-build `validate` ("no checksum found"). kali.download is used
#    (not cdimage) because it serves SHA256SUMS without a redirect. ────────────
if [ -z "$ISO_URL" ]; then
    have curl || die "curl needed to resolve the current Kali ISO (or pass --iso-url)"
    log "resolving the current Kali installer ISO from kali.download"
    line="$(curl -fsSL --max-time 30 https://kali.download/base-images/current/SHA256SUMS \
              | grep -E 'kali-linux-.*-installer-amd64\.iso$' | head -1 || :)"
    [ -n "$line" ] || die "could not resolve the ISO filename (pass --iso-url + --iso-checksum)"
    iso_name="$(printf '%s\n' "$line" | awk '{print $2}')"
    ISO_URL="https://kali.download/base-images/current/$iso_name"
    log "ISO: $ISO_URL"
fi

# ── Validate-only fast path (no VM, no ISO download — just the config) ────────
if [ "$VALIDATE_ONLY" -eq 1 ]; then
    log "packer fmt -check + validate"
    ( cd "$CHECKOUT" && "$PACKER_BIN" fmt -check -diff config.pkr.hcl ) \
        && log "fmt: OK (upstream is canonically formatted)" \
        || warn "fmt: differences reported above (upstream not re-formatted — informational)"
    # -except vagrant-cloud skips the upload post-processor (needs a real token);
    # packer prints a cosmetic 'did not match any build' note for it — harmless.
    ( cd "$CHECKOUT" && "$PACKER_BIN" validate \
        -var "build_iso_url=$ISO_URL" \
        -var "build_iso_checksum=$ISO_CHECKSUM" \
        -var "build_qemu_accelerator=$ACCEL" \
        -var "cloud_token=UNUSED" \
        -except vagrant-cloud \
        config.pkr.hcl ) || die "packer validate FAILED — the config is not sane on this packer/plugin set"
    log "validate: OK — config + all builder/provisioner/post-processor schemas are valid"
    exit 0
fi

# ── Build ────────────────────────────────────────────────────────────────────
[ -e /dev/kvm ] || warn "/dev/kvm missing — the build VM has no acceleration"
BUILD_ARGS=(build)
[ "$FORCE" -eq 1 ] && BUILD_ARGS+=(-force)
BUILD_ARGS+=(
    -only "$ONLY"
    -except vagrant-cloud
    -var "build_iso_url=$ISO_URL"
    -var "build_iso_checksum=$ISO_CHECKSUM"
    -var "build_qemu_accelerator=$ACCEL"
    -var "build_headless=$HEADLESS"
    -var "build_ssh_timeout=$SSH_TIMEOUT"
    -var "cloud_token=UNUSED"
    config.pkr.hcl
)
log "building '$ONLY' (accel=$ACCEL, headless=$HEADLESS, ssh_timeout=$SSH_TIMEOUT)"
log "this downloads a ~4 GB ISO and runs a full unattended Kali install — grab a coffee"
( cd "$CHECKOUT" && "$PACKER_BIN" "${BUILD_ARGS[@]}" ) || die "packer build failed — see output above (raise --ssh-timeout on slow/tcg hosts)"

BOX="$(ls -t "$CHECKOUT"/packer_kalirolling_*.box 2>/dev/null | head -1 || :)"
[ -n "$BOX" ] || { warn "build finished but no *.box found in $CHECKOUT (did you --only a non-qemu target?)"; exit 0; }
log "done: $BOX ($(du -h "$BOX" 2>/dev/null | cut -f1 || echo '?') on disk)"
log "boot it graphically:  examples/kali-packer-vagrant/run-graphical.sh"
log "  (login: vagrant / vagrant)"
