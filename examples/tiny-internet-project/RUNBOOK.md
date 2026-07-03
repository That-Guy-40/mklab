# RUNBOOK — building the Tiny Internet by hand

This walks the same build the [`tiny-internet.sh`](tiny-internet.sh) driver
automates, but step by step with the **why** at each stop, mapped to John
Tonello's three articles ([archived here](upstream-tutorial/)). The driver is
the source of truth for exact commands; this is for *understanding*, and for
when you want to poke a single node rather than run the whole pipeline.

Everything runs through `phase5-lxd/lab-lxd.sh`. Shorthand used below:

```bash
cd examples/tiny-internet-project
L() { ../../phase5-lxd/lab-lxd.sh "$@"; }        # L exec tiny-internet/dns01 -- …
```

The original series builds on **Proxmox VMs + Ubuntu 14.04**; we build the same
architecture as **Debian 13 Incus containers**. Where the distro forces a change,
it's flagged **⚠ DIVERGENCE**.

---

## Part I — the substrate and the first server

*Upstream: [Part I](upstream-tutorial/tiny-internet-project-part-i.html) — install
the hypervisor, carve out a private network, clone a template VM.*

Tonello installs Proxmox and defines a `10.128.1.0/24` lab network. Our
equivalent is one Incus **managed bridge**, and instead of cloning a template VM
we launch from the `images:debian/13` image.

```bash
# The bridge = the lab's private LAN. dns.mode=none is the crucial bit:
#   it tells the bridge's built-in dnsmasq to stop answering DNS, so OUR BIND
#   servers are the only authority for tiny.lab (⚠ DIVERGENCE 9 — Proxmox had no
#   such shadow resolver). DHCP still hands out the static reservations.
incus network create labbr0 ipv4.address=10.128.1.1/24 ipv4.nat=true \
    dns.domain=tiny.lab dns.mode=none

# Launch all six "machines" (the TOML pins each one's static IP by overriding
# the default profile's eth0 onto labbr0 — ⚠ DIVERGENCE 10: static IPs need a
# *managed* bridge):
L up --config tiny-internet.toml
# then restart each so eth0 comes up on labbr0, or just use: ./tiny-internet.sh up
```

Why containers and not VMs? They boot in a second, need no nested KVM, and run
rootless — the whole tiny internet fits in a few hundred MB. The trade-off: a
container shares the host kernel (fine for every service here).

---

## Part II — DNS, the local repo, and making the LAN resolve

*Upstream: [Part II](upstream-tutorial/tiny-internet-project-part-ii.html) —
BIND9 primary + secondary, and a local apt mirror.*

### dns01 — the authoritative primary

```bash
L exec tiny-internet/dns01 -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y bind9 bind9utils'
# push the zones + config (see config/dns/):
L exec tiny-internet/dns01 -- tee /etc/bind/named.conf.options < config/dns/named.conf.options
L exec tiny-internet/dns01 -- tee /etc/bind/named.conf.local   < config/dns/named.conf.local
L exec tiny-internet/dns01 -- tee /etc/bind/db.tiny.lab        < config/dns/db.tiny.lab
L exec tiny-internet/dns01 -- tee /etc/bind/db.10.128.1        < config/dns/db.10.128.1
L exec tiny-internet/dns01 -- named-checkzone tiny.lab /etc/bind/db.tiny.lab   # always check zones
L exec tiny-internet/dns01 -- systemctl restart named          # ⚠ DIVERGENCE 2: it's `named`, not `bind9`
```

`named.conf.options` makes dns01 **authoritative *and* recursive**: authoritative
for `tiny.lab`, and recursive (with `forwarders { 10.128.1.1; }`) for everything
else, so a node pointed only at dns01 still reaches the outside world. The forward
zone (`db.tiny.lab`) maps names→IPs; the reverse zone (`db.10.128.1`) maps
IPs→names for PTR lookups. **Bump the SOA serial on every edit** or the secondary
won't pull the change.

### dns02 — the secondary that learns by AXFR

```bash
L exec tiny-internet/dns02 -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y bind9 bind9utils'
L exec tiny-internet/dns02 -- tee /etc/bind/named.conf.options < config/dns/named.conf.options
L exec tiny-internet/dns02 -- tee /etc/bind/named.conf.local   < config/dns/dns02.named.conf.local
L exec tiny-internet/dns02 -- systemctl restart named
```

dns02 has **no zone files** — it declares the zones `type slave` with
`masters { 10.128.1.3; }` and pulls them over the wire (**AXFR**) into
`/var/cache/bind/`. dns01's `allow-transfer { 10.128.1.4; }` + `also-notify`
authorize and trigger it. Prove it happened:

```bash
L exec tiny-internet/dns02 -- journalctl -u named | grep 'transfer.*completed'
L exec tiny-internet/admin -- dig +short web01.tiny.lab @10.128.1.4   # the SLAVE answers
```

This primary/secondary pair is the heart of the project — real DNS redundancy you
built yourself.

### mirror — the local package source

⚠ **DIVERGENCE 1.** Tonello runs `apt-mirror`, which downloads a **full ~100 GB**
copy of the archive. That's absurd for a laptop lab, so we use **apt-cacher-ng**,
a caching proxy that fetches each package **once on demand** and serves it from
cache thereafter:

```bash
L exec tiny-internet/mirror -- sh -c 'echo "apt-cacher-ng apt-cacher-ng/tunnelenable boolean false" | debconf-set-selections'
L exec tiny-internet/mirror -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y apt-cacher-ng'
```

### make every node use OUR DNS + repo

⚠ **DIVERGENCE 9 (the container-specific trap).** The Debian image runs
**systemd-resolved**, which owns `/etc/resolv.conf` (a symlink to its
`127.0.0.53` stub). Until you dislodge it, BIND is *not* the resolver:

```bash
for n in dns01 dns02 mail mirror web01 admin; do
  L exec tiny-internet/$n -- sh -c 'systemctl disable --now systemd-resolved; rm -f /etc/resolv.conf'
  L exec tiny-internet/$n -- tee /etc/resolv.conf          < config/common/resolv.conf.tiny
  L exec tiny-internet/$n -- tee /etc/apt/apt.conf.d/01acng < config/mirror/01acng-client.conf
done
```

Now `getent hosts web01.tiny.lab` resolves via dns01/dns02, and `apt-get update`
flows through `mirror.tiny.lab:3142`. **Order matters:** DNS + mirror must exist
*before* this, or `mirror.tiny.lab` won't resolve — which is exactly the order
the driver's `provision` enforces.

---

## Part III — mail and web

*Upstream: [Part III](upstream-tutorial/tiny-internet-project-part-iii.html) —
Postfix + Dovecot, then LAMP + phpMyAdmin (+ Webmin).*

### mail — Postfix + Dovecot

⚠ **DIVERGENCE 3:** Postfix's setup is a pink `debconf` dialog; there's no TTY in
`exec`, so we preseed it. ⚠ **DIVERGENCE 4 & 5 (the sharp ones):** Dovecot **2.4**
on Debian 13 removed `mail_location` (now `mail_driver` + `mail_path`) *and* ships
`mail_inbox_path=/var/mail/%{user}`, which points INBOX at the root-owned mbox
spool and makes every fetch fail with *"Failed to autocreate mailbox: Permission
denied"*. [`config/mail/99-tiny.conf`](config/mail/99-tiny.conf) fixes both.

```bash
L exec tiny-internet/mail -- tee /tmp/p.preseed < config/mail/debconf-postfix.preseed
L exec tiny-internet/mail -- sh -c 'debconf-set-selections < /tmp/p.preseed'
L exec tiny-internet/mail -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y postfix dovecot-imapd dovecot-pop3d'
# mailboxes are system users:
L exec tiny-internet/mail -- sh -c 'useradd -m alice; echo alice:tinylab | chpasswd'
# apply Postfix keys + the Dovecot 2.4 drop-in:
L exec tiny-internet/mail -- tee /tmp/pc < config/mail/postfix.postconf
L exec tiny-internet/mail -- sh -c 'while IFS= read -r l; do case "$l" in ""|\#*) ;; *) postconf -e "$l";; esac; done < /tmp/pc'
L exec tiny-internet/mail -- tee /etc/dovecot/conf.d/99-tiny.conf < config/mail/99-tiny.conf
L exec tiny-internet/mail -- systemctl restart postfix dovecot
```

Test the round-trip (send SMTP from admin, fetch IMAP as alice) — see
[MANUAL_TESTING.md](MANUAL_TESTING.md).

### web01 — LAMP + phpMyAdmin

⚠ **DIVERGENCE 6/7:** there's no `lamp-server^` meta-package on Debian (install
the parts explicitly), and MySQL is **MariaDB** (root over `unix_socket`).
⚠ **DIVERGENCE 8:** Tonello adds **Webmin** as a GUI admin; it isn't in the Debian
archive and it's only a front-end over the same config files we're already
writing by hand — so it's **dropped** (that's the real lesson anyway).

```bash
L exec tiny-internet/web01 -- tee /tmp/pma < config/web/debconf-phpmyadmin.preseed
L exec tiny-internet/web01 -- sh -c 'debconf-set-selections < /tmp/pma'
L exec tiny-internet/web01 -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 mariadb-server php libapache2-mod-php php-mysql phpmyadmin'
L exec tiny-internet/web01 -- mkdir -p /var/www/tiny
L exec tiny-internet/web01 -- tee /var/www/tiny/index.html   < config/web/index.html
L exec tiny-internet/web01 -- tee /var/www/tiny/phpinfo.php  < config/web/phpinfo.php
L exec tiny-internet/web01 -- tee /etc/apache2/sites-available/000-tiny.conf < config/web/000-tiny.conf
L exec tiny-internet/web01 -- sh -c 'a2dissite 000-default; a2ensite 000-tiny; systemctl reload apache2'
```

Then from `admin`: `curl http://web01.tiny.lab/phpinfo.php` (PHP is live) and
`curl http://web01.tiny.lab/phpmyadmin/` (→ 200).

---

## Tear down

```bash
./tiny-internet.sh down          # stop + delete the 6 containers
./tiny-internet.sh clean --net   # …and delete labbr0
```

## Going further (author's extras we left as options)

- **Webmin** — if you want Tonello's GUI, add the upstream Webmin apt repo by
  hand; nothing else in the lab depends on it.
- **A second web host / load balancing**, **TLS everywhere** (the lab is
  deliberately plaintext), or **more mailbox users** — all straightforward
  extensions of the configs in `config/`.
