# Vendored upstream — Oils install docs + release source

Byte-exact archive of the two Oils documentation pages this lab operationalizes,
plus the release **source tarball** it builds.  Vendored so the lab is
reproducible offline and its provenance is explicit (docs move, rot, or get
re-rendered per release).

Everything here is pinned to the **0.37.0** release — the same version as the
tarball in the parent directory.

## Provenance

| Field | INSTALL | Getting Started |
|---|---|---|
| Title | Installing Oils | Getting Started |
| Author | Andy Chu / the Oils project | Andy Chu / the Oils project |
| Canonical URL | <https://oils.pub/release/0.37.0/doc/INSTALL.html> | <https://oils.pub/release/0.37.0/doc/getting-started.html> |
| Release | Oils 0.37.0 | Oils 0.37.0 |
| Published | 2025-11-30 (0.37.0 release) | 2025-11-30 (0.37.0 release) |
| **Retrieved** | **2026-06-24** | **2026-06-24** |

The release source tarball:

| Field | Value |
|---|---|
| File | `../oils-for-unix-0.37.0.tar.gz` |
| Canonical URL | <https://oils.pub/download/oils-for-unix-0.37.0.tar.gz> |
| Release home | <https://oils.pub/release/0.37.0/> |
| Published | 2025-11-30 |
| **Retrieved** | **2026-06-24** (provided locally by the lab author) |

## Files & `sha256`

```
# docs (byte-exact, as served)
6163e079080aa5f23375bd6708faca140c412c4e81fcba59a0f5220f08153957  doc/INSTALL.html
a0f604ffa4b9954a192a936ffcf1bfdef452c4472c5eca2b375f52cd57841aa4  doc/getting-started.html

# primary CSS (so the pages render offline; same paths the HTML references as ../web/)
c4aa8e27eefa475f1a80c0de1572dd23a7e4d1898aa82a90a750f015aa509ab0  web/base.css
79b2c8c0ffd06cb5801abaafa3e4a3b9c9598b2453abb83f9222aec3a728c33c  web/code.css
c6b9f53eda60f8c1036cf9c926d74d6c16db42e3cea5f1ca0c58ab6ea7b6a37a  web/install.css
4e79d2ddeac820f534fcd1cb9b111d46894320e2d20bf86bb728e00bc0cbce73  web/language.css
9d9106a3e40d63a8339fd128da8fb76f3ddad5f042c58af2f307bf1f95f59bb6  web/manual.css
b51ddadf1a7a30ea58ca57544059834b2fd8021e703cc28fa607f0bc22e38a67  web/toc.css

# release source tarball (in the parent dir)
f4d41d20a0523dbcfbd4ba231f82edf25b08d4965d65bc71fcb56666d6743000  ../oils-for-unix-0.37.0.tar.gz
```

Verify any time with, e.g.:

```bash
sha256sum -c <<'EOF'
6163e079080aa5f23375bd6708faca140c412c4e81fcba59a0f5220f08153957  doc/INSTALL.html
f4d41d20a0523dbcfbd4ba231f82edf25b08d4965d65bc71fcb56666d6743000  ../oils-for-unix-0.37.0.tar.gz
EOF
```

## Layout (why `doc/` + `web/`)

The pages are kept byte-exact, so their `<link rel="stylesheet" href="../web/…">`
references are untouched.  Mirroring the upstream URL layout — `doc/*.html`
alongside a sibling `web/*.css` — makes those relative links resolve **within
this archive**, so the pages render offline with no edits.  Open
`doc/INSTALL.html` directly in a browser.

## Not vendored (live links remain absolute to oils.pub)

- Page images, JavaScript, and web fonts — the pages are readable without them.
- Other doc pages the two link to (`help-mirror.html`, `portability.html`,
  `ref/`, etc.) — out of scope; follow the absolute links to the live site.
- The tarball's own contents are not re-listed here — extract it to inspect;
  `INSTALL.txt` inside it is the canonical plain-text twin of `doc/INSTALL.html`.

## Copyright / attribution

These documents and the Oils source are © the Oils project (Andy Chu and
contributors). They are reproduced here **verbatim for offline reference** as
part of an educational lab; all rights remain with the authors. Oils is released
under the Apache-2.0 license (see `LICENSE.txt` inside the tarball). No
endorsement is implied. To remove this archive, `git rm` this directory and the
sibling tarball.

Sources of truth, in order, live at:

- <https://oils.pub/release/0.37.0/doc/INSTALL.html>
- <https://oils.pub/release/0.37.0/doc/getting-started.html>
