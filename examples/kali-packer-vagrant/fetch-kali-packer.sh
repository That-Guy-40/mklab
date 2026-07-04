#!/usr/bin/env bash
# fetch-kali-packer.sh — clone/update Kali's (now-retired) HashiCorp Packer build
#                        scripts into a local work dir, ready for build-kali-box.sh.
#
# Upstream: https://gitlab.com/kalilinux/build-scripts/kali-packer
#   This is how Kali built its *Vagrant* base boxes BEFORE 2025.2 — with Packer
#   driving a real Kali installer ISO unattended (boot_command + preseed over
#   HTTP), then packaging the result as a `.box`.  Kali has since moved to debos
#   (see examples/kali-vm-builder); this repo is archived/"no longer in
#   production", which is exactly why it's interesting: it's the *other*
#   image-factory mechanism (drive-the-installer vs. assemble-the-rootfs).
#
# We keep a pinned CHECKOUT — not the artifacts — under a work dir OUTSIDE this
# repo, because a build downloads a multi-GB ISO and writes a ~6 GB box.
#
# Usage:
#   examples/kali-packer-vagrant/fetch-kali-packer.sh [--workdir DIR] [--ref REF] [--force]
#
# Options:
#   --workdir DIR  Where to keep the checkout. Default: $KALI_PACKER_DIR or
#                  $HOME/kali-packer-build. The checkout lands in <workdir>/kali-packer.
#   --ref REF      git ref/branch/tag to check out. Default: main
#   --pin SHA      expected commit to land on; warn (don't fail) if HEAD differs,
#                  so provenance drift is visible. Default: the recorded pin below.
#   --url URL      upstream repo URL. Default: the GitLab kali-packer repo
#   --force        re-clone from scratch even if the checkout already exists
#   --help         show this help and exit
#
# Prints the checkout path on stdout (build-kali-box.sh consumes it).

set -euo pipefail

URL_DEFAULT="https://gitlab.com/kalilinux/build-scripts/kali-packer.git"
# Recorded provenance pin — see UPSTREAM.md (retrieved 2026-07-03).
PIN_DEFAULT="b8c9b34efc553a3744b39387d359b89ede04267b"
WORKDIR="${KALI_PACKER_DIR:-$HOME/kali-packer-build}"
REF="main"
PIN="$PIN_DEFAULT"
URL="$URL_DEFAULT"
FORCE=0

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[fetch]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[fetch] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[fetch] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir) WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --ref)     REF="${2:?--ref needs a value}";        shift 2 ;;
        --pin)     PIN="${2:?--pin needs a sha}";          shift 2 ;;
        --url)     URL="${2:?--url needs a value}";         shift 2 ;;
        --force)   FORCE=1; shift ;;
        --help|-h) usage 0 ;;
        *)         die "unknown argument: $1  (try --help)" ;;
    esac
done

command -v git >/dev/null || die "git not found — install it (sudo apt install -y git)"

CHECKOUT="$WORKDIR/kali-packer"

if [ "$FORCE" -eq 1 ] && [ -d "$CHECKOUT" ]; then
    log "removing existing checkout (--force): $CHECKOUT"
    rm -rf "$CHECKOUT"
fi

mkdir -p "$WORKDIR"

if [ -d "$CHECKOUT/.git" ]; then
    log "updating existing checkout: $CHECKOUT"
    git -C "$CHECKOUT" fetch --depth 1 origin "$REF"
    git -C "$CHECKOUT" checkout -q "$REF"
    git -C "$CHECKOUT" merge --ff-only FETCH_HEAD >/dev/null 2>&1 || :
else
    log "cloning $URL (ref: $REF) → $CHECKOUT"
    git clone --depth 1 --branch "$REF" "$URL" "$CHECKOUT" 2>/dev/null \
        || git clone --depth 1 "$URL" "$CHECKOUT"   # fallback if REF is a sha
fi

HEAD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [ -n "$PIN" ] && [ "$HEAD_SHA" != "$PIN" ]; then
    warn "HEAD ($HEAD_SHA)"
    warn "differs from recorded pin ($PIN) — upstream moved; re-check UPSTREAM.md/provenance."
fi

# Sanity: the files build-kali-box.sh + run-graphical.sh expect.
for f in config.pkr.hcl http/preseed.cfg scripts/vagrant.sh scripts/minimize.sh Vagrantfile.tpl; do
    [ -e "$CHECKOUT/$f" ] || warn "expected upstream file missing: $f (layout may have changed)"
done

log "ready: $CHECKOUT @ $(git -C "$CHECKOUT" rev-parse --short HEAD)"
printf '%s\n' "$CHECKOUT"
