# Vendored upstream — Ciro S. Costa's two `/proc` articles (ops.tips)

Byte-exact archives of the two ops.tips articles this lab provides a hands-on
sandbox for, plus the site's stylesheet and the five explanatory SVG diagrams, so
the writing and its figures are preserved offline and the provenance is explicit
(web pages move, rot, or change).

## Provenance

| Field | Article 1 | Article 2 |
|---|---|---|
| Title | What is /proc? | How is /proc able to list process IDs? |
| Author | Ciro S. Costa (Ciro da Silva da Costa) | same |
| Publication | **ops.tips** (the author's blog) | same |
| Canonical URL | <https://ops.tips/blog/what-is-slash-proc/> | <https://ops.tips/blog/how-is-proc-able-to-list-pids/> |
| Published (in-page `datetime`) | 2018-10-10 | 2018-10-11 |
| **Retrieved** | **2026-07-03** | **2026-07-03** |
| License | © Ciro da Silva da Costa, 2018 — no explicit open license (see below) | same |

## Files & `sha256`

The two article pages are kept **byte-exact**. Their asset links (CSS, diagrams,
fonts) are **absolute** (`https://ops.tips/…`, `/blog/-/images/…`) — ops.tips is
a Hugo static site with content-addressed bundles — so, unlike a page with
*relative* links, the byte-exact HTML cannot be made to load those assets from
`file://` without editing it (which would break the hashes). The CSS and the five
content SVGs are therefore vendored **alongside** purely for preservation; view
the byte-exact pages best while online, or read the articles' prose directly.

```
b05fc4176bde8173cf16317ee26bcfae9f14a981cbd225a9bfb1475d437d8aeb  what-is-slash-proc.html
5e6c9f3c23757873117c332f74119b88241a3b86d72a21d452741615aa1b78b6  how-is-proc-able-to-list-pids.html
75922cc496f110bdc184ab4d765a2174146459fd2494dc8a354af9ea71997227  bundle.min.css
8f836b75f4c80571ce3301e3df9ddf32fc6070594575026999e11274b27cb452  images/vfs-abstraction.svg
c38016e8b5dfd7fdc0f2fe2a74a5809b5baa7d9c9c43dcfdb1f818aae269d05e  images/kernel-open-and-read.svg
3e4ade7efbfaa13afab9d1d61d8a526ec7a45d25d72cd27f13c6fa5a98c98f5b  images/procfs-file-operations.svg
ec8b617413578882be07c3e8a5d35cc7aa3b2b1d436aaa4d5da0365cd16151e9  images/getdents-under-the-hood.svg
565767f4d603bd42688c6c717d0a1150ba22f0a25df9c4fe765d368a209048c8  images/ls-proc.svg
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
b05fc4176bde8173cf16317ee26bcfae9f14a981cbd225a9bfb1475d437d8aeb  what-is-slash-proc.html
5e6c9f3c23757873117c332f74119b88241a3b86d72a21d452741615aa1b78b6  how-is-proc-able-to-list-pids.html
75922cc496f110bdc184ab4d765a2174146459fd2494dc8a354af9ea71997227  bundle.min.css
8f836b75f4c80571ce3301e3df9ddf32fc6070594575026999e11274b27cb452  images/vfs-abstraction.svg
c38016e8b5dfd7fdc0f2fe2a74a5809b5baa7d9c9c43dcfdb1f818aae269d05e  images/kernel-open-and-read.svg
3e4ade7efbfaa13afab9d1d61d8a526ec7a45d25d72cd27f13c6fa5a98c98f5b  images/procfs-file-operations.svg
ec8b617413578882be07c3e8a5d35cc7aa3b2b1d436aaa4d5da0365cd16151e9  images/getdents-under-the-hood.svg
565767f4d603bd42688c6c717d0a1150ba22f0a25df9c4fe765d368a209048c8  images/ls-proc.svg
EOF
```

> The stylesheet's filename **is** its own `sha256` (`bundle.min.<hash>.css`) —
> Hugo content-addresses its asset bundle, so the hash above matching the name is
> a second, independent integrity check.

## Which SVG belongs to which article

| SVG | Article |
|---|---|
| `images/vfs-abstraction.svg` | 1 — the VFS layer over ext4 vs procfs |
| `images/kernel-open-and-read.svg` | 1 — the `open()`→`read()` path into `f_op->read` |
| `images/procfs-file-operations.svg` | 1 — different procfs paths, different `file_operations` |
| `images/getdents-under-the-hood.svg` | 2 — `getdents64` from userspace down to the fs |
| `images/ls-proc.svg` | 2 — `ls /proc` calling into `proc_pid_readdir` |

## Not vendored (live links remain absolute to the original hosts)

- **Fonts** — the Lato `.woff`/`.woff2` files the CSS references by `url(/fonts/…)`.
  Text falls back to a system sans-serif; no meaning is lost.
- **JavaScript, analytics, comments** — site chrome and the Disqus/analytics
  includes. The articles read fully without them.
- **Header / social images** — `me.jpg`, `opstips.png`, the `slash-proc.png`
  OpenGraph card. These are branding, not article content; the five **content**
  SVGs above are the only in-body figures and are all vendored.

## License / attribution

The articles are © **Ciro da Silva da Costa, 2018** (the footer notice). The site
carries **no explicit open license**, so they are treated as all-rights-reserved
and reproduced here **verbatim, with attribution, for offline educational
reference** only — not redistribution. All rights remain with the author; no
endorsement is implied. To remove this archive, `git rm` this directory.

Source of truth:
<https://ops.tips/blog/what-is-slash-proc/> ·
<https://ops.tips/blog/how-is-proc-able-to-list-pids/>
