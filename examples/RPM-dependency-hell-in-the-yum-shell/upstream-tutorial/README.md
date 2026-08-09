# Vendored upstream — "yum shell - bat out of dependency hell"

Byte-exact archive of the write-up this lab operationalizes, plus its primary
stylesheet, so it reads offline and its provenance is explicit (web pages move,
rot, or get paywalled).

The post is a working sysadmin's war story, and its arc is the lab's script:
a one-package `yum install` refused because two library packages both provide
`libmysqlclient.so.18` and conflict; the "obvious" `yum remove` that would take
**six** innocent production packages with it (postfix and `redhat-lsb-core`
among the casualties — "Very much not OK"); and then the turn — *"Did you notice
the use of the word **transaction** in Transaction Summary from yum? A
transaction is actually what I want"* — resolved by `yum shell`, where `remove`
+ `install` ride in **one** depsolver run. His closing line before the fix:
*"And as so many times before, it is a shell that solves our problems."*

## Provenance

| Field | Value |
|---|---|
| Title | *yum shell - bat out of dependency hell* |
| Author | **Sigurd Urdahl** — Senior Systems Consultant at Redpill Linpro |
| Canonical URL | <https://www.redpill-linpro.com/techblog/2018/01/22/bat_out_of_dependency_hell.html> |
| Published | **2018-01-22** (the page notes it first appeared on the author's private blog; a site-side "Format" touch-up is stamped 2025-09-03) |
| **Retrieved** | **2026-08-09** |
| License | **No license statement anywhere on the page or site** |

## Files & `sha256`

The page is kept **byte-exact**, so its stylesheet link is untouched. The
archive **mirrors the site's path layout** so the root-relative link
(`/techblog/assets/css/main.css`) resolves when served.

```
d0fe30793e030ed4f62d8cc61d2173de340b7db46c2dc39f601b64cf69cab3ef  redpill-linpro/techblog/2018/01/22/bat_out_of_dependency_hell.html
107400ea4b037b9a45819607faf1dc2ae23400c08b5f7e0bf849789326d051eb  redpill-linpro/techblog/assets/css/main.css
```

Verify any time (from this directory):

```bash
sha256sum -c <<'EOF'
d0fe30793e030ed4f62d8cc61d2173de340b7db46c2dc39f601b64cf69cab3ef  redpill-linpro/techblog/2018/01/22/bat_out_of_dependency_hell.html
107400ea4b037b9a45819607faf1dc2ae23400c08b5f7e0bf849789326d051eb  redpill-linpro/techblog/assets/css/main.css
EOF
```

## Opening it offline

The page links its CSS root-relatively (`/techblog/assets/css/main.css`), which
a browser resolves against the *filesystem root* over `file://` — so opening
the `.html` directly renders **unstyled** (every word and code block is still
there and perfectly readable). To see it as published, serve the mirror root
over HTTP so `/techblog/...` resolves:

```bash
( cd redpill-linpro && python3 -m http.server 8899 )   # then open
# http://localhost:8899/techblog/2018/01/22/bat_out_of_dependency_hell.html
```

(Port 8899 is arbitrary and host-local.)

## Not vendored (live links remain absolute to the original hosts)

The site's JavaScript (jQuery, modernizr, `scripts.min.js` — none needed to
read the article) and its images: the Redpill Linpro logo, the author photo,
and the header photo of Meat Loaf's *Bat out of Hell* tour — credited on the
page as "By TubularWorld (Own work) CC BY-SA 3.0, via Wikimedia Commons".
Their `src` attributes are root-relative or absolute, so they show as
broken-image icons offline; the article contains **no content-bearing figures**
— every technical artifact is a `<pre>` code block, and those are all here.

## What running it on Rocky Linux surfaced

The article is EL7 + yum. This lab replays it on **Rocky Linux 9**, where
`/usr/bin/yum` *is* dnf (the `dnf-3` compat CLI) — so every command runs
verbatim — and two things have changed underneath, both proven by the lab's
[`demo.sh`](../demo.sh):

1. **The error message learned the answer.** His EL7 yum could only suggest
   `--skip-broken` (which does not help — the missing package is *conflicting*,
   not broken). EL9's dnf prints `try to add '--allowerasing'` inside the very
   refusal — and `--allowerasing` solves the whole post in one command, erasing
   exactly the one package he had to hand-pick in 2018.
2. **The trick became a verb.** `dnf swap A B` is the remove+install-as-one-
   transaction shell session, spelled as a single command. `dnf shell` itself
   survives unchanged (his three commands run verbatim from a script file).

Neither change retires the article: `yum shell` is still the general form — a
swap plus any other marks you want in the *same* transaction — and the story is
still the cleanest demonstration in print of *why* the transaction is the unit
that matters.

## License / attribution

The page states **no license**, so it is treated as all-rights-reserved and
reproduced here **verbatim, with attribution, for offline educational
reference** only — not redistribution. All rights remain with the author and
Redpill Linpro; no endorsement is implied. To remove the archive, `git rm`
this directory.

Source of truth:
<https://www.redpill-linpro.com/techblog/2018/01/22/bat_out_of_dependency_hell.html>
