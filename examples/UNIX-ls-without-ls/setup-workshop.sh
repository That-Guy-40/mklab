#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready box for
# `ddls`, the ls-without-ls: bash (the interpreter), GNU coreutils (BOTH the
# `stat` that ddls is built on AND the real `ls` the demo uses as its oracle),
# ncurses `tput`, util-linux `script` (the demo's tty harness for the color
# and column checks), a non-root `learner` user, and a `~/ls-without-ls/`
# sandbox holding the script VERBATIM, its corrected twin under `bin/fixed/`,
# and a runnable `demo.sh`.
#
# THE DIVERGENCE THIS FIXES (see README): ddls "lives off the land", but the
# land it assumes is GNU. Debian 13 has everything out of the box. Alpine has
# NONE of it: no bash (the interpreter), a BusyBox `stat` with no --printf
# (the engine), no `tput` (the terminal probe) — and its `ls` is a BusyBox
# applet, so it cannot even serve as the oracle.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX-ls-without-ls/ls-without-ls-debian.toml
#   examples/UNIX-ls-without-ls/setup-workshop.sh ls-without-ls-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/ls-without-ls"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. ls-without-ls-debian/shell)" >&2; exit 1; }
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

echo "==> [2/5] installing bash + GNU coreutils + tput + script"
case "$DISTRO" in
    debian)
        # Debian has all of these in the base image; install anyway so the lab
        # is explicit about what it stands on (and survives slim images).
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils ncurses-bin util-linux diffutils' ;;
    alpine)
        # Alpine has NONE of these: no bash, BusyBox stat (no --printf),
        # no tput, BusyBox ls (not GNU -- useless as the demo's oracle).
        # coreutils brings GNU ls/stat/touch/head; ncurses brings tput;
        # util-linux brings script(1); shadow brings a usable su/useradd.
        g sh -c 'apk add --no-cache bash coreutils ncurses util-linux diffutils shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/ls-without-ls sandbox"
g sh -c "mkdir -p '$SANDBOX/bin/fixed'"
push "$HERE/bin/ddls"       "$SANDBOX/bin/ddls"        # VERBATIM (sha-checked by demo.sh)
push "$HERE/bin/fixed/ddls" "$SANDBOX/bin/fixed/ddls"  # corrected twin
push "$HERE/demo.sh"        "$SANDBOX/demo.sh"
g sh -c "chmod +x '$SANDBOX/demo.sh' '$SANDBOX/bin/ddls' '$SANDBOX/bin/fixed/ddls'"
g sh -c "chmod -R a+rX '$SANDBOX'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  bash   : $(bash --version | head -1)"
echo "  ls     : $(ls --version | head -1)"
echo "  stat   : $(stat --version | head -1)"
echo "  tput   : $(command -v tput)"
echo "  --- running ~/ls-without-ls/demo.sh ---"
bash ~/ls-without-ls/demo.sh'

echo
echo "==> done.  ls-without-ls sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then try:  bash ~/ls-without-ls/bin/ddls -la --color /etc"
