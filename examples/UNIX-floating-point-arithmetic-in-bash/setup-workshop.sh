#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready floating-point
# box for Michael Wood's `shellmath` and Cyrus's recursive `div`: bash (both are
# #!/bin/bash), `bc` and `dc` (the orthodox external calculators), gawk (the
# binary-IEEE oracle), zsh + ksh (to prove that *other* shells have had float
# arithmetic in `$(( ))` all along), a non-root `learner` user, and a
# `~/float-math/` sandbox holding Cyrus's `div` verbatim, corrected twins under
# `bin/fixed/`, a pinned clone of shellmath, and a runnable `demo.sh`.
#
# THE DIVERGENCE THIS FIXES (it is inverted between the two bases -- see README):
#   Debian 13 ships bash but NO bc and NO dc -- the canonical "just use bc"
#             advice does not work out of the box.
#   Alpine    ships bc and dc (as BusyBox applets!) but NO bash at all -- so
#             neither shellmath nor Cyrus's div can even be interpreted.
# Each base is missing exactly what the other has, and this lab needs both.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX-floating-point-arithmetic-in-bash/float-math-debian.toml
#   examples/UNIX-floating-point-arithmetic-in-bash/setup-workshop.sh float-math-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/float-math"

# shellmath is upstream CODE (a repo, not a single page), so per house convention
# we CITE AND PIN rather than mirror: this exact commit, fetched at setup time.
# Its README -- the tutorial -- IS vendored, under upstream-tutorial/shellmath/.
SHELLMATH_REPO="https://github.com/clarity20/shellmath.git"
SHELLMATH_SHA="f2cbc6cb99c676ce56de493133890370f3b002f7"   # 2023-09-28, master

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. float-math-debian/shell)" >&2; exit 1; }
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

echo "==> [2/5] installing bash + bc/dc + gawk + zsh/ksh + git"
case "$DISTRO" in
    debian)
        # Debian HAS bash; it does NOT have bc or dc. Its default awk is mawk.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash bc dc gawk zsh ksh git ca-certificates diffutils less' ;;
    alpine)
        # Alpine has NO bash. It DOES have bc + dc as BusyBox applets, but we install
        # the real GNU bc so `bc -l` (and e(1), used by demo.sh) behaves identically.
        g sh -c 'apk add --no-cache bash bc gawk zsh git ca-certificates diffutils less shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac
# Make `awk` mean gawk on BOTH bases (Debian's default is mawk, Alpine's is
# BusyBox awk). Both do IEEE doubles, but gawk makes the two bases byte-identical.
g sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login)"
# The login shell IS bash: shellmath and Cyrus's div are both #!/bin/bash, and
# shellmath's no-subshell optimization depends on Bash's variable semantics.
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/float-math sandbox (+ pinned shellmath $SHELLMATH_SHA)"
g sh -c "mkdir -p '$SANDBOX/bin/fixed'"
push "$HERE/bin/div"           "$SANDBOX/bin/div"             # Cyrus, VERBATIM
push "$HERE/bin/fixed/div"     "$SANDBOX/bin/fixed/div"       # corrected twin
push "$HERE/bin/fixed/sci2dec" "$SANDBOX/bin/fixed/sci2dec"   # shellmath workaround
push "$HERE/demo.sh"           "$SANDBOX/demo.sh"

# Pin the fetch: clone, then check out the exact commit this lab was written and
# verified against. A moving `master` would silently change the errata.
g sh -c "
    set -e
    rm -rf '$SANDBOX/shellmath'
    git clone -q '$SHELLMATH_REPO' '$SANDBOX/shellmath'
    cd '$SANDBOX/shellmath'
    git checkout -q '$SHELLMATH_SHA'
    chmod +x *.sh
    echo \"    shellmath pinned at \$(git rev-parse --short HEAD) (\$(git log -1 --format=%cd --date=short))\"
"
g sh -c "chmod +x '$SANDBOX/demo.sh' '$SANDBOX'/bin/div '$SANDBOX'/bin/fixed/* 2>/dev/null || true"
g sh -c "chmod -R a+rX '$SANDBOX'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  bash   : $(bash --version | head -1)"
echo "  bc     : $(bc --version 2>/dev/null | head -1)"
echo "  awk    : $(awk --version 2>/dev/null | head -1)"
echo "  zsh    : $(zsh --version 2>/dev/null | head -1)"
echo "  --- running ~/float-math/demo.sh ---"
bash ~/float-math/demo.sh'

echo
echo "==> done.  Floating-point sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then read  examples/UNIX-floating-point-arithmetic-in-bash/upstream-tutorial/shellmath/README.md"
