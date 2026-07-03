# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the three-part write-up that this lab
operationalizes, vendored here for offline reference and provenance (sources
move, rot, or get paywalled).

| | |
|---|---|
| **Title** | *The Tiny Internet Project* — Parts I, II & III |
| **Author** | John S. Tonello |
| **Publication** | Linux Journal |
| **Canonical URLs** | Part I — <https://www.linuxjournal.com/content/tiny-internet-project-part-i> <br> Part II — <https://www.linuxjournal.com/content/tiny-internet-project-part-ii> <br> Part III — <https://www.linuxjournal.com/content/tiny-internet-project-part-iii> |
| **Published** | Part I: 2016-09-29 · Part II: 2016-11-17 · Part III: 2016-12-22 |
| **Retrieved** | 2026-07-03 |

## Files

| File | sha256 |
|---|---|
| [`tiny-internet-project-part-i.html`](tiny-internet-project-part-i.html)     | `e4c9ae9f3146188349591165055398bd185b9c772bf0c21da8fddb14821d6c35` |
| [`tiny-internet-project-part-ii.html`](tiny-internet-project-part-ii.html)   | `7a85637d7e226026542b613e26b87c7f9f5b9b16835ea5cd48e5eb1b1ca3cccb` |
| [`tiny-internet-project-part-iii.html`](tiny-internet-project-part-iii.html) | `7f58e10ede80bc0e8333731664da22a1d93843620b0d7395a92d8836f082b466` |

## What is and isn't vendored

The three HTML pages are saved **exactly as served** — the full article text and
**every command** (the Proxmox setup, the `apt-mirror` config, the BIND9 zone
files, the Postfix/Dovecot steps, the LAMP install) are present and readable
offline with no network.

As with this repo's other Linux Journal archive
([`../../kdump-kexec-lab/upstream-tutorial/`](../../kdump-kexec-lab/upstream-tutorial/)),
linuxjournal.com is a **Drupal** site that pulls in ~20 small CMS/theme
stylesheets plus remote assets (fonts, third-party theme CSS, a Cloudflare
email-decode script), each by an **absolute** URL with cache-busting query
strings. Those are **not vendored** — mirroring a CMS's whole asset pipeline
byte-exact is neither practical nor the point; they're cosmetic and resolve
against the live site. Per the repo's provenance convention this is the "many
assets → cite, don't mirror" case for the *chrome*, while the **article pages
themselves are fully mirrored** (the content that matters). Open a `.html` in a
browser and it renders unstyled-but-complete.

## Copyright & attribution

This series is the work of **John S. Tonello** and **Linux Journal**, and **all
rights and copyright remain with them.** It is archived here solely as an
offline, fixed-point reference for the [`../`](../) lab, which reproduces the
Tiny Internet on Debian 13 + Incus containers instead of the original's Proxmox
VMs + Ubuntu 14.04. For the authoritative version — and to support the author —
always go to the canonical pages linked above. If you are the author and would
prefer this copy not be redistributed, removing it is a one-line `git rm`.
