# Vendored upstream — Matt Might, *"Hello, Perceptron: An introduction to artificial neural networks"*

Byte-exact archive of Matt Might's perceptron / neural-net introduction — the
tutorial this lab provides a Python sandbox for — plus its two inline diagrams and
the stylesheet it references, so the article renders and reads offline and its
provenance is explicit (web pages move, rot, or change).

## Provenance

| Field | Value |
|---|---|
| Title | Hello, Perceptron: An introduction to artificial neural networks |
| Author | Matt Might (professor; matt.might.net) |
| Canonical URL | <https://matt.might.net/articles/hello-perceptron/> |
| Published | Not dated on the page; written post-ChatGPT (it references ChatGPT and a Feb-2023 Wolfram essay), so **c. 2023** |
| **Retrieved** | **2026-06-28** |
| License | No explicit open license — standard copyright © Matt Might (see below) |

## Files & `sha256`

The page is kept **byte-exact**, so its `href="../../css/mm2.css"` link is
untouched. The archive **mirrors the site's path layout** so that relative link
resolves *within this directory* — the page sits at `articles/hello-perceptron/`
and the CSS at `css/`, exactly as on matt.might.net. Open
[`articles/hello-perceptron/index.html`](articles/hello-perceptron/index.html)
directly in a browser.

```
52fa9289632e0115031a3864590ab350f67f5165c572e183aa1c4ae341bdf833  articles/hello-perceptron/index.html
66ab68585c4a7eb15cb47469e81026e3fe4d0c4935e53d125ee6c2a968f9e177  css/mm2.css
b2485bb41b85452fc05025e8dfea8b5a1d6731d79038be04313e3e6c5e6be711  images/blog/linear-separability-AND.png
6550d2d9d6e7890d686e822bc8f94609a90da969f6715d8c2d048e65164eb91d  images/blog/midjourney-glowing-blue-neural-network-small.png
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
52fa9289632e0115031a3864590ab350f67f5165c572e183aa1c4ae341bdf833  articles/hello-perceptron/index.html
66ab68585c4a7eb15cb47469e81026e3fe4d0c4935e53d125ee6c2a968f9e177  css/mm2.css
b2485bb41b85452fc05025e8dfea8b5a1d6731d79038be04313e3e6c5e6be711  images/blog/linear-separability-AND.png
6550d2d9d6e7890d686e822bc8f94609a90da969f6715d8c2d048e65164eb91d  images/blog/midjourney-glowing-blue-neural-network-small.png
EOF
```

> **Note on the images.** Unlike Might's older articles (which link images with a
> relative `./images/…`), this newer page references its two content diagrams by
> **absolute** URL (`https://matt.might.net/images/blog/…`). The diagrams are
> vendored here at the matching site path (`images/blog/`) for archival
> completeness, but because the byte-exact HTML keeps the absolute links, the page
> pulls them from the live site when you have network and shows broken-image icons
> fully offline. The **text and layout** (the actual lesson) read fine offline via
> the vendored CSS.

## Not vendored (live links remain absolute to the original hosts)

- **JavaScript** — the site's `js/mm2.js` (header/nav rendering) and a Google Tag
  Manager beacon. The article is fully readable without them; only the site chrome
  and analytics need JS.
- **Amazon affiliate image** — a book-cover widget (`amazon-adsystem.com`). The
  two *content* diagrams (the Midjourney neural-net banner and the AND
  linear-separability plot) **are** vendored.
- **RSS** — the `feed.rss` alternate link.

The CSS references no external fonts or images (no `url(...)`), so it renders
standalone.

## License / attribution

The article is © **Matt Might**. The site carries **no explicit open license**
([legal page](https://matt.might.net/articles/legal/)), so it is treated as
all-rights-reserved and reproduced here **verbatim, with attribution, for offline
educational reference** only — not redistribution. The author does encourage
sharing his guides (his companion guides invite the reader to *"forward this
series to a student, friend, partner or spouse"*). All rights remain with the
author; no endorsement is implied. To remove this archive, `git rm` this
directory.

Source of truth: <https://matt.might.net/articles/hello-perceptron/>
