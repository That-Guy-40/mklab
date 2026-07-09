# Vendored upstream — two treatments of relational algebra in the shell

Byte-exact archives of the **two** write-ups this lab operationalizes, plus the
stylesheets they reference, so both render and read offline and their provenance
is explicit (web pages move, rot, or get paywalled).

The lab is built on the pair *because they disagree in a useful way*: Might
(c. 2010) **implements the algebra's primitives by hand in bash** — including the
one Unix never shipped, Cartesian product — while Walsh (2026) maps the same
algebra onto the **native tools** (`join`, `comm`, `uniq -c`) and cross-checks it
against **SQL**. Read Might for *why the primitives are what they are*; read Walsh
for *what to actually type today*.

## Provenance

| Field | Matt Might | Jason Walsh |
|---|---|---|
| Title | **Relational shell programming** (the URL slug is `sql-in-the-shell`) | **SQL in the Shell: Relational Algebra with Unix Tools** |
| Author | Matt Might (professor; `matt.might.net`) | Jason Walsh (`wal.sh`) |
| Canonical URL | <https://matt.might.net/articles/sql-in-the-shell/> | <https://wal.sh/research/relational-algebra> |
| Published | Not dated on the page | **May 23, 2026** (page byline); Org-Mode build stamp `2026-06-12 22:32` |
| **Retrieved** | **2026-07-08** | **2026-07-08** |
| License | No explicit open license — standard copyright © Matt Might | No license stated anywhere on the page or site footer |

> Note the title mismatch: Might's page is titled *"Relational shell
> programming"*; only its **URL** says `sql-in-the-shell`. Walsh's page — which
> cites Might as "the canonical treatment" — takes *"SQL in the Shell"* as its
> actual title. This lab's directory name follows the phrase they share.

## Files & `sha256`

Each page is kept **byte-exact**, so its stylesheet links are untouched. Each
archive **mirrors its site's path layout** so those links resolve *within* the
archive.

```
2e0243e1c7046fb6a7018a3715c8e4626f1ace62507dc538f675fb06ca992f0e  matt-might/articles/sql-in-the-shell/index.html
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  matt-might/css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  matt-might/css/raised-paper-2-handheld.css
48664eb7d6ae429aa2cb146c318e8c9d222dee29c4285297b11a6eed3edef42d  wal-sh/research/relational-algebra/index.html
83123cefd4914ee2d092d1a15c30bc6e447d9daef5dfc3252c9f58c29c1ea0d8  wal-sh/static/css/style.css
0c21b6de9963df540ce80afead99628521e215f772e76de0ad3cdf2bb6ec1d63  wal-sh/static/css/webring.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
2e0243e1c7046fb6a7018a3715c8e4626f1ace62507dc538f675fb06ca992f0e  matt-might/articles/sql-in-the-shell/index.html
391dce6385ab5c745ef6b3a22b30cbb3b4950e84cbd2de073a7c2fe7001ae7df  matt-might/css/raised-paper-2.css
131ffff18fe0ffeaac46b42daa9b93314eea87708a189965cd8da934d42a90c5  matt-might/css/raised-paper-2-handheld.css
48664eb7d6ae429aa2cb146c318e8c9d222dee29c4285297b11a6eed3edef42d  wal-sh/research/relational-algebra/index.html
83123cefd4914ee2d092d1a15c30bc6e447d9daef5dfc3252c9f58c29c1ea0d8  wal-sh/static/css/style.css
0c21b6de9963df540ce80afead99628521e215f772e76de0ad3cdf2bb6ec1d63  wal-sh/static/css/webring.css
EOF
```

## Opening them offline

- **Might** — open
  [`matt-might/articles/sql-in-the-shell/index.html`](matt-might/articles/sql-in-the-shell/index.html)
  straight from the filesystem. Its CSS links are **relative**
  (`../../css/raised-paper-2.css`), and the mirrored layout makes them resolve, so
  it renders fully styled over `file://`.
- **Walsh** — its CSS links are **absolute** (`/static/css/style.css`), which a
  browser resolves against the *filesystem root* over `file://`, so opening
  [`wal-sh/research/relational-algebra/index.html`](wal-sh/research/relational-algebra/index.html)
  directly renders it **unstyled** (the prose is all there). To see it as
  published, serve the mirror over HTTP so `/static/...` resolves:

  ```bash
  ( cd wal-sh && python3 -m http.server 8899 )   # then open
  # http://localhost:8899/research/relational-algebra/
  ```

  (Port 8899 is arbitrary and host-local; this repo's netboot labs use 8181
  because 8080 is taken on the author's host.)

## Not vendored (live links remain absolute to the original hosts)

**Might** — the site's JavaScript (`matt.might.js`, `manifest.js`,
`index-manifest.js`; header/nav chrome only, the article reads fine without it),
the RSS alternate link, and the **Amazon affiliate images** — book-cover widgets
for *sed & awk* and Date's *SQL and Relational Theory*, served from
`assoc-amazon.com`. Those are the page's only `<img>` tags; **the article
contains no diagrams**.

**Walsh** — the page has **no images at all**. Its ~27 JavaScript files (a
`static/js/adtech/` tree — beacons, prebid, tag-manager, metered-access,
content-gate, and friends — plus `webring.js`, `heading-anchors.js`,
`web-vitals-init.js`) are **deliberately not vendored**: none are needed to read
the prose, and archiving third-party ad/analytics code offline serves no purpose
here. Both stylesheets **are** vendored; neither contains any `url(...)`
reference, so both render standalone.

(Might's two CSS files are byte-identical to the copies vendored under
[`../../UNIX-sculpting-text-regex-grep-sed-awk/`](../../UNIX-sculpting-text-regex-grep-sed-awk/upstream-tutorial/README.md),
[`../../shell-intermediate-programming-by-example/`](../../shell-intermediate-programming-by-example/upstream-tutorial/README.md)
and [`../../UNIX_novice_survival_guide/`](../../UNIX_novice_survival_guide/upstream-tutorial/README.md)
— same author, same site theme. Each lab keeps its own copy to stay
self-contained.)

## Errata found by running the code

Both pages were **executed**, not just read. Three published commands do not do
what their surrounding prose claims. They are archived here **unmodified** — the
corrections live in the lab, not in the archive:

| # | Source | As published | What it actually does |
|---|---|---|---|
| 1 | Walsh, *Natural Join* | `join … \| cut -f2,4` under the heading `SELECT e.name, d.dept_name` | `join`'s output is `dept_id,id,name,salary,dept_name,location`, so `-f2,4` projects **`id, salary`**. The stated SQL needs **`cut -f3,5`**. |
| 2 | Walsh, *Selection* | `grep -E '^(id\|.*\tengineering)' departments.tsv` | **Prints nothing at all**, for two independent reasons: the header row is `dept_id`, so `^id` never matches it; and POSIX ERE has no `\t` escape, so GNU grep reads it as a literal `t` and hunts for `…tengineering`. Portable fix: `[[:blank:]]`. |
| 3 | Might, *Cartesian product* | `cartesian -t` for tab-delimited output | The script sets `delim="\t"` and emits it with `echo` under a `#!/bin/bash` shebang — bash's `echo` does **not** expand escapes, so you get a literal backslash-`t`. It would work only if `echo` were dash/ash's. Use `-d "$(printf '\t')"`. |

Proof for each — commands and captured output — is in
[`../MANUAL_TESTING.md`](../MANUAL_TESTING.md#documented-errata-three-published-commands-that-dont-do-what-they-say).
None of the three affects Might's flagship worked example, which reproduces
**byte-for-byte**.

## License / attribution

Neither page carries an explicit open license.

Might's article is © **Matt Might**; his site states no open license
([legal page](https://matt.might.net/articles/legal/)), so it is treated as
all-rights-reserved. Walsh's page states no license at all, so it is likewise
treated as all-rights-reserved.

Both are reproduced here **verbatim, with attribution, for offline educational
reference** only — not redistribution. All rights remain with the respective
authors; no endorsement is implied. To remove either archive, `git rm` its
directory.

Sources of truth:
- <https://matt.might.net/articles/sql-in-the-shell/>
- <https://wal.sh/research/relational-algebra>
