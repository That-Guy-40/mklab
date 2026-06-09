# TODO — mklab

Project-level backlog, in the order raised (roughly: readiness, not priority).
For per-lab status see the phase `SHOWCASE.md`s and
[`examples/00-INDEX.md`](examples/00-INDEX.md); for the staged design see
[`PLAN.md`](PLAN.md). Large items should graduate to their own `*_LAB_PLAN.md`
(cf. [`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
[`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md)).

---

## 1. Crack the FLOPPINUX login hash (educational security exercise)

Demonstrate, **on our own throwaway lab artifact**, how weak a classic `$1$`
(MD5-crypt) password is. The 2.88 MB FLOPPINUX QoL + login build (`LOGIN=1`)
ships this account in `/etc/passwd`:

```
root:$1$floppinx$2WKWnHcP/VZpbTpD57PW30:0:0:root:/home:/bin/sh
```

The plaintext is already known (`lab`) — the point isn't to *learn* it, it's to
show the recovery and explain the *why*.

- [ ] Recover `lab` from the hash with `john` and/or `hashcat` + a small wordlist
      (e.g. rockyou); time it and record the exact command + wall-clock.
- [ ] Write up the WHY: `$1$` = MD5-crypt (1000 iterations, 8-char salt
      `floppinx`); why it's trivially crackable on a modern GPU/CPU versus `$6$`
      (SHA-512-crypt) or bcrypt/argon2; what the salt does (kills rainbow
      tables / shared-hash detection) and does **not** do (slow a targeted
      guess).
- [ ] Lab-hygiene takeaway: a published throwaway credential is fine for an
      air-gapped floppy in QEMU — and is exactly why you never ship `LOGIN=1` on
      a real network.
- [ ] Land it as a short doc under the lab (e.g.
      `examples/tiny-linux-experiments/floppinux/HASH_CRACKING.md`), linked from
      that README and `00-INDEX`.

Scope: our own hash, our own lab, educational — not targeting any third party.

## 2. Vendor an `upstream-tutorial/` copy for every tutorial-based lab

Promote the FLOPPINUX pattern to a **repo-wide convention**: any lab that
operationalizes an external write-up keeps a byte-exact, attributed archive of
that source *alongside* the operationalization — so the lab is reproducible
offline and its provenance is explicit.

Exemplar to copy:
[`examples/tiny-linux-experiments/floppinux/upstream-tutorial/`](examples/tiny-linux-experiments/floppinux/upstream-tutorial/)
— vendored HTML/CSS, a provenance table (title / author / canonical URL /
retrieved date), per-file `sha256`s, and a copyright/attribution note.

- [x] Audit `examples/` for labs derived from a *specific* external tutorial or
      blog post (candidates to confirm: the PXE / netboot labs, the
      kickstart / preseed galleries, the `kali-*` builders).
- [x] For each, add an `upstream-tutorial/` dir with the vendored source + a
      README matching the floppinux exemplar (provenance, `sha256`s, attribution).
- [x] Where a lab follows *official docs* rather than one page, capture the exact
      URLs + retrieval date + a note instead of mirroring whole doc sites.
- [x] Record the convention in [`CLAUDE.md`](CLAUDE.md) so future labs follow it.
- [x] Keep `tools/link_check.py` green (0 broken links) after every add.

**✅ Done 2026-06-07.** Six single-write-up labs vendored byte-exact under their
own `upstream-tutorial/` (HTML + CSS + `sha256`s + attribution, parent README
linked): five under `examples/` — `debian-http-boot/` & `almalinux-pxe-lab/` &
`rocky-pxe-lab/` (Kenneth Finnegan / CIQ write-ups), `kali-llm-lab/` &
`kali-llm-desktop-lab/` (the Kali Ollama+5ire blog, byte-identical copy in each
per self-containment) — plus `micro-linux/` (Uros Popovic's post; see the
*Closed* note below). Seven official-docs / upstream-wrapper labs got a dated
provenance note (URL + as-of date, not mirrored): `kali-pxe-lab/`,
`kali-preseed-gallery/`, `rocky-kickstart-gallery/`,
`ansible/almalinux-infra-ansible/`, `kali-nonroot-chroot/`, `offsec-awae-vm/`,
`kali-vm-builder/`. Convention recorded in `CLAUDE.md` › *Provenance*.
`link_check.py`: 0 broken.

**Closed 2026-06-07 (the two out-of-`examples/` items, once the user supplied
the URLs):**
- **`micro-linux/`** — full-vendored: Uros Popovic's *"Making a micro Linux
  distro"* (<https://popovicu.com/posts/making-a-micro-linux-distro/>, published
  2023-09-21) archived byte-exact under `micro-linux/upstream-tutorial/` (HTML +
  3 CSS + provenance + `sha256`s); linked from `micro-linux/README.md` and the
  plan's status line — which finally gives the plan's ~20 "the source post"
  references a resolvable canonical URL. The archive README notes the deliberate
  "adaptation in the spirit of" divergence (plan §1.1 / §11).
- **`phase1-chroot --rootless`** — full-vendored (a phase feature, but archived
  for parity at the user's request): Alex Bradbury's *"Rootless cross-architecture
  debootstrap"*
  (<https://muxup.com/2024q4/rootless-cross-architecture-debootstrap>, published
  2024-12-03) archived byte-exact under `phase1-chroot/upstream-tutorial/` (a
  single self-contained HTML — inline CSS + inline `data:` SVG — + provenance +
  `sha256`). Linked from `phase1-chroot/README.md`; the exact URL is also in the
  two PLAN.md mentions.

## 3. Container lab to hand-implement each upstream tutorial

Stand up a disposable container (Docker / Podman / Incus / LXD — chosen per
tutorial) that gives a clean, repeatable environment to **walk each upstream
tutorial by hand, step-by-step** — distinct from the automated `build-*.sh`
operationalization. Value: a sandbox to learn the recipe manually, and a way to
catch upstream drift against our scripts.

- [x] Pick the runtime per tutorial (rootless Phase-4 podman for all seven;
      `--cap-add SYS_ADMIN` where `binfmt`/chroot needs it; the author's distro
      as base where the tutorial is distro-specific).
- [x] Reuse the existing phases instead of one-off containers: each `hand-walk/`
      ships a `Containerfile` driven via `lab-podman.sh build`/`up` (`build =`).
- [x] Per tutorial: a `Containerfile` + a `RUNBOOK.md` pointing at the
      `upstream-tutorial/` copy from item 2, + a 00-INDEX entry + parent inbound link.
- [x] ~~Start with FLOPPINUX~~ → **started with micro-linux instead** (fully
      unblocked: apt cross-toolchain, pure TCG, no devices, no fetch gate — the one
      lab the agent can build *and* boot to verify end-to-end). FLOPPINUX turned out
      to be the *worst* first pick: it hits **both** the `musl.cc` fetch gate **and**
      loop-mount/`mknod` (blocked in-sandbox even `--privileged`) — both are
      author-only. (The TODO's "container sidesteps the gate" claim is **half-true**:
      the layer is a clean artifact, but an *agent-triggered* `podman build` of a
      musl.cc fetch is still gated — the classifier reads the Containerfile; the
      *user* runs that build.)
- [x] Catalog the container labs in [`examples/00-INDEX.md`](examples/00-INDEX.md)
      (§ *🚶 Hand-walk the tutorials*).

**✅ Done 2026-06-08.** Seven `hand-walk/` sandboxes, each = Containerfile (the
author's environment as code) + RUNBOOK (the post by hand, with the *why*) +
00-INDEX entry + parent inbound link; `link_check.py` green. Split by what the
build sandbox can run:
- **Agent built + boot/run-verified end-to-end:** `micro-linux/` (kernel→`init.c`→
  u-root boots), `phase1-chroot/` (muxup rootless foreign debootstrap, `uname -m
  → riscv64`), `examples/debian-http-boot/` (fakeroot debootstrap + initrd + iPXE),
  `examples/almalinux-pxe-lab/` (iPXE EFI build + dnsmasq config).
- **Agent built env + verified the tractable parts; one step author-only:**
  `examples/rocky-pxe-lab/` (box + `lorax`/`dnsmasq`/`tftp` present; the **Lorax
  run** needs loop → host), `examples/tiny-linux-experiments/floppinux/` (Arch env
  verified; **musl.cc fetch + `mknod`/loop floppy** → host).
- **Authored, you-build:** `examples/kali-llm-lab/` (multi-GB Kali + model; Ollama
  is a fetch-and-exec you authorize — RUNBOOK §1 sha512-verifies it).

Convention recorded in `CLAUDE.md` › *Hand-walk sandboxes*. Three real prereq
gotchas the "reproduce the env" exercise surfaced + fixed: `libc6-dev-riscv64-cross`
(hosted-C cross), `build-essential` not bare `gcc` (iPXE host helper needs
`<stdint.h>`), `fakeroot`+`systempaths=unconfined` (rootless debootstrap `mknod` +
`unshare --mount-proc`).

## 4. Net-booted, RAM-resident infrastructure images (immutable infra; reboot = newest build)

Explore **stateless infrastructure nodes** that PXE/iPXE-boot a kernel + initramfs
**entirely into RAM** (the initramfs *is* the root fs — no OS on local disk), so a
**reboot re-pulls the latest image**: update centrally, reboot the fleet, done.
Where a role needs persistent data, the **OS stays ephemeral** and only the *state*
is mounted from elsewhere — local disk (a ZFS pool) or network storage
(iSCSI/NFS) — attached by `/init` or an early systemd unit, never baked into the
image. Boot transport is HTTP **and HTTPS**, so nodes can boot over a LAN *or* the
open internet.

This is the immutable-infrastructure / "golden image" pattern, and the repo
already has the load-bearing mechanic: [`examples/debian-http-boot/`](examples/debian-http-boot/)
boots a whole systemd Debian from a single gzipped-cpio initramfs over HTTP
(Kenneth Finnegan's hand-rolled `/init`). The work here is to grow that one trick
into *role-specific* infra images and the serving/state plumbing around them.

**Candidate roles (each a lab):**
- **AnyCast DNS node** — RAM OS + an authoritative DNS server; the **zone/record
  database is the state** (mounted from local disk or fetched at boot). Announce
  the anycast prefix (BGP via `bird`/ExaBGP) **only while healthy**, withdraw on
  failure — the point of anycast. Models Gandi's design (ref below).
- **CDN edge** — RAM OS + a local **ZFS pool** holding the cache/content
  (persists across reboots though the OS doesn't); cache/webserver (nginx/varnish)
  runs from RAM.
- **Lightweight package mirror** — RAM OS, the mirror tree mounted over **iSCSI**,
  webserver served from RAM. Rebuild the image whenever; a reboot picks it up.

**Sketch / sub-tasks:**
- [ ] Boot path: iPXE (the [`EMBED=` script pattern](examples/debian-http-boot/upstream-tutorial/))
      chainloading kernel + initramfs over **HTTP and HTTPS**; reuse the repo's
      netboot pipeline ([`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
      [`netboot/`](netboot/), [`examples/pxe-boot-mechanics/`](examples/pxe-boot-mechanics/)).
- [ ] **Image integrity is non-negotiable here** — "reboot pulls newest" must mean
      *newest **verified***, not "trust whatever the server returns." Sign the
      kernel+initramfs (or pin a hash / TLS cert), in the spirit of the repo's
      verified-download ethos (`micro-linux` gpgv + `versions.lock`). Booting
      executable code over the internet is a supply-chain surface — treat it like one.
- [ ] Stateless-OS + externalized-state split: the image is ephemeral; `/init` (or
      a systemd unit) mounts ZFS / iSCSI / NFS for the *data* after boot. One
      state model documented per role.
- [ ] Health-gated service announce (anycast): bring the route up only when the
      service answers; pull it on failure.
- [ ] Versioned / A-B images so a bad build rolls back by booting the prior one.
- [ ] Build the images on existing foundations — [`micro-linux/`](micro-linux/)
      (from-source kernel+initramfs; the `--baked` single-file blob is ideal to
      sign+serve) and/or [`phase1-chroot/`](phase1-chroot/) (debootstrap the rootfs)
      → packed like `debian-http-boot`'s initramfs.
- [ ] Per the conventions: **vendor** the Gandi post (CLAUDE.md › *Provenance*),
      add **hand-walk** sandboxes (CLAUDE.md › *Hand-walk sandboxes*), and a
      [`examples/00-INDEX.md`](examples/00-INDEX.md) entry for each lab.

Large — likely graduates to its own `*_LAB_PLAN.md` (cf.
[`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md)), perhaps split per role.

**References:**
- Gandi, *Booting an anycast DNS network* (2019) —
  <https://news.gandi.net/en/2019/03/booting-an-anycast-dns-network/> (the
  10,000-ft view; **vendor when the lab is built**).
- Kenneth Finnegan, *Booting Linux over HTTP* (2020) —
  <https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html> —
  **already vendored** at [`examples/debian-http-boot/upstream-tutorial/`](examples/debian-http-boot/upstream-tutorial/);
  the RAM-root-over-HTTP building block.

---

*Created 2026-06-06.*
