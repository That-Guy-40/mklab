# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the write-up whose technique Phase 1's
`--rootless` mode follows, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Rootless cross-architecture debootstrap* |
| **Author** | Alex Bradbury (muxup.com) |
| **Canonical URL** | <https://muxup.com/2024q4/rootless-cross-architecture-debootstrap> |
| **Site home** | <https://muxup.com/> |
| **Published** | 2024-12-03 |
| **Retrieved** | 2026-06-07 |

## Files

| File | sha256 |
|---|---|
| [`rootless-cross-architecture-debootstrap.html`](rootless-cross-architecture-debootstrap.html) | `f21ee894cc6c027dfe4755b82add32e4f0a0b90723a73dbfcebf5bd527dd1cfe` |

The page is **fully self-contained** — its CSS is inline and its one image is an
inline `data:` SVG — so the single saved HTML file renders exactly as served with
no network and nothing left un-vendored.

> **Scope note.** Unlike the vendored *labs* (each reimplements a whole post),
> this is a **phase feature**: `phase1-chroot/lab-chroot.sh --rootless` adopts
> the *technique* from this post (`unshare -Ur` + `fakechroot` + `fakeroot` +
> `qemu-user-static`) rather than reproducing it end-to-end. Archived in full
> anyway, for parity and offline reference.

## Copyright & attribution

This post is the work of **Alex Bradbury**, and **all rights and copyright remain
with the author.** It is archived here solely as an offline, fixed-point
reference for Phase 1's rootless mode, which builds on his cross-architecture
`debootstrap` technique. For the authoritative, maintained version — and to
support the author — always go to the [canonical
page](https://muxup.com/2024q4/rootless-cross-architecture-debootstrap). If you
are the author and would prefer this copy not be redistributed, removing it is a
one-line `git rm`.
