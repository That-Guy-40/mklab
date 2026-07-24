# Vendored source — Gandi, *Booting an anycast DNS network*

This lab operationalizes one specific write-up, so per the repo's provenance
convention (`CLAUDE.md` › *Provenance*) that source is archived here **byte-exact**
for offline reproducibility and explicit attribution.

## Provenance

| | |
|---|---|
| **Title** | Booting an anycast DNS network |
| **Author** | Gandi (Gandi News) |
| **Canonical URL** | <https://news.gandi.net/en/2019/03/booting-an-anycast-dns-network/> |
| **Published** | March 2019 |
| **Retrieved** | 2026-07-23 |

The post describes how Gandi boots its authoritative anycast DNS nodes: a
**RAM-resident OS pulled at boot** (no local disk state), the DNS server running
from RAM, and each node **announcing the anycast prefix via BGP only while it is
healthy** — withdrawing on failure. Those three ideas are exactly the mechanics
this lab reproduces (RAM-boot + externalized state, and the **health-gated BGP
announce** proven by [`../demo-anycast.sh`](../demo-anycast.sh)).

## Files & checksums

| File | sha256 |
|---|---|
| `gandi-anycast-dns.html` | `7027d48b92d5c74260fbe630479dc4abbb512b0bde61b20520bfb345266ce704` |
| `gandi-news-main.min.css` | `468e837676ff90b993d481de60bada27a0452df2622b05894d869a63421f6db4` |

Verify:

```bash
sha256sum -c <<'EOF'
7027d48b92d5c74260fbe630479dc4abbb512b0bde61b20520bfb345266ce704  gandi-anycast-dns.html
468e837676ff90b993d481de60bada27a0452df2622b05894d869a63421f6db4  gandi-news-main.min.css
EOF
```

## What is NOT vendored

`gandi-anycast-dns.html` is the article page as served. `gandi-news-main.min.css`
is the theme's primary stylesheet (the page also carries three inline `<style>`
blocks, captured within the HTML). **Not** archived: images, fonts, JavaScript,
and secondary WordPress plugin stylesheets — those remain absolute links to the
live site and are inessential to reading the article offline.

## Copyright / attribution

All rights to the article and its styling remain with **Gandi**. This copy is
archived **solely for offline reference and provenance** as part of a teaching
lab; it is not redistributed or relicensed. To remove it, `git rm` this directory
(the parent lab links it, so also drop that link — see
[`../README.md`](../README.md)).
