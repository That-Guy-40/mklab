#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready /proc box for
# Ciro S. Costa's two ops.tips articles ("What is /proc?" and "How is /proc able
# to list process IDs?"): a C toolchain (gcc) + strace, a non-root `learner`
# user, and a `~/proc-lab/` sandbox holding the articles' two C programs
# (open-fd.c, list-pids.c) and a runnable demo.sh that reads /proc, traces
# getdents64, and compiles + runs both programs.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian.toml
#   examples/linux-proc-vfs-internals/setup-workshop.sh linux-proc-vfs-internals-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/proc-lab"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. linux-proc-vfs-internals-debian/shell)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }
# Push a host file into the guest via the wrapper's stdin.
push() { g sh -c "cat > '$2'" < "$1"; }

echo "==> [1/5] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/5] installing the C toolchain + strace"
# Article 2's list-pids.c #includes <linux/types.h> and calls the raw
# SYS_getdents64. Those kernel UAPI headers ship with libc6-dev on Debian
# (pulled by build-essential); on Alpine they are a SEPARATE package
# `linux-headers`, without which the compile fails — the sharpest divergence
# this lab teaches. `procps` gives Debian a real `ps`; Alpine has BusyBox ps.
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends build-essential strace procps' ;;
    alpine)
        # build-base = gcc + musl-dev + make; linux-headers = <linux/types.h>;
        # shadow = useradd/-style tools (we use adduser, but keep parity).
        g sh -c 'apk add --no-cache build-base linux-headers strace' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (POSIX /bin/sh login)"
# No bash needed (this lab is C + /proc, not shell scripting), so the learner
# logs into the base /bin/sh — dash on Debian, BusyBox ash on Alpine.
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/sh $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/sh $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/proc-lab sandbox (the article source + demo)"
g sh -c "mkdir -p '$SANDBOX'"
# The exact code the demo compiles/runs, kept here for the learner to read,
# edit, and rebuild — this is the point of the box.
for f in open-fd.c list-pids.c demo.sh; do
    push "$HERE/sandbox/$f" "$SANDBOX/$f"
done
g sh -c "chmod +x '$SANDBOX/demo.sh'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): compilers + run demo.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  uname  : $(uname -sr)"
echo "  gcc    : $(gcc --version | head -1)"
echo "  libc   : $(ldd --version 2>&1 | head -1)"
echo "  strace : $(strace --version 2>&1 | head -1)"
echo "  --- running ~/proc-lab/demo.sh ---"
cd ~/proc-lab && sh ./demo.sh'

echo
echo "==> done.  /proc exploration box ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then read  examples/linux-proc-vfs-internals/upstream-tutorial/what-is-slash-proc.html"
echo "    and poke   ~/proc-lab/  (open-fd.c, list-pids.c, demo.sh)."
