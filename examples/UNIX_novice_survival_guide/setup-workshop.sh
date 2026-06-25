#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready environment
# for Matt Might's "A survival guide for Unix beginners": BASH + the standard
# complement of Unix tools the guide walks through (navigation, text viewers,
# editors, man/info, grep/find, ssh), a non-root `learner` user, and a small
# `~/unix-survival/` sandbox that mirrors the guide's running examples so the
# learner can type the commands and see matching output.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX_novice_survival_guide/unix-survival-debian.toml
#   examples/UNIX_novice_survival_guide/setup-workshop.sh unix-survival-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. unix-survival-debian/shell)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }

echo "==> [1/5] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/5] installing BASH + the standard complement of Unix tools"
case "$DISTRO" in
    debian)
        # The trixie container already has bash + GNU coreutils/grep/sed/find;
        # add the guide's interactive tools: viewers/editors (less, nano, vim),
        # docs (man-db + manpages + info), search context, and ssh.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils findutils grep sed gawk \
                     nano vim less man-db manpages info \
                     openssh-client ca-certificates file tree procps' ;;
    alpine)
        # Alpine ships ash + BusyBox applets and, crucially, NO `man` and NO `ssh`
        # by default — the very tools the guide's "man up" / ssh sections teach.
        # Install the real bash + GNU tools, man (mandoc), apropos/whatis
        # (mandoc-apropos), info (texinfo), and openssh-client. Per-tool man pages
        # live in `*-doc` subpackages. Then build the apropos index (Debian's
        # man-db does this in its postinst; on Alpine it's a manual makewhatis).
        g sh -c 'apk add --no-cache \
                     bash coreutils findutils grep sed gawk \
                     nano vim less mandoc mandoc-apropos man-pages texinfo \
                     openssh-client ca-certificates \
                     coreutils-doc grep-doc sed-doc findutils-doc \
                     file tree procps-ng shadow
                 makewhatis /usr/share/man 2>/dev/null || true' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login shell)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] building the ~/unix-survival sandbox (mirrors the guide's examples)"
# Recreate the files the guide uses in its examples so the learner can type the
# exact commands from the article and get matching output — e.g.
# `find . | grep READ` finds README.txt + Desktop/READINGLIST.txt, and
# `ls -l` shows the `baz -> bar` symlink.
g su - "$LEARNER" -c '
set -e
mkdir -p ~/Documents ~/Desktop ~/unix-survival
printf "%s\n%s\n" "* A README file for my home directory." "Documents contains my files." > ~/README.txt
printf "%s\n%s\n%s\n" "The UNIX Programming Environment" "The Cathedral and the Bazaar" "Classic Shell Scripting" > ~/Desktop/READINGLIST.txt
cd ~/unix-survival
: > foo
: > bar
ln -sf bar baz                         # symbolic-link demo: baz -> bar
printf "%s\n%s\n" "hello unix" "the command line is a language" > notes.txt
'

echo "==> [5/5] verifying the sandbox (as $LEARNER): a few commands straight from the guide"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  shell  : $(bash --version | head -1)"
echo "  pwd    : $(pwd)"
echo "  --- find . | grep READ  (the guide'"'"'s pipe example) ---"
cd ~ && find . | grep READ
echo "  --- ls -l ~/unix-survival  (symbolic link) ---"
ls -l ~/unix-survival | grep -- "-> bar"
echo "  --- man ls | head -1  (documentation works) ---"
man ls 2>/dev/null | head -1 || echo "  (man check skipped)"
'

echo
echo "==> done.  Survival-guide box ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/UNIX_novice_survival_guide/upstream-tutorial/articles/basic-unix/index.html  and follow along."
