# Tiny Internet Project — a self-contained internet on one host

Operationalizes John S. Tonello's three-part **[Tiny Internet
Project](upstream-tutorial/)** (Linux Journal, 2016) on this repo's
**phase5-lxd** substrate: six Debian 13 Incus containers on a private bridge
that, between them, are a whole **internet in miniature** — the `tiny.lab`
domain on `10.128.1.0/24` with your *own* authoritative DNS, package source,
mail, and web hosting. Everything air-gappable on one machine.

Tonello built it on **Proxmox VMs + Ubuntu 14.04**; this repo has no Proxmox and
14.04 is long EOL, so the lab rebuilds the same architecture as **rootless Incus
system containers on Debian 13** — and documents every place the modern distro
diverges from the 2016 recipe (there are several sharp ones — see
[Debian-13 divergences](#debian-13-divergences-from-the-2016-tutorial)).

## The topology

```
                         labbr0  (Incus managed bridge, 10.128.1.1/24, NAT, dns.mode=none)
   ┌───────────┬───────────┬───────────┬───────────┬───────────┬──────────────┐
 dns01 .3    dns02 .4    mail .5     mirror .6   web01 .7     admin .25
 BIND9       BIND9       Postfix +   apt-cacher- Apache +     the "admin PC":
 PRIMARY  ──AXFR──▶ SECONDARY  Dovecot     ng cache    MariaDB+PHP  runs the probes
 (tiny.lab           (slave       (IMAP/POP3) :3142       + phpMyAdmin
  authoritative)      via AXFR)
```

| Node | IP | Role |
|---|---|---|
| `dns01`  | 10.128.1.3  | BIND9 **primary**, authoritative for `tiny.lab` (forward + reverse) |
| `dns02`  | 10.128.1.4  | BIND9 **secondary** — pulls both zones from dns01 by **AXFR** |
| `mail`   | 10.128.1.5  | Postfix (Internet Site) + Dovecot IMAP/POP3, PAM mailboxes |
| `mirror` | 10.128.1.6  | apt-cacher-ng caching proxy (`http://mirror.tiny.lab:3142`) |
| `web01`  | 10.128.1.7  | Apache + MariaDB + PHP + phpMyAdmin (`www`/`tiny.lab` → here) |
| `admin`  | 10.128.1.25 | client that runs `dig`/`curl`/IMAP probes against the rest |

## The gems

1. **Your own authoritative DNS for a private TLD.** dns01 is master for
   `tiny.lab`; dns02 is a real secondary that learns the zone **over the wire**
   by AXFR (not a copied file), and dns01 `also-notify`s it on every change.
   Every other node uses these two as its *only* resolver — they're also
   recursive (forwarders), so they answer for the outside world too.
2. **Air-gappable installs.** Every node's `apt` flows through
   `mirror.tiny.lab:3142`; warm the cache once and the rest of the lab installs
   with no public internet.
3. **Local mail that delivers.** Send from `admin` to `alice@tiny.lab` over SMTP
   and fetch it back over IMAP — a real cross-host round-trip.
4. **LAMP + phpMyAdmin** at `web01.tiny.lab`.
5. The sum: **a self-contained internet** — the reason the series exists.

## Quickstart

```bash
cd examples/tiny-internet-project

./tiny-internet.sh up          # create labbr0 + launch the 6 nodes (via lab-lxd.sh)
./tiny-internet.sh provision   # install + configure every daemon (a few minutes)
./tiny-internet.sh verify      # dig / apt / SMTP+IMAP / curl probes from admin
./tiny-internet.sh status      # node / IP / reachability table

# poke around by hand:
../../phase5-lxd/lab-lxd.sh exec tiny-internet/admin -- dig tiny.lab @10.128.1.4
../../phase5-lxd/lab-lxd.sh exec tiny-internet/dns01 -- rndc status

./tiny-internet.sh down         # stop + delete the containers
./tiny-internet.sh clean --net  # …and delete the labbr0 bridge
```

`verify` prints a green **ALL PROBES PASSED** when the whole tiny internet is
live. See [MANUAL_TESTING.md](MANUAL_TESTING.md) for the captured transcript.

## What's in this directory

| File | What it is |
|---|---|
| [`tiny-internet.sh`](tiny-internet.sh)     | the driver: `net`/`up`/`provision`/`verify`/`status`/`down`/`clean` |
| [`tiny-internet.toml`](tiny-internet.toml) | phase5-lxd spec: 6 nodes, static-IP nics on `labbr0` |
| [`config/dns/`](config/dns/)     | BIND9 zones + `named.conf.*` (primary and secondary) |
| [`config/mail/`](config/mail/)   | Postfix `postconf` + debconf preseed, Dovecot 2.4 drop-in |
| [`config/web/`](config/web/)     | Apache vhost, `phpinfo.php`, phpMyAdmin preseed, landing page |
| [`config/mirror/`](config/mirror/) | apt proxy client drop-in |
| [`config/common/`](config/common/) | the static `resolv.conf` pointing at dns01/dns02 |
| [`RUNBOOK.md`](RUNBOOK.md)                 | by-hand walk, mapped to the tutorial's Parts I/II/III |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md)   | verified pass/fail transcript |
| [`TINY_INTERNET_PROJECT_PLAN.md`](TINY_INTERNET_PROJECT_PLAN.md) | the design plan |
| [`upstream-tutorial/`](upstream-tutorial/) | byte-exact archive of the 3 articles + provenance |

## How provisioning works

The driver never talks to `incus` for lifecycle — it drives
[`phase5-lxd/lab-lxd.sh`](../../phase5-lxd/lab-lxd.sh) (`up`/`exec`/`down`) and
pushes each config file into a container over `exec … -- tee <path>` stdin. The
one thing lab-lxd.sh can't do is **create the bridge** (it never creates
networks), so `up` runs `incus network create labbr0 …` first. Order in
`provision` matters: DNS + mirror come up first (using the stock resolver, since
`tiny.lab` doesn't resolve yet), then every node is **repointed** at dns01/dns02
+ the apt cache, then mail and web install *through* the cache over lab DNS.

## Debian-13 divergences from the 2016 tutorial

Rebuilding a 2016 Ubuntu-14.04 recipe on Debian 13 surfaced a pile of real
breakages — each is handled in the configs/driver and called out where it lives:

| # | 2016 tutorial | Debian 13 reality | Handled by |
|---|---|---|---|
| 1 | `apt-mirror` (~100 GB full mirror) | **apt-cacher-ng** caching proxy (cache-on-demand) | `config/mirror/` |
| 2 | `/etc/default/bind9`, `service bind9` | **`/etc/default/named`**, `named.service` | driver uses `named` |
| 3 | Postfix dialog clicked by hand | **debconf preseed** (no TTY in a container) | `config/mail/debconf-postfix.preseed` |
| 4 | Dovecot `mail_location = maildir:~/Maildir` | Dovecot **2.4 renamed it** → `mail_driver` + `mail_path` (old name is a hard error) | `config/mail/99-tiny.conf` |
| 5 | INBOX = the Maildir | Debian 2.4 ships `mail_inbox_path=/var/mail/%u` → INBOX wrongly points at the mbox spool (unwritable) → *"Failed to autocreate mailbox: Permission denied"* | `config/mail/99-tiny.conf` blanks/points it at the Maildir root |
| 6 | `lamp-server^` tasksel meta | **doesn't exist on Debian** → install the packages explicitly | driver `prov_web01` |
| 7 | MySQL | **MariaDB** (root via `unix_socket`) | phpMyAdmin preseed lets dbconfig use socket-root |
| 8 | **Webmin** GUI admin | not in the Debian archive → **dropped**; we author the configs directly (the actual lesson) | — (optional "going further") |
| 9 | bridge DNS = whatever | Incus bridge dnsmasq would shadow BIND → set **`dns.mode=none`**; disable **systemd-resolved** in each node and pin a static `resolv.conf` | `cmd_net` + `repoint` |
| 10 | static IPs on a plain LAN | need a **managed** bridge (`ipv4.address` on the nic device) | `tiny-internet.toml` |

## What's verified vs. yours to run

**Verified end-to-end here (rootless Incus, no sudo), 2026-07-03** — `up` +
`provision` + `verify` all green: authoritative DNS on dns01 **and** the AXFR
secondary on dns02, `apt` through the cache, a full SMTP→IMAP mail round-trip,
and LAMP + phpMyAdmin over lab DNS. Transcript in
[MANUAL_TESTING.md](MANUAL_TESTING.md).

**Caveats / yours to run:** the first `provision` needs the host's uplink to warm
the apt cache and pull packages — the air-gap is *after* warm-up, not during. An
Incus `launch` very occasionally wedges client-side (a known local flake); if
`up` hangs, `down` and re-run.

## ⚠️ Security

Everything here uses **throwaway lab credentials** (mailbox users `alice`/`bob`
with password `tinylab`, a phpMyAdmin app password `tinylab`) and **no TLS**
(plaintext IMAP/POP3, HTTP). That is fine on an isolated NAT bridge and nowhere
else — never expose these nodes to a real network or reuse the passwords.

---

Built from John S. Tonello's *Tiny Internet Project* (Linux Journal). The
articles are archived byte-exact under [`upstream-tutorial/`](upstream-tutorial/)
with full provenance and attribution; all rights remain with the author.
