#!/usr/bin/env bash
# setup-limits.sh — provision a MEMORY-CAPPED container (from one of the
# *-limited.toml specs) into a box for the cgroups/limits half of Ciro Costa's
# /proc series: a C toolchain + `strace` + `procps` (real free/top), a non-root
# `learner`, and a `~/proc-lab/` sandbox with the articles' two C programs
# (mem-hog.c, limit-open-files.c) and a runnable demo-limits.sh that shows the
# cgroup memory cap biting and prlimit() changing a process's open-file limit.
#
# Engine-agnostic (LXD or Incus) — drives only phase5-lxd/lab-lxd.sh. Run AFTER
# `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/linux-proc-vfs-internals/linux-proc-vfs-internals-debian-limited.toml
#   examples/linux-proc-vfs-internals/setup-limits.sh linux-proc-vfs-internals-debian-limited/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# Counterpart to setup-workshop.sh (which does the VFS/getdents half on the
# unlimited boxes). The by-hand walk is RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/proc-lab"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. linux-proc-vfs-internals-debian-limited/shell)" >&2; exit 1; }
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

echo "==> [2/5] installing toolchain + strace + procps (real free/top)"
# procps gives GNU `free`/`top` (BusyBox has thinner applets); linux-headers on
# Alpine keeps parity with the VFS box (not needed by these two programs, but
# harmless). The 512 MiB cap is roomy enough for these installs.
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends build-essential strace procps' ;;
    alpine)
        g sh -c 'apk add --no-cache build-base linux-headers strace procps' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (POSIX /bin/sh login)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/sh $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/sh $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/proc-lab sandbox (article 3 & 4 source + demo)"
g sh -c "mkdir -p '$SANDBOX'"
for f in mem-hog.c limit-open-files.c demo-limits.sh; do
    push "$HERE/sandbox/$f" "$SANDBOX/$f"
done
g sh -c "chmod +x '$SANDBOX/demo-limits.sh'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo-limits.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  free   : $(free -h 2>/dev/null | awk "NR==2{print \$2\" total\"}")"
echo "  --- running ~/proc-lab/demo-limits.sh ---"
cd ~/proc-lab && sh ./demo-limits.sh'

echo
echo "==> done.  cgroups/limits box ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    read       examples/linux-proc-vfs-internals/upstream-tutorial/why-top-inside-container-wrong-memory.html"
echo "    and poke   ~/proc-lab/  (mem-hog.c, limit-open-files.c, demo-limits.sh)."
