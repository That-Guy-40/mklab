# Upstream provenance — Philip Hands' "Hands-Off" framework

This lab **operationalizes** Philip Hands' *Hands-Off* Debian-installer preseed
framework. Per the repo's provenance convention, an upstream that is **live,
maintained code** (not a single frozen page) is **cited + fetched (pinned)**,
not wholesale-vendored into this repo. So nothing under `hands-off`'s tree is
committed here — [`fetch-hands-off.sh`](fetch-hands-off.sh) clones it on demand,
pinned to a specific commit.

## Provenance

| Field | Value |
|---|---|
| Project | *"Hands-Off" Debian Installation* |
| Author | Philip Hands `<phil@hands.com>` (Debian Developer) |
| Home / docs | <https://hands.com/d-i/> |
| Git (upstream) | `http://git.hands.com/hands-off.git` |
| Pinned commit | `ec6e817a26419dcdb5a9e4c74377477bbc846ea4` |
| Pinned date | 2026-05-18 |
| Retrieved | 2026-07-03 |
| License | GNU GPL v2 or later (see `preseed/COPYING` in the checkout) |

`fetch-hands-off.sh` carries the same pinned commit; bump both together when you
re-pin.

## What we use vs. what we add

- **From upstream (unmodified, served verbatim):** the whole `trixie/` tree —
  `preseed.cfg`, `checksigs.sh`, `start.sh`, `assemble_preseed.sh`, `classes/`,
  `files/`, `MD5SUMS`/`.sig`/`trustedkeys.gpg`. The framework's machinery is
  Phil's; we run it as-is.
- **What this lab adds (in *this* repo):** `fetch-hands-off.sh`,
  `setup-hands-off.sh`, and a small `lab-overlay/local/` — the framework's own
  intended **site-customization hook** (see `preseed/local/README` upstream) —
  which makes the minimal default install unattended for a single-disk lab VM.

## The two integrity modes (see `setup-hands-off.sh`)

- **Unsigned** (default): the lab `local/` overlay isn't in upstream's signed
  `MD5SUMS`, so we boot with `hands-off/checksigs=false` (the framework's own
  switch) to skip the gpgv bootstrap. Still exercises the full class assembly.
- **Signed** (`setup-hands-off.sh --sign`): regenerate `MD5SUMS` over the staged
  tree (incl. our overlay), sign it with a **throwaway lab key**, and replace
  `trustedkeys.gpg` — the real "mirror it, add your site config, re-sign with
  your key" workflow. The lab key is *not* a trust anchor; it demonstrates the
  mechanism.

## Attribution

The Hands-Off framework is © 2005–2025 Philip Hands (and contributors, incl.
Daniel Dehennin), GPL-2+. All rights remain with the upstream authors; this lab
merely drives it. To remove the local checkout: `rm -rf ~/hands-off-src`.
