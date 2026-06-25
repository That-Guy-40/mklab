# Vendored upstream — Matt Might, *"A survival guide for Unix beginners"*

Byte-exact archive of Matt Might's introductory howto — the tutorial this lab
provides a ready environment for — plus the two stylesheets it references, so the
guide renders and reads offline and its provenance is explicit (web pages move,
rot, or change).

## Provenance

| Field | Value |
|---|---|
| Title | A survival guide for Unix beginners (heading: *"Survival guide for Unix newbies"*) |
| Author | Matt Might (professor; matt.might.net) |
| Canonical URL | <https://matt.might.net/articles/basic-unix/> |
| Published | Not dated on the page (matt.might.net article, `ArticleVersion = 2`) |
| **Retrieved** | **2026-06-25** |
| License | No explicit open license — standard copyright © Matt Might (see below) |

## Files & `sha256`

The page is kept **byte-exact**, so its `href="../../css/raised-paper-2.css"`
links are untouched. The archive **mirrors the site's path layout** so those
relative links resolve *within this directory* — the page sits at
`articles/basic-unix/` and the CSS at `css/`, exactly as on matt.might.net, so
`../../css/…` lands on the vendored copy. Open
[`articles/basic-unix/index.html`](articles/basic-unix/index.html) directly in a
browser.

```
e97b5d9151e0249e15fdb6d10d7aaf6754177ed3aad0ea94c2545451f5c0f6f3  articles/basic-unix/index.html
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  css/raised-paper-2-handheld.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
e97b5d9151e0249e15fdb6d10d7aaf6754177ed3aad0ea94c2545451f5c0f6f3  articles/basic-unix/index.html
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  css/raised-paper-2-handheld.css
EOF
```

## Not vendored (live links remain absolute to the original hosts)

- **JavaScript** — the site's `matt.might.js`, `manifest.js`,
  `index-manifest.js` (header/nav rendering) and a Google Tag Manager beacon. The
  guide is fully readable without them; only the site chrome and analytics need JS.
- **Images** — the only `<img>`s are Amazon affiliate book-cover widgets
  (`assoc-amazon.com`) in the "Good books" section; they load from Amazon when
  online and are irrelevant to the lesson.
- **RSS** — the `feed.rss` alternate link.

The two CSS files reference no external fonts or images (no `url(...)`), so they
render standalone.

## License / attribution

The article is © **Matt Might**. The site carries **no explicit open license**
([legal page](https://matt.might.net/articles/legal/)), so it is treated as
all-rights-reserved and reproduced here **verbatim, with attribution, for offline
educational reference** only — not redistribution. The author does, in the
article itself, explicitly encourage sharing it: *"Please feel free to forward
this series to a student, friend, partner or spouse that needs a little help
getting started."* All rights remain with the author; no endorsement is implied.
To remove this archive, `git rm` this directory.

Source of truth: <https://matt.might.net/articles/basic-unix/>
