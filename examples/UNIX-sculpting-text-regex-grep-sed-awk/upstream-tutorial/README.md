# Vendored upstream — Matt Might, *"Sculpting text with regex, grep, sed and awk"*

Byte-exact archive of Matt Might's text-processing guide — the tutorial this lab
provides a hands-on sandbox for — plus the two stylesheets it references, so the
guide renders and reads offline and its provenance is explicit (web pages move,
rot, or change). The article has **no images** (only Amazon affiliate widgets,
which are not vendored).

## Provenance

| Field | Value |
|---|---|
| Title | Sculpting text with regex, grep, sed and awk (the page `<h1>` adds "emacs and vim") |
| Author | Matt Might (professor; matt.might.net) |
| Canonical URL | <https://matt.might.net/articles/sculpting-text/> |
| Published | Not dated on the page (matt.might.net article) |
| **Retrieved** | **2026-06-28** |
| License | No explicit open license — standard copyright © Matt Might (see below) |

## Files & `sha256`

The page is kept **byte-exact**, so its `href="../../css/raised-paper-2.css"`
links are untouched. The archive **mirrors the site's path layout** so those
relative links resolve *within this directory* — the page sits at
`articles/sculpting-text/` and the CSS at `css/`, exactly as on matt.might.net.
Open [`articles/sculpting-text/index.html`](articles/sculpting-text/index.html)
directly in a browser.

```
64a7c958cfbc59c631afa65048a4c2da0f2e810e6cd6f701fdf3fc74e1ac952a  articles/sculpting-text/index.html
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  css/raised-paper-2-handheld.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
64a7c958cfbc59c631afa65048a4c2da0f2e810e6cd6f701fdf3fc74e1ac952a  articles/sculpting-text/index.html
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  css/raised-paper-2-handheld.css
EOF
```

(The two CSS files are byte-identical to the ones vendored under
[`../../shell-intermediate-programming-by-example/`](../../shell-intermediate-programming-by-example/upstream-tutorial/README.md)
and [`../../UNIX_novice_survival_guide/`](../../UNIX_novice_survival_guide/upstream-tutorial/README.md)
— same author, same site theme. Each lab keeps its own copy to stay
self-contained.)

## Not vendored (live links remain absolute to the original hosts)

- **JavaScript** — the site's `matt.might.js`, `manifest.js`, `index-manifest.js`
  (header/nav rendering). The guide is fully readable without them; only the site
  chrome needs JS.
- **Amazon affiliate images** — the book-cover widgets for *sed & awk* and
  *Mastering Regular Expressions* (`assoc-amazon.com`). These are the only `<img>`
  tags on the page; the article itself contains **no diagrams**.
- **RSS** — the `feed.rss` alternate link.

The two CSS files reference no external fonts or images (no `url(...)`), so they
render standalone.

## License / attribution

The article is © **Matt Might**. The site carries **no explicit open license**
([legal page](https://matt.might.net/articles/legal/)), so it is treated as
all-rights-reserved and reproduced here **verbatim, with attribution, for offline
educational reference** only — not redistribution. The author does encourage
sharing his guides. All rights remain with the author; no endorsement is implied.
To remove this archive, `git rm` this directory.

Source of truth: <https://matt.might.net/articles/sculpting-text/>
