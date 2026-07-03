# PLAN — Tiny Internet Project lab (DELIVERED)

Design record for `examples/tiny-internet-project/`, which operationalizes John
S. Tonello's three-part *Tiny Internet Project* (Linux Journal, 2016). Status:
**built and verified end-to-end 2026-07-03** (see
[MANUAL_TESTING.md](MANUAL_TESTING.md)). This document captures the decisions and
their rationale; [README.md](README.md) is the user-facing entry point.

## 1. Context

The series teaches Linux by building a whole self-contained internet in
miniature: the private domain `tiny.lab` (`10.128.1.0/24`) with your own
authoritative DNS, a local package source, mail that delivers, and LAMP web
hosting — air-gappable on one host. The original runs on **Proxmox VMs + Ubuntu
14.04**; this repo has no Proxmox and 14.04 is EOL, so the lab rebuilds the same
architecture on the repo's **phase5-lxd** substrate (rootless Incus system
containers) on **Debian 13**.

**Decisions (locked in with the user):** substrate = LXD/Incus containers; scope
= the full faithful service set; local repo = apt-cacher-ng caching proxy (not a
100 GB mirror); distro = Debian 13.

## 2. Architecture

Six Debian 13 containers on one Incus **managed bridge** `labbr0`
(`10.128.1.1/24`, NAT, `dns.mode=none`), static IPs pinned via each instance's
`eth0` nic override in the TOML:

| Node | IP | Role |
|---|---|---|
| dns01 | .3 | BIND9 primary, authoritative `tiny.lab` (fwd + reverse) |
| dns02 | .4 | BIND9 secondary — AXFR slave of dns01 |
| mail | .5 | Postfix (Internet Site) + Dovecot IMAP/POP3 |
| mirror | .6 | apt-cacher-ng caching proxy (:3142) |
| web01 | .7 | Apache + MariaDB + PHP + phpMyAdmin |
| admin | .25 | client that runs the verify probes |

## 3. Substrate mechanics (what made this work)

- **Bridge** is created by the driver (`incus network create`), **not** the TOML
  — `lab-lxd.sh` never creates networks. `dns.mode=none` stops the bridge
  dnsmasq from shadowing BIND.
- **Static IPs** ride on the nic device `"ipv4.address"` key, which `lab-lxd.sh`
  passes through verbatim; the device is named `eth0` to override the default
  profile's incusbr0 nic. Nodes are **restarted** after `up` so eth0 comes up on
  labbr0.
- **Provisioning** = `lab-lxd.sh exec <lab>/<svc> -- tee <path>` with the config
  file on stdin, plus `exec … -- sh -c` for commands. No TOML provisioning hook
  exists; this is the established pattern.
- **Order** in `provision`: DNS + mirror first (using the stock resolver, since
  `tiny.lab` doesn't resolve yet) → repoint every node at dns01/dns02 + the apt
  cache → install mail + web through the cache over lab DNS.

## 4. Debian-13 divergences (documented as first-class gotchas)

Ten concrete breakages vs. the 2016 Ubuntu recipe — full table in
[README.md](README.md#debian-13-divergences-from-the-2016-tutorial). The two
sharpest were **Dovecot 2.4** (removed `mail_location`; Debian's
`mail_inbox_path=/var/mail/%u` sends INBOX to an unwritable mbox spool), found
and fixed by watching real `doveadm`/strace output during the build.

## 5. Deliverables (all present)

Driver (`tiny-internet.sh`), TOML (`tiny-internet.toml`), the `config/` tree
(dns/mail/web/mirror/common), README / RUNBOOK / MANUAL_TESTING / this plan, and
`upstream-tutorial/` (3 byte-exact HTML archives + provenance + sha256 +
all-rights-reserved attribution, matching the sibling
[kdump-kexec-lab](../kdump-kexec-lab/) Linux Journal archive).

## 6. Verification (done)

`./tiny-internet.sh up && ./tiny-internet.sh provision && ./tiny-internet.sh
verify` → **ALL PROBES PASSED**: authoritative DNS on dns01, AXFR secondary on
dns02, apt through the cache, a full SMTP→IMAP mail round-trip, and LAMP +
phpMyAdmin over lab DNS. Only external dependency: the host uplink to warm the
apt cache on first run.

## 7. Deliberate scope calls

- **Webmin dropped** — not in the Debian archive, and only a GUI over configs we
  author directly (noted as optional "going further").
- **apt-cacher-ng, not apt-mirror** — a cache, not a 100 GB full mirror; the
  air-gap holds after warm-up.
- **No TLS, throwaway creds** — plaintext IMAP/POP3/HTTP and lab-only passwords;
  fine on an isolated NAT bridge, nowhere else.
