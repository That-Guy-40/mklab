# Upstream tutorials — archived copies

This lab operationalizes **two** write-ups about OpenStack **VirtualBMC**, vendored
here **byte-exact** for offline reference and provenance (sources move, rot, or get
paywalled). The lab adapts both to *this* host (Ubuntu 24.04, `vbmcd` in a
container, a PXE provisioning bridge), so the originals are kept verbatim as the
fixed-point source of truth.

- **siberoloji** — the conceptual VirtualBMC/KVM walk on **AlmaLinux** (install,
  `vbmc add/start/list/show`, the `ipmitool … power` verbs). The repo's
  loopback creds (`admin`/`password`) come straight from this page.
- **server-world** — the **Ubuntu 24.04** host recipe: install VirtualBMC into a
  `/opt/virtualbmc` venv behind a `systemd` unit, then `vbmc add` + `ipmitool`,
  including the **remote** `--libvirt-uri qemu+ssh://…` variant. This is the page
  the lab's host-install instructions track.

## Provenance

| | siberoloji | server-world |
|---|---|---|
| **Title** | *How to Use VirtualBMC on KVM with AlmaLinux* | *Ubuntu 24.04 : KVM : Use VirtualBMC* |
| **Author / publisher** | Siberoloji | Server World |
| **Canonical URL** | <https://www.siberoloji.com/virtualbmc-kvm-almalinux/> | <https://www.server-world.info/en/note?os=Ubuntu_24.04&p=kvm&f=14> |
| **Published** | 2024-12-11 (modified 2025-12-05) | © 2007–2026 |
| **Retrieved** | 2026-06-23 | 2026-06-23 |

## Files

| File | sha256 |
|---|---|
| [`siberoloji/virtualbmc-kvm-almalinux.html`](siberoloji/virtualbmc-kvm-almalinux.html) | `057787a98ab1f31b78b4a6f9f1b88d95fb58716ab4e700a578bc245d5f46ba12` |
| [`siberoloji/scss/main.min.130bb094bf37923b92b213d57fe43065ccbb78deea2c22c9ba41e0f7fa7279b7.css`](siberoloji/scss/main.min.130bb094bf37923b92b213d57fe43065ccbb78deea2c22c9ba41e0f7fa7279b7.css) | `130bb094bf37923b92b213d57fe43065ccbb78deea2c22c9ba41e0f7fa7279b7` |
| [`siberoloji/css/prism.css`](siberoloji/css/prism.css) | `2614cb234c8d8f03c4bd863f78314ffb7a8e535efaa166a240a08b88d0a7109f` |
| [`siberoloji/css/katex.min.css`](siberoloji/css/katex.min.css) | `f0d32ef2437ef1b96991f84805c1da150873c774eb90eebb67d61ed9c7462e93` |
| [`server-world/ubuntu-2404-kvm-virtualbmc.html`](server-world/ubuntu-2404-kvm-virtualbmc.html) | `608b480ccaae60c5df0249eb0b47b30ebaa4d35dcec6a912832679284f2ef298` |
| [`server-world/css/base.css`](server-world/css/base.css) | `d3b1783e2b41ed445b89f728c49c987a74297e508db9548742d51992232972f8` |
| [`server-world/css/navi.css`](server-world/css/navi.css) | `61465a61e9f0f07ee25bf4885f36e1d22f9510b273355f3f41325d82c8064af9` |
| [`server-world/css/main.css`](server-world/css/main.css) | `9b0a7ac28ce5305fe2bc6536c747b24d42b2e4659474dcb2995ade5b7da08270` |

The siberoloji main stylesheet's filename **is** its sha256 (Hugo's content
fingerprint), so its hash matches its name — a nice built-in integrity check.

### Rendering offline

- **server-world** references its CSS by *relative* path (`./css/base.css` …), so
  opening `server-world/ubuntu-2404-kvm-virtualbmc.html` directly from disk
  (`file://`) renders fully styled with no network.
- **siberoloji** references its CSS by *absolute* root path (`/scss/…`, `/css/…`),
  which `file://` can't resolve to the local copies. To see it fully styled, serve
  the subdir as a docroot — `python3 -m http.server -d siberoloji` then open
  `http://localhost:8000/virtualbmc-kvm-almalinux.html`. The HTML is kept
  **byte-exact** rather than rewritten, so the archive stays a faithful copy.

## What's left un-vendored

Images, JavaScript, fonts, and the KaTeX/PrismJS web-font and icon assets are
**not** mirrored — their absolute links resolve against the live sites and are not
needed to read either tutorial offline. Only each page's HTML plus its primary
CSS is archived.

## Copyright & attribution

These tutorials are the work of **Siberoloji** and **Server World** respectively,
and **all rights and copyright remain with their authors.** They are archived here
solely as offline, fixed-point references for the [`../`](../) lab, which adapts
their VirtualBMC recipes to this host. For the authoritative, maintained
versions — and to support the authors — always go to the canonical pages linked
above. If you are an author and would prefer your copy not be redistributed,
removing it is a one-line `git rm`.
