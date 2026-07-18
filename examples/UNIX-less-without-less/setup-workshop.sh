#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready box for
# `ddpager`, the less-without-less: bash (the interpreter), GNU coreutils
# (the dd whose stderr is the binary detector), ncurses `tput` (every escape
# the pager draws with), python3 (the pty harness that types at the pager
# like a human), a non-root `learner` user, and a `~/less-without-less/`
# sandbox holding the pager VERBATIM, the pty driver, and a runnable
# `demo.sh`.
#
# THE DIVERGENCE THIS FIXES (see README): the pager's constraint set —
# "just bash, dd, tput" — sounds like it would run anywhere. On Alpine every
# leg of the tripod is missing: no bash, BusyBox dd (a different stderr
# dialect for the detector to parse), no tput at all.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX-less-without-less/less-without-less-debian.toml
#   examples/UNIX-less-without-less/setup-workshop.sh less-without-less-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/less-without-less"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. less-without-less-debian/shell)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

g() { "$LXD" exec "$TARGET" -- "$@"; }
push() { g sh -c "cat > '$2'" < "$1"; }

echo "==> [1/5] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/5] installing bash + coreutils (GNU dd) + tput + python3"
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils ncurses-bin python3 diffutils' ;;
    alpine)
        # Alpine: no bash, BusyBox dd, no tput. coreutils brings GNU dd
        # (whose stderr format detect_binary parses); ncurses brings tput;
        # python3 runs the pty driver; shadow brings a usable su.
        g sh -c 'apk add --no-cache bash coreutils ncurses python3 diffutils shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/less-without-less sandbox"
g sh -c "mkdir -p '$SANDBOX/bin'"
push "$HERE/bin/ddpager"    "$SANDBOX/bin/ddpager"     # VERBATIM (sha-checked by demo.sh)
push "$HERE/drive-pager.py" "$SANDBOX/drive-pager.py"  # the pty harness
push "$HERE/demo.sh"        "$SANDBOX/demo.sh"
g sh -c "chmod +x '$SANDBOX/demo.sh' '$SANDBOX/bin/ddpager' '$SANDBOX/drive-pager.py'"
g sh -c "chmod -R a+rX '$SANDBOX'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo.sh"
g su - "$LEARNER" -c '
echo "  whoami  : $(whoami)"
echo "  bash    : $(bash --version | head -1)"
echo "  dd      : $(dd --version 2>/dev/null | head -1 || echo busybox)"
echo "  tput    : $(command -v tput)"
echo "  python3 : $(python3 --version)"
echo "  --- running ~/less-without-less/demo.sh ---"
bash ~/less-without-less/demo.sh'

echo
echo "==> done.  less-without-less sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then try:  bash ~/less-without-less/bin/ddpager /etc/passwd /etc/hosts"
