#!/usr/bin/env bash
# setup-observe.sh — provision a DEBUG/TOOLS container (from one of the *-debug.toml
# specs) into a box for the observability half of Ciro Costa's /proc series: a C
# toolchain + gdb + strace + iproute2 (ss/ip) + procps, a non-root `learner`, and
# a `~/proc-lab/` sandbox with the articles' two C programs (accept.c, socket.c)
# and a runnable demo-observe.sh that reads a blocked process's kernel wchan and
# watches sockets appear in /proc.
#
# Engine-agnostic (LXD or Incus) — drives only phase5-lxd/lab-lxd.sh. Run AFTER
# `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian-debug.toml
#   examples/linux-proc-vfs-internals/setup-observe.sh linux-proc-vfs-internals-debian-debug/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# Third counterpart to setup-workshop.sh (VFS) and setup-limits.sh (cgroups). The
# by-hand walk is RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/proc-lab"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. linux-proc-vfs-internals-debian-debug/shell)" >&2; exit 1; }
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

echo "==> [2/5] installing toolchain + gdb + strace + iproute2 + procps"
# gdb/gstack give userspace backtraces; strace shows the socket() syscall;
# iproute2 provides `ss` and `ip netns`; procps provides `ps`/`pidof`.
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends build-essential gdb strace iproute2 procps' ;;
    alpine)
        g sh -c 'apk add --no-cache build-base gdb strace iproute2 procps' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (POSIX /bin/sh login)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/sh $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/sh $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/proc-lab sandbox (article 5 & 6 source + demo)"
g sh -c "mkdir -p '$SANDBOX'"
for f in accept.c socket.c demo-observe.sh; do
    push "$HERE/sandbox/$f" "$SANDBOX/$f"
done
g sh -c "chmod +x '$SANDBOX/demo-observe.sh'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo-observe.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  gdb    : $(gdb --version | head -1)"
echo "  --- running ~/proc-lab/demo-observe.sh ---"
cd ~/proc-lab && sh ./demo-observe.sh'

echo
echo "==> done.  /proc observability box ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    read       examples/linux-proc-vfs-internals/upstream-tutorial/using-procfs-to-get-process-stack-trace.html"
echo "    and poke   ~/proc-lab/  (accept.c, socket.c, demo-observe.sh)."
