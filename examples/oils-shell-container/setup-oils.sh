#!/usr/bin/env bash
# setup-oils.sh — build + install Oils-for-Unix 0.37.0 inside an already-running
# LXD/Incus container, from the vendored release tarball, with GNU readline as a
# HARD dependency.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic: identical on LXD or Incus.  Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/oils-shell-container/oils-debian.toml
#   examples/oils-shell-container/setup-oils.sh oils-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
VERSION="0.37.0"
TARBALL="$HERE/oils-for-unix-$VERSION.tar.gz"
SRCDIR="oils-for-unix-$VERSION"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. oils-debian/shell)" >&2; exit 1; }
[[ -f "$TARBALL" ]] || { echo "missing vendored tarball: $TARBALL" >&2; exit 1; }
[[ -x "$LXD"     ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }

echo "==> [1/6] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/6] installing build deps (C++11 toolchain + GNU readline)"
case "$DISTRO" in
    debian)
        # Exactly the upstream INSTALL.html one-liner.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y build-essential libreadline-dev' ;;
    alpine)
        # Upstream lists `gcc`, but Oils is C++ — `c++` (g++) and libstdc++ live
        # in `build-base`, not the `gcc` package.  See RUNBOOK.md "Alpine deps".
        g sh -c 'apk add --no-cache build-base readline-dev' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/6] pushing + extracting the release tarball into /root"
# Stream the tarball in through the phase tool (no separate file-push verb
# needed; `exec` forwards stdin).  Then extract exactly as INSTALL.html shows.
g sh -c "cat > /root/oils-for-unix-$VERSION.tar.gz" < "$TARBALL"
g sh -c "cd /root && rm -rf '$SRCDIR' && tar -x --gz < oils-for-unix-$VERSION.tar.gz"

echo "==> [4/6] ./configure --with-readline   (readline is mandatory)"
# --with-readline => configure FAILS if readline is missing, instead of quietly
# building a non-interactive binary.  That is the hard-dependency guarantee.
g sh -c "cd /root/$SRCDIR && ./configure --with-readline"

echo "==> [5/6] _build/oils.sh   (compile; 30-60s)"
g sh -c "cd /root/$SRCDIR && _build/oils.sh"

echo "==> [5/6] ./install   (-> /usr/local/bin/{oils-for-unix,osh,ysh})"
g sh -c "cd /root/$SRCDIR && ./install"

echo "==> [6/6] smoke test"
g osh -c 'echo "OSH says: $(echo hi)"'
g ysh -c 'json write ({build: "ok", readline: true})'
echo
echo "    readline linked in?"
g sh -c 'ldd "$(command -v oils-for-unix)" | grep -i readline || echo "    (no readline in ldd — unexpected)"'

echo
echo "==> done.  Oils $VERSION is installed in $TARGET."
echo "    interactive:  $LXD exec $TARGET -- osh"
echo "                  $LXD exec $TARGET -- ysh"
