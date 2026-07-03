# Manual testing — Tiny Internet Project

Verified **end-to-end, rootless Incus, no sudo**, on Debian 13 (trixie) guests,
2026-07-03. The whole lab was built by the driver (`up` → `provision`) and
checked by the driver's own probe suite (`verify`), which exits non-zero if any
probe fails.

## Full run

```bash
cd examples/tiny-internet-project
./tiny-internet.sh up          # labbr0 + 6 nodes on their static IPs
./tiny-internet.sh provision   # install + configure every daemon
./tiny-internet.sh verify
```

### `up` — all six nodes land on their reserved addresses

```text
[tiny] bridge 'labbr0' already exists
[tiny] launching the six nodes via lab-lxd.sh up …
[info] launching container 'dns01' as lab-tiny-internet-dns01 (image=images:debian/13)
…
[info] ── lab 'tiny-internet' up (6 incus instance(s), 0 skipped) ──
[tiny] restarting nodes so eth0 comes up on labbr0 …
[tiny] waiting for static addresses …
[tiny]   dns01 = 10.128.1.3
[tiny]   dns02 = 10.128.1.4
[tiny]   mail = 10.128.1.5
[tiny]   mirror = 10.128.1.6
[tiny]   web01 = 10.128.1.7
[tiny]   admin = 10.128.1.25
[tiny] up complete — next: ./tiny-internet.sh provision
```

### `verify` — every probe green

```text
[tiny] ── DNS: authoritative + AXFR secondary ──
  PASS dig web01.tiny.lab @dns01 → 10.128.1.7
  PASS dig web01.tiny.lab @dns02 → 10.128.1.7 (AXFR secondary answers)
  PASS reverse 10.128.1.5 → mail.tiny.lab
[tiny] ── mirror: apt through the cache ──
  PASS apt-get update flows via mirror.tiny.lab:3142
[tiny] ── mail: SMTP send + IMAP fetch round-trip ──
  PASS SMTP: admin → mail accepted
  PASS IMAP: alice's INBOX reachable (Dovecot)
[tiny] ── web01: LAMP + phpMyAdmin ──
  PASS PHP live at web01.tiny.lab/phpinfo.php
  PASS phpMyAdmin at web01.tiny.lab/phpmyadmin/ → 200

[tiny] ALL PROBES PASSED — the tiny internet is live 🎉
```

```text
$ ./tiny-internet.sh status
NODE     IP             STATE     PING
dns01    10.128.1.3     RUNNING   up
dns02    10.128.1.4     RUNNING   up
mail     10.128.1.5     RUNNING   up
mirror   10.128.1.6     RUNNING   up
web01    10.128.1.7     RUNNING   up
admin    10.128.1.25    RUNNING   up
```

## The DNS gem, close up — AXFR really happened

The secondary didn't get a copied file; it pulled the zones over the wire. From
dns02's own log:

```text
$ lab-lxd.sh exec tiny-internet/dns02 -- journalctl -u named | grep 'transfer.*completed'
named[934]: transfer of '1.128.10.in-addr.arpa/IN' from 10.128.1.3#53: Transfer completed: 1 messages, 10 records, 291 bytes (serial 2026070301)
named[934]: transfer of 'tiny.lab/IN' from 10.128.1.3#53: Transfer completed: 1 messages, 13 records, 319 bytes (serial 2026070301)
```

Both nameservers answer identically:

```text
$ lab-lxd.sh exec tiny-internet/admin -- dig +short NS tiny.lab @10.128.1.3
dns01.tiny.lab.
dns02.tiny.lab.
$ lab-lxd.sh exec tiny-internet/admin -- dig +short mail.tiny.lab @10.128.1.4   # the SECONDARY
10.128.1.5
```

## The mail gem, close up — a real cross-host round-trip

```bash
# send from admin → mail over SMTP (curl as the SMTP client)
lab-lxd.sh exec tiny-internet/admin -- sh -c '
  printf "From: postmaster@tiny.lab\r\nTo: alice@tiny.lab\r\nSubject: hi\r\n\r\nit works\r\n" > /tmp/m.txt
  curl -s --url smtp://mail.tiny.lab:25 --mail-from postmaster@tiny.lab \
       --mail-rcpt alice@tiny.lab --upload-file /tmp/m.txt'

# fetch it back over IMAP (Dovecot), as alice
lab-lxd.sh exec tiny-internet/admin -- \
  curl -s --url 'imap://mail.tiny.lab/INBOX;MAILINDEX=1' --user alice:tinylab
```

```text
Subject: hi

it works
```

Mailbox users (⚠️ **throwaway lab creds**): `alice` / `bob`, password `tinylab`.

## The mirror gem, close up — apt served from the cache

`apt-get update` on any node fetches through `mirror.tiny.lab:3142`; the acng
access log on `mirror` shows the client pulling (`|I|` = fetched upstream, `|O|`
= served to client):

```text
…|O|223200|10.128.1.25|secdeb/dists/trixie-security/main/binary-amd64/by-hash/SHA256/…
…|I|135526|10.128.1.25|secdeb/dists/trixie-security/main/i18n/by-hash/SHA256/…
```

## Notes / gotchas hit while building this

- **Dovecot 2.4 config renames** (Debian 13). `mail_location` is gone — you must
  write `mail_driver = maildir` + `mail_path`, and Debian's default
  `mail_inbox_path = /var/mail/%{user}` silently sends INBOX to the (unwritable)
  mbox spool → *"Failed to autocreate mailbox: Permission denied"*. Both are
  fixed in `config/mail/99-tiny.conf`; see the comments there.
- **Intermittent `incus launch` wedge.** Twice during development a launch hung
  client-side (empty `incus operation list`, instance never created). It's a
  local flake, not the lab: kill the stuck launch **by PID**, `down`, and re-run
  — a plain retry succeeded every time.
- **First provision needs the uplink.** apt-cacher-ng is a *cache*, not a static
  mirror; the first pull of each package goes upstream through it. Air-gap works
  only after the cache is warm.
