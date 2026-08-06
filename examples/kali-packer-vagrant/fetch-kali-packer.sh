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
# ── OFFLINE BY DEFAULT (since 2026-08-06) ────────────────────────────────────
# The source is now the VENDORED archive at ../upstream-repo/kali-packer, not a
# network clone.  Upstream is RETIRED — last commit 2026-03-25 — so a build that
# reaches for GitLab depends on a server nobody maintains, and TODO item 7 asks
# for a builder runnable "in whole, per its own instructions".  Vendoring the
# bytes and then still requiring the network at build time would have left the
# archive decorative.
#
# The archive is VERIFIED against its own SHA256SUMS every time, not trusted:
# a vendored tree is a cached copy, and a cached copy nobody re-checks is this
# repo's bug class #1.  A mismatch REFUSES rather than warns — building from an
# altered archive would silently stop being the thing UPSTREAM.md describes.
#
# `--upstream` restores the network clone (to check whether upstream moved, or to
# try a different --ref).  Both paths land the same layout in <workdir>/kali-packer,
# so build-kali-box.sh does not care which was used — and neither ever writes back
# into the repo: the two compat patches are applied to the WORKDIR copy.
#
# Usage:
#   examples/kali-packer-vagrant/fetch-kali-packer.sh [--workdir DIR] [--upstream] [--force]
#
# Options:
#   --workdir DIR  Where to keep the checkout. Default: $KALI_PACKER_DIR or
#                  $HOME/kali-packer-build. The checkout lands in <workdir>/kali-packer.
#   --upstream     Clone from GitLab instead of using the vendored archive
#                  (needs network). Implied by --ref/--url.
#   --vendored     Force the offline path (the default; explicit for scripts).
#   --ref REF      git ref/branch/tag to check out. Default: main. Implies --upstream.
#   --pin SHA      expected commit to land on; warn (don't fail) if HEAD differs,
#                  so provenance drift is visible. Default: the recorded pin below.
#   --url URL      upstream repo URL. Default: the GitLab kali-packer repo.
#                  Implies --upstream.
#   --force        re-clone/re-copy from scratch even if the checkout already exists
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
SOURCE="vendored"          # vendored | upstream — see the header
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DIR="$SCRIPT_DIR/upstream-repo"
ARCHIVE="$ARCHIVE_DIR/kali-packer"

_c() { [ -t 2 ] && printf '\033[%sm' "$1" >&2 || :; }
log()  { _c 36; printf '[fetch]'   >&2; _c 0; printf ' %s\n' "$*" >&2; }
warn() { _c 33; printf '[fetch] WARNING:' >&2; _c 0; printf ' %s\n' "$*" >&2; }
die()  { _c 31; printf '[fetch] ERROR:'   >&2; _c 0; printf ' %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --workdir) WORKDIR="${2:?--workdir needs a path}"; shift 2 ;;
        # --ref/--url only mean anything against a real remote, so they imply
        # --upstream rather than being silently ignored on the offline path.
        --ref)     REF="${2:?--ref needs a value}";  SOURCE=upstream; shift 2 ;;
        --url)     URL="${2:?--url needs a value}";  SOURCE=upstream; shift 2 ;;
        --upstream) SOURCE=upstream; shift ;;
        --vendored) SOURCE=vendored; shift ;;
        --pin)     PIN="${2:?--pin needs a sha}";          shift 2 ;;
        --force)   FORCE=1; shift ;;
        --help|-h) usage 0 ;;
        *)         die "unknown argument: $1  (try --help)" ;;
    esac
done

CHECKOUT="$WORKDIR/kali-packer"

if [ "$FORCE" -eq 1 ] && [ -d "$CHECKOUT" ]; then
    log "removing existing checkout (--force): $CHECKOUT"
    rm -rf "$CHECKOUT"
fi

mkdir -p "$WORKDIR"

if [ "$SOURCE" = vendored ]; then
    # ── offline: the byte-exact archive in this repo ────────────────────────
    [ -d "$ARCHIVE" ] \
        || die "vendored archive missing at $ARCHIVE — re-add it, or use --upstream to clone (needs network). See upstream-repo/README.md."
    command -v sha256sum >/dev/null \
        || die "sha256sum not found — cannot verify the vendored archive, and an unverified archive is exactly what its SHA256SUMS exists to prevent. Install coreutils, or use --upstream."

    # VERIFY, don't trust. A vendored tree is a cached copy of somebody else's
    # repository; if it has drifted, everything downstream — the compat patches,
    # UPSTREAM.md's pin, the provenance table — is describing something else.
    # This REFUSES rather than warning: a build from an altered archive is not
    # the build this lab documents.
    log "verifying the vendored archive against its SHA256SUMS"
    if ! ( cd "$ARCHIVE_DIR" && sha256sum -c SHA256SUMS ) >/dev/null 2>&1; then
        ( cd "$ARCHIVE_DIR" && sha256sum -c SHA256SUMS 2>&1 | grep -v ': OK$' | head -20 ) >&2 || :
        die "the vendored archive does not match SHA256SUMS (files listed above). It has been edited or corrupted — restore it with 'git checkout -- upstream-repo/', or use --upstream to clone from GitLab."
    fi
    n_files="$(grep -c . "$ARCHIVE_DIR/SHA256SUMS")"
    log "archive verified: $n_files files match"

    # Copy OUT of the repo before anything touches it. build-kali-box.sh applies
    # two compat patches to this tree, and patching the committed archive in
    # place would (a) dirty the working tree and (b) make the next verification
    # fail against the repo's own bytes.
    log "staging the vendored archive → $CHECKOUT"
    mkdir -p "$CHECKOUT"
    cp -a "$ARCHIVE/." "$CHECKOUT/"
    HEAD_SHA="$PIN_DEFAULT"
    log "source: vendored archive (offline) @ ${HEAD_SHA:0:12} — the pin recorded in UPSTREAM.md"
else
    # ── network: clone the real repository ──────────────────────────────────
    command -v git >/dev/null || die "git not found — install it (sudo apt install -y git)"
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
fi

# Sanity: the files build-kali-box.sh + run-graphical.sh expect.
for f in config.pkr.hcl http/preseed.cfg scripts/vagrant.sh scripts/minimize.sh Vagrantfile.tpl; do
    [ -e "$CHECKOUT/$f" ] || warn "expected upstream file missing: $f (layout may have changed)"
done

# NOT `$(git -C "$CHECKOUT" rev-parse --short HEAD)`: the vendored path stages plain
# files with no .git at all, so that call fails — and under `set -e`, inside a command
# substitution in an argument, it takes the script with it after all the work is done.
# $HEAD_SHA is set by both branches, which is the point of setting it in both.
log "ready: $CHECKOUT @ ${HEAD_SHA:0:12} (source: $SOURCE)"
printf '%s\n' "$CHECKOUT"
