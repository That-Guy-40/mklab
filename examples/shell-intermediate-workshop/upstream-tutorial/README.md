# Vendored upstream — "Bash by example" (Daniel Robbins, IBM developerWorks)

Byte-exact archive of the three **"Bash by example"** articles by **Daniel
Robbins** (founder/former BDFL of Gentoo Linux) — the intermediate bash-
*programming* series this lab provides an environment for. Vendored so the
workshop is reproducible offline and its provenance is explicit (the original
IBM developerWorks pages are long gone; these survive only as mirrors).

These are **PDFs** — self-contained, no external assets to vendor.

## Provenance

| | Part 1 | Part 2 | Part 3 |
|---|---|---|---|
| File | [`bash.pdf`](bash.pdf) | [`bash2.pdf`](bash2.pdf) | [`bash3.pdf`](bash3.pdf) |
| Title | Bash by example, Part 1 | Bash by example, Part 2 | Bash by example, Part 3 |
| Subtitle | Fundamental programming in the Bourne again shell (bash) | More bash programming fundamentals | Exploring the ebuild system |
| Author | Daniel Robbins | Daniel Robbins | Daniel Robbins |
| Originally published | IBM developerWorks, March 2000 | IBM developerWorks, April 2000 | IBM developerWorks, May 2000 |
| Pages | 7 | 7 | 9 |
| Mirror URL (retrieved) | <https://theory.stanford.edu/~sbansal/tut/bash/bash.pdf> | <https://theory.stanford.edu/~sbansal/tut/bash/bash2.pdf> | <https://theory.stanford.edu/~sbansal/tut/bash/bash3.pdf> |
| **Retrieved** | **2026-06-24** | **2026-06-24** | **2026-06-24** |

Original source: IBM developerWorks, Linux library (the `ibm.com/developerworks`
URLs are defunct). Captured here from the Stanford mirror
(`theory.stanford.edu/~sbansal/tut/bash/`).

## Files & `sha256`

```
2006be0379cc88f6ed3816ecbfb26d0a1bdace39b9107f09eae1b1335187aacb  bash.pdf
592041bd2f70de832f2babb90314a3a0620f1abad93e9d0aecf18b174ad2fffb  bash2.pdf
1f59f9a052a55870f589a77c38bf0f9ef74d64b04f8f140f7f927fce493f0dc7  bash3.pdf
```

Verify any time:

```bash
sha256sum -c <<'EOF'
2006be0379cc88f6ed3816ecbfb26d0a1bdace39b9107f09eae1b1335187aacb  bash.pdf
592041bd2f70de832f2babb90314a3a0620f1abad93e9d0aecf18b174ad2fffb  bash2.pdf
1f59f9a052a55870f589a77c38bf0f9ef74d64b04f8f140f7f927fce493f0dc7  bash3.pdf
EOF
```

## Copyright / attribution

These articles are © Daniel Robbins / IBM (developerWorks). They are **not**
released under an open license. They are reproduced here **verbatim for offline
educational reference** as part of a learning lab; **all rights remain with the
author and original publisher**. No endorsement is implied. If this is not
acceptable for your use, `git rm` this directory to remove the archive — the lab
still works (it just provides the bash environment; you supply the reading).

Open them with any PDF viewer. Part 3 ("Exploring the ebuild system") is
Gentoo-specific and is reading material — its `emerge`/ebuild commands don't run
on this lab's Debian/Alpine box; the bash *language* lessons in Parts 1–2 do.
