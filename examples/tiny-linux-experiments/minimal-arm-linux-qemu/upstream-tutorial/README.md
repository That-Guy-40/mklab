# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the blog post this lab operationalizes,
vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Build and boot a minimal Linux system with qemu* |
| **Author** | David Corvoysier |
| **Canonical URL** | <https://www.kaizou.org/2016/09/boot-minimal-linux-qemu.html> |
| **Published** | 23 Sep 2016 |
| **Retrieved** | 2026-07-02 |
| **License** | [Creative Commons **BY-NC-SA 3.0**](https://creativecommons.org/licenses/by-nc-sa/3.0/) (stated in the page footer) |

## Files

| File | sha256 |
|---|---|
| [`boot-minimal-linux-qemu.html`](boot-minimal-linux-qemu.html) | `13f25e7ae1fb60eb3ef2f2152320938319d63a2f8f0901c4097a8fe1906fe083` |
| [`css/style.css`](css/style.css) | `8532ab7b64b544cb9cf40bb9e78728a74ef24f8ffadcd275e3c3d69e040c2045` |

The HTML is saved exactly as served. The page links its stylesheet with the
**absolute** site path `/css/style.css`, so the CSS is vendored at
[`css/style.css`](css/style.css) — that layout resolves when the archive is
served from its own root (`cd upstream-tutorial && python3 -m http.server`);
opened as a bare `file://`, the page still reads fine, just unstyled.

**Left un-vendored** (absolute links to the live site, per the "cite the rest"
rule): MathJax / jQuery / markdeep / prefixfree JS (CDN + `/js/`), the site
chrome images (`/images/Octocat.png`, `/images/rss.svg`, `/images/linkedin.jpg`),
and the Creative-Commons badge (`i.creativecommons.org`). None are needed to read
the recipe.

## Copyright & attribution

This tutorial is the work of **David Corvoysier** and is licensed
**[CC BY-NC-SA 3.0](https://creativecommons.org/licenses/by-nc-sa/3.0/)** — that
license is what *permits* this archived, attributed, non-commercial copy (with
share-alike). It is kept here solely as an offline, fixed-point reference for the
[`../`](../README.md) lab, which reimplements the recipe on a modern Debian host.
For the authoritative, maintained version — and to support the author — always go
to the [canonical page](https://www.kaizou.org/2016/09/boot-minimal-linux-qemu.html).
If you are the author and would prefer this copy not be redistributed, removing it
is a one-line `git rm`.
