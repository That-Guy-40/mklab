# TODO — mklab

Project-level backlog, in the order raised (roughly: readiness, not priority).
For per-lab status see the phase `SHOWCASE.md`s and
[`examples/00-INDEX.md`](examples/00-INDEX.md); for the staged design see
[`PLAN.md`](PLAN.md). Large items should graduate to their own `*_LAB_PLAN.md`
(cf. [`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
[`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md)).

---

## 0. Next up — the three things nearest the front of the queue

*Added 2026-08-07.* The list below is otherwise **in the order raised, not priority**, so
this section exists to say what is actually next. All three are micro-cloud debts, all
three are small-to-medium, and each is **blocked on packaging or on a host, never on a
question nobody has answered**.

They are deliberately stated as what is **NOT** done, because two of them are the shape
this repo keeps getting caught by: *the experiment is finished, so the item feels finished.*
It is not — an experiment nobody can re-run is a story.

| # | what | state |
|---|---|---|
| **0.1** | **`examples/nested-calico-sandbox/` — the lab unit** | ⚠️ **the experiment is DONE; the packaging is not.** [Appendix O](MICRO_CLOUD_LAB_PLAN.md#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07) has the whole recipe and it reproduces **unprivileged in ~15 minutes**. What is missing is the cohesive-lab shape: a phase-2 `.toml`, `README.md`, `MANUAL_TESTING.md`, a `tests/` harness **carrying the delete-the-winner control**, a 00-INDEX row and a `learning-paths.toml` route. Detail in [§9](#9-nested-calico-sandbox--a-disposable-cluster-so-the-cni-beliefs-can-be-tested) |
| **0.2** | **G.9's remaining break-pass scenario** | **partly answered, not closed.** DHCP exhaustion is green; `retap` is green. What remains is *give a **`fabric.sh` tap** an address on purpose and watch it become a candidate* — [G.9](MICRO_CLOUD_LAB_PLAN.md#g9-not-run--recorded-as-unknown-not-as-pass). Appendix O measured the **property** with a dummy interface in a guest at Calico v3.29.3; **a dummy in a guest and a tap on `br-mc0` are not the same subject**, and this host runs v3.28.1. Needs 0.1 |
| **0.3** | **the fabric's own teardown code, under a live agent** | **named as not covered** by [`test-vsock-chaos.sh`](examples/micro-cloud/tests/test-vsock-chaos.sh). Its network row severs the guest's link with `set_link down`, which is a *superset* of losing the bridge — so the **property** is measured — but `fabric.sh down`'s teardown path is never exercised with a guest attached. **A stronger fault does not imply the weaker one ran**; that is why the matrix says so instead of letting it pass quietly. Root-gated |

- [x] **0.1** ✅ **DONE 2026-08-07** — [`examples/nested-calico-sandbox/`](examples/nested-calico-sandbox/):
      spec, driver, guest experiment, stamped `findings.env`, four tests, 00-INDEX row,
      `learning-paths` route. The harness refuses to compare across a Calico mismatch,
      naming both versions. [Appendix Q](MICRO_CLOUD_LAB_PLAN.md#appendix-q--the-sandbox-packaged-g9-closed-on-the-real-artifact-2026-08-07)
- [x] **0.2** ✅ **DONE 2026-08-07** — G.9 closed **on the real artifact**: a genuine
      `fabric.sh` tap, given an address on purpose, captured the guest cluster's tunnel.
      F.6 reproduced deliberately, at Calico v3.29.3.
- [x] **0.3** ✅ **DONE 2026-08-07** — the vsock chaos matrix has a `fabric.sh down beneath a
      live agent` row. Root-gated; a skip reports **UNCOVERED** rather than folding into the pass.

**0.4 — the flaky-CI shape, partly fixed** *(added 2026-08-07, after main went red twice)*.
`producer | grep -q PATTERN || fail` is wrong in two independent ways when the thing being
asserted is a **container's** state: the state is *eventual* (a tool returning is not the
container having done the thing), and `grep -q` exits on first match, closes the pipe, and
the producer can die on SIGPIPE — which under `pipefail` reports the **pipeline** as failed
though the match was found. That inversion is now on its **fifth** recorded instance here.

`await_line` / `await_match` in `phase3-docker/tests/lib.sh` and
`phase4-podman/tests/lib.sh` capture first and test second, with a deadline, and were
watched to fail on a needle that never arrives.

- [x] **0.4** ✅ **DONE 2026-08-07.** All 13 sites classified rather than swept, and the
      classification changed the plan: three of them were `&& fail` — **eventual absence** —
      where the inversion fails in the *dangerous* direction. A SIGPIPE'd producer makes the
      pipeline non-zero, `&& fail` never runs, and *"container still present after destroy"*
      reports a **pass**. Demonstrated, not argued: `producer | grep -qx name` over 200k
      lines returns **141** and the assertion silently skips.
      That also corrects this entry's own rule. *"A negative assertion must not gain a
      retry"* is true of an **invariant** ("must never appear") and false of **eventual
      absence** ("must be gone after this action") — which all three were. They now use
      `await_absent`.
      Converted by class: 3 eventual-absence → `await_absent`; 2 eventual-presence →
      `await_line`; 4 immediate → `has_line`/`has_match` (capture-then-test, no pointless
      retry); 4 `yq --version` precondition guards and 1 file-grep left alone.
      [`tools/tests/test-no-pipe-gates.sh`](tools/tests/test-no-pipe-gates.sh) now gates the
      **silent** variant repo-wide and inventories the 8 remaining noisy `|| fail` sites
      without gating them — the first draft flagged all 30 hits including its own
      documentation, which would have bred exemptions until it meant nothing.

## 1. Crack the FLOPPINUX login hash (educational security exercise)

Demonstrate, **on our own throwaway lab artifact**, how weak a classic `$1$`
(MD5-crypt) password is. The 2.88 MB FLOPPINUX QoL + login build (`LOGIN=1`)
ships this account in `/etc/passwd`:

```
root:$1$floppinx$2WKWnHcP/VZpbTpD57PW30:0:0:root:/home:/bin/sh
```

The plaintext is already known (`lab`) — the point isn't to *learn* it, it's to
show the recovery and explain the *why*.

- [x] Recover `lab` from the hash with `john` and/or `hashcat` + a small wordlist
      (e.g. rockyou); time it and record the exact command + wall-clock.
- [x] Write up the WHY: `$1$` = MD5-crypt (1000 iterations, 8-char salt
      `floppinx`); why it's trivially crackable on a modern GPU/CPU versus `$6$`
      (SHA-512-crypt) or bcrypt/argon2; what the salt does (kills rainbow
      tables / shared-hash detection) and does **not** do (slow a targeted
      guess).
- [x] Lab-hygiene takeaway: a published throwaway credential is fine for an
      air-gapped floppy in QEMU — and is exactly why you never ship `LOGIN=1` on
      a real network.
- [x] Land it as a short doc under the lab (e.g.
      `examples/tiny-linux-experiments/floppinux/HASH_CRACKING.md`), linked from
      that README and `00-INDEX`.

Scope: our own hash, our own lab, educational — not targeting any third party.

**✅ Done 2026-07-23.** [`HASH_CRACKING.md`](examples/tiny-linux-experiments/floppinux/HASH_CRACKING.md)
+ a self-contained [`crack.py`](examples/tiny-linux-experiments/floppinux/crack.py)
(pure-Python md5crypt — works on 3.13+ where `crypt` is gone; no install/network).
Recovers `lab`: recompute-verify (`openssl passwd -1` byte-matches), dictionary
(15-word list, **3.2 ms**), exhaustive `[a-z]³` (7438/17576, **~2.1 s** single-thread
pure-python; a compiled `crypt(3)` ~4× faster, john/hashcat millions/s). WHY
written up (MD5-crypt = 1000 MD5 rounds = fast; salt kills rainbow tables + shared-
hash detection but does NOT slow a *targeted* guess; `$6$`/bcrypt/Argon2 table).
Linked from the lab README (Files + ⚠️ Security) and 00-INDEX; `john`/`hashcat`
commands documented (author-run — not installed here). link_check green.

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

**GRADUATED to [`RAM_INFRA_LAB_PLAN.md`](RAM_INFRA_LAB_PLAN.md) (2026-07-23).**
Flagship role **`examples/anycast-dns-ram/`** landed; two of the four new
mechanics are built + verified. Remaining roles/mechanics tracked in the plan.

**Sketch / sub-tasks:**
- [x] Boot path: iPXE chainloading kernel + initramfs over **HTTP and HTTPS** —
      already provided by the mature netboot pipeline (`netboot/`,
      `pxe-boot-mechanics/`); the RAM-infra labs reuse it.
- [x] **Image integrity (non-negotiable) — DONE & verified.** Payload signing +
      iPXE **`imgverify`** + A/B rollback: [`netboot/sign-payload.sh`](netboot/sign-payload.sh)
      + `build-ipxe.sh --imgverify --payload-trust`; proven 3/3 headless (signed
      boots, tampered rolls back, both-tampered refuses) in
      [`netboot/MANUAL_TESTING.md`](netboot/MANUAL_TESTING.md) §13. Closes **F2**.
- [x] Health-gated service announce (anycast) — **DONE & verified.** ExaBGP
      health-gate + bird2 collector in [`examples/anycast-dns-ram/`](examples/anycast-dns-ram/)
      (`demo-anycast.sh` → PASS: announce while healthy, withdraw on failure,
      re-announce on recovery).
- [x] Versioned / A-B images so a bad build rolls back by booting the prior one —
      **DONE** (the iPXE `imgverify` boot script's `current`→`previous` rollback).
- [x] Stateless-OS + externalized-state split (`/init` mounts ZFS/iSCSI/NFS) —
      **DONE.** **ZFS (cdn-edge)** verified ([`examples/cdn-edge-ram/`](examples/cdn-edge-ram/) —
      `demo-cdn-state.sh` PASS: a fresh OS imports a ZFS cache pool + serves the
      survivor content over HTTP). **network NFS/iSCSI (package-mirror)** —
      [`examples/package-mirror-ram/`](examples/package-mirror-ram/): the
      `||`-guarded `state-mount.sh` verified docker-free
      (`test-state-mount-guard.sh` PASS); the live mount is author-run (touches
      host-global kernel state; ready-to-run ganesha/tgt recipes shipped).
- [x] Build on existing foundations — flagship image spec
      [`anycast-dns-chroot.toml`](examples/anycast-dns-ram/anycast-dns-chroot.toml)
      debootstraps the stack; `micro-linux --baked` used as the verify spike payload.
- [x] Vendor the Gandi post + [`examples/00-INDEX.md`](examples/00-INDEX.md) entry —
      done for the flagship. (Hand-walk N/A: the Gandi post is a design overview,
      not a step recipe → cite+vendor, and `demo-anycast.sh`'s container already
      reproduces the environment.)

**Still open (follow-on passes):** the **cdn-edge-ram** (ZFS state) and
**package-mirror-ram** (iSCSI/NFS state) roles — see
[`RAM_INFRA_LAB_PLAN.md`](RAM_INFRA_LAB_PLAN.md) §4b/§4c.

**References:**
- Gandi, *Booting an anycast DNS network* (2019) —
  <https://news.gandi.net/en/2019/03/booting-an-anycast-dns-network/> (the
  10,000-ft view; **vendor when the lab is built**).
- Kenneth Finnegan, *Booting Linux over HTTP* (2020) —
  <https://blog.thelifeofkenneth.com/2020/03/booting-linux-over-http.html> —
  **already vendored** at [`examples/debian-http-boot/upstream-tutorial/`](examples/debian-http-boot/upstream-tutorial/);
  the RAM-root-over-HTTP building block.

## 5. AlmaLinux: demo + automated run (RHEL-family `rd.break`, mirror Rocky)

The AlmaLinux sibling of the Rocky root-password-reset work
([`setup-rocky-target.sh`](examples/root-password-reset/setup-rocky-target.sh) +
[`reset-demo-rocky.sh`](examples/root-password-reset/reset-demo-rocky.sh)) — a
hand-walk on-ramp + a hands-off serial-driven **`rd.break`** proof on a real
AlmaLinux 9. AlmaLinux is RHEL-family, so the method is identical to Rocky's
(dracut initramfs → `chroot /sysroot` → `passwd` → `touch /.autorelabel` → SELinux
relabel) and the scripts should port nearly verbatim — including the grub2 serial
char-drop fix (`serial-drive.py --char-delay 0.08`) and the **editor-append** for
`rd.break`.

**Primary / first subproject — port the kickstart gallery to AlmaLinux:**
- [x] `examples/almalinux-kickstart-gallery/` ported from
      [`examples/rocky-kickstart-gallery/`](examples/rocky-kickstart-gallery/):
      `fetch-kickstarts.sh` + `select-kickstart.sh` + the unified P4+P2 TOML +
      README + MANUAL_TESTING. Point it at AlmaLinux's upstream kickstart catalog
      (find the AlmaLinux equivalent of `rocky-linux/kickstarts`) and reuse
      [`examples/almalinux-pxe-lab/`](examples/almalinux-pxe-lab/)'s installer fetch
      (`vmlinuz`/`initrd.img`/`install.img`) the way the Rocky gallery reuses
      `rocky-pxe-lab/fetch-rocky-installer.sh`.
- [x] Same gallery patches as Rocky where needed (`shutdown`→`reboot`, unlock root
      via `--root-pw`, `/dev/vda` pinning if any kickstart hardcodes a disk).
      Provenance: a dated note (official upstream catalog → cite, don't mirror).
      *(AlmaLinux's were Packer kickstarts hardcoding `/dev/sda` → the `/dev/vda`
      rewrite is REQUIRED here, not the no-op it is for Rocky; gencloud install
      boot-verified end-to-end on KVM, root/lab, AlmaLinux 9.8.)*

**Then the reset pair (mirror the Rocky scripts):**
- [x] `examples/root-password-reset/setup-almalinux-target.sh` +
      `reset-demo-almalinux.sh` — build via the new gallery (`gencloud`),
      pre-stage (widen GRUB `--timeout` via `grub2-mkconfig`), then serial-drive the
      `rd.break` reset + verify *old-rejected / new-`uid=0`* with the relabel applied.
      *(VERIFIED end-to-end on KVM 2026-06-11, first attempt: Ctrl-n×3 to the BLS
      `linux` line carries over from Rocky; one AlmaLinux difference — gencloud bakes
      `bootloader --timeout=0`, a hidden menu, so the pre-stage also sets
      `GRUB_TIMEOUT_STYLE=menu`.)*
- [x] `almalinux.toml` in the reset lab, delegating to the gallery (mirrors
      `rocky.toml` / `kali.toml`); update `RUNBOOK-rd-break.md` (note AlmaLinux),
      the README matrix, MANUAL_TESTING; add a 00-INDEX entry; keep `link_check.py`
      green.

Exemplars: the just-built Rocky pair +
[`examples/rocky-kickstart-gallery/`](examples/rocky-kickstart-gallery/);
[`examples/kali-preseed-gallery/`](examples/kali-preseed-gallery/) (the gallery shape).

## 6. UEFI variant of each root-password-reset method

The lab already argues the reset is **firmware-agnostic** with a Debian
**BIOS + UEFI pair** ([`debian-bios.toml`](examples/root-password-reset/debian-bios.toml)
verified; [`debian-uefi.toml`](examples/root-password-reset/debian-uefi.toml) on
OVMF, author-run). Round that out: a **UEFI variant of every method/distro**, using
`debian-uefi.toml` as the exemplar — once you reach the GRUB editor the steps are
identical; only *getting to the menu* differs (OVMF shows its own phase first; on
EFI the loader may be systemd-boot, also `e`).

- [x] Verify the existing [`debian-uefi.toml`](examples/root-password-reset/debian-uefi.toml)
      end-to-end (currently author-run) — reach GRUB over serial under OVMF, run the
      `init=/bin/bash` reset — to lock in the exemplar.
- [x] **Kali UEFI** — a UEFI build of the preseed-gallery target (drop `firmware`,
      set `pxe_bootfile = "ipxe.efi"` per the gallery README) + the `init=/bin/bash`
      reset under OVMF. *(Authored as an author-run recipe in RUNBOOK-init-shell.md —
      firmware-agnostic once at the GRUB menu, which the verified Debian/UEFI run
      proves; the heavy gallery-under-OVMF install is the author-run part.)*
- [x] **Rocky / AlmaLinux UEFI** — a UEFI build of the kickstart-gallery target +
      the `rd.break` reset under OVMF. *(Authored, author-run, in RUNBOOK-rd-break.md
      with the EFI specifics: `grub.cfg` under `/boot/efi/EFI/<distro>/` → the
      `grub2-mkconfig` target changes; Secure Boot's shim→grubx64 chain + the
      GRUB-password interaction; OVMF secboot vs non-secboot variant.)*
- [x] **systemd debug shell** — note the UEFI path if it differs. *(RUNBOOK-systemd-
      debug-shell.md: firmware-agnostic — same `e`/cmdline edit; only the GRUB-
      password/Secure-Boot caveat.)*
- [x] Extend the README firmware matrix to each method × BIOS/UEFI; add 00-INDEX
      coverage; keep `link_check.py` green.

**✅ Done 2026-07-23.** The headline item — **`debian-uefi.toml` verified end-to-end
under OVMF/KVM** (`BdsDxe`/`EDK II` boot-manager phase → `Welcome to GRUB!` over
serial → the full `init=/bin/bash` reset → old pw `Login incorrect`, new pw
`uid=0(root)`; every step EXPECT-confirmed live, rc=0). Evidence in
[`MANUAL_TESTING.md`](examples/root-password-reset/MANUAL_TESTING.md) → *Debian
UEFI/OVMF — verified end-to-end*; `debian-uefi.toml` STATUS flipped to ✅ verified;
README firmware-axis note + matrix updated (init-shell now **BIOS + UEFI**). The
other distros' UEFI variants (Kali/Rocky/AlmaLinux) + the systemd debug shell are
**authored as author-run recipes** in the RUNBOOKs — each is `firmware = "uefi"`
gallery build + the *identical* in-menu reset, and the verified Debian/UEFI run is
the load-bearing "firmware-agnostic" proof. `link_check` green.

Exemplar: [`debian-uefi.toml`](examples/root-password-reset/debian-uefi.toml) + the
firmware-axis note in
[`examples/root-password-reset/README.md`](examples/root-password-reset/README.md)
(`lab-vm.sh` `firmware = "uefi"` = OVMF/edk2).

## 7. Vendor the official **Packer** image-builder repos (Kali first, then AlmaLinux) — whole + automated

Both Kali and AlmaLinux publish a **Packer-based image-builder repo** that produces
their official cloud/VM images. AlmaLinux's is
[`AlmaLinux/cloud-images`](https://github.com/AlmaLinux/cloud-images) — the *same*
repo the [`almalinux-kickstart-gallery`](examples/almalinux-kickstart-gallery/)
already pulls its `http/*.ks` kickstarts from, but here we want the **whole Packer
builder**, not just the kickstarts. Kali has an equivalent (URL **to be supplied by
the user** — see the prerequisite). Each lab has **two halves**: (a) the upstream
repo **vendored in full**, runnable **per its own instructions** (offline,
byte-faithful), and (b) an **mklab automation wrapper** that drives the Packer build
through the existing phases.

> **Vendoring note (deliberate exception).** CLAUDE.md's default for "follows
> upstream *code*" is *cite, don't mirror* — but the explicit requirement here is to
> have each builder **available in whole to run per the repo's own instructions**,
> so this is a **full vendor**: pin the exact upstream **commit** + a **Retrieved**
> date, keep the upstream **LICENSE**, and add a provenance `README.md` (a
> `git rm`-to-remove note). Decide submodule-pin vs. flattened copy when starting;
> a flattened copy is more self-contained (matches the repo's offline ethos).

**Prerequisite — do this FIRST, before any work:**
- [x] **Ask the user for the Kali Packer image-builder repo URL.** Supplied
      2026-08-06: <https://gitlab.com/kalilinux/build-scripts/kali-packer>.

> ⚠️ **And the answer reframed the Kali half: most of it already existed.**
> [`examples/kali-packer-vagrant/`](examples/kali-packer-vagrant/) has operationalized
> **that exact repository** since 2026-07-03 — same URL, and
> [`UPSTREAM.md`](examples/kali-packer-vagrant/UPSTREAM.md) already pinned the same
> commit `b8c9b34e…`, which a fresh clone on 2026-08-06 confirmed is *still* HEAD.
> The lab has a driver (`build-kali-box.sh`), a pinned fetcher, a README, a
> MANUAL_TESTING, a 00-INDEX row, and it was **built and booted end-to-end** with two
> documented bitrot fixes. Writing this item's "vendor it under its own `examples/`
> subdir" as specified would have produced a **second lab for the same upstream** —
> the duplication this repo's own blast-radius rule exists to prevent. What was
> genuinely missing was narrower: the **bytes**, and the hand-walk.

**Kali first:**
- [x] Vendor the Kali Packer builder **in full** (pinned commit + provenance +
      LICENSE), runnable per upstream's README. **Done 2026-08-06** —
      [`examples/kali-packer-vagrant/upstream-repo/`](examples/kali-packer-vagrant/upstream-repo/):
      all **17** tracked files byte-exact (verified against the source checkout,
      0 mismatches), a per-file `sha256` table, a `SHA256SUMS` for
      `sha256sum -c`, upstream's `LICENSE` preserved, and the posture change
      recorded in `UPSTREAM.md`. The retirement is what makes it worth doing: a
      pinned URL is a poor custodian of a repository nobody maintains.
      *(One trap worth naming: upstream ships a `.gitignore`, and vendoring it
      verbatim silently applies those rules to our subtree. Checked rather than
      assumed — `git status --ignored` shows nothing hidden, and all 17 stage.)*
- [x] ~~mklab automation wrapper — a build script~~ **already existed**:
      [`build-kali-box.sh`](examples/kali-packer-vagrant/build-kali-box.sh) +
      [`fetch-kali-packer.sh`](examples/kali-packer-vagrant/fetch-kali-packer.sh).
- [x] **Point the driver at the vendored copy** so the lab builds **offline** by
      default, with a flag to clone upstream live instead. **Done 2026-08-06.**
      `fetch-kali-packer.sh` stages the archive after verifying it against
      `SHA256SUMS` (**refuses** a mismatch, naming the file — a vendored tree is a
      cached copy, and one nobody re-checks is bug class #1); `--upstream` restores
      the clone. *It nearly stayed decorative:* `build-kali-box.sh` passed
      `--ref "$REF"` **unconditionally** with `REF=main`, and `--ref` implies
      `--upstream`, so every build would still have cloned and the offline path
      would have existed and never run — one defaulted flag. Guarded by
      [`tests/test-offline-archive.sh`](examples/kali-packer-vagrant/tests/test-offline-archive.sh),
      which asserts the property against **`build-kali-box.sh`** and not only the
      fetcher, because that is where the defect was.
- [x] **Hand-walk `Containerfile`** (Packer + QEMU baked in, per the *Hand-walk
      sandboxes* convention); partition what the agent can run vs. an explicit
      "you run this" marker (Packer needs KVM/`/dev/kvm`; flag if blocked here).
      **Done 2026-08-06** — [`examples/kali-packer-vagrant/hand-walk/`](examples/kali-packer-vagrant/hand-walk/)
      (`Containerfile` + `RUNBOOK.md`); see the follow-up entry below, which
      records what building it surfaced. *This box stayed unticked while the very
      next subsection said the work was done and the section ended on "Item 7 is
      COMPLETE" — the same stale-record shape the audit findings had.*

**AlmaLinux second:**
- [x] Vendor [`AlmaLinux/cloud-images`](https://github.com/AlmaLinux/cloud-images)
      **in full** (same provenance discipline), and cross-link it with the
      kickstart gallery (which already consumes a slice of this repo).
      **Done 2026-08-06** — [`examples/almalinux-packer-images/`](examples/almalinux-packer-images/):
      563 files byte-exact at pinned `6d808bf7`, `SHA256SUMS`, upstream `LICENSE`
      preserved, cross-linked both ways with the gallery.
      ⚠️ **The argument is INVERTED versus Kali and the lab says so:** that upstream
      is *retired*, this one is *actively maintained*, so the archive is a **dated
      snapshot, not a mirror** — its pin records *which* factory the lab documents,
      and `--upstream` shows what moved.
      **The `.gitignore` trap fired here.** Upstream's `.gitignore` lists
      `*.pkrvars.hcl` *and* upstream tracks `tests/test-values.pkrvars.hcl`, so a
      plain `git add` silently dropped it. Force-added, and the test asserts
      **on disk == in SHA256SUMS == tracked by git** so a future re-vendor cannot
      lose a file quietly. *(Checked for Kali too, where it did not fire.)*
- [x] Same automation wrapper + hand-walk `Containerfile` shape as the Kali half.
      **Done** — `fetch-cloud-images.sh` (offline by default, verifies 563 files,
      **refuses** a tamper by name; `--upstream` to clone live) +
      [`hand-walk/`](examples/almalinux-packer-images/hand-walk/RUNBOOK.md) (RHEL-9
      box with QEMU/KVM, Packer from HashiCorp's RPM repo, `ansible-core`).
      ⛔ **Deliberately NO `build-alma-image.sh`.** Unlike the Kali lab, no image has
      been built here — a wrapper would imply a path somebody walked. The build is
      **author-run and marked as such** (`/dev/kvm`, a ~1 GB ISO, tens of minutes);
      what is CI-gated is the archive, the offline staging and the tamper refusal.

- [x] **Kali hand-walk `Containerfile`** — **done 2026-08-06**, and it surfaced a live
      doc defect: the HashiCorp apt line this lab's own README gives,
      `$(lsb_release -cs)`, expands to `kali-rolling` on Kali and **404s** (HashiCorp
      publishes no such suite). Pinned to `bookworm`, with the 404 recorded next to it.
- [x] **A real `packer` run against BOTH vendored archives** — `init` + `validate`,
      **verified 2026-08-06**:
      - Kali: `build-kali-box.sh --validate-only` inside the sandbox → **`The
        configuration is valid.`** — archive verified offline, both compat patches
        applied, 5 plugins installed, live ISO resolved, every schema checked.
      - AlmaLinux: `packer validate -only='qemu.almalinux-9-gencloud-x86_64'` on the
        vendored 563 files → **`The configuration is valid.`**

      This is the first proof either vendored archive is a *valid Packer config* rather
      than merely a byte-exact pile of files. ⚠️ **And the AlmaLinux run found a false
      success:** on RHEL-family, `cracklib-dicts` ships `/usr/sbin/packer`, which
      **shadows** HashiCorp's `/usr/bin/packer`; a bare `packer version` prints `0 0` and
      **exits 0**, so `validate` "passed" twice while checking nothing. Fixed with a PATH
      order *and* a build-time assertion — a PATH tweak is a mechanism, the assertion is
      the outcome.

- [x] **A full `packer build` producing an actual image** — **DONE 2026-08-06, author-run.**
      `build-kali-box.sh --install-packer` on the host: **`packer_kalirolling_libvirt_amd64.box`,
      5.7 GB, built in 11 min 12 s** on QEMU 8.2.2 + KVM with the pinned packer 1.13.1 —
      **from the VENDORED archive, offline** (`archive verified: 17 files match`), both compat
      patches applied, the 4.47 GB ISO checksum-verified by packer.
      **The whole chain is now proven end to end**: vendored bytes → verified → staged →
      patched → `packer init` → live ISO resolution → unattended d-i install → Ansible-free
      shell provisioning → `vagrant` post-processor → a bootable box.

      ⚠️ **The first attempt failed and it was NOT a defect.** It died at
      `Error running boot command: … use of closed network connection` — the VNC socket
      closing mid-type. I predicted "bitrot #3" and was **wrong**: an identical re-run, same
      host, no changes, succeeded. That is the §17.5 control (*same commit, re-run*)
      distinguishing flaky from real, and the honest label is **flaky**, recorded in the
      README beside the two genuine bitrots rather than promoted to one.

- [x] **AlmaLinux image built, for symmetry** — **DONE 2026-08-06**:
      `AlmaLinux-9-GenericCloud-9.8-20260806.x86_64.qcow2`, 567 MB, **5 min 55 s**, from the
      vendored archive in the hand-walk container (Ansible `ok=36 changed=23 failed=0`),
      then **booted to `localhost login:`**. Two host-specific findings, both of which look
      like a broken build: upstream's `qemu_binary` default is `null` so packer seeks
      `qemu-system-x86_64` — **a name RHEL-family does not ship**, so *upstream's own default
      fails on upstream's own distro* (their CI runs Debian-family runners); and booting
      needs `-cpu host` because AlmaLinux 9 requires **x86-64-v2** while QEMU's default
      `qemu64` panics init with `Fatal glibc error: CPU does not support x86-64-v2`.

**Item 7 is COMPLETE.** Both builders vendored in full, both runnable offline against
verified archives, both hand-walks built, both configs `packer validate`-clean, and **both
built into real, booted images**.

Per-lab, both halves: a `README.md` + `MANUAL_TESTING.md`, a 00-INDEX entry, and
`tools/link_check.py` green (0 broken, no orphans).

Exemplars: the *Provenance* + *Hand-walk sandboxes* conventions in
[`CLAUDE.md`](CLAUDE.md); existing vendored sources under
`examples/*/upstream-tutorial/` and hand-walk `Containerfile`s
([`micro-linux/hand-walk/`](micro-linux/hand-walk/)); the distros' existing labs
([`examples/kali-preseed-gallery/`](examples/kali-preseed-gallery/),
[`examples/almalinux-kickstart-gallery/`](examples/almalinux-kickstart-gallery/))
as the d-i/kickstart counterparts to these Packer builders.

## 8. Repo health review (2026-08-03): one real defect + deferred follow-ups

A full health pass run on a **minimal container (root, no
podman/qemu/incus/debootstrap, no docker daemon)** — deliberately hostile
conditions, and a good stress test of the "no silent exits, honest SKIPs"
discipline. The record, so the next reviewer knows what was already checked:

- **Green:** `tools/link_check.py` (368 docs, 0 broken, 0 orphans);
  `tools/paths.py --check`; `bash -n` over all 363 tracked scripts; all
  `tools/tests/` suites; phases 1, 2, 3, 5, 7 + micro-linux (runnable tests
  pass, the rest SKIP with named reasons); phase6-tui + phase6b-web pytest
  (154 passed, 1 skipped); `netboot/tests/test-sign-payload.sh`; the
  [`examples/metal-as-a-service/`](examples/metal-as-a-service/) chaos suite
  (28 passed, 7 skipped, 0 failed — zero criticals, all 9 layers covered).
- **Provenance verified beyond what CI checks:** all **204** recorded `sha256`s
  across the 32 `upstream-tutorial/` archives re-hashed against the archived
  bytes — 204 match, 0 mismatches. The one archive-less dir
  ([`examples/linuxboot-uefi-kexec/upstream-tutorial/`](examples/linuxboot-uefi-kexec/upstream-tutorial/))
  is the *cite, don't mirror* tier correctly applied.

**The defect: phase4's `export` path gates before it validates — and its two
tests FAIL where they should SKIP.**
[`test-validation.sh`](phase4-podman/tests/test-validation.sh)'s
"export bogus format" assertion and
[`test-compose-export.sh`](phase4-podman/tests/test-compose-export.sh) both
**FAIL** on a host without podman (and fail *differently* as root: the
rootless-first refusal fires instead). Two distinct problems:

1. [`lab-podman.sh`](phase4-podman/lab-podman.sh)'s export path runs the
   root-gate / podman-presence check **before argument validation**, unlike
   every other subcommand — 13 sibling usage-validation checks pass fine in
   the same podman-less run. Usage errors should not require a working podman
   to be diagnosable.
2. The two tests carry no skip guard, violating the contract
   [`ci.yml`](.github/workflows/ci.yml) itself states ("daemon/root tests
   self-skip"). CI masks both (GitHub runners are non-root and ship podman) —
   this only bites on a minimal or root box, exactly the case the SKIP
   discipline exists for. Credit where due:
   [`run-all.sh`](phase4-podman/tests/run-all.sh) honestly exited 1.

- [x] Reorder `lab-podman.sh` `export` to validate its arguments (unknown
      format, missing lab) *before* the rootless gate and podman-presence
      check, matching the other subcommands.
- [x] ~~Give the "export bogus format" assertion and `test-compose-export.sh`
      a skip guard~~ — **this was the wrong fix, and doing it would have
      cemented the defect.** See below.
- [x] Negative control per house rules: after the fix, rerun both tests on a
      podman-less box and watch them PASS; re-inject the defect and watch all
      three assertions bite.

**✅ Done 2026-08-06.** The gates moved *inside* the `case` arms rather than
above it, so each format consults exactly what it uses. But investigating first
found the diagnosis above was **half the defect**: `--format compose` **never
calls podman at all** — it reads the stored `spec.toml` and prints YAML — so it
was a pure text transformation gated on a container engine *and* on being
non-root. `test-compose-export.sh` has carried "no live podman needed" in its
header since the day it was written; the code disagreed, and nothing noticed
because CI's runners ship podman.

**That is why sub-task 2 was the wrong fix.** A skip guard would have made a
podman-less host report `SKIP` for a test that needs no podman — retiring the
question while it was still open, which is exactly what the *UNKNOWN is not
PASS* rule forbids in the other direction. Neither test needs a guard now:
both pass on a podman-less `PATH`, as does `export bogus format`.

**The regression guard is new, because the existing assertion is inert where CI
runs it.** `expect_error "export bogus format"` only distinguishes fixed from
broken on a host with **no** podman, so it passed identically before and after
and would never catch this coming back.
[`tests/test-export-needs-no-podman.sh`](phase4-podman/tests/test-export-needs-no-podman.sh)
makes podman-presence *observable* instead of environmental: it runs a copy of
the tool with both gate functions replaced by tripwires that exit 9 by name, so
"did this path consult podman?" has a recorded answer on every host. Two
controls, because a one-sided test would also pass if the fix simply deleted the
gates: `logs` **must** trip the tripwire (proving it is wired), and
`--format kube` **must** trip it (proving the path that really does run
`podman kube generate` kept its gate).

Verified: full phase4 suite with real podman **11 passed · 1 skipped · 0
failed**; all three tests green on a `PATH` mirroring the host minus podman; and
with the defect re-injected all three fail — the new guard *with podman
installed*, which the other two cannot do. The root half of the original report
("fails differently as root — the rootless-first refusal fires") is fixed
structurally: neither surviving path reaches `require_rootless` at all, which is
what the `kube`-must-trip control measures.

**Known-open items re-confirmed, not new** (tracked elsewhere, listed for
completeness): the Alpine `--allow-untrusted` gap — the residue of
[`AUDIT.md`](AUDIT.md) F2 — plus backlog items #4/#5 follow-on passes and #7
(Packer vendoring, blocked on its prerequisite question).

## 9. `nested-calico-sandbox/` — a disposable cluster, so the CNI beliefs can be tested

This host runs **microk8s with Calico on the metal**, and that single fact has shaped
several labs and cost one real outage
([`MICRO_CLOUD_LAB_PLAN.md`](MICRO_CLOUD_LAB_PLAN.md) F.6: a lab's tap captured the live
cluster's VXLAN tunnel endpoint). The mitigations that came out of it —
[`examples/micro-cloud/fabric.sh`](examples/micro-cloud/fabric.sh)'s bridge-naming rule and
its addressless-tap rule — are **derived from one host at one Calico version and have never
been falsified**, because falsifying them means breaking the cluster the machine is using.

A **throwaway microk8s inside a phase-2 VM** removes that constraint. It is listed here as
well as in the micro-cloud queue because its value is not confined to that lab: it is the
repo's only way to ask "what does the CNI actually do when I provoke it?" without the answer
costing an outage, and the same box is a safe host for the **whole** slice-3 break pass —
including `retap`, which no test has ever called.

> ⚠️ **Read the boxes carefully: the EXPERIMENT is done and the LAB is not.** On
> 2026-08-07 a disposable microk8s (v1.35.6, Calico **v3.29.3**) was stood up by hand in a
> `lab-vm.sh` guest and both rules were measured —
> [Appendix O](MICRO_CLOUD_LAB_PLAN.md#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07).
> That closes the *questions*. It does not close this item: a measurement nobody can re-run
> is a story, and the recipe currently lives only in an appendix. This is
> [§0.1](#0-next-up--the-three-things-nearest-the-front-of-the-queue).

- [ ] **`examples/nested-calico-sandbox/`: a phase-2 `.toml` (cloud image + cloud-init
      installing microk8s), `README.md`, `MANUAL_TESTING.md`, a `tests/` harness, a
      00-INDEX row and a `learning-paths.toml` route — the cohesive-lab shape.** ← the
      open one. Reproduces unprivileged in ~15 min from Appendix O.
- [x] Re-run **F.6** on purpose: give an interface an address and watch the node IP
      migrate. ✅ **measured 2026-08-07** — Calico migrated to the decoy **on its own
      60-second poll**, nothing restarted. (One interval was not enough: still on the
      incumbent at ~100 s, moved by ~3 min.) **Caveat kept:** this was a *dummy interface
      in a guest*, not a **`fabric.sh` tap** beside a cluster whose loss would matter —
      [§0.2](#0-next-up--the-three-things-nearest-the-front-of-the-queue) is that gap.
- [x] Verify **rule 1** by naming a bridge both ways and watching only one get picked.
      ✅ **measured 2026-08-07, and only because of the control**: deleting the winner made
      Calico fall back to the incumbent at index **2**, *skipping* an addressed `br-decoy`
      at index **8**. Index ordering cannot explain that, so the `^br-.*` exclusion is real
      — it had until then only ever been *read out of a binary*. Bound to **v3.29.3**; this
      host runs **v3.28.1**, and the finding is about the algorithm at a named version, not
      about this machine.
- [x] Exercise `retap` against a deliberately root-owned tap. ✅ **GREEN 2026-08-07** — `TUNSETIFF-FAILED errno=1` on a tap with owner uid 0 → `retap` → `TUNSETIFF-OK`, reservation byte-identical and still single, tap addressless on `br-mc0`, both verbs refusing the other's case, Calico unmoved. **Three privileged runs, two harness defects, zero defects in `fabric.sh`** — the test caught itself twice (an owner-**less** tap is attachable by anyone; and §5 asserted a *message* where the tool was right). [Appendix P](MICRO_CLOUD_LAB_PLAN.md#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07)
      ([`test-retap-recovers-a-root-owned-tap.sh`](examples/micro-cloud/tests/test-retap-recovers-a-root-owned-tap.sh));
      it stages the real defect and asserts the **`TUNSETIFF` outcome**, not the owner
      file. Root-gated, so it SKIPs unprivileged — **the privileged run is still owed**,
      and the box stays unticked until it has actually executed its assertions.
- [ ] A **CNI-layer chaos scenario**. ⚠️ **Partly overtaken**: micro-cloud *does* now have a
      chaos matrix ([`test-vsock-chaos.sh`](examples/micro-cloud/tests/test-vsock-chaos.sh),
      five rows, 2026-08-07), but **the CNI is not one of its layers** and the fabric's own
      teardown code is explicitly named as uncovered —
      [§0.3](#0-next-up--the-three-things-nearest-the-front-of-the-queue). Per
      [`CLAUDE.md`](CLAUDE.md)'s "every discrete layer gets an injection point".

**Two constraints that must be honoured or the results are worthless**, both instances of
this repo's bug class #1: the sandbox must enumerate **its own** candidate set (ordering
depends on which interfaces exist, and the guest has neither `lxdbr0` nor `incusbr0`), and
it must **record the Calico version it observed** and refuse to generalise across a
mismatch — microk8s bundles whatever its channel ships, while every fact we hold is
**v3.28.1**. The finding transfers as a statement about a named version's selection
algorithm, **not** as a prediction about this host.

Full brief, with the five derived constraints and what "done" looks like:
[`examples/micro-cloud/DEFERRED.md`](examples/micro-cloud/DEFERRED.md#queued--nested-calico-sandbox-a-disposable-cluster-to-break-on-purpose).
Needs ~4 GiB RAM and ~10 GiB disk; **nested KVM is not required**.

---

## 10. ~~Extend the EXIT-trap safety net to phases 1–5 and micro-linux~~ — **DONE 2026-08-06**

Closed the same day it was filed. The scope grew once the shared checker existed: every
`tests/` directory in the repo now has the same shape, so the rule needs no exemption
list.

| tests dir | before | now |
|---|---|---|
| `phase1-chroot/` | 17 of 21 tests with **no net** | lib owns the trap; 22 traps → `on_exit` |
| `phase2-qemu-vm/` | 13 of 17 with no net | 7 traps → `on_exit` |
| `phase3-docker/` | 15 of 16 with no net | 8 traps → `on_exit` |
| `phase4-podman/` | 11 of 13 with no net | 6 traps → `on_exit` |
| `phase5-lxd/` | 10 of 10 with no net | 7 traps → `on_exit` |
| `micro-linux/` | 10 of 10 with no net | 1 trap → `on_exit` |
| `phase7-firecracker/` | net fine, no `on_exit` | gained the registry |
| `examples/micro-cloud/` | net per test (6 copies) | lib owns it; 6 traps → `on_exit` |
| `examples/bmc-toolkit/`, `examples/zfsbootmenu-boot-environments/`, `examples/metal-as-a-service/` | fixed earlier the same day | now on the shared checker too |

- [x] `_VERDICT` + `on_exit` + `_on_exit` in every `lib.sh`, with the trap installed there.
- [x] Every test that installed its own EXIT trap converted (~50 sites).
- [x] **One** implementation of the check — [`tools/check-harness-net.sh`](tools/check-harness-net.sh)
      — with a five-line `tests/test-harness-net.sh` per directory so it runs inside that
      suite's `run-all.sh`, and therefore CI. The bespoke copy written for
      metal-as-a-service hours earlier was replaced by a wrapper.
- [x] All eleven suites run, and the six converted ones diffed **per-test verdict against
      a baseline captured before the change**: all 87 identical. A green summary would
      not have shown a test flipping PASS→SKIP.

**What the work added beyond the brief:** registered cleanup can read the exit status as
`$_EXIT_RC`. Without it, a teardown that branches on failure — micro-cloud's
DHCP-exhaustion test keeps its log directory when the run fails — has no choice but to
write its own `trap … EXIT`, which is the very defect being removed. A rule people cannot
follow is a rule that gets broken.

---

*Created 2026-06-06; #5–#6 added 2026-06-11; #7 added 2026-06-11; #8 added
2026-08-03; #9 added 2026-08-06; #10 added 2026-08-06.*
