# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the write-up that this lab
operationalizes, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Oops! Debugging Kernel Panics* |
| **Author** | Petros Koutoupis |
| **Publication** | Linux Journal |
| **Canonical URL** | <https://www.linuxjournal.com/content/oops-debugging-kernel-panics-0> |
| **Published** | 2019-08-07 |
| **Retrieved** | 2026-06-09 |

## Files

| File | sha256 |
|---|---|
| [`oops-debugging-kernel-panics.html`](oops-debugging-kernel-panics.html) | `075023a83ba27c1759240c3342e4fc6b8093fbb232ea15d38791410b2be64915` |

## What is and isn't vendored

The HTML is saved **exactly as served** — the full article text and **every code
block** (the `test-module.c` source, the Makefile, the `crash`/`bt`/`sym`/`mod -s`
transcripts, and every shell command) are present and readable offline with no
network.

Unlike this repo's single-stylesheet archives, linuxjournal.com is a **Drupal**
site that pulls in ~20 small CMS/theme stylesheets plus remote assets (fonts, a
SourceForge-media theme CSS on `a.fsdn.com`, a Cloudflare email-decode script),
each by an **absolute** URL with cache-busting query strings. Those are
**not vendored** — mirroring a CMS's whole asset pipeline byte-exact is neither
practical nor the point; they're cosmetic and resolve against the live site. Per
the repo's provenance convention this is the "many assets → cite, don't mirror"
case for the *chrome*, while the one **article page itself is fully mirrored**
(the content that matters). Open the `.html` in a browser and it renders
unstyled-but-complete.

## Copyright & attribution

This tutorial is the work of **Petros Koutoupis** and **Linux Journal**, and
**all rights and copyright remain with them.** It is archived here solely as an
offline, fixed-point reference for the [`../`](../) lab, which reproduces the
kdump/kexec crash-debugging workflow on Debian 12 (bookworm). The lab's
[`../test-module.c`](../test-module.c) is the author's crashing module
(the deliberate null-deref bug is verbatim on line 8; a `MODULE_LICENSE` line is
appended for modern `modpost` — see the lab README). For the authoritative
version — and to support the author — always go to the [canonical
page](https://www.linuxjournal.com/content/oops-debugging-kernel-panics-0). If
you are the author and would prefer this copy not be redistributed, removing it
is a one-line `git rm`.
