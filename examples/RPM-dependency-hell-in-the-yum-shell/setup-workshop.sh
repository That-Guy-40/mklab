#!/usr/bin/env bash
# setup-workshop.sh — turn a fresh Rocky Linux LXD/Incus container into the
# opening scene of Sigurd Urdahl's "yum shell - bat out of dependency hell":
# a local repo of ten tiny RPMs recreating his Percona dependency topology,
# the "production" baseline installed (bat-shared-56 + six innocent
# bystanders), a sudo-capable non-root `learner`, and a ~/dependency-hell/
# sandbox with demo.sh + the repo-build and reset tools.
#
# It drives ONLY the Phase-5 tool (phase5-lxd/lab-lxd.sh exec), so it is
# engine-agnostic (LXD or Incus). Run it AFTER `lab-lxd.sh up`:
#
#   phase5-lxd/lab-lxd.sh up --config examples/RPM-dependency-hell-in-the-yum-shell/yum-shell-rocky.toml
#   examples/RPM-dependency-hell-in-the-yum-shell/setup-workshop.sh yum-shell-rocky/shell
#
# This is the automated counterpart to the by-hand walk in RUNBOOK.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
LXD="$REPO_ROOT/phase5-lxd/lab-lxd.sh"
LEARNER="learner"
SANDBOX="/home/$LEARNER/dependency-hell"

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "usage: $0 <lab>/<service>   (e.g. yum-shell-rocky/shell)" >&2; exit 1; }
[[ -x "$LXD" ]] || { echo "not found: $LXD" >&2; exit 1; }

# Every guest command goes through the phase tool.
g() { "$LXD" exec "$TARGET" -- "$@"; }
push() { g sh -c "cat > '$2'" < "$1"; }

echo "==> [1/6] confirming the box is EL (this lab is RPM/dnf-specific)"
g sh -c '[ -f /etc/rocky-release ] || [ -f /etc/redhat-release ]' \
    || { echo "not an EL box; launch yum-shell-rocky.toml first" >&2; exit 1; }
g sh -c 'cat /etc/rocky-release 2>/dev/null || cat /etc/redhat-release'

echo "==> [2/6] installing the toolsmith's tools (rpm-build, createrepo_c, sudo)"
# The one step that needs the network: everything after runs from the local repo.
g dnf -y -q install rpm-build createrepo_c sudo shadow-utils

echo "==> [3/6] building the bat-hell repo (ten metadata-only RPMs + createrepo)"
push "$HERE/bin/build-bat-hell-repo.sh" /root/build-bat-hell-repo.sh
g bash /root/build-bat-hell-repo.sh

echo "==> [4/6] installing the production baseline, then cutting the box loose"
g dnf -y -q install bat-shared-56 meatloaf-mta python-bat perl-DBD-bat \
                    hellban hellban-sendmail hell-lsb-core
# Disable the network mirrors: the whole walk needs only the local bat-hell
# repo, and an offline box is deterministic and fast. Reversible any time with:
#   sed -i 's/^enabled=0/enabled=1/' /etc/yum.repos.d/rocky*.repo
g sh -c 'for f in /etc/yum.repos.d/*.repo; do
             [ "$f" = /etc/yum.repos.d/bat-hell.repo ] && continue
             sed -i "s/^enabled=1/enabled=0/" "$f"
         done'

echo "==> [5/6] creating the non-root '$LEARNER' (sudo: dnf transactions are root's job)"
g sh -c "id $LEARNER >/dev/null 2>&1 || useradd -m -s /bin/bash $LEARNER"
g sh -c "echo '$LEARNER ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/$LEARNER
         chmod 440 /etc/sudoers.d/$LEARNER"

echo "==> [6/6] pushing the ~/dependency-hell sandbox and running demo.sh in it"
g mkdir -p "$SANDBOX/bin"
push "$HERE/demo.sh"                  "$SANDBOX/demo.sh"
push "$HERE/bin/reset-hell.sh"        "$SANDBOX/bin/reset-hell.sh"
push "$HERE/bin/build-bat-hell-repo.sh" "$SANDBOX/bin/build-bat-hell-repo.sh"
g sh -c "chmod +x $SANDBOX/demo.sh $SANDBOX/bin/*.sh
         chown -R $LEARNER: $SANDBOX"
g su - "$LEARNER" -c "bash ~/dependency-hell/demo.sh"

echo
echo "==> done.  The hell is installed and the escape is proven in $TARGET."
echo "    start it:  $LXD exec $TARGET -- su - $LEARNER"
echo "    then walk RUNBOOK.md with the article open:"
echo "    examples/RPM-dependency-hell-in-the-yum-shell/upstream-tutorial/redpill-linpro/techblog/2018/01/22/bat_out_of_dependency_hell.html"
