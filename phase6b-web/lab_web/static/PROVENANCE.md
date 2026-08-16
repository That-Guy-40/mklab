# Vendored assets — provenance

Phase 6b vendors its JavaScript instead of loading it from a CDN, and
[`README.md`](../../README.md) names that as the supply-chain mitigation. A vendored
file with no recorded origin is a weaker version of the same problem: nobody can say
what it is, whether it is current, or whether it still matches what upstream published.
This file is that record (P6B-2, [`REVIEW-phase6b.md`](../../../REVIEW-phase6b.md)).

**The digests below are enforced**, not decorative:
[`tests/test_vendored_provenance.py`](../../tests/test_vendored_provenance.py) recomputes
them on every run. A record that silently drifts from its subject is the bug class this
repo tracks most carefully — see CLAUDE.md, *"a record that outlives the thing it
describes"*.

| file | version | sha256 | source |
|---|---|---|---|
| `htmx.min.js` | **1.9.12** | `449317ade7881e949510db614991e195c3a099c4c791c24dacec55f9f4a2a452` | <https://unpkg.com/htmx.org@1.9.12/dist/htmx.min.js> |
| `sse.js` | **unknown** (see below) | `c07c53b007c0898bc70493e55479019684dcfb9e21ab5368534f6b36ada7502b` | htmx SSE extension, <https://unpkg.com/htmx.org@1.9.12/dist/ext/sse.js> |
| `style.css` | n/a — written for this project | `a00ab243f0722016920a7dade233753cdde17eefeb00106a8e53e475d82c4a9d` | not vendored |

**Vendored:** 2026-05-28 (file mtime; the retrieval predates this record).
**Recorded:** 2026-08-16.

## The asymmetry worth knowing about

`htmx.min.js` carries its own version in the bytes — `version:"1.9.12"` — so its identity
is recoverable from the file even with no record at all. **`sse.js` does not.** Its header
comment names the extension and nothing else:

```
/*
Server Sent Events Extension
============================
```

So its version is *not* recoverable from what is on disk, and the pairing above is an
inference from the mtime matching `htmx.min.js`'s, not a fact read out of the file. That
is why it is marked **unknown** rather than assumed to be 1.9.12 — a guess written down
becomes a fact three sessions later.

To settle it, re-fetch that URL and compare digests; if they match, replace this
paragraph with the version.

## What this record does NOT claim

**No CVE research has been done on htmx 1.9.12.** P6B-2 is about unrecorded provenance,
not a vulnerability claim, and nothing here should be read as asserting the pinned
version is free of known issues. htmx 2.x exists; upgrading is a separate decision with
its own compatibility question (the SSE extension moved out of the core distribution).

## Refreshing an asset

1. Fetch the exact URL above and confirm it returns 200 and the expected content.
2. `sha256sum <file>` and update the table **in the same commit** as the file.
3. Run `pytest tests/test_vendored_provenance.py` — it fails if the two disagree.
