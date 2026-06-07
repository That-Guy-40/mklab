# Upstream tutorial — archived copy

An **unmodified, byte-exact archive** of the blog post that this lab is built
around, vendored here for offline reference and provenance.

| | |
|---|---|
| **Title** | *Making a micro Linux distro* |
| **Author** | Uros Popovic |
| **Canonical URL** | <https://popovicu.com/posts/making-a-micro-linux-distro/> |
| **Site home** | <https://popovicu.com/> |
| **Published** | 2023-09-21 |
| **Retrieved** | 2026-06-07 |

## Files

| File | sha256 |
|---|---|
| [`making-a-micro-linux-distro.html`](making-a-micro-linux-distro.html) | `f08778642b2a067e0693aae9b62883f43855f10d4663e395d966092d808af13d` |
| [`style.css`](style.css) | `4ecf55c526bc01de2c2773f9881d9c0bef99559f45c4eef65408a70c06c16c97` |
| [`post.css`](post.css) | `060f1d60ea3755db67d3aff23bcc0d50da198a2babafa5601163db796d380cc3` |
| [`chroma.css`](chroma.css) | `1746837baca1449656cb8f421eec178502a51563c2b6a8c69af9fe8c479867ad` |

The HTML is saved exactly as served; the site's three local stylesheets
(`/static/css/style.css`, `/static/css/post.css`, `/css/chroma.css` — the last is
the syntax-highlighter theme) are vendored alongside so the page renders styled
with no network. The Google-Fonts stylesheet is **left as-is** (a remote font
loader, not needed to read the post offline); the post has no inline images.

> **Fidelity note.** This lab is an **adaptation *in the spirit of*** this post,
> not a transcription — the source targets **riscv64** with a hand-written C
> `init` → `little_shell` and plain cpio, while the lab's default tracks differ.
> See [`../../MICRO_LINUX_LAB_PLAN.md`](../../MICRO_LINUX_LAB_PLAN.md) §1.1
> *"Fidelity & deltas"* and §11 *"Faithful track"* (which reproduces the post's
> exact riscv64 + u-root + plain-cpio recipe) for the precise deltas.

## Copyright & attribution

This post is the work of **Uros Popovic**, and **all rights and copyright remain
with the author.** It is archived here solely as an offline, fixed-point
reference for the [`../`](../) lab, which generalizes his micro-distro recipe into
a reproducible, multi-arch build pipeline. For the authoritative, maintained
version — and to support the author — always go to the [canonical
page](https://popovicu.com/posts/making-a-micro-linux-distro/). If you are the
author and would prefer this copy not be redistributed, removing it is a one-line
`git rm`.
