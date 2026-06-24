# Vendored upstream — Software Carpentry *shell-novice* (all-in-one)

Byte-exact archive of the **all-in-one view** of The Carpentries' *The Unix
Shell* (`shell-novice`) lesson — the full-day workshop this lab provides an
environment for — plus its primary stylesheet. Vendored so the workshop is
reproducible offline and its provenance is explicit (the lesson is continuously
updated; this pins one retrieval).

The workshop **data** (`shell-lesson-data.zip`) lives one directory up, next to
the lab's specs; its provenance is in the table below too.

## Provenance

| Field | Value |
|---|---|
| Title | The Unix Shell: All in One View (`shell-novice`) |
| Author | The Carpentries / Software Carpentry community |
| Canonical URL | <https://swcarpentry.github.io/shell-novice/aio.html> |
| Data zip URL | <https://swcarpentry.github.io/shell-novice/data/shell-lesson-data.zip> |
| License | **CC-BY 4.0** (<https://creativecommons.org/licenses/by/4.0/>) |
| Lesson last updated | 2026-06-23 (per the page's changelog dates) |
| **Retrieved** | **2026-06-24** |

## Files & `sha256`

```
# the lesson page (byte-exact, as served)
b41d05b0331e65d999d14a814a55eaac48f0d749f8f37ef5d74c7316f03ffaab  aio.html

# primary stylesheet (so the page renders offline; same path the HTML references as assets/styles.css)
00b0115b0ee224e0a35ffe5be64ac74572c25dd9d1abc7068f996571857a57a1  assets/styles.css

# workshop data archive (in the parent dir)
1fc5de99bc979ad584980df29937795ea019ca4657d706f884cac6691ea59c09  ../shell-lesson-data.zip
```

Verify any time:

```bash
sha256sum -c <<'EOF'
b41d05b0331e65d999d14a814a55eaac48f0d749f8f37ef5d74c7316f03ffaab  aio.html
00b0115b0ee224e0a35ffe5be64ac74572c25dd9d1abc7068f996571857a57a1  assets/styles.css
1fc5de99bc979ad584980df29937795ea019ca4657d706f884cac6691ea59c09  ../shell-lesson-data.zip
EOF
```

## Layout (why `assets/`)

`aio.html` is kept byte-exact, so its `<link rel="stylesheet"
href="assets/styles.css">` reference is untouched. Mirroring the upstream path —
`assets/styles.css` alongside the page — makes that relative link resolve
**within this archive**, so the page renders offline. Open `aio.html` directly
in a browser.

## Not vendored (live links remain absolute to swcarpentry.github.io)

- **JavaScript** — `assets/scripts.js`, `assets/themetoggle.js`, MathJax (jsDelivr
  CDN), and the Matomo analytics beacon. The lesson is fully readable without
  them; only the dark-mode toggle, math rendering, and collapsible solutions
  need JS.
- **Web fonts** — the Mulish font family referenced by `styles.css`
  (`assets/fonts/Mulish-*`). The page falls back to a system sans-serif offline.
- **Images / icons** — episode figures and the Carpentries logo load from the
  live site.

## License / attribution

The *shell-novice* lesson content is © The Carpentries and is licensed
**CC-BY 4.0**. It is reproduced here **verbatim, with attribution**, for offline
use in an educational lab — exactly what CC-BY permits. The `shell-lesson-data`
archive is distributed by the same lesson under the same terms. No endorsement
by The Carpentries is implied. To remove this archive, `git rm` this directory
and the sibling `shell-lesson-data.zip`.

Source of truth: <https://swcarpentry.github.io/shell-novice/>
