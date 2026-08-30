# upstream-tutorial — *FORTH Hacking on Sparc Hardware* (Phrack 53:9, 1998)

A near-byte-exact archive of the Phrack article that **inspired this lab** — the
OpenBIOS bring-up and the binary-structure DSL both trace back to it — vendored
here for offline reference and provenance. Sources move, rot, and get reindexed;
Phrack has already migrated hosts more than once.

## Provenance

| | |
|---|---|
| **Title** | FORTH Hacking on Sparc Hardware |
| **Author** | mudge \<mudge@l0pht.com\>, L0pht Heavy Industries |
| **In** | Phrack Magazine, Volume 8, Issue 53, article 9 of 15 |
| **Published** | 1998-07-08 |
| **Canonical URL** | <https://phrack.org/issues/53/hacking-in-forth> |
| **Retrieved** | 2026-08-30 (HTTP 200, `<title>` `.:: Hacking in Forth ::.`) |

## Files

| File | sha256 |
|---|---|
| [`hacking-in-forth.html`](hacking-in-forth.html) | `db7546391f3239120993f5b56106f9ab1c7de1ac085dd16f86284831b2c5ef5c` |
| [`css/palette.css`](css/palette.css) | `8a33a4916be70ac9ad362c07b0553dc1eb5bb9a61b64e538a80169a9f975454f` |
| [`css/Default.aGptptxO.css`](css/Default.aGptptxO.css) | `48880351a0a4d96c0b6da4d7db5fb51001ef5fc594a4b032545847688a63d4ae` |

**The one modification, recorded in full.** The page as served links its two
stylesheets by **absolute** path (`/css/palette.css`, `/_astro/Default.aGptptxO.css`),
which would fetch from the live site. Those two `href`s — and *only* those two —
were rewritten to the local `css/` copies so the page renders offline. Nothing
in the article body was touched. The as-served HTML hashes
`c5632c654736106a54f66a583450c8eafff344a445ad3992b1a20000d58da4a7`. The change is
two `<link>` tags — which sit on the **same physical line**, because the page is
minified: of the file's 394 lines, exactly **one** differs.

**And that is checkable, which is the point of recording it.** Put the two
`href`s back and the as-served digest comes out byte-for-byte:

```console
$ python3 -c '
import hashlib
b = open("hacking-in-forth.html","rb").read()
b = b.replace(b"href=\"css/palette.css\"", b"href=\"/css/palette.css\"")
b = b.replace(b"href=\"css/Default.aGptptxO.css\"", b"href=\"/_astro/Default.aGptptxO.css\"")
print(hashlib.sha256(b).hexdigest())'
c5632c654736106a54f66a583450c8eafff344a445ad3992b1a20000d58da4a7
```

The `sha256` table above proves only that *these bytes are these bytes*.
Re-deriving the upstream digest from the vendored copy proves the thing a
provenance record is actually for: that the **edit list is complete** — nothing
else in the file was touched, including in the article body.

**Un-vendored, left as absolute links to the live site:** the site chrome (nav,
fonts, favicons, JS) that Phrack's Astro build pulls in around the article. The
`<pre>` article body and its primary CSS are complete offline; the surrounding
page furniture is not, and does not matter for reference.

## Why this article is here — the capability lineage

The lab did not follow this article step by step; it **generalised the moves in
it into named words**. The mapping is close enough to be worth stating:

| mudge, 1998 (Sun OpenBoot) | this lab |
|---|---|
| `:light-on 1 aux@ or aux! ;` — read-modify-write a device register | `t-set` / `t-clr` / `t-tog` in [`../dsl/struct.fth`](../dsl/struct.fth), the same idiom over a **typed field**, memory or device — `smoke-openbios.sh rmw-fields` |
| `aux@` / `aux!` — device-register access | IEEE 1275 §5.3.7.2's `rb@` / `rb!`, which shipped **empty** in OpenBIOS and got bodies in [patch 49](../patches/49-device-register-words-were-empty.patch); the `dev-field:` backend |
| `f5e09000 18 + l@` then `f5a99858 4 + l@` — a C struct from `proc.h` overlaid on live memory, one field at a time | `field:` / `le-field:` — a layout applied at a base, so the offset and width ride along instead of being retyped at every access |
| `variable ciscofoo 40 allot` then `C!` byte by byte | `int!+` / `bytes!+` and the cursor; `elf64-new` authors a header the same way |
| `abort" contains invalid char"` guarding hex input | `chk` / `?elf64` — a constraint that **refuses** rather than misreads |
| `xor` in the cisco decryptor | `t-tog`, and `bits@` / `bit?` |
| `' led-on (see)` — decompile a word | the FCode detokenizer this lab already carries |

The one move the lab reaches that mudge's does **not**: he read the running
kernel's memory from the PROM after an `L1-A` break — *below* the OS's
permission model. That is the "firmware-owned state" the review
([`REVIEW-preboot-forth-as-a-poke-engine.md`](../../../REVIEW-preboot-forth-as-a-poke-engine.md)
§P3) calls the one thing no hosted tool can reach, demonstrated 26 years early.

## Copyright & attribution

This article is the work of **mudge (Peiter Zatko)**, and **all rights and
copyright remain with the author and Phrack Magazine.** It is archived here
solely as an offline, fixed-point reference for the [`../`](../) lab, whose
capabilities it inspired. For the authoritative version — and for the rest of
Phrack — always go to the [canonical page](https://phrack.org/issues/53/hacking-in-forth).
If you are the author or a Phrack editor and would prefer this copy not be
redistributed, removing it is a one-line `git rm`.
