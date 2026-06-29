# Vendored upstream — vermaden, *"Automated Kickstart Install of RHEL/Clones"*

Byte-exact archive of vermaden's blog post — the tutorial this lab operationalizes
— so the article and its shell scripts read offline and the provenance is explicit
(web pages move, rot, or get reorganized). The post contains **no images** (only
Amazon affiliate book-cover widgets, not vendored); its real payload is the prose
plus the `kickstart.config` / `kickstart.skel` / `kickstart.sh` scripts, all
preserved verbatim in the HTML.

## Provenance

| Field | Value |
|---|---|
| Title | Automated Kickstart Install of RHEL/Clones |
| Author | vermaden (`vermaden.wordpress.com`) |
| Canonical URL | <https://vermaden.wordpress.com/2022/04/11/automated-kickstart-install-of-rhel-clones/> |
| Published | 2022-04-11 (from the post URL/date) |
| **Retrieved** | **2026-06-29** |
| License | No explicit license stated on the page — treated as all-rights-reserved © vermaden (see below) |

## Files & `sha256`

The page is kept **byte-exact**. The archive mirrors the post's URL date-path so
the saved file sits where the original URL points:

```
d3f4ef36f4a815472c0be431d1e1ad63672b0bd377941ab10a530c9e2e64e66b  2022/04/11/automated-kickstart-install-of-rhel-clones/index.html
8548c8e4efb764e800fdb8d3c8c8a4483de2983cfc58ed16e7148deb23581ac5  css/twentytwelve-style.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
d3f4ef36f4a815472c0be431d1e1ad63672b0bd377941ab10a530c9e2e64e66b  2022/04/11/automated-kickstart-install-of-rhel-clones/index.html
8548c8e4efb764e800fdb8d3c8c8a4483de2983cfc58ed16e7148deb23581ac5  css/twentytwelve-style.css
EOF
```

## Not vendored — and why this page renders only partially offline

This is a **WordPress.com** page; unlike a static site, its styling is delivered
by WordPress.com's CSS **concatenator** (`/_static/??-eJx…` bundles built on the
fly from many files) plus the `twentytwelve` theme, served from `s0.wp.com`. Those
dynamic bundle URLs cannot be mapped cleanly to local files, so the byte-exact HTML
keeps its absolute WordPress.com links and the page shows **unstyled (or partially
styled) offline**. That is expected and harmless:

- **The article text and every shell script are fully preserved** in the saved
  HTML — open it in a browser (online for full styling, offline for the content),
  or read the scripts in [`../templating/`](../templating/), which are adapted
  from them.
- `css/twentytwelve-style.css` is the theme's **base** stylesheet, vendored
  best-effort for archival reference (the page references the concatenated bundle,
  not this file, so it is not auto-loaded).
- **Not vendored:** the WordPress.com concatenated CSS/JS bundles, gravatar/hovercard
  JS, share buttons, comment widgets, and the Amazon affiliate book-cover images —
  all absolute links to their original hosts. None are needed to read the tutorial.

## License / attribution

The post carries **no explicit open license**, so it is treated as
all-rights-reserved © **vermaden** and reproduced here **verbatim, with
attribution, for offline educational reference** only — not redistribution. The
author publishes the series publicly and invites readers (the blog has a
`/donate/` and `/contact/`); all rights remain with the author and no endorsement
is implied. To remove this archive, `git rm` this directory.

Source of truth: <https://vermaden.wordpress.com/2022/04/11/automated-kickstart-install-of-rhel-clones/>
