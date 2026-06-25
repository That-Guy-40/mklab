#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready BASH
# scripting box for Matt Might's "Shell programming with bash: by example": BASH +
# the standard complement of Unix tools, a non-root `learner` user, and a
# `~/bash-by-example/` playground with a runnable starter script that exercises
# constructs straight from the article (arrays, parameter expansion, (( ))
# arithmetic, a function).
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-programming-by-example/bash-by-example-debian.toml
#   examples/shell-intermediate-programming-by-example/setup-workshop.sh bash-by-example-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. bash-by-example-debian/shell)" >&2; exit 1; }
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
        # add the reading/scripting tools, the bash man page, bc, diff.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils findutils grep sed gawk nano less \
                     man-db manpages bash-doc file tree procps bc diffutils' ;;
    alpine)
        # Alpine ships ash + BusyBox and has NO bash at all; install it + GNU
        # tools (see "bash vs BusyBox ash"). `man bash` needs bash-doc; per-tool
        # man pages are in `*-doc` subpackages on Alpine.
        g sh -c 'apk add --no-cache bash bash-doc coreutils findutils grep sed gawk \
                     nano less mandoc man-pages coreutils-doc grep-doc sed-doc findutils-doc \
                     file tree procps-ng shadow bc diffutils' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login shell)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] creating the ~/bash-by-example playground with a starter script"
# Quoted heredoc delimiter ("EOS") => nothing in the script body is expanded when
# it is written; demo.sh is stored verbatim and only runs when the learner does.
# The body deliberately avoids apostrophes so the single-quoted `-c '...'` wrapper
# needs no escaping — the example strings stay faithful to the article's ops.
g su - "$LEARNER" -c '
mkdir -p ~/bash-by-example
cat > ~/bash-by-example/demo.sh <<"EOS"
#!/usr/bin/env bash
# A few constructs straight from Matt Might, "bash by example".

# Arrays: every variable is an array; use @ for all elements (NOT ${#arr},
# which counts the characters of element 0).
fruits=("apple" "ripe banana" "cherry")
echo "array   : count=${#fruits[@]}  second=${fruits[1]}"   # count=3  second=ripe banana

# Parameter expansion: replace, longest-suffix strip, slice.
phrase="the cat sat"
echo "replace : ${phrase/cat/dog}"          # the dog sat
path="/usr/bin:/bin:/sbin"
echo "strip   : ${path%%/bin*}"             # /usr
sentence="a fan of dogs"
echo "slice   : ${sentence:2:3}"            # fan

# Arithmetic: (( )) to assign, $(( )) for a value.
(( product = 3 * 12 ))
echo "arith   : 3 * 12 = $product, 7 + 5 = $(( 7 + 5 ))"

# A subroutine: factorial (the article finale).
fact() {
  local result=1 n=$1
  while (( n >= 1 )); do (( result = n * result )); (( n -= 1 )); done
  echo "$result"
}
echo "fact    : 5! = $(fact 5)"             # 120
EOS
chmod +x ~/bash-by-example/demo.sh'

echo "==> [5/5] verifying the playground (as $LEARNER): run the starter script"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  shell  : $(bash --version | head -1)"
echo "  pwd    : $(pwd)"
echo "  --- running ~/bash-by-example/demo.sh ---"
bash ~/bash-by-example/demo.sh'

echo
echo "==> done.  Bash-scripting playground ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/shell-intermediate-programming-by-example/upstream-tutorial/articles/bash-by-example/index.html  and follow along."
