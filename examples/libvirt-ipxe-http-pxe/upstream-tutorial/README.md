# Upstream tutorials — archived copies

**Unmodified, byte-exact archives** of the two Dusty Mabe blog posts this lab
operationalizes, vendored for offline reference and provenance. The second post
is a direct follow-up to the first.

| | Post 1 | Post 2 |
|---|---|---|
| **Title** | *Easy PXE boot testing with only HTTP using iPXE and libvirt* | *Update on Easy PXE boot testing post: minus PXELINUX* |
| **Author** | Dusty Mabe (dustymabe) | Dusty Mabe (dustymabe) |
| **Published** | 2019-01-04 | 2019-09-13 |
| **Canonical URL** | <https://dustymabe.com/2019/01/04/easy-pxe-boot-testing-with-only-http-using-ipxe-and-libvirt/> | <https://dustymabe.com/2019/09/13/update-on-easy-pxe-boot-testing-post-minus-pxelinux/> |
| **Retrieved** | 2026-07-02 | 2026-07-02 |

## Files

| File | sha256 |
|---|---|
| [`2019-01-04-easy-pxe-boot-testing-http-ipxe-libvirt.html`](2019-01-04-easy-pxe-boot-testing-http-ipxe-libvirt.html) | `1ed1f6a142c5a23afb6e3038379088c12f4607f63b95de736f413060afcb7d8e` |
| [`2019-09-13-minus-pxelinux.html`](2019-09-13-minus-pxelinux.html) | `c06f0a88385cdd1b7084c9aeb49564336fb3b8cdaf91022be6dbff2428c16d19` |
| [`css/main-nodark.css`](css/main-nodark.css) | `87ea4e20b654cc99f9ba5d63a71f9c9736881aef0fe8b7fbf63dd065ba732b34` |
| [`css/syntax.css`](css/syntax.css) | `0bb9889d109239cc1637804498a7d278af2c65903df963773796928a6b36bee6` |
| [`css/codeblock.css`](css/codeblock.css) | `f7a34e8bf31acfdfceb7f9a892ee13a9556cef300932515a08a66bcae292d7c5` |

The HTML is saved exactly as served. Each page links its three theme
stylesheets with the **absolute** site path `/css/…`, so they're vendored under
[`css/`](css/) — that layout resolves when the archive is served from its own
root (`cd upstream-tutorial && python3 -m http.server`); opened as a bare
`file://`, the pages still read fine, just unstyled.

**Left un-vendored** (absolute links to the live web, per the "cite the rest"
rule): FontAwesome + KaTeX + PhotoSwipe CSS/JS (CDN), Google Fonts, and site
chrome images. None are needed to read the recipe.

## Copyright & attribution

These posts are the work of **Dusty Mabe**, and — no explicit open license being
stated on the pages — **all rights and copyright remain with the author.** They
are archived here solely as an offline, fixed-point reference for the
[`../`](../README.md) lab, which reimplements the recipe for a modern
Fedora + libvirt host. For the authoritative, maintained versions — and to
support the author — always go to the canonical pages linked above. If you are
the author and would prefer these copies not be redistributed, removing them is
a one-line `git rm`.
