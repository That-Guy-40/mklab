#!/usr/bin/env bash
# build-bat-hell-repo.sh — build the local "bat hell" RPM repo: ten tiny
# metadata-only packages that recreate, name for name, the dependency topology
# of Sigurd Urdahl's "yum shell - bat out of dependency hell" (Redpill Linpro
# techblog, 2018-01-22) — with the Percona packages renamed after the article's
# Meat Loaf epigraph, so nothing here shadows a real repository.
#
#   the article (EL7, Percona)                       this repo (bat hell)
#   ---------------------------------------------    ---------------------------------
#   Percona-Server-shared-56  (libmysqlclient.so.18) bat-shared-56        (libbat.so.18)
#   Percona-Server-shared-compat-57  (conflicts ^)   bat-shared-compat-57 (conflicts ^)
#   Percona-Server-shared-57                         bat-shared-57
#   Percona-Server-client-57                         bat-client-57
#   postfix        (needs libmysqlclient.so.18)      meatloaf-mta         (needs libbat.so.18)
#   MySQL-python                                     python-bat
#   perl-DBD-MySQL                                   perl-DBD-bat
#   fail2ban                                         hellban
#   fail2ban-sendmail  (needs an MTA)                hellban-sendmail     (needs mta)
#   redhat-lsb-core    (needs /usr/sbin/sendmail)    hell-lsb-core        (needs mta)
#
# All ten are noarch and payload-free: RPM dependency resolution is pure
# metadata (Provides / Requires / Conflicts), so an empty %files section is all
# the hell requires. Run as root inside the lab box; needs rpm-build and
# createrepo_c (setup-workshop.sh installs both).
set -euo pipefail

for tool in rpmbuild createrepo_c; do
    command -v "$tool" >/dev/null || { echo "missing: $tool (run setup-workshop.sh first)" >&2; exit 1; }
done

REPO=/opt/bat-hell/repo
TOP=/opt/bat-hell/rpmbuild
LOG=/opt/bat-hell/rpmbuild.log
mkdir -p "$REPO" "$TOP"/{SPECS,RPMS}

# spec NAME VERSION RELEASE SUMMARY [Directive: value]...  — write one minimal spec
spec() {
    local name=$1 ver=$2 rel=$3 summary=$4; shift 4
    {
        printf 'Name: %s\nVersion: %s\nRelease: %s\nSummary: %s\n' "$name" "$ver" "$rel" "$summary"
        printf 'License: MIT\nBuildArch: noarch\n'
        local d; for d in "$@"; do printf '%s\n' "$d"; done
        printf '%%description\n%s\nPart of the bat-hell teaching repo; installs no files.\n' "$summary"
        printf '%%files\n'
    } > "$TOP/SPECS/$name.spec"
}

# The two library providers: same soname, mutually exclusive — the crux of the
# article. (A real soname dependency would be spelled libbat.so.18()(64bit) and
# generated from the payload; a plain string keeps these packages noarch.)
spec bat-shared-56        5.6.38 rel83.0.el9 \
    "Shared libraries for bat 5.6 (provides libbat.so.18)" \
    "Provides: libbat.so.18"
spec bat-shared-compat-57 5.7.20 19.1.el9 \
    "Compatibility shared libraries for bat 5.7 (provides libbat.so.18)" \
    "Provides: libbat.so.18" \
    "Conflicts: bat-shared-56"

# The 5.7 stack you are actually trying to install.
spec bat-shared-57 5.7.20 19.1.el9 \
    "Shared libraries for bat 5.7" \
    "Requires: bat-shared-compat-57"
spec bat-client-57 5.7.20 19.1.el9 \
    "Client utilities for bat 5.7" \
    "Requires: bat-shared-57"

# The innocent bystanders — "production" packages that happen to need libbat,
# or need something that needs it. Versions mirror the article's casualty list.
spec meatloaf-mta 2.10.1 6.el9 \
    "Mail transfer agent (links libbat.so.18)" \
    "Requires: libbat.so.18" \
    "Provides: mta"
spec python-bat 1.2.5 1.el9 \
    "Python bindings for bat (links libbat.so.18)" \
    "Requires: libbat.so.18"
spec perl-DBD-bat 4.023 5.el9 \
    "Perl DBD driver for bat (links libbat.so.18)" \
    "Requires: libbat.so.18"
spec hellban 0.9.7 1.el9 \
    "Ban hosts that cause multiple authentication errors (metapackage)" \
    "Requires: hellban-sendmail"
spec hellban-sendmail 0.9.7 1.el9 \
    "Sendmail actions for hellban (needs an MTA)" \
    "Requires: mta"
spec hell-lsb-core 4.1 27.el9 \
    "Hell Standard Base Core module support" \
    "Requires: mta"

: > "$LOG"
for s in "$TOP"/SPECS/*.spec; do
    rpmbuild --define "_topdir $TOP" -bb "$s" >> "$LOG" 2>&1 \
        || { echo "rpmbuild failed for $s — log follows:" >&2; tail -20 "$LOG" >&2; exit 1; }
done
cp "$TOP"/RPMS/noarch/*.rpm "$REPO"/
createrepo_c --quiet "$REPO"

cat > /etc/yum.repos.d/bat-hell.repo <<EOF
[bat-hell]
name=bat hell - local teaching repo
baseurl=file://$REPO
enabled=1
gpgcheck=0
EOF

echo "bat-hell repo ready: $(ls "$REPO"/*.rpm | wc -l) packages in $REPO"
