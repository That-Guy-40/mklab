#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a bash-scripting
# playground for Daniel Robbins' "Bash by example" series: BASH + the standard
# complement of Unix tools, a non-root `learner` user, and a working directory
# to write and run scripts in as you read the three PDFs.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/shell-intermediate-workshop/shell-intermediate-debian.toml
#   examples/shell-intermediate-workshop/setup-workshop.sh shell-intermediate-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
PLAYGROUND="bash-by-example"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. shell-intermediate-debian/shell)" >&2; exit 1; }
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
        # The trixie base already has bash + GNU coreutils; add scripting/reading
        # tools, the bash man page (man-db), and a couple of script staples.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils findutils grep sed gawk \
                     nano less man-db manpages bash-doc \
                     file tree procps bc diffutils' ;;
    alpine)
        # Alpine ships ash + BusyBox; the articles assume BASH + GNU tools.
        # Install the real ones (see RUNBOOK "BusyBox vs GNU"). `man bash` needs
        # bash-doc; per-tool man pages live in `*-doc` subpackages on Alpine.
        g sh -c 'apk add --no-cache \
                     bash bash-doc coreutils findutils grep sed gawk \
                     nano less mandoc man-pages \
                     coreutils-doc grep-doc sed-doc findutils-doc \
                     file tree procps-ng shadow bc diffutils' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login shell)"
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] creating the scripting playground ~/$PLAYGROUND with a starter script"
# A tiny, benign starter exercising Part 1-2 constructs: variable + parameter
# expansion, a function, a [[ ]] conditional, a for loop, and $(( )) arithmetic.
g su - "$LEARNER" -c "mkdir -p ~/$PLAYGROUND && cat > ~/$PLAYGROUND/demo.sh <<'EOS'
#!/usr/bin/env bash
# demo.sh — a first taste of Bash by example, Parts 1-2.
greet() { echo \"Hello from \${1:-bash}!\"; }   # function + parameter expansion
greet \"\$(whoami)\"
total=0
for n in 1 2 3 4 5; do total=\$(( total + n )); done   # loop + arithmetic
if [[ \$total -eq 15 ]]; then                          # [[ ]] conditional
    echo \"sum 1..5 = \$total  (loop + arithmetic OK)\"
fi
EOS
chmod +x ~/$PLAYGROUND/demo.sh"

echo "==> [5/5] verifying the playground (as $LEARNER): run the starter script"
g su - "$LEARNER" -c "echo \"  whoami : \$(whoami)\"
                      echo \"  shell  : \$(bash --version | head -1)\"
                      echo \"  pwd    : \$(pwd)\"
                      echo \"  --- running ~/$PLAYGROUND/demo.sh ---\"
                      bash ~/$PLAYGROUND/demo.sh"

echo
echo "==> done.  Bash-scripting playground ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then read  examples/shell-intermediate-workshop/upstream-tutorial/bash{,2,3}.pdf"
echo "    and write your scripts in  ~/$PLAYGROUND/"
