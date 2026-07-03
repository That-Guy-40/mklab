# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the write-up that this lab
operationalizes, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Exploring Containers - Part 3* |
| **Author** | Thomas Van Laere |
| **Canonical URL** | <https://thomasvanlaere.com/posts/2020/12/exploring-containers-part-3/> |
| **Blog home** | <https://thomasvanlaere.com/> |
| **Published** | 2020-12 |
| **Retrieved** | 2026-07-03 |

## Files

| File | sha256 |
|---|---|
| [`exploring-containers-part-3.html`](exploring-containers-part-3.html) | `dcc8392fc8b4baacde5d429450c36df5cdd31438c808dfbbe8d0bc735de0db38` |
| [`bundle.min.css`](bundle.min.css) | `7b2e3b8768cc31c167f210b75247e2d52c4b70c973376984d10d98b937016753` |
| [`ec1.jpg`](ec1.jpg) | `38c754f07845a863bc2f3081ba343d4904f07f3a3a3e06925533bc317b0d4b84` |

The HTML is saved exactly as served. The site's single minified stylesheet is
vendored alongside as `bundle.min.css` (byte-identical to the copies under the
sibling parts — same site stylesheet). The page references it by an **absolute**
`https://thomasvanlaere.com/css/bundle.min.<hash>.css` URL, so a browser fetches
it live; repoint that `<link>` at this local copy to render offline. The single
content image (`ec1.jpg`, the PID-namespace tree diagram) is the post's own JPEG,
also referenced by **absolute** URL — vendored here so it survives offline. The
page's favicons, the `hreflang` alternate, and a Cloudflare email-obfuscation
script are **left as-is** — their absolute links resolve against the live site and
none are needed to read the tutorial offline.

## Copyright & attribution

This tutorial is the work of **Thomas Van Laere**, and **all rights and
copyright remain with the author.** It is archived here solely as an offline,
fixed-point reference for the [`../`](../) lab, which reproduces his PID / cgroup
/ user namespace demonstrations. The lab's [`../alloc.c`](../alloc.c) is the
author's program **verbatim**. For the authoritative, maintained version — and to
support the author — always go to the [canonical
page](https://thomasvanlaere.com/posts/2020/12/exploring-containers-part-3/). If
you are the author and would prefer this copy not be redistributed, removing it
is a one-line `git rm`.
