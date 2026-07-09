#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh LXD/Incus container into a ready relational-shell
# box for Matt Might's "Relational shell programming" and Jason Walsh's "SQL in the
# Shell": bash (the article's scripts need it), GNU coreutils (`join`, `comm`,
# `cut`, `sort`, `uniq`, `paste`), gawk, sqlite3 as an SQL oracle, a non-root
# `learner` user, and a `~/relational-algebra/` sandbox holding Might's four
# scripts verbatim, corrected twins under `bin/fixed/`, both articles' sample
# relations, and a runnable `demo.sh` that proves all four implementations agree.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/UNIX-relational-algebra-sql-in-the-shell/relational-algebra-debian.toml
#   examples/UNIX-relational-algebra-sql-in-the-shell/setup-workshop.sh relational-algebra-debian/shell
#
# Distro (Debian vs Alpine) is auto-detected; override with DISTRO=debian|alpine.
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/relational-algebra"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. relational-algebra-debian/shell)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }
# Push a host file into the guest via the wrapper's stdin (no nested-quoting of
# the awk programs and regexes these files are full of).
push() { g sh -c "cat > '$2'" < "$1"; }

echo "==> [1/5] detecting distro in $TARGET"
DISTRO="${DISTRO:-}"
if [[ -z "$DISTRO" ]]; then
    if   g sh -c '[ -f /etc/alpine-release ]'; then DISTRO=alpine
    elif g sh -c '[ -f /etc/debian_version ]'; then DISTRO=debian
    else echo "could not detect distro; set DISTRO=debian|alpine" >&2; exit 1; fi
fi
echo "    distro=$DISTRO"

echo "==> [2/5] installing bash + GNU coreutils + gawk + sqlite3"
# Both articles assume: bash (Might's scripts are #!/bin/bash; `<(...)` process
# substitution and $'\t' are bash, not POSIX sh), GNU coreutils for `join` and
# `comm` (BusyBox ships no `join` at all), gawk, and sqlite3 as the SQL oracle.
case "$DISTRO" in
    debian)
        # Debian has GNU grep/sed/coreutils and bash already; its default awk is
        # mawk, and it has no sqlite3.
        g sh -c 'export DEBIAN_FRONTEND=noninteractive
                 apt-get update -qq
                 apt-get install -y --no-install-recommends \
                     bash coreutils gawk sqlite3 diffutils less' ;;
    alpine)
        # Alpine has NO bash, NO join, and BusyBox applets for everything else.
        g sh -c 'apk add --no-cache bash coreutils gawk sqlite grep sed diffutils less shadow' ;;
    *) echo "unknown DISTRO=$DISTRO" >&2; exit 1 ;;
esac
# Make `awk` mean gawk on BOTH bases (Debian's default is mawk; Alpine's is
# BusyBox awk). /usr/local/bin is first in PATH, so this wins without fighting the
# package manager.
g sh -c 'ln -sf "$(command -v gawk)" /usr/local/bin/awk'

echo "==> [3/5] creating the non-root '$LEARNER' user (bash login)"
# Unlike the sibling text-processing lab, the login shell here IS bash: Might's
# four scripts carry a #!/bin/bash shebang, and the modern one-liners lean on
# process substitution `<(sort A)` and $'\t', neither of which POSIX sh has.
case "$DISTRO" in
    debian) g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER" ;;
    alpine) g sh -c "id $LEARNER >/dev/null 2>&1 || adduser -D -s /bin/bash $LEARNER" ;;
esac

echo "==> [4/5] installing the ~/relational-algebra sandbox"
g sh -c "mkdir -p '$SANDBOX/bin/fixed' '$SANDBOX/data'"
# Might's four scripts, verbatim — the object of study.
for f in cartesian memberp difference equijoin; do
    push "$HERE/bin/$f" "$SANDBOX/bin/$f"
    push "$HERE/bin/fixed/$f" "$SANDBOX/bin/fixed/$f"
done
# Both articles' sample relations.
for f in passwd etc-passwd bad.db f1 f2 employees.tsv departments.tsv; do
    push "$HERE/sample-data/$f" "$SANDBOX/data/$f"
done
push "$HERE/demo.sh" "$SANDBOX/demo.sh"
# `difference` calls `memberp` through PATH, exactly as the article assumes.
g sh -c "printf '%s\n' 'PATH=\"\$HOME/relational-algebra/bin:\$PATH\"' >> /home/$LEARNER/.profile"
g sh -c "printf '%s\n' 'PATH=\"\$HOME/relational-algebra/bin:\$PATH\"' >> /home/$LEARNER/.bashrc"
g sh -c "chmod +x '$SANDBOX/demo.sh' '$SANDBOX'/bin/* '$SANDBOX'/bin/fixed/* 2>/dev/null || true"
g sh -c "chmod -R a+rX '$SANDBOX'; chown -R $LEARNER '$SANDBOX' /home/$LEARNER/.profile /home/$LEARNER/.bashrc"

echo "==> [5/5] verifying the sandbox (as $LEARNER): run demo.sh"
g su - "$LEARNER" -c '
echo "  whoami : $(whoami)"
echo "  bash   : $(bash --version | head -1)"
echo "  join   : $(join --version 2>/dev/null | head -1)"
echo "  awk    : $(awk --version 2>/dev/null | head -1)"
echo "  sqlite : $(sqlite3 --version)"
echo "  --- running ~/relational-algebra/demo.sh ---"
bash ~/relational-algebra/demo.sh'

echo
echo "==> done.  Relational-shell sandbox ready in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then open  examples/UNIX-relational-algebra-sql-in-the-shell/upstream-tutorial/matt-might/articles/sql-in-the-shell/index.html"
