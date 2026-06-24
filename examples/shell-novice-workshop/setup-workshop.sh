#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready-to-go
# Software Carpentry "shell-novice" workshop box: BASH + the standard complement
# of Unix tools, a non-root `learner` user, and the lesson data unzipped in their
# home directory.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/shell-novice-workshop/shell-novice-debian.toml
#   examples/shell-novice-workshop/setup-workshop.sh shell-novice-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
ZIP="$HERE/shell-lesson-data.zip"
LEARNER="learner"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. shell-novice-debian/shell)" >&2; exit 1; }
[[ -f "$ZIP" ]] || { echo "missing vendored data: $ZIP" >&2; exit 1; }
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
        # add the workshop's interactive tools + man pages + unzip.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils findutils grep sed gawk \
                     nano less man-db manpages \
                     unzip wget ca-certificates file tree procps' ;;
    alpine)
        # Alpine ships ash + BusyBox applets; the workshop assumes BASH + GNU
        # coreutils. Install the real tools (see RUNBOOK "BusyBox vs GNU").
        # man pages for individual tools live in `*-doc` subpackages on Alpine.
        g sh -c 'apk add --no-cache \
                     bash coreutils findutils grep sed gawk \
                     nano less mandoc man-pages \
                     coreutils-doc grep-doc sed-doc findutils-doc \
                     unzip wget ca-certificates file tree procps-ng shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login shell)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] unzipping the workshop data into /home/$LEARNER"
# Stream the zip in through the phase tool (exec forwards stdin), unzip, chown.
g sh -c "cat > /tmp/shell-lesson-data.zip" < "$ZIP"
g sh -c "cd /home/$LEARNER && rm -rf shell-lesson-data && unzip -q /tmp/shell-lesson-data.zip && chown -R $LEARNER:$LEARNER shell-lesson-data && rm -f /tmp/shell-lesson-data.zip"

echo "==> [5/5] verifying the workshop environment (as $LEARNER)"
g su - "$LEARNER" -c 'echo "  whoami : $(whoami)"
                      echo "  shell  : $0 ($(bash --version | head -1))"
                      echo "  pwd    : $(pwd)"
                      echo "  data   : $(ls -F ~/shell-lesson-data)"
                      echo "  GNU ls : $(ls --version | head -1)"
                      echo "  count  : $(wc -l < ~/shell-lesson-data/exercise-data/numbers.txt) lines in exercise-data/numbers.txt"'

echo
echo "==> done.  Workshop ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/shell-novice-workshop/upstream-tutorial/aio.html  and follow the Linux track."
