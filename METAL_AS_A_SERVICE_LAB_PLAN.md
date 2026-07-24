# Metal-as-a-Service Lab — Design Plan v1

> **Status**: Draft v1 — proposed 2026-07-24 (option **B** of the "what can we
> compose?" survey). Anchors on `examples/virtualbmc-ipmi-lab/` (IPMI power +
> boot-device + PXE install, all ✅ verified), the netboot PXE-install pipeline
> (`netboot/`, `examples/almalinux-pxe-lab/`, `examples/debian-pxe-lab/`), and the
> Phase-6 TUI / Phase-6b web surface. Scope: wrap those proven-but-scattered pieces
> into **one control loop** that drives a *fleet* of libvirt "machines" through the
> Ironic/MAAS lifecycle — enroll → inspect → provision → deploy — from a single
> pane of glass. Awaiting user go-ahead; nothing built or committed yet.

---

## 1. What we're building

A miniature **bare-metal control plane**. Today the repo can drive *one* libvirt
domain over IPMI and *separately* PXE-install an OS into a VM; nobody wired the two
into a loop, and nothing surfaces the *fleet* as managed inventory. This lab closes
that: a control driver (`maas-lab.sh`) plus a Phase-6 panel that treats each libvirt
domain as a **node with a lifecycle state**, and moves it through that state machine
using tools the repo already proves work.

```
     operator (TUI panel  ·  or  maas-lab.sh)
         │  enroll / inspect / provision / deploy / release
         ▼
   ┌───────────────── control plane ─────────────────┐
   │  node registry (state file: enrolled→…→active)  │  [NEW]
   │        │                                         │
   │        ├─ power/bootdev ──► vbmcd ──libvirt──► domain  (✅ virtualbmc-ipmi-lab)
   │        │      (ipmitool over IPMI/UDP 6230)           │
   │        ├─ inspect ────────► bootdev=pxe + a probe image reports CPU/RAM/NIC  [NEW]
   │        ├─ provision ──────► PXE + kickstart/preseed auto-install  (✅ pxe-lab)│
   │        │      (netboot iPXE + :8181 payloads, imgverify-signed — RAM_INFRA ①) │
   │        └─ deploy ─────────► bootdev=disk + power → the OS you just installed   │
   └──────────────────────────────────────────────────────────────────────────────┘
         ▲
   Phase-6 inventory ── reads the registry + `virsh list` → shows each node's STATE
```

**The teaching arc:** this is how a data centre provisions metal it can't touch —
OpenStack **Ironic**, Canonical **MAAS**, Tinkerbell. The BMC is the out-of-band
hand; PXE + a config-management payload is the install; a state machine is the
orchestrator. We build the *smallest honest version* of all three on one laptop, and
name every place the toy diverges from the real thing.

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

The single most important finding, as with RAM-INFRA: **the hard parts are done.**
IPMI-drives-a-domain and PXE-installs-an-OS are both ✅ verified. The new work is a
*registry + state machine + a fleet* on top, and teaching Phase 6 to see it.

| Capability | Status | Foundation to reuse |
|---|---|---|
| IPMI power / boot-device round-trip | ✅ **verified** | `examples/virtualbmc-ipmi-lab/` (`vbmc-lab.sh power/bootdev`) |
| Serial console of the managed node | ✅ verified | libvirt `virsh console` (VirtualBMC has no SOL — honest sub) |
| PXE auto-install (Anaconda/kickstart) | ✅ verified | `virtualbmc-ipmi-lab` PXE finale + `almalinux-pxe-lab` |
| PXE auto-install (Debian preseed) | ✅ verified | `examples/debian-pxe-lab/`, `preseed-gallery` |
| Signed, A/B netboot payloads | ✅ verified | `netboot/sign-payload.sh` + `build-ipxe.sh --imgverify` (RAM_INFRA ①) |
| Read-only cross-phase inventory UI | ✅ landed | `phase6-tui/`, `phase6b-web/` |
| **Define & manage N libvirt nodes** | ❌ **GAP** | — invent: `create-node.sh --count` / a fleet TOML |
| **A node registry + lifecycle state machine** | ❌ **GAP (crux)** | — invent: `maas-lab.sh` state file + verbs |
| **Hardware "inspection" step** | ❌ **GAP** | — invent: a tiny PXE probe image that POSTs CPU/RAM/NIC back |
| **Phase-6 sees libvirt domains + BMC/node state** | ❌ **GAP** | — invent: a `libvirt`/`maas` inventory source for the TUI |

Host reality check: this is the repo's **only libvirt-based** lab family
(Phase 2 is raw QEMU, zero libvirt). VirtualBMC's *only* driver is libvirt, so the
whole plane talks `qemu:///system`; `vbmcd` runs **rootful** (the system socket is
`root:libvirt`). Phase 6 currently reads `$LAB_STATE_DIR/{chroots,vms,podman,lxd}` —
it has **no libvirt awareness today**, so a new inventory source is required work,
not a config tweak.

---

## 3. The crux — a node lifecycle state machine (the reusable centrepiece)

Ironic's value isn't any one action; it's the **state machine** that sequences them
and never lets a node skip a step. That's what's missing here and what this lab
contributes. `maas-lab.sh` owns a per-node registry (`~/maas-lab/nodes/<name>.state`)
and the transitions:

```
  enrolled ─enroll──► manageable ─inspect──► available ─provision──► deploying
                                                                        │
                          active ◄──deploy(bootdev=disk)◄── deployed ◄──┘
                            │
                          release ──► available   (wipe + back to the pool)
```

- **enroll** — define the libvirt domain (`create-node.sh`) + `vbmc add` it →
  `manageable`. The node now answers IPMI but has no OS.
- **inspect** — `bootdev=pxe` + power on a **tiny probe initramfs** (a `micro-linux`
  or busybox image) whose `/init` reads `/proc/cpuinfo`, `/proc/meminfo`, and the NIC
  MAC and `curl`s them back to the control plane's `:8181`, then powers off. Fills in
  the registry's hardware facts → `available`. (This is Ironic's real "introspection"
  step, in miniature — and a lovely reuse of the RAM-boot mechanic.)
- **provision** — `bootdev=pxe` + power → the existing kickstart/preseed auto-install
  writes an OS to the domain's disk; the installer powers off at the end (already the
  verified behaviour in `virtualbmc-ipmi-lab` and the pxe-labs) → `deployed`.
- **deploy** — `bootdev=disk` + power → boot the freshly-installed OS → `active`.
- **release** — power off, zero the disk (guarded, handed to the user per house rule),
  back to `available`.

Every transition is an **IPMI or PXE action the repo already proves works** — the lab
is the *sequencing and bookkeeping*, which is exactly the part a pile of one-off
scripts lacks. Optional stretch: gate `provision` on `imgverify` so a node can only be
deployed a **signed** image (folds RAM-INFRA mechanic ① straight in).

---

## 4. Surfacing it — Phase 6 as the control pane

Phase 6 already renders a per-lab tree and drives topologies through the phase
scripts; it just can't see libvirt or node-state yet. Two increments:

- **4a. A `libvirt` inventory source** — a read module that lists `qemu:///system`
  domains and joins each to its `maas-lab` registry state, so the browser tree gains
  a `metal (N)` group showing `alpine-node ● active [deploy]`, etc. Read-only, in the
  established Phase-6 style (every mutation still shells out; every read pulls state).
- **4b. A node-actions panel** — key-bindings that call `maas-lab.sh
  inspect/provision/deploy/release <node>` and stream the console into the lower pane
  (mirrors the existing `c` console-attach + topology `u`/`d`). Phase-6b/web gets the
  same verbs as HTMX routes for SSH-forward use.

If Phase 6 is deleted, `maas-lab.sh` still drives the whole loop from the CLI — the
UI is a lens, never the logic (house invariant).

---

## 5. New components & files

| File | Type | Notes |
|---|---|---|
| `METAL_AS_A_SERVICE_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/metal-as-a-service/maas-lab.sh` | new | the control plane: `enroll/inspect/provision/deploy/release/list`; owns the registry + state machine |
| `examples/metal-as-a-service/create-fleet.sh` | new | define N libvirt domains + `vbmc add` each on ports 623X (wraps `virtualbmc-ipmi-lab/create-node.sh`) |
| `examples/metal-as-a-service/fleet.toml` | new | the fleet spec (node count, disk/RAM, PXE network) |
| `examples/metal-as-a-service/probe-init.sh` | new | the inspection initramfs `/init` — POST CPU/RAM/MAC to `:8181`, power off |
| `examples/metal-as-a-service/tests/` | new | one-verdict smokes: enroll→inspect state transition (dry, no install); EXIT-trap net |
| `phase6-tui/lab_tui/sources/libvirt.py` | new | Phase-6 inventory source: `virsh list` ⋈ registry state |
| `phase6-tui/lab_tui/…` node-actions panel | edit | key-bindings → `maas-lab.sh` verbs + console stream |
| `phase6b-web/…` | edit | same verbs as HTMX routes |
| `examples/metal-as-a-service/{README,RUNBOOK,MANUAL_TESTING}.md` | new | concept + by-hand Ironic-mapping + verified transcripts |
| `examples/00-INDEX.md` | edit | one row (Phase-2/libvirt section, near the VirtualBMC row) |
| `examples/learning-paths.toml` | edit | route it: a **step after `virtualbmc-ipmi-lab`** in a "bare-metal provisioning" journey; observable checkpoint = a node reaching `active` via the state machine. Then `paths.py render && --check`. |

---

## 6. Provenance (cite-and-vendor)

- **VirtualBMC** how-tos are **already vendored** under
  `examples/virtualbmc-ipmi-lab/upstream-tutorial/` (siberoloji + server-world); this
  lab *builds on* that lab and cites it (self-containment — no re-mirror).
- **OpenStack Ironic** *node states* + **Canonical MAAS** lifecycle docs are the
  design model → **cite, don't mirror** (URL + retrieved date in the README): the
  state machine is "official docs / upstream code," not one blog post.
- Kickstart / preseed payloads reuse the repo's existing pinned installer assets.

---

## 7. Security posture (AUDIT.md alignment)

- **F1 (throwaway creds).** BMC `admin`/`password` on **loopback** (`127.0.0.1:623X`),
  node OS `root`/lab. README states in bold: never point a BMC at a real or networked
  host — IPMI-over-LAN is famously unauthenticated-by-default.
- **F2 (download integrity).** Optional-but-recommended: `provision` verifies the
  netboot payload via `imgverify` (RAM-INFRA ①) so a node deploys only signed images.
- **F7 (destructive-op guard).** `release`'s disk-wipe and `destroy`'s domain/pool
  teardown are **path/name-guarded and handed to the user** (`!`), never auto-run.
- **Kill by PID**, never `pkill -f` — `vbmcd`, QEMU/libvirt, and the probe VM share
  cmdline substrings (the serial.sock footgun).
- **Rootful caveat, framed honestly:** `vbmcd` needs the system libvirt socket →
  rootful container. The README carries the container-vs-host-install trade-off the
  VirtualBMC lab already documents.

---

## 8. Build order (dependency-aware) & verified-vs-author-run

1. **Fleet + registry** — `create-fleet.sh` (N domains + N `vbmc` ports) and
   `maas-lab.sh` with the state file + `enroll`/`list`. *Verifiable headless
   (state transitions provable without an install).* 
2. **Inspection step** — the probe initramfs + the `:8181` POST-back. *Verifiable in
   QEMU/libvirt: a node goes `manageable → available` carrying real CPU/RAM facts.*
3. **provision → deploy** — sequence the existing PXE install + `bootdev=disk` boot
   into the state machine. *Verifiable end-to-end (the underlying install is already
   ✅); a full multi-node parallel install may be **author-run** (time/host load).* 
4. **Phase-6 surface** — libvirt inventory source + actions panel; 6b/web parity.
   *TUI render verifiable; live drive shown in MANUAL_TESTING.*

Each step ends in a POC-style writeup with real transcripts; the lab ships
one-verdict smokes + EXIT-trap net; both catalogs stay green; anything env-blocked
(e.g. a big parallel install) is marked author-run with the exact handed-over command.

---

## 9. Open items / decisions to confirm

- **First increment scope** (needs a nod): recommend **(1) fleet+registry+state
  machine driving power/bootdev** — the novel spine, fully headless-verifiable — then
  review before wiring the inspection probe and the Phase-6 panel.
- **Node count for the "fleet"** — 3 feels right (enough to show pool semantics,
  light on the host). One BMC port per node (6230, 6231, …).
- **Whether inspection reuses `micro-linux` or a busybox initramfs** — leaning
  busybox (tiny, no toolchain box needed) for the probe.
- **Phase-6 vs. CLI-only for v1** — the state machine has standalone value; the panel
  can be a fast-follow if we want to land the control loop first.
