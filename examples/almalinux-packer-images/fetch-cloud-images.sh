#!/usr/bin/env bash
# fetch-cloud-images.sh — stage AlmaLinux's official Packer image factory into a work dir.
#
# Upstream: https://github.com/AlmaLinux/cloud-images
#   The Packer + Ansible pipeline that builds AlmaLinux's *published* cloud images —
#   AMI, Azure, GCP, OCI, OpenNebula, Vagrant and the "gencloud" qcow2 — for releases
#   8, 9 and 10.  The kickstarts under http/ are the same ones
#   examples/almalinux-kickstart-gallery/ consumes; this lab takes the whole builder.
#
# ── OFFLINE BY DEFAULT ───────────────────────────────────────────────────────
# The source is the VENDORED archive at upstream-repo/cloud-images (563 files,
# pinned 6d808bf7, retrieved 2026-08-06), VERIFIED against its own SHA256SUMS on
# every run.  A mismatch REFUSES: a vendored tree is a cached copy of somebody
# else's repository, and if it has drifted then this lab's docs, its pin and its
# provenance table are describing something else.
#
# UNLIKE the Kali sibling, THIS UPSTREAM IS ALIVE.  The archive is a dated
# snapshot, not a mirror, and `--upstream` exists precisely so you can see what
# has moved since.  See upstream-repo/README.md for why that changes the argument
# but not the mechanism.
#
# Usage:
#   examples/almalinux-packer-images/fetch-cloud-images.sh [--workdir DIR] [--upstream] [--force]
#
# Options:
#   --workdir DIR  Where to stage. Default: $ALMA_IMAGES_DIR or
#                  $HOME/almalinux-cloud-images-build. Lands in <workdir>/cloud-images.
#   --upstream     Clone from GitHub instead of the archive (needs network).
#                  Implied by --ref/--url.
#   --vendored     Force the offline path (the default; explicit for scripts).
#   --ref REF      git ref to check out. Default: main. Implies --upstream.
#   --pin SHA      expected commit; warn (don't fail) if HEAD differs. Default: the
#                  recorded pin below.
#   --url URL      upstream repo URL. Implies --upstream.
#   --force        re-stage from scratch even if the work dir already has a copy
#   --help         show this help and exit
#
# Prints the staged path on stdout.

set -euo pipefail

URL_DEFAULT="https://github.com/AlmaLinux/cloud-images.git"
PIN_DEFAULT="6d808bf710be1ca57c456f91db5d2d750e92d4e3"   # retrieved 2026-08-06
WORKDIR="${ALMA_IMAGES_DIR:-$HOME/almalinux-cloud-images-build}"
REF="main"
PIN="$PIN_DEFAULT"
URL="$URL_DEFAULT"
FORCE=0
SOURCE="vendored"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DIR="$SCRIPT_DIR/upstream-repo"
ARCHIVE="$ARCHIVE_DIR/cloud-images"

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[fetch]' >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[fetch] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[fetch] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir)  WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        --ref)      REF="${2:?--ref needs a value}"; SOURCE=upstream; shift 2 ;;
        --url)      URL="${2:?--url needs a value}"; SOURCE=upstream; shift 2 ;;
        --upstream) SOURCE=upstream; shift ;;
        --vendored) SOURCE=vendored; shift ;;
        --pin)      PIN="${2:?--pin needs a sha}"; shift 2 ;;
        --force)    FORCE=1; shift ;;
        --help|-h)  usage 0 ;;
        *)          die "unknown argument: $1  (try --help)" ;;
    esac
done

CHECKOUT="$WORKDIR/cloud-images"

if [ "$FORCE" -eq 1 ] && [ -d "$CHECKOUT" ]; then
    log "removing existing copy (--force): $CHECKOUT"
    rm -rf "$CHECKOUT"
fi
mkdir -p "$WORKDIR"

if [ "$SOURCE" = vendored ]; then
    [ -d "$ARCHIVE" ] \
        || die "vendored archive missing at $ARCHIVE — re-add it, or use --upstream to clone (needs network). See upstream-repo/README.md."
    command -v sha256sum >/dev/null \
        || die "sha256sum not found — cannot verify the vendored archive, and an unverified archive is exactly what SHA256SUMS exists to prevent. Install coreutils, or use --upstream."

    log "verifying the vendored archive against its SHA256SUMS (563 files)"
    if ! ( cd "$ARCHIVE_DIR" && sha256sum -c SHA256SUMS ) >/dev/null 2>&1; then
        ( cd "$ARCHIVE_DIR" && sha256sum -c SHA256SUMS 2>&1 | grep -v ': OK$' | head -20 ) >&2 || :
        die "the vendored archive does not match SHA256SUMS (files listed above). It has been edited or corrupted — restore it with 'git checkout -- upstream-repo/', or use --upstream to clone from GitHub."
    fi
    n_files="$(grep -c . "$ARCHIVE_DIR/SHA256SUMS")"
    log "archive verified: $n_files files match"

    # Stage OUT of the repo. Packer writes into its checkout (packer_cache/, plugins,
    # output dirs) and any patching happens to this copy — the committed archive must
    # stay byte-identical to what SHA256SUMS describes, or the next run refuses.
    log "staging the vendored archive → $CHECKOUT"
    mkdir -p "$CHECKOUT"
    cp -a "$ARCHIVE/." "$CHECKOUT/"
    HEAD_SHA="$PIN_DEFAULT"
    log "source: vendored archive (offline) @ ${HEAD_SHA:0:12} — the pin in upstream-repo/README.md"
else
    command -v git >/dev/null || die "git not found — install it (sudo apt install -y git)"
    if [ -d "$CHECKOUT/.git" ]; then
        log "updating existing checkout: $CHECKOUT"
        git -C "$CHECKOUT" fetch --depth 1 origin "$REF"
        git -C "$CHECKOUT" checkout -q "$REF"
        git -C "$CHECKOUT" merge --ff-only FETCH_HEAD >/dev/null 2>&1 || :
    else
        log "cloning $URL (ref: $REF) → $CHECKOUT"
        git clone --depth 1 --branch "$REF" "$URL" "$CHECKOUT" 2>/dev/null \
            || git clone --depth 1 "$URL" "$CHECKOUT"
    fi
    HEAD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
    if [ -n "$PIN" ] && [ "$HEAD_SHA" != "$PIN" ]; then
        warn "HEAD ($HEAD_SHA)"
        warn "differs from the recorded pin ($PIN). THIS IS EXPECTED — upstream is actively"
        warn "maintained. The pin says which factory this lab documents, not which is current."
    fi
fi

# Sanity: the pieces the build driver and the docs refer to.
for f in variables.pkr.hcl http ansible tests; do
    [ -e "$CHECKOUT/$f" ] || warn "expected upstream path missing: $f (layout may have changed)"
done

log "ready: $CHECKOUT @ ${HEAD_SHA:0:12} (source: $SOURCE)"
printf '%s\n' "$CHECKOUT"
