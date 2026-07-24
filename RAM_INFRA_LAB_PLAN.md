# Net-booted RAM-resident Infrastructure Lab — Design Plan v1

> **Status**: Draft v1 — scoped from `TODO.md` §4 ("Net-booted, RAM-resident
> infrastructure images"), 2026-07-23. Anchors on the *mature* netboot pipeline
> (`NETBOOT_LAB_PLAN.md`) and the RAM-root mechanic
> (`examples/debian-http-boot/`, `micro-linux/ --baked`). Scope: grow the one
> proven "boot a whole OS into RAM over HTTP" trick into **role-specific
> stateless infrastructure nodes** (anycast DNS · CDN edge · package mirror) plus
> the **four mechanics none of those foundations have yet**. Likely splits into
> one lab per role, built in the order below.

---

## 1. What we're building

Stateless infrastructure nodes that iPXE-boot a kernel + initramfs **entirely
into RAM** (the initramfs *is* the root fs — no OS on local disk), so a **reboot
re-pulls the latest *verified* image**. Update centrally, reboot the fleet, done.
Where a role needs persistent data, the **OS stays ephemeral** and only the
*state* is mounted from elsewhere (local ZFS pool, iSCSI, or NFS), attached by an
early boot step — never baked into the image.

```
                          build host (this box)
   phase1-chroot debootstrap ─┐          micro-linux --baked ─┐
   (role rootfs → initramfs)  │          (from-source blob)   │
                              ▼                                ▼
                   export-initrd  ────────► role image = { kernel, initrd.gz }
                              │                     │
                              │              sign-payload.sh  [NEW]
                              │              → kernel.sig / initrd.sig (CMS)
                              ▼                     ▼
                   rootless nginx  ───────►  https://HOST:8443/images/<role>/<A|B>/
                              │                     ▲
                              │            iPXE  (DOWNLOAD_PROTO_HTTPS + imgverify)  [NEW wiring]
                              ▼                     │  fetch → imgverify vs baked trust root → boot
                       ┌──────────────── the node boots into RAM ───────────────┐
                       │  early unit: mount STATE (zfs import / iscsi login /    │  [NEW /init plumbing]
                       │              nfs mount)  — role-specific, ||-guarded    │
                       │  service: knot / nginx+varnish / apt-mirror            │
                       │  ExaBGP: announce anycast /32 WHILE healthy, withdraw  │  [NEW]
                       │          on failure  ── observed at a bird2 collector  │
                       └────────────────────────────────────────────────────────┘
```

**The teaching arc:** immutable infrastructure / "golden image" — the machine
holds no durable OS state, so it is disposable and always current. The security
spine is that "reboot pulls newest" must mean **newest *verified***: booting
executable code over a network is a supply-chain surface (`AUDIT.md` **F2**), so
the payload is signed and the bootloader refuses anything it can't verify.

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

The single most important finding: **the hard parts are already done.** The
boot-into-RAM mechanic and the HTTP(S) transport are solid, proven foundations.
This lab family is mostly *new roles* + *four new mechanics* bolted onto them.

| Capability | Status | Foundation to reuse |
|---|---|---|
| RAM-resident boot (initramfs = root fs) | ✅ **proven end-to-end** | `examples/debian-http-boot/` (systemd trixie); `micro-linux/ --baked` single-file blob |
| Build the role rootfs → initramfs | ✅ exists | `phase1-chroot/lab-chroot.sh create` + `export-initrd --init-script` |
| Serve over HTTP / **HTTPS** | ✅ exists (snakeoil TLS) | rootless nginx `:8181`/`:8443`; `10.0.2.2:8181` from slirp |
| iPXE build with embedded DHCP script | ✅ exists | `netboot/build-ipxe.sh` |
| iPXE **HTTPS** + embedded DER trust store | ✅ exists | `netboot/ipxe-build-inner.sh --tls --tls-cert` |
| Secure-Boot-sign the iPXE *binary* | ✅ exists | `netboot/sign-ipxe.sh` |
| **① Sign the *payload* + verify at boot** | ❌ **GAP (crux)** | — invent: `sign-payload.sh` + iPXE `imgverify` wiring |
| **② Health-gated BGP announce (anycast)** | ❌ **GAP** | — invent: ExaBGP health-script + bird2 collector |
| **③ `/init` state-mount (ZFS/iSCSI/NFS)** | ❌ **GAP** | — invent: early-unit mount, `||`-guarded |
| **④ A/B versioned images + rollback** | ❌ **GAP** | — invent: `A|B` layout + iPXE menu/`current` symlink |

Host reality check (2026-07-23): **ZFS is live on this host** (`zfs`/`zpool` +
`zfs.ko` for 6.8.0-136) → the CDN-edge ZFS-pool state story is demonstrable for
real; `iscsiadm` + `exportfs` present → iSCSI initiator / NFS server side work;
`bird2`, `exabgp`, `knot` are in the apt cache → they live **inside the role
image** (built by debootstrap), never on the host.

---

## 3. The crux — "newest" must mean "newest *verified*" (mechanic ①)

The `TODO.md` §4 sub-task calls image integrity **non-negotiable**, and the
`AUDIT.md` gap analysis agrees: today **nothing signs the served kernel/initramfs
or verifies it at fetch time.** The two signing mechanisms that *do* exist both
miss this target:

- `micro-linux/` gpgv verifies **upstream build inputs** (the kernel/BusyBox
  tarballs) against a vendored keyring — build-time, not boot-time, and not the
  *output* blob.
- `netboot/sign-ipxe.sh` Secure-Boot-signs the **iPXE binary** — the *loader*,
  not the *payload* it downloads.

**Design (primary): iPXE `imgverify`.** iPXE natively verifies a detached CMS
signature against a trust root **compiled into the iPXE binary** (the same
`CERTSTORE=`/`TRUST=` mechanism `--tls-cert` already uses for the TLS root). The
embedded boot script becomes:

```ipxe
#!ipxe
dhcp
set base https://${next-server}:8443/images/dns/current
kernel ${base}/vmlinuz
imgverify vmlinuz ${base}/vmlinuz.sig   || goto rollback   # refuse unverified
initrd ${base}/initrd.gz
imgverify initrd.gz ${base}/initrd.gz.sig || goto rollback
boot
:rollback
  set base https://${next-server}:8443/images/dns/previous
  # …same verify-then-boot against the prior A/B slot…
```

So the node **cannot boot code the fleet operator didn't sign**, even if the HTTP
server is compromised or MITM'd — HTTPS gives confidentiality, `imgverify` gives
*authenticity of the payload itself*. This directly closes **F2** for the netboot
path and is the reusable centrepiece other repos' netboot labs lack.

- **Signing side:** new `netboot/sign-payload.sh` — `openssl cms -sign` (detached,
  DER) over `kernel` and `initrd.gz` with a lab code-signing key; the matching
  cert is the trust root baked into iPXE via `build-ipxe.sh --payload-trust`.
  Keys are throwaway/snakeoil in-lab (`AUDIT.md` **F1** framing: never real keys);
  the *mechanism* is production-shaped.
- **Belt-and-suspenders (secondary):** the `micro-linux --baked` blob can *also*
  carry a detached gpg signature verified by a one-liner in `/init` before
  `exec /sbin/init` — a second, independent trust anchor. Documented, optional.
- **Honest framing** (per house convention): the lab's trust root is a snakeoil
  CA — the *real* production anchor is your fleet's offline code-signing key +
  HSM. The lab proves the **mechanism and the failure mode** (flip one byte of
  the initrd → `imgverify` fails → node rolls back / refuses), not a real chain.

---

## 4. The three roles (one lab each)

Each role = a `[[chroot]]` rootfs spec + an `export-initrd` pack + a role service
+ its state model. They share mechanics ①/④ (verify + A/B) and differ on the
service and the **state externalization** (mechanic ③).

### 4a. `examples/anycast-dns-ram/` — **the flagship** (build first)

- **Service:** authoritative **Knot DNS** (`knotd`) serving a small zone. Models
  the Gandi *Booting an anycast DNS network* design (vendored — §7).
- **State:** the **zone/record DB is the state**, and it is *small* → fetched at
  boot over the same verified HTTPS channel (or mounted read-only from NFS as a
  variant). No ZFS/iSCSI needed → the flagship doesn't block on the exotic state
  models, so it lands first.
- **Mechanic ② (the star): health-gated anycast announce.** An **ExaBGP** process
  runs a health-check script that `dig @localhost` the node's own zone; **while it
  answers**, ExaBGP announces the anycast `/32`; the moment DNS stops answering,
  ExaBGP **withdraws** the route. ExaBGP is chosen for the gated node because its
  whole model *is* "a process prints `announce`/`withdraw` on stdout" — the health
  script literally *is* the control plane, which is maximally teachable.
- **Observability (honest):** true anycast (one IP announced from N sites, clients
  routed to the nearest) needs real BGP infrastructure we don't have. The lab
  demonstrates the **mechanism**: a second node running **bird2** as a passive
  BGP collector / looking-glass **sees the route appear when the node is healthy
  and vanish when `knotd` is killed** (`birdc show route`). That announce/withdraw
  cycle is the observable checkpoint — not global anycast, and the README says so.
- **Topology note:** the BGP peering + RAM-boot are cleanest to show in **two
  containers on a shared podman network** (Phase 4) — `lab-vm.sh` slirp has no
  VM-to-VM L2. The RAM-boot *artifact* is exercised separately via QEMU
  (`vm-netboot-ipxe.toml` style). Verified-vs-author-run marked per piece.

### 4b. `examples/cdn-edge-ram/` — ZFS-backed cache state (mechanic ③, real ZFS)

- **Service:** nginx (or nginx + varnish) reverse-proxy cache, running from RAM.
- **State:** a **local ZFS pool** on a second disk holds the cache/content and
  **persists across reboots though the OS doesn't.** An early systemd unit does
  `zpool import -f cdncache` (||-guarded) and points the cache dir at it.
  Demonstrable **for real** — host ZFS is live; in QEMU attach a second virtual
  disk, `zpool create` once, prove the cache survives an image swap + reboot.
- **Teaching moment:** ephemeral OS + durable state on the *same box* — the split
  the whole pattern rests on.

### 4c. `examples/package-mirror-ram/` — iSCSI/NFS-backed mirror tree (mechanic ③, network state)

- **Service:** nginx serving a Debian package mirror (`apt-mirror` tree), from RAM.
- **State:** the multi-GB **mirror tree is mounted over iSCSI** (an iSCSI target —
  `tgt`/LIO in a container — exports a LUN; the node's early unit does
  `iscsiadm` login + mount, ||-guarded). An **NFS** variant (`exportfs` present)
  is the simpler alternative and is documented alongside.
- **Teaching moment:** state too big to ship in the image → network block/file
  storage attached at boot; the image stays tiny and current.

---

## 5. Cross-cutting mechanic ④ — A/B images + rollback

- **Layout:** `…/images/<role>/A/` and `…/images/<role>/B/`, each a
  `{vmlinuz, vmlinuz.sig, initrd.gz, initrd.gz.sig}` set, plus `current` and
  `previous` symlinks (or an iPXE menu). Version = build timestamp / git short-sha
  baked into a `VERSION` file in the set.
- **Roll forward:** publish a new set to the idle slot, flip `current`, reboot.
- **Roll back:** a bad build fails `imgverify` **or** fails its post-boot health
  gate → the iPXE script's `:rollback` label boots `previous` (see §3). A
  never-verifies build can *never* take down the slot it isn't in.
- **Reuse:** extends `lab-vm.sh publish-netboot` (already copies kernel+initrd to a
  netboot dir) with an `--slot A|B` + `--sign` option, rather than new tooling.

---

## 6. New components & files

| File | Type | Notes |
|---|---|---|
| `RAM_INFRA_LAB_PLAN.md` | **this doc** | roadmap |
| `netboot/sign-payload.sh` | new | `openssl cms -sign` detached DER over kernel+initrd; snakeoil key (F1) |
| `netboot/build-ipxe.sh` | edit | `--payload-trust <cert>` → bake payload code-signing root into iPXE `CERTSTORE`; emit an `imgverify`+A/B `:rollback` embedded script |
| `netboot/ipxe-build-inner.sh` | edit | wire `IMAGE_TRUST_CMD` / `imgverify` config into the iPXE `.config` |
| `phase2-qemu-vm/lab-vm.sh` | edit | `publish-netboot --slot A|B --sign` |
| `examples/anycast-dns-ram/` | **new lab (flagship)** | `README.md`, `MANUAL_TESTING.md`, chroot spec, ExaBGP + health-script, bird2 collector spec, podman network spec, 00-INDEX row |
| `examples/cdn-edge-ram/` | new lab | ZFS-pool state unit + second-disk QEMU spec |
| `examples/package-mirror-ram/` | new lab | iSCSI target container + initiator early-unit; NFS variant |
| `examples/*/upstream-tutorial/` | new | **vendor the Gandi post** byte-exact for anycast-dns-ram (§7) |
| `examples/*/hand-walk/` | new | per house convention — disposable container reproducing each build env |
| `examples/00-INDEX.md` | edit | one row per new lab |
| `examples/learning-paths.toml` | edit | route each into a path/collection + `paths.py render && --check` |

---

## 7. Provenance (cite-and-vendor)

- **Gandi, *Booting an anycast DNS network* (2019)** — the flagship's design
  model. Per CLAUDE.md › *Provenance*, a lab built from **one specific write-up →
  vendor it**: `examples/anycast-dns-ram/upstream-tutorial/` gets the post
  byte-exact (HTML + CSS) with the provenance table + sha256 table + attribution.
  Verify 200 + expected title **before** hashing.
- **Kenneth Finnegan, *Booting Linux over HTTP* (2020)** — the RAM-root building
  block, **already vendored** at `examples/debian-http-boot/upstream-tutorial/`;
  the new labs *cite* it (self-containment: they build on the mechanic, they don't
  re-mirror it).
- ExaBGP / bird2 / Knot follow **official docs → cite, don't mirror** (URL +
  retrieved date in each README).

---

## 8. Security posture (AUDIT.md alignment)

- **F2 (download integrity) — the whole point.** `sign-payload.sh` + iPXE
  `imgverify` close it for the netboot payload; a tamper test (flip one initrd
  byte → verify fails → rollback) is a required MANUAL_TESTING signature.
- **F1 (throwaway creds).** All signing keys are snakeoil, generated in-lab, never
  reused; READMEs state the real anchor is an offline/HSM fleet key.
- **F5 (pinned inputs).** iPXE ref + base image pinned as elsewhere in `netboot/`.
- **F7 (destructive-op guard).** ZFS/iSCSI teardown (`zpool destroy`, target
  delete) is path/name-guarded and, per house rule + user preference, **handed to
  the user to run** (`!`), never auto-run.
- Kill processes **by PID** (ExaBGP/knotd/QEMU), never `pkill -f` (the serial.sock
  / shared-cmdline footgun).

---

## 9. Build order (dependency-aware) & verified-vs-author-run

1. **Mechanic ① first — `sign-payload.sh` + iPXE `imgverify` wiring** (spike:
   sign a kernel/initrd, build iPXE with the payload trust root, boot in QEMU,
   prove a tampered payload is rejected). It's the "non-negotiable" spine and every
   role depends on it. *Verifiable headless in QEMU.*
2. **Flagship `anycast-dns-ram`** — Knot in RAM + ExaBGP health-gate + bird2
   collector (containers) + verified A/B boot (QEMU). The announce/withdraw cycle
   is the money checkpoint. *Mostly verifiable; true anycast is author-run/honest.*
3. **`cdn-edge-ram`** — ZFS state (real, host ZFS live). *Verifiable in QEMU with a
   second disk.*
4. **`package-mirror-ram`** — iSCSI/NFS state. *iSCSI target in a container;
   verifiable; large mirror sync may be author-run.*

Each step ends in a POC-style writeup with real transcripts; each lab ships the
one-verdict smokes + EXIT-trap net; both catalogs (`00-INDEX`, `learning-paths`)
stay green; anything env-blocked is marked author-run with the exact handed-over
command.

---

## 10. Open items / decisions to confirm

- **First increment scope** (needs user nod): recommend **(1) mechanic ①
  payload-verify spike + (2) the anycast-dns-ram flagship** this pass — the two
  most novel, most teachable pieces — with cdn-edge / package-mirror as follow-on
  passes. Alternative: do the payload-verify spike alone first (smallest, fully
  headless-verifiable) and review before committing to the flagship.
- ExaBGP vs. bird2 **both ends** vs. gobgp collector — leaning ExaBGP (gated node)
  + bird2 (collector) for pedagogy; open to bird-both-ends for a lighter dep set.
- Whether the flagship's BGP demo is **container-only** (cleanest multi-node) or
  also gets a two-VM bridged variant (heavier; needs a tap/bridge, not slirp).

## Decision (resolved 2026-07-23)

First increment = **crux + flagship** (user pick).

**Mechanic ① — DONE & verified (2026-07-23).** Payload signing + boot-time
`imgverify` + A/B rollback, proven headless in QEMU (3/3 scenarios: verified
boots, tampered rolls back, both-tampered refuses). Productized in `netboot/`:
- `netboot/sign-payload.sh` (new) — CMS-sign payloads (codeSigning EKU, `-certfile`
  CA-in-CMS), mint snakeoil trust root, fail closed.
- `netboot/build-ipxe.sh --imgverify --payload-trust <ca.der>` + `ipxe-build-inner.sh`
  — enable `IMAGE_TRUST_CMD`, bake `TRUST=`, emit the verify+rollback boot script.
  (Also fixed a latent docker `-v` arg-splitting bug via a bind-mount array.)
- `netboot/tests/test-sign-payload.sh` (new) — CI-friendly (openssl only), PASS.
- Evidence + reproducer: `netboot/MANUAL_TESTING.md` §13.

`lab-vm.sh publish-netboot --slot A|B --sign` **deferred** — the flagship stages
A/B slots with `sign-payload.sh` directly (its payload comes from debootstrap +
export-initrd, not a kernel+initrd VM), so the publish-netboot verb isn't on the
critical path. Revisit if a VM-sourced A/B workflow needs it.

**Mechanic ② (health-gated BGP) + flagship lab** — in progress.
