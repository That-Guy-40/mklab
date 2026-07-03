# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the write-up that this lab
operationalizes, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Exploring Containers - Part 2* |
| **Author** | Thomas Van Laere |
| **Canonical URL** | <https://thomasvanlaere.com/posts/2020/08/exploring-containers-part-2/> |
| **Blog home** | <https://thomasvanlaere.com/> |
| **Published** | 2020-08 |
| **Retrieved** | 2026-07-03 |

## Files

| File | sha256 |
|---|---|
| [`exploring-containers-part-2.html`](exploring-containers-part-2.html) | `b64c6459f099948b731b8bbbcfe25c0cabd16b6d2cabe0b8f7281c0ec019add8` |
| [`bundle.min.css`](bundle.min.css) | `7b2e3b8768cc31c167f210b75247e2d52c4b70c973376984d10d98b937016753` |
| [`ec1.jpg`](ec1.jpg) | `bd1986557dbf0733c20dc6272c86c7a646adee5dea1afb3b3c298b93d70fdcb8` |
| [`ec2.jpg`](ec2.jpg) | `8aea28bd07772f69f5c991883391473475c402a9010f1f0e4763c3d7839dbf03` |
| [`ec3.jpg`](ec3.jpg) | `bac30619b34d1c13359067f882726275e5797774fa564b416ccca0bc63feb593` |
| [`ec4.jpg`](ec4.jpg) | `6d63061a2d7570b6e55d0604f645fee989c692534e15d421c3c55b357bafad17` |

The HTML is saved exactly as served. The site's single minified stylesheet is
vendored alongside as `bundle.min.css` (byte-identical to the copy under
[`../../part-1-chroot/upstream-tutorial/`](../../part-1-chroot/upstream-tutorial/) —
same site stylesheet). The page references it by an **absolute**
`https://thomasvanlaere.com/css/bundle.min.<hash>.css` URL, so a browser fetches
it live; repoint that `<link>` at this local copy to render offline. The four
content images (`ec1`–`ec4.jpg`, the network-topology diagrams) are the post's
own JPEGs, also referenced by **absolute** URL — vendored here so the diagrams
survive offline even though the byte-exact HTML still points at the live site.
The page's favicons, the `hreflang` alternate, and a Cloudflare email-obfuscation
script are **left as-is** — their absolute links resolve against the live site and
none are needed to read the tutorial offline.

## Copyright & attribution

This tutorial is the work of **Thomas Van Laere**, and **all rights and
copyright remain with the author.** It is archived here solely as an offline,
fixed-point reference for the [`../`](../) lab, which reproduces his IPC /
network / time namespace demonstrations. The lab's [`../processA.c`](../processA.c)
and [`../processB.c`](../processB.c) are the author's programs **verbatim**. For
the authoritative, maintained version — and to support the author — always go to
the [canonical page](https://thomasvanlaere.com/posts/2020/08/exploring-containers-part-2/).
If you are the author and would prefer this copy not be redistributed, removing
it is a one-line `git rm`.
