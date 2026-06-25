# Vendored upstream — Matt Might, *"Shell programming with bash: by example, by counter-example"*

Byte-exact archive of Matt Might's intermediate bash-programming guide — the
tutorial this lab provides a scripting playground for — plus its two inline
screenshots and the two stylesheets it references, so the guide renders and reads
offline and its provenance is explicit (web pages move, rot, or change).

## Provenance

| Field | Value |
|---|---|
| Title | Shell programming with bash: by example, by counter-example |
| Author | Matt Might (professor; matt.might.net) |
| Canonical URL | <https://matt.might.net/articles/bash-by-example/> |
| Published | Not dated on the page (matt.might.net article) |
| **Retrieved** | **2026-06-25** |
| License | No explicit open license — standard copyright © Matt Might (see below) |

## Files & `sha256`

The page is kept **byte-exact**, so its `href="../../css/raised-paper-2.css"` and
`src="./images/…"` links are untouched. The archive **mirrors the site's path
layout** so those relative links resolve *within this directory* — the page sits
at `articles/bash-by-example/`, its images at `articles/bash-by-example/images/`,
and the CSS at `css/`, exactly as on matt.might.net. Open
[`articles/bash-by-example/index.html`](articles/bash-by-example/index.html)
directly in a browser.

```
4ed92fafdac57601387cc054a21f03db8a581b5755c9798717cf2c9835ddd421  articles/bash-by-example/index.html
a599b822e25ec63ac977a66c7618207a164fd827da562e9909979c01f4ce4a55  articles/bash-by-example/images/bash-script.png
43bf0058acbd2ad82534e5c0dd02e8646c325d08933a31aa29374c434e0d967b  articles/bash-by-example/images/bash-shell.png
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  css/raised-paper-2-handheld.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
4ed92fafdac57601387cc054a21f03db8a581b5755c9798717cf2c9835ddd421  articles/bash-by-example/index.html
a599b822e25ec63ac977a66c7618207a164fd827da562e9909979c01f4ce4a55  articles/bash-by-example/images/bash-script.png
43bf0058acbd2ad82534e5c0dd02e8646c325d08933a31aa29374c434e0d967b  articles/bash-by-example/images/bash-shell.png
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  css/raised-paper-2-handheld.css
EOF
```

(The two CSS files are byte-identical to the ones vendored under
[`../../UNIX_novice_survival_guide/`](../../UNIX_novice_survival_guide/upstream-tutorial/README.md)
— same author, same site theme. Each lab keeps its own copy to stay
self-contained.)

## Not vendored (live links remain absolute to the original hosts)

- **JavaScript** — the site's `matt.might.js`, `manifest.js`,
  `index-manifest.js` (header/nav rendering) and a Google Tag Manager beacon. The
  guide is fully readable without them; only the site chrome and analytics need JS.
- **Amazon affiliate images** — the book-cover widgets (`assoc-amazon.com`). The
  two *content* screenshots (`bash-script.png`, `bash-shell.png`) **are** vendored.
- **RSS** — the `feed.rss` alternate link.

The two CSS files reference no external fonts or images (no `url(...)`), so they
render standalone.

## License / attribution

The article is © **Matt Might**. The site carries **no explicit open license**
([legal page](https://matt.might.net/articles/legal/)), so it is treated as
all-rights-reserved and reproduced here **verbatim, with attribution, for offline
educational reference** only — not redistribution. The author does encourage
sharing his guides (his companion *survival guide* says *"Please feel free to
forward this series to a student, friend, partner or spouse"*). All rights remain
with the author; no endorsement is implied. To remove this archive, `git rm` this
directory.

Source of truth: <https://matt.might.net/articles/bash-by-example/>
