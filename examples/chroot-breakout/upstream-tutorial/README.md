# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the write-up that this lab
operationalizes, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Exploring Containers - Part 1* |
| **Author** | Thomas Van Laere |
| **Canonical URL** | <https://thomasvanlaere.com/posts/2020/04/exploring-containers-part-1/> |
| **Blog home** | <https://thomasvanlaere.com/> |
| **Published** | 2020-04 |
| **Retrieved** | 2026-06-09 |

## Files

| File | sha256 |
|---|---|
| [`exploring-containers-part-1.html`](exploring-containers-part-1.html) | `f41a8c711d50ea05f78d10cc3f64781ac35da147da14d7f0a32b225e3cf41e43` |
| [`bundle.min.css`](bundle.min.css) | `7b2e3b8768cc31c167f210b75247e2d52c4b70c973376984d10d98b937016753` |

The HTML is saved exactly as served. The site's single minified stylesheet is
vendored alongside as `bundle.min.css` (the page's `<link>` references it by an
**absolute** `https://thomasvanlaere.com/css/bundle.min.<hash>.css` URL, so a
browser fetches it live — repoint that `<link>` at the local copy to render the
page fully offline). The page's favicons, the `hreflang` alternate, and a
Cloudflare email-obfuscation script (`/cdn-cgi/.../email-decode.min.js`) are
**left as-is** — their absolute links resolve against the live site and none are
needed to read the tutorial offline. The post embeds no content images.

## Copyright & attribution

This tutorial is the work of **Thomas Van Laere**, and **all rights and
copyright remain with the author.** It is archived here solely as an offline,
fixed-point reference for the [`../`](../) lab, which reproduces his chroot-escape
demonstration on Alpine 3.11. The lab's [`../breakout.c`](../breakout.c) is the
author's escape program **verbatim**. For the authoritative, maintained version
— and to support the author — always go to the [canonical
page](https://thomasvanlaere.com/posts/2020/04/exploring-containers-part-1/). If
you are the author and would prefer this copy not be redistributed, removing it
is a one-line `git rm`.
