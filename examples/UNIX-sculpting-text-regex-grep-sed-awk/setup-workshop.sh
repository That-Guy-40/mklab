#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready text-sculpting
# box for Matt Might's "Sculpting text with regex, grep, sed, awk": GNU
# grep/sed/gawk (the dialects the article is written for), a non-root `learner`
# user, a `/usr/share/dict/words`, and a `~/sculpting-text/` sandbox with sample
# data + a runnable `demo.sh` exercising the article's grep/sed/awk trio.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX-sculpting-text-regex-grep-sed-awk/sculpting-text-debian.toml
#   examples/UNIX-sculpting-text-regex-grep-sed-awk/setup-workshop.sh sculpting-text-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/sculpting-text"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. sculpting-text-debian/shell)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }
# Push a host file into the guest via the wrapper's stdin (no nested-quoting of
# the single-quoted regex the sample files are full of).
push() { g sh -c "cat > '$2'" < "$1"; }

echo "==> [1/5] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/5] installing GNU grep/sed/gawk (the article's dialects)"
# The article assumes GNU grep (backreferences in -E), GNU sed (\U, etc.) and
# gawk (functions, arrays). Debian already has GNU grep/sed but its default awk is
# mawk; Alpine has BusyBox applets for all three. So: install gawk everywhere, the
# GNU grep/sed on Alpine, and a pager.
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends grep sed gawk coreutils less' ;;
    alpine)
        g sh -c 'apk add --no-cache grep sed gawk coreutils less shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac
# Make `awk` mean gawk on BOTH bases (Debian's default is mawk; Alpine's is
# BusyBox awk). /usr/local/bin is first in PATH, so this wins without fighting the
# package manager.
g sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'

echo "==> [3/5] creating the non-root '$LEARNER' user (POSIX /bin/sh login)"
# No bash is installed (this lab is about grep/sed/awk, not shell scripting), so
# the learner logs into the base /bin/sh — dash on Debian, BusyBox ash on Alpine.
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/sh $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/sh $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/sculpting-text sandbox + /usr/share/dict/words"
g sh -c "mkdir -p '$SANDBOX' /usr/share/dict"
for f in words passwd access_log dupes.txt demo.sh; do
    push "$HERE/sample-data/$f" "$SANDBOX/$f" 2>/dev/null || push "$HERE/$f" "$SANDBOX/$f"
done
# The article's flagship data source: a real /usr/share/dict/words. (On a real box
# this comes from `wamerican`/`words` on Debian; Alpine ships no clean equivalent,
# so the lab supplies a compact curated list — same on both, so examples match.)
push "$HERE/sample-data/words" /usr/share/dict/words
g sh -c "chmod +x '$SANDBOX/demo.sh'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  grep   : $(grep --version | head -1)"
echo "  sed    : $(sed --version | head -1)"
echo "  awk    : $(awk --version 2>/dev/null | head -1)"
echo "  --- running ~/sculpting-text/demo.sh ---"
sh ~/sculpting-text/demo.sh'

echo
echo "==> done.  Text-sculpting sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/UNIX-sculpting-text-regex-grep-sed-awk/upstream-tutorial/articles/sculpting-text/index.html  and follow along."
