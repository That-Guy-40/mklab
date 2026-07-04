#!/usr/bin/env bash
# fetch-hands-off.sh — Clone (or update) Philip Hands' "Hands-Off" d-i framework.
#
# Hands-Off (https://hands.com/d-i/) is a Debian Developer's canonical preseed
# FRAMEWORK — not a single .cfg.  A tiny entry preseed (preseed.cfg) chains via
# `preseed/run` into checksigs.sh (GPG-bootstraps trust) → start.sh → assembles
# the real preseed on the fly from a tree of composable, per-*class* fragments
# (classes/) selected by `auto-install/classes=…`.  This lab operationalizes it:
# we serve its `trixie/` tree + a small lab `local/` site overlay and drive an
# unattended VM install through it.
#
# Provenance: this CLONES upstream (cite-don't-mirror — it's live, maintained
# code, like examples/kali-vm-builder fetches kali-vm), pinned to a commit for
# reproducibility.  Nothing from upstream is committed into THIS repo.
#
#   Upstream : http://git.hands.com/hands-off.git   (browse: https://hands.com/d-i/)
#   Pinned   : ec6e817a26419dcdb5a9e4c74377477bbc846ea4  (2026-05-18)
#   License  : GNU GPL v2+, © Philip Hands (see preseed/COPYING in the checkout)
#
# Usage:
#   examples/debian-hands-off-install/fetch-hands-off.sh [OPTIONS]
#
# Options:
#   --dir   <dir>   checkout dir      (default: ~/hands-off-src)
#   --ref   <ref>   commit/branch/tag (default: the pinned commit above)
#   --url   <url>   upstream git URL  (default: http://git.hands.com/hands-off.git)
#   --force         re-clone from scratch (wipes --dir first)
#   --help          show this help and exit

set -euo pipefail

readonly LAB_PROG="${0##*/}"
readonly DEFAULT_URL="http://git.hands.com/hands-off.git"
readonly PINNED_REF="ec6e817a26419dcdb5a9e4c74377477bbc846ea4"

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

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

dir="" ref="$PINNED_REF" url="$DEFAULT_URL" force=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)   shift; dir="${1:?--dir requires a path}";  shift ;;
        --ref)   shift; ref="${1:?--ref requires a ref}";   shift ;;
        --url)   shift; url="${1:?--url requires a URL}";    shift ;;
        --force) force=1; shift ;;
        --help|-h) usage ;;
        *) die "unknown option: $1  (try --help)" ;;
    esac
done
[[ -n "$dir" ]] || dir="$HOME/hands-off-src"

command -v git >/dev/null || die "git is required but not found in PATH"

if (( force )) && [[ -d "$dir" ]]; then
    log_warn "--force: removing existing checkout $dir"
    rm -rf "$dir"
fi

if [[ -d "$dir/.git" ]]; then
    log_info "updating existing checkout in $dir"
    git -C "$dir" fetch --all --tags 2>&1 | sed 's/^/  /' >&2 || log_warn "fetch failed (offline?) — using what's on disk"
else
    log_info "cloning ${url} → ${dir}"
    # dumb-HTTP transport: no shallow; a full clone is small (~a few MB).
    git clone "$url" "$dir" 2>&1 | sed 's/^/  /' >&2 || die "clone failed from ${url}"
fi

log_info "checking out pinned ref: ${ref}"
git -C "$dir" checkout -q "$ref" 2>/dev/null || die "ref '${ref}' not found in the checkout"

head="$(git -C "$dir" rev-parse HEAD)"
[[ -d "$dir/trixie" ]] || die "checkout has no trixie/ tree — did upstream reorganise? (got $head)"

log_ok "hands-off ready at ${dir}  (HEAD ${head:0:12})"
log_info "next: stage it into the served dir + apply the lab overlay:"
log_info "    examples/debian-hands-off-install/setup-hands-off.sh --src ${dir}"
