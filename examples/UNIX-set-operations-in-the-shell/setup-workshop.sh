#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready set-operations
# box for Peteris Krumins' "Set Operations in the Unix Shell" (+ its cheat sheet
# and the Google Treasure Hunt puzzle that inspired it) and Thomas Guest's
# "He Sells Shell Scripts to Intersect Sets": bash, GNU coreutils (`comm`, `join`,
# `uniq`, `factor`), gawk, perl, sqlite3 as a set oracle, busybox for the
# BusyBox-vs-GNU contrast, a non-root `learner` user, and a `~/set-operations/`
# sandbox holding the articles' recipes verbatim, corrected twins under
# `bin/fixed/`, both authors' sample data, a `demo.sh` that proves the recipes
# agree, and a `treasure-hunt.sh` that reproduces the 2008 puzzle answer.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX-set-operations-in-the-shell/set-operations-debian.toml
#   examples/UNIX-set-operations-in-the-shell/setup-workshop.sh set-operations-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/set-operations"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. set-operations-debian/shell)" >&2; exit 1; }
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

echo "==> [2/5] installing bash + GNU coreutils + gawk + perl + sqlite3 + busybox"
# What each is for:
#   bash      -- `<(...)` process substitution, which every `comm` recipe uses.
#   coreutils -- comm, join, uniq, sort, and `factor` (the prime generator that
#                replaces Krumins' 500 MB download).  BusyBox has no `join`.
#   gawk      -- the cheat sheet's awk implementations; Debian's default is mawk.
#   perl      -- Krumins' power-set one-liner.
#   sqlite3   -- the SET ORACLE: its UNION / INTERSECT / EXCEPT *are* the operators.
#   busybox   -- so BOTH bases can show what BusyBox sort/grep do differently.
case "$DISTRO" in
    debian)
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils gawk perl sqlite3 diffutils busybox less' ;;
    alpine)
        # Alpine has no bash, no join, no sqlite3, no perl; busybox is the base.
        g sh -c 'apk add --no-cache bash coreutils gawk perl sqlite grep sed diffutils less shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac
# Make `awk` mean gawk on BOTH bases (Debian's default is mawk; Alpine's is
# BusyBox awk). /usr/local/bin is first in PATH, so this wins cleanly.
g sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login)"
# bash, not /bin/sh: every `comm -12 <(sort A) <(sort B)` needs process
# substitution, and Debian's /bin/sh is dash, which does not have it.
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/set-operations sandbox"
g sh -c "mkdir -p '$SANDBOX/bin/fixed' '$SANDBOX/data'"
# The recipes as published, and their corrected twins.
for f in setops powerset powerset.pl; do
    push "$HERE/bin/$f"       "$SANDBOX/bin/$f"
    push "$HERE/bin/fixed/$f" "$SANDBOX/bin/fixed/$f"
done
# Krumins' hand-crafted sets, the collation landmine, and Guest's Apache logs.
for f in A B Asub Anotsub Aequal Bequal P Q access_log1 access_log2; do
    push "$HERE/sample-data/$f" "$SANDBOX/data/$f"
done
push "$HERE/demo.sh"          "$SANDBOX/demo.sh"
push "$HERE/treasure-hunt.sh" "$SANDBOX/treasure-hunt.sh"
g sh -c "chmod +x '$SANDBOX'/*.sh '$SANDBOX'/bin/powerset '$SANDBOX'/bin/powerset.pl \
         '$SANDBOX'/bin/fixed/powerset '$SANDBOX'/bin/fixed/powerset.pl"
g sh -c "chmod -R a+rX '$SANDBOX'; chown -R $LEARNER '$SANDBOX'"

echo "==> [5/5] verifying the sandbox (as $LEARNER): demo.sh, then treasure-hunt.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  bash   : $(bash --version | head -1)"
echo "  comm   : $(comm --version | head -1)"
echo "  awk    : $(awk --version 2>/dev/null | head -1)"
echo "  perl   : $(perl -e "print \"perl $^V\n\"")"
echo "  sqlite : $(sqlite3 --version)"
echo "  --- running ~/set-operations/demo.sh ---"
bash ~/set-operations/demo.sh
echo
echo "  --- running ~/set-operations/treasure-hunt.sh ---"
bash ~/set-operations/treasure-hunt.sh'

echo
echo "==> done.  Set-operations sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/UNIX-set-operations-in-the-shell/upstream-tutorial/catonmat/set-operations-in-unix-shell/index.html"
