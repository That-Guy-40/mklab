#!/usr/bin/env bash
# tiny-internet.sh — build John S. Tonello's "Tiny Internet Project" (Linux
# Journal, 2016) as six Debian 13 Incus containers on a private bridge.
#
#   Upstream series : upstream-tutorial/  (byte-exact archives + provenance)
#     Part I   : https://www.linuxjournal.com/content/tiny-internet-project-part-i
#     Part II  : https://www.linuxjournal.com/content/tiny-internet-project-part-ii
#     Part III : https://www.linuxjournal.com/content/tiny-internet-project-part-iii
#
# THE GEM: a whole self-contained internet — the tiny.lab domain on
# 10.128.1.0/24 — with your OWN authoritative DNS (BIND9 primary + secondary
# kept in sync by AXFR zone transfer), your OWN package source (apt-cacher-ng),
# local mail that actually delivers (Postfix + Dovecot), and LAMP + phpMyAdmin
# web hosting. Tonello built it on Proxmox VMs + Ubuntu 14.04; this drives the
# repo's phase5-lxd substrate (rootless Incus system containers) on Debian 13,
# and documents every place the modern distro diverges from the 2016 recipe.
#
# The provisioning runs entirely through phase5-lxd/lab-lxd.sh (up / exec /
# down) — configs are pushed into containers over `exec … -- tee <path>` stdin.
#
# Usage:
#   tiny-internet.sh net             # create the labbr0 managed bridge
#   tiny-internet.sh up              # net + lab-lxd.sh up + settle on labbr0
#   tiny-internet.sh provision [svc] # install + configure all nodes (or just one)
#   tiny-internet.sh verify          # dig / apt / imap / curl probes from admin
#   tiny-internet.sh status          # node/IP/reachability table
#   tiny-internet.sh down            # lab-lxd.sh down (stop+delete instances)
#   tiny-internet.sh clean [--net]   # down + (with --net) delete the labbr0 bridge
#   tiny-internet.sh help
#
# Env: LABBR0_SUBNET (default 10.128.1.1/24), TINY_DOMAIN (default tiny.lab)
set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/config"
TOML="$HERE/tiny-internet.toml"
LAB="tiny-internet"                         # must match [lab].name in the TOML
LABLXD="$(cd "$HERE/../../phase5-lxd" && pwd)/lab-lxd.sh"

# ─── Lab constants ───────────────────────────────────────────────────────────
BRIDGE="labbr0"
SUBNET="${LABBR0_SUBNET:-10.128.1.1/24}"
DOMAIN="${TINY_DOMAIN:-tiny.lab}"
DNS1="10.128.1.3"; DNS2="10.128.1.4"
# service → last octet (addresses live in tiny-internet.toml; kept here for
# `status`/`verify` and the settle wait).
NODES="dns01 dns02 mail mirror web01 admin"
ip_of() { case "$1" in
    dns01) echo 10.128.1.3;; dns02) echo 10.128.1.4;; mail) echo 10.128.1.5;;
    mirror) echo 10.128.1.6;; web01) echo 10.128.1.7;; admin) echo 10.128.1.25;;
    *) return 1;; esac; }

log()  { printf '\033[1;36m[tiny]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[tiny] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[tiny] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ─── exec/file-push helpers (all through lab-lxd.sh) ─────────────────────────
# ex <svc> <args...>       — run a command in the node (args after the -- )
ex()   { "$LABLXD" exec "$LAB/$1" -- "${@:2}"; }
# sh_in <svc> <<'EOF'…     — run a shell script piped over stdin (sh -s)
sh_in(){ "$LABLXD" exec "$LAB/$1" -- sh -s; }
# push <svc> <localfile-under-config/> <remote-path>
push() { "$LABLXD" exec "$LAB/$1" -- tee "$3" < "$CONF/$2" >/dev/null \
             || die "push $2 -> $1:$3 failed"; }

require() { command -v "$1" >/dev/null || die "need '$1' on the host"; }

# ─── net: create the managed bridge (lab-lxd.sh never creates networks) ──────
cmd_net() {
    require incus
    if incus network show "$BRIDGE" >/dev/null 2>&1; then
        log "bridge '$BRIDGE' already exists"
    else
        log "creating bridge '$BRIDGE' ($SUBNET, NAT, dns.mode=none)"
        # dns.mode=none: stop the bridge's dnsmasq from answering DNS, so our
        # BIND servers are the sole authority for tiny.lab (no split-brain).
        # DHCP still hands out the static reservations from the TOML nic devices.
        incus network create "$BRIDGE" \
            ipv4.address="$SUBNET" ipv4.nat=true \
            dns.domain="$DOMAIN" dns.mode=none >/dev/null \
            || die "incus network create $BRIDGE failed"
        log "bridge '$BRIDGE' created"
    fi
}

# ─── up: bridge + lab-lxd.sh up + settle every node onto labbr0 ──────────────
cmd_up() {
    [[ -x "$LABLXD" ]] || die "lab-lxd.sh not found/executable at $LABLXD"
    cmd_net
    log "launching the six nodes via lab-lxd.sh up …"
    # NOTE: an Incus launch very occasionally wedges client-side (empty
    # operation list, no instance) — a known local flake. If `up` hangs, Ctrl-C,
    # `./tiny-internet.sh down`, and re-run; a plain retry clears it.
    "$LABLXD" up --config "$TOML" || die "lab-lxd.sh up failed"
    # Each node boots on the profile's incusbr0 nic, then the TOML overrides eth0
    # onto labbr0 with a static IP. Restart so it comes up ON labbr0, then wait
    # for the reserved address to appear.
    log "restarting nodes so eth0 comes up on $BRIDGE …"
    local svc iname
    for svc in $NODES; do
        iname="lab-${LAB}-${svc}"
        incus restart "$iname" >/dev/null 2>&1 || warn "restart $iname failed"
    done
    log "waiting for static addresses …"
    local want got tries
    for svc in $NODES; do
        want="$(ip_of "$svc")"; iname="lab-${LAB}-${svc}"; tries=0
        until got="$(incus list "$iname" -c4 --format csv 2>/dev/null | grep -o "$want")"; do
            tries=$((tries+1)); [[ $tries -gt 30 ]] && { warn "$svc never reached $want"; break; }
            sleep 1
        done
        [[ "$got" == "$want" ]] && log "  $svc = $want"
    done
    log "up complete — next: ./tiny-internet.sh provision"
}

# ─── repoint: a node uses OUR DNS + the apt cache (Debian-13 gotcha handling) ─
# Disables systemd-resolved (which owns /etc/resolv.conf) and drops a static
# resolv.conf pointing at dns01/dns02, plus the apt proxy config for mirror.
repoint() {
    local svc="$1"
    log "repoint $svc → dns01/dns02 + apt cache"
    ex "$svc" sh -c 'systemctl disable --now systemd-resolved >/dev/null 2>&1 || true; rm -f /etc/resolv.conf'
    push "$svc" common/resolv.conf.tiny        /etc/resolv.conf
    push "$svc" mirror/01acng-client.conf      /etc/apt/apt.conf.d/01acng
}

# apt install helper: quiet, non-interactive, inside a node
apt_in() { ex "$1" sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq ${*:2}"; }

# ─── provision: install + configure every daemon ─────────────────────────────
prov_dns01() {
    log "── dns01: BIND9 primary (authoritative tiny.lab) ──"
    apt_in dns01 bind9 bind9utils dnsutils
    push dns01 dns/named.conf.options /etc/bind/named.conf.options
    push dns01 dns/named.conf.local   /etc/bind/named.conf.local
    push dns01 dns/db.tiny.lab        /etc/bind/db.tiny.lab
    push dns01 dns/db.10.128.1        /etc/bind/db.10.128.1
    ex dns01 named-checkconf
    ex dns01 named-checkzone "$DOMAIN" /etc/bind/db.tiny.lab
    ex dns01 named-checkzone 1.128.10.in-addr.arpa /etc/bind/db.10.128.1
    ex dns01 systemctl restart named
    log "dns01 primary up"
}
prov_dns02() {
    log "── dns02: BIND9 secondary (AXFR slave of dns01) ──"
    apt_in dns02 bind9 bind9utils dnsutils
    push dns02 dns/named.conf.options      /etc/bind/named.conf.options
    push dns02 dns/dns02.named.conf.local  /etc/bind/named.conf.local
    ex dns02 named-checkconf
    ex dns02 systemctl restart named
    log "dns02 secondary up (pulls zones from dns01 by AXFR)"
}
prov_mirror() {
    log "── mirror: apt-cacher-ng caching proxy ──"
    # tunnelenable=false: don't act as a CONNECT proxy for https (we set
    # Acquire::https::Proxy DIRECT on clients anyway).
    ex mirror sh -c 'echo "apt-cacher-ng apt-cacher-ng/tunnelenable boolean false" | debconf-set-selections'
    apt_in mirror apt-cacher-ng
    ex mirror systemctl enable --now apt-cacher-ng
    log "mirror up on http://mirror.$DOMAIN:3142"
}
prov_mail() {
    log "── mail: Postfix (Internet Site) + Dovecot IMAP/POP3 ──"
    # Mailboxes ARE system users (Dovecot authenticates via PAM). Create the lab
    # users so there's something to deliver to / fetch as. ⚠️ throwaway lab
    # passwords — documented in MANUAL_TESTING.md, never reuse.
    ex mail sh -c 'for u in alice bob; do id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"; done; printf "alice:tinylab\nbob:tinylab\n" | chpasswd'
    push mail mail/debconf-postfix.preseed /tmp/postfix.preseed
    ex mail sh -c 'debconf-set-selections < /tmp/postfix.preseed'
    apt_in mail postfix dovecot-imapd dovecot-pop3d
    # Postfix: apply the lab settings via postconf -e (skip comments/blanks).
    push mail mail/postfix.postconf /tmp/postfix.postconf
    ex mail sh -c 'while IFS= read -r l; do case "$l" in ""|\#*) continue;; esac; postconf -e "$l"; done < /tmp/postfix.postconf'
    # Dovecot: lab drop-in (see the file for the 2.4 mail_location/mail_inbox_path gotchas).
    push mail mail/99-tiny.conf /etc/dovecot/conf.d/99-tiny.conf
    ex mail systemctl restart postfix dovecot
    log "mail up (SMTP:25, IMAP:143, POP3:110)"
}
prov_web01() {
    log "── web01: Apache + MariaDB + PHP + phpMyAdmin ──"
    push web01 web/debconf-phpmyadmin.preseed /tmp/pma.preseed
    ex web01 sh -c 'debconf-set-selections < /tmp/pma.preseed'
    apt_in web01 apache2 mariadb-server php libapache2-mod-php php-mysql phpmyadmin
    ex web01 mkdir -p /var/www/tiny
    push web01 web/index.html   /var/www/tiny/index.html
    push web01 web/phpinfo.php  /var/www/tiny/phpinfo.php
    push web01 web/000-tiny.conf /etc/apache2/sites-available/000-tiny.conf
    ex web01 sh -c 'a2dissite 000-default >/dev/null 2>&1 || true; a2ensite 000-tiny >/dev/null; systemctl reload apache2'
    log "web01 up (http://web01.$DOMAIN/, /phpinfo.php, /phpmyadmin/)"
}
prov_admin() {
    log "── admin: client tools (dig, curl) ──"
    apt_in admin dnsutils curl
    log "admin ready to run probes"
}

cmd_provision() {
    [[ -x "$LABLXD" ]] || die "lab-lxd.sh not found at $LABLXD"
    if [[ $# -gt 0 ]]; then
        # single node — assumes its dependencies (DNS, mirror) are already up
        case "$1" in
            dns01) prov_dns01;; dns02) prov_dns02;; mirror) prov_mirror;;
            mail) repoint mail; prov_mail;; web01) repoint web01; prov_web01;;
            admin) repoint admin; prov_admin;;
            *) die "unknown node '$1' (one of: $NODES)";;
        esac
        return
    fi
    # Full order matters:
    #  1. Stand up DNS + mirror using the stock (systemd-resolved) resolver,
    #     since tiny.lab / mirror.tiny.lab don't resolve yet.
    prov_dns01
    prov_dns02
    prov_mirror
    #  2. Now that DNS + cache exist, repoint EVERY node at them.
    local svc; for svc in $NODES; do repoint "$svc"; done
    #  3. Install the service nodes through the cache, over lab DNS.
    prov_mail
    prov_web01
    prov_admin
    log "provision complete — run: ./tiny-internet.sh verify"
}

# ─── verify: probe the whole tiny internet from the admin node ───────────────
cmd_verify() {
    local fail=0
    _ok()   { printf '\033[1;32m  PASS\033[0m %s\n' "$*"; }
    _bad()  { printf '\033[1;31m  FAIL\033[0m %s\n' "$*"; fail=1; }

    log "── DNS: authoritative + AXFR secondary ──"
    [[ "$(ex admin dig +short web01.$DOMAIN @$DNS1 2>/dev/null)" == "10.128.1.7" ]] \
        && _ok "dig web01.$DOMAIN @dns01 → 10.128.1.7" || _bad "forward lookup @dns01"
    [[ "$(ex admin dig +short web01.$DOMAIN @$DNS2 2>/dev/null)" == "10.128.1.7" ]] \
        && _ok "dig web01.$DOMAIN @dns02 → 10.128.1.7 (AXFR secondary answers)" || _bad "forward lookup @dns02 (AXFR?)"
    [[ "$(ex admin dig +short -x 10.128.1.5 @$DNS1 2>/dev/null)" == "mail.$DOMAIN." ]] \
        && _ok "reverse 10.128.1.5 → mail.$DOMAIN" || _bad "reverse PTR"

    log "── mirror: apt through the cache ──"
    if ex admin sh -c "apt-get update 2>&1 | grep -q 'deb.debian.org'"; then
        _ok "apt-get update flows via mirror.$DOMAIN:3142"
    else _bad "apt through proxy"; fi

    log "── mail: SMTP send + IMAP fetch round-trip ──"
    ex admin sh -c 'id >/dev/null; printf "From: postmaster@'"$DOMAIN"'\r\nTo: alice@'"$DOMAIN"'\r\nSubject: verify\r\n\r\nround-trip ok\r\n" > /tmp/v.txt
        curl -s --url smtp://mail.'"$DOMAIN"':25 --mail-from postmaster@'"$DOMAIN"' --mail-rcpt alice@'"$DOMAIN"' --upload-file /tmp/v.txt' \
        && _ok "SMTP: admin → mail accepted" || _bad "SMTP send"
    sleep 2
    if ex admin sh -c "curl -s --url imap://mail.$DOMAIN/INBOX --user alice:tinylab -X 'STATUS INBOX (MESSAGES)' | grep -q MESSAGES"; then
        _ok "IMAP: alice's INBOX reachable (Dovecot)"
    else _bad "IMAP fetch"; fi

    log "── web01: LAMP + phpMyAdmin ──"
    ex admin sh -c "curl -s http://web01.$DOMAIN/phpinfo.php | grep -qi 'PHP Version'" \
        && _ok "PHP live at web01.$DOMAIN/phpinfo.php" || _bad "phpinfo"
    [[ "$(ex admin sh -c "curl -s -o /dev/null -w '%{http_code}' http://web01.$DOMAIN/phpmyadmin/")" == "200" ]] \
        && _ok "phpMyAdmin at web01.$DOMAIN/phpmyadmin/ → 200" || _bad "phpMyAdmin"

    echo
    (( fail )) && die "one or more probes FAILED (see above)" || log "ALL PROBES PASSED — the tiny internet is live 🎉"
}

# ─── status: node / IP / reachability ────────────────────────────────────────
cmd_status() {
    require incus
    printf '%-8s %-14s %-9s %s\n' NODE IP STATE PING
    local svc iname state ping
    for svc in $NODES; do
        iname="lab-${LAB}-${svc}"
        state="$(incus list "$iname" -c s --format csv 2>/dev/null || echo -)"
        [[ -z "$state" ]] && state="absent"
        if [[ "$state" == RUNNING ]] && incus exec "$iname" -- true 2>/dev/null; then ping=up; else ping=-; fi
        printf '%-8s %-14s %-9s %s\n' "$svc" "$(ip_of "$svc")" "$state" "$ping"
    done
}

# ─── down / clean ────────────────────────────────────────────────────────────
cmd_down()  { [[ -x "$LABLXD" ]] || die "no lab-lxd.sh"; "$LABLXD" down --lab "$LAB"; }
cmd_clean() {
    cmd_down
    if [[ "${1:-}" == "--net" ]]; then
        require incus
        log "deleting bridge '$BRIDGE'"
        incus network delete "$BRIDGE" >/dev/null 2>&1 \
            && log "bridge deleted" || warn "bridge '$BRIDGE' not deleted (still in use?)"
    else
        log "bridge '$BRIDGE' left in place (pass --net to delete it)"
    fi
}

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d;s/^# \{0,1\}//'; }

case "${1:-help}" in
    net)       cmd_net;;
    up)        cmd_up;;
    provision) shift; cmd_provision "$@";;
    verify)    cmd_verify;;
    status)    cmd_status;;
    down)      cmd_down;;
    clean)     shift; cmd_clean "$@";;
    help|-h|--help) usage;;
    *) die "unknown command '${1}' (try: help)";;
esac
