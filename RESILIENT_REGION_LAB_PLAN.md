# Resilient RAM Region Lab — Design Plan v1

> **Status**: Draft v1 — proposed 2026-07-24 (option **C** of the "what can we
> compose?" survey). Anchors on the completed **RAM-INFRA trio**
> (`examples/anycast-dns-ram/`, `cdn-edge-ram/`, `package-mirror-ram/` — all ✅) plus
> `examples/tiny-internet-project/` (six Debian services, ✅ verified), the netboot
> `imgverify` + A/B mechanic (`RAM_INFRA_LAB_PLAN.md` ①/④), and
> `examples/kdump-kexec-lab/`. Scope: compose the individually-proven stateless
> nodes into **one "region" topology** with a two-tier edge/origin split, then add
> the piece none of them has alone — a **chaos harness** that induces failure and
> shows the region *heal*. Awaiting user go-ahead; nothing built or committed yet.

---

## 1. What we're building

A **region-in-a-box**: an *edge tier* of stateless, RAM-booted, A/B-signed nodes
(the RAM-INFRA trio) sitting in front of an *origin tier* of stateful services
(the Tiny Internet Project's DNS/mail/web/mirror). The nodes already work in
isolation; what's new is (a) **wiring them into one region** with a shared control
view, and (b) a **chaos driver** that proves the resilience each node was built for
but never demonstrated *together*: kill a node → traffic sheds; ship a bad image →
the bootloader refuses and rolls back; panic a kernel → kdump captures the crash.

```
                         ┌──────────────── EDGE TIER (stateless, RAM, A/B-signed) ─────────────┐
   client / probe ──►    │  anycast-dns-ram   cdn-edge-ram        package-mirror-ram           │
                         │  (Knot + ExaBGP)   (nginx + ZFS cache)  (nginx + NFS/iSCSI mirror)   │
                         │        │ announce/withdraw /32   ▲ imports pool   ▲ mounts state     │
                         └────────┼─────────────────────────┼────────────────┼─────────────────┘
                                  ▼                          │                │
                         bird2 collector (looking-glass)     │  ORIGIN TIER (stateful, Incus)
                         `birdc show route`                  ▼                ▼
                                              tiny-internet-project: dns01/02 · web01 · mirror · mail
                                              (durable state lives HERE; the edge is disposable)

   chaos-region.sh ──►  [1] kill knotd on a node    → route withdrawn, collector sees it vanish
                        [2] publish tampered A image → imgverify fails → node boots B (rollback)
                        [3] panic the guest kernel   → kdump/kexec captures vmcore   (kdump-kexec-lab)
```

**The teaching arc:** immutable/ephemeral edge + durable origin is the shape of every
real CDN/anycast POP. The lessons the trio each taught alone — *reboot pulls newest
verified*, *ephemeral OS + externalized state*, *health-gated route control* — only
become a *system* when you can watch the region absorb a fault and stay up. The chaos
harness is the payoff: **resilience you can trigger and observe**, not assert.

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

Almost everything is built; this lab is **composition + a fault injector**, not new
node types.

| Capability | Status | Foundation to reuse |
|---|---|---|
| RAM-boot stateless node (initramfs = root) | ✅ proven | `debian-http-boot/`, RAM-INFRA trio |
| Health-gated anycast announce/withdraw | ✅ verified | `anycast-dns-ram/` (ExaBGP + bird2 collector) |
| Ephemeral OS + externalized ZFS state | ✅ verified | `cdn-edge-ram/` (host ZFS live) |
| Ephemeral OS + network (NFS/iSCSI) state | ✅ verified (guard) / author-run (live mount) | `package-mirror-ram/` |
| Signed A/B payloads + rollback | ✅ verified | `netboot/` mechanics ①/④ |
| Stateful origin services (DNS/mail/web) | ✅ verified | `tiny-internet-project/` (6 Incus nodes) |
| Kernel-crash capture | ✅ verified | `kdump-kexec-lab/` |
| **One region topology tying edge+origin** | ❌ **GAP** | — invent: a region spec + a shared bring-up driver |
| **Chaos / fault-injection harness (crux)** | ❌ **GAP** | — invent: `chaos-region.sh` + observable checkpoints |
| **Edge caches the origin (not a static blob)** | ❌ **GAP** | — invent: point `cdn-edge`'s upstream at `web01.tiny.lab` |

Host reality check (unchanged from RAM-INFRA): host ZFS is live; NFS/iSCSI are
**host-global kernel state** (this dev box already serves NFS) → the live network-state
mount stays **author-run**. The anycast BGP demo is **container-only** (slirp has no
VM-to-VM L2) — the region's edge-tier control-plane view is cleanest as podman
containers on a shared network, with the RAM-boot *artifact* exercised separately in
QEMU. Both facts are inherited honesty, restated in this README.

---

## 3. The crux — the chaos harness (the reusable centrepiece)

The trio proves each node *can* fail safely; nothing yet *makes* one fail and shows
the region routing around it. `chaos-region.sh` is that missing verb — a menu of
reproducible faults, each with an **observable checkpoint** (the house rule for path
steps), so every scenario ends in a green/red line, not a vibe:

| Fault | Injection (by PID / by name, never `pkill -f`) | Observable recovery |
|---|---|---|
| **Node down** | `kill <knotd-pid>` on an edge DNS node | collector `birdc show route` shows the `/32` **withdrawn**; a sibling still answers `dig` |
| **Bad image** | publish a **1-byte-flipped** initrd to the `current` A slot | node's iPXE `imgverify` **fails → boots `previous` (B)**; `/proc/cmdline`/VERSION proves the rollback |
| **Kernel panic** | `echo c > /proc/sysrq-trigger` in a guest | kdump/kexec boots the capture kernel, writes a `vmcore` (kdump-kexec-lab signature) |
| **State detached** | stop the NFS/iSCSI export (author-run) | `state-mount.sh` `||`-guard keeps PID 1 alive; node serves a **degraded** page, not a panic |

The tamper test is the same **flip-one-byte → verify-fails → rollback** signature
RAM-INFRA already requires — here it runs *inside a live region*, so you watch the
node self-heal rather than just refuse in isolation. Safety: injections target **only
lab PIDs/containers**, resolved to a PID first; no destructive verb ever touches the
host (house `pkill -f` + by-PID rules apply verbatim).

---

## 4. Wiring the tiers (the composition work)

- **Origin = Tiny Internet Project, mostly as-is.** `web01` (LAMP), `dns01/02`
  (BIND authoritative + AXFR), `mirror` (apt cache) become the *durable* backend the
  edge fronts. One small graft: `cdn-edge-ram`'s nginx upstream points at
  `web01.tiny.lab` instead of a static asset, so the ZFS cache holds **real origin
  content** and a cache-survives-reboot demo becomes end-to-end.
- **Edge = the RAM-INFRA trio, unchanged internally**, brought up together by a
  region driver that sequences: origin first (Incus), then the edge containers +
  collector, then (optionally) the QEMU RAM-boot artifact for the signed-A/B demo.
- **Region driver `region.sh`** — `up`/`status`/`down` over the existing phase
  scripts (`lab-lxd.sh` for origin, `lab-podman.sh` for edge), never re-implementing
  lifecycle; `status` prints a node/tier/health table (mirrors `tiny-internet.sh
  status`). If any layer is deleted, the others still stand (house invariant).

---

## 5. New components & files

| File | Type | Notes |
|---|---|---|
| `RESILIENT_REGION_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/resilient-region/region.sh` | new | `up`/`status`/`down` sequencing origin (Incus) + edge (podman) + optional QEMU artifact |
| `examples/resilient-region/region.toml` | new | the two-tier topology spec (references the trio + tiny-internet units) |
| `examples/resilient-region/chaos-region.sh` | new | the fault menu (§3); each scenario → one verdict + observable checkpoint; EXIT-trap net |
| `examples/resilient-region/tests/` | new | one-verdict smokes for each chaos scenario that is host-safe (node-down, tamper-rollback); author-run ones documented |
| `examples/resilient-region/{README,RUNBOOK,MANUAL_TESTING}.md` | new | concept + the failure-drills walkthrough + verified transcripts |
| `examples/cdn-edge-ram/` | edit (tiny) | optional upstream-points-at-`web01` variant config |
| `examples/00-INDEX.md` | edit | one row (cross-phase / RAM-infra section) |
| `examples/learning-paths.toml` | edit | route it as the **capstone of the netboot-pipeline / RAM-infra journey**, *after* the trio; observable checkpoint = a chaos scenario's green line (e.g. tamper → rollback, `EXIT`/route-withdrawn marker). Then `paths.py render && --check`. |

---

## 6. Provenance (cite-and-vendor)

- The **Gandi anycast** post (flagship model) and Tonello's **Tiny Internet Project**
  are **already vendored** under their respective labs' `upstream-tutorial/`; this lab
  *composes* those and cites them (self-containment — no re-mirror).
- **Chaos-engineering** framing (Netflix Principles of Chaos / "blast radius") →
  cite, don't mirror (URL + retrieved date); the harness is our own, the vocabulary
  is theirs.
- ExaBGP / bird2 / Knot / kdump follow the existing labs' cite-don't-mirror lines.

---

## 7. Security posture (AUDIT.md alignment)

- **F1 (throwaway creds).** Inherits the trio's + tiny-internet's snakeoil creds and
  no-TLS-on-an-isolated-bridge posture; README restates "never expose these nodes."
- **F2 (download integrity).** The tamper→rollback drill *is* the F2 proof, now run
  inside a live region.
- **F7 (destructive-op guard).** ZFS/iSCSI teardown and any origin wipe are
  path/name-guarded and **handed to the user** (`!`).
- **Fault injection is PID-scoped.** `chaos-region.sh` resolves every target to a PID
  (or a specific container name via the phase tool's own lifecycle verb) before
  signalling — **never** `pkill -f` (the shared-cmdline / serial.sock footgun that
  once killed a QEMU VM). Only lab processes are ever targeted; the host is off-limits.

---

## 8. Build order (dependency-aware) & verified-vs-author-run

1. **`region.sh up/status/down`** — bring the two tiers up together over the existing
   phase scripts. *Verifiable: `status` shows origin + edge + collector all live.*
2. **Edge-caches-origin graft** — point `cdn-edge-ram` at `web01`. *Verifiable: an
   asset requested through the edge is served from the ZFS cache and survives a node
   reboot.*
3. **`chaos-region.sh` — node-down + tamper-rollback** (both host-safe). *Fully
   verifiable headless; the two marquee drills.*
4. **`chaos-region.sh` — kernel-panic (kdump) + state-detach** (heavier). *kdump
   verifiable in QEMU; the live NFS/iSCSI detach is **author-run** (host-global state),
   with the exact command handed over.*

Each step ends in a POC-style writeup with real transcripts; the lab ships one-verdict
smokes + EXIT-trap net; both catalogs stay green; anything env-blocked is marked
author-run with the handed-over command.

---

## 9. Open items / decisions to confirm

- **First increment scope** (needs a nod): recommend **(1) `region.sh` + the two
  host-safe chaos drills (node-down, tamper-rollback)** — the highest-signal, fully
  headless-verifiable slice — then add the edge-caches-origin graft and the heavier
  kdump/state-detach drills.
- **Origin footprint** — full 6-node tiny-internet, or a trimmed origin (just
  `web01` + `dns01`) to keep the region light? Leaning trimmed for v1.
- **Whether the region gets a Phase-6 view** — a "region health" panel is a natural
  fast-follow (shares the option-B libvirt/inventory work), but the CLI `status` has
  standalone value and lands first.
- **Anycast realism** — stays container-collector/looking-glass (honest); a
  two-VM bridged variant is a documented stretch, not v1 (needs tap/bridge, not slirp).
