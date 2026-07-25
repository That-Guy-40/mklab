# BMC Toolkit Lab — Out-of-Band Management as Reusable Infra — Design Plan v1

> **Status**: Draft v1 — proposed 2026-07-24. **Extracted from
> `METAL_AS_A_SERVICE_LAB_PLAN.md` §11a/b/c** (the deferred vbmc/IPMI/SOL/Redfish
> work) and promoted to a lab of its own. Anchors on the completed
> `examples/virtualbmc-ipmi-lab/` (IPMI power + bootdev + PXE-install, all ✅) and
> reuses its libvirt domain + PXE assets. Plan only — no lab files created yet.
>
> **Proposed name:** `examples/bmc-toolkit/` (alt considered: `oob-management/`).
> Rename is a cheap call at assembly; the plan uses `bmc-toolkit` throughout.
>
> **Decisions locked (this session):**
> - **Scope = all three** deferred sections move here: Redfish/`sushy-tools` virtual
>   media (§11b), the richer IPMI surface — SDR/FRU/`sel`/chassis-identify (§11c),
>   **and** the faithful IPMI Serial-over-LAN spike via OpenIPMI `ipmi_sim` (§11a).
>   SOL is fundamentally ipmitool surface, so it belongs with the OOB transport layer.
> - **Positioning = reusable infra block.** Framed like `netboot/` / `nixos-ipxe-deploy`:
>   a BMC/out-of-band toolkit that *other* labs (MAAS increment 1, resilient-region)
>   import as their OOB control layer, behind a **stable, backend-pluggable verb
>   surface**. Lives under `examples/` but self-describes as a building block.
> - **Centerpiece = virtual media as a deploy path** (Redfish `InsertMedia` → boot an
>   ISO, *no PXE/DHCP at all*), with the **protocol-comparison tour** given a nod so it
>   reads as a teaching lab too — modular enough to rip out and reuse elsewhere.
> - **Real SOL is a goal, not a substitute.** The user's explicit steer: *"I want what's
>   in the plan, and a more real SOL implementation if we can get it."* v1 targets a
>   **genuine `ipmitool -I lanplus … sol activate`** session over RMCP+ (via `ipmi_sim`),
>   not the libvirt-console stand-in that `virtualbmc-ipmi-lab` and MAAS v1 ship. See §5.

---

## 1. What we're building

A **reusable out-of-band (OOB) management toolkit** for libvirt domains: one
protocol-agnostic verb surface (`bmc.sh <node> <verb>`) sitting over **three
interchangeable backends** —

| Backend | Speaks | Faithfully implements | This is |
|---|---|---|---|
| **`vbmcd`** (OpenStack VirtualBMC) | IPMI-over-LAN (UDP 623X) | power + boot-device | the ✅-proven baseline (`virtualbmc-ipmi-lab`) |
| **`ipmi_sim`** (OpenIPMI lanserv) | IPMI-over-LAN + **RMCP+/lanplus** | power + bootdev + **real SOL** + sensors/FRU/`sel`/identify | the *full* IPMI BMC (new) |
| **`redfish`** (`sushy-tools`) | Redfish (HTTPS/JSON) | power + boot override + **virtual media** + serial console | modern OOB (new) |

The point is not three demos — it's **one interface, three transports**, so a
consumer (the MAAS control plane, a resilient-region driver, or a one-off script)
says `bmc.sh node2 power on` / `bmc.sh node2 insert-media alma.iso` and *doesn't care*
which protocol reaches the metal. That's the abstraction real fleet software is built
on, and it's what makes this lab **rip-out-and-reuse infra** rather than a fourth
BMC demo.

```
   consumer (maas-lab.sh · region.sh · you at a shell)
        │  bmc.sh <node> power|bootdev|sol|insert-media|sensors|fru|sel|identify|inspect
        ▼
   ┌──────────────── bmc.sh — protocol-agnostic front door ────────────────┐
   │  --backend {vbmcd | ipmi_sim | redfish}   (per-node, from a registry)  │
   │      │                    │                        │                   │
   │      ▼                    ▼                        ▼                   │
   │  ipmitool ──IPMI──►   ipmitool -I lanplus ──►  redfishtool/curl ──►    │
   │   vbmcd:623X          ipmi_sim:623X            sushy-emulator:8000     │
   │      │                    │  SOL bridged            │  InsertMedia     │
   │      ▼                    ▼  to serial sock         ▼  mounts ISO      │
   │            libvirt domain  "node2"  (qemu:///system)                   │
   └────────────────────────────────────────────────────────────────────────┘
```

**The teaching arc:** a BMC is the machine's out-of-band hand, and there is more than
one protocol reaching for it. We build the smallest honest version of each, put a
single verb surface over all three, and — the centerpiece — show that Redfish
**virtual media** is a *whole new way to install an OS* (mount an ISO, boot it, no
netboot infrastructure required). Along the way we get the thing IPMI-over-libvirt
never had: **real Serial-over-LAN**.

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

| Capability | Status | Foundation to reuse |
|---|---|---|
| IPMI power / boot-device (baseline backend) | ✅ **verified** | `virtualbmc-ipmi-lab/` (`vbmcd`, `create-node.sh`, `setup-pxe-net.sh`) |
| A managed libvirt domain + NoCloud serial login | ✅ verified | `virtualbmc-ipmi-lab/create-node.sh` (Alpine gencloud + CIDATA seed) |
| PXE assets (for the `install`-over-IPMI comparison) | ✅ verified | `~/netboot` on `:8181`, `setup-pxe-net.sh` |
| Serial-console driving over a pty/socket | ✅ verified | `capture-login.py` (pty.fork), `tools/drive-pty-repl.py` |
| Install ISOs to feed virtual media | ✅ available | repo AlmaLinux / Alpine assets (reuse, don't re-download) |
| **Protocol-agnostic OOB verb surface (`bmc.sh`)** | ❌ **GAP (crux ①)** | — invent: front door + per-node backend registry + capability model |
| **`ipmi_sim` backend + real SOL bridge** | ❌ **GAP (the "more real" goal)** | — invent: `ipmi_sim` lan.conf/.emu + chassis→virsh shim + SOL→serial-socket wiring |
| **`redfish`/`sushy-tools` backend + virtual media** | ❌ **GAP (crux ②, centerpiece)** | — invent: sushy-emulator container + `InsertMedia`→boot-CD deploy path |
| **Richer IPMI surface (sensors/FRU/sel/identify)** | ❌ **GAP** | — invent: `ipmi_sim` SDR/FRU config (real, not stubbed — ipmi_sim provides these) |
| **Capability `inspect` (what does this backend faithfully do?)** | ❌ **GAP** | — invent: per-backend capability table the consumer can query |

Host reality (carried from the vbmc lab, restated in this lab's RUNBOOK):
- This is a **libvirt** lab (Phase 2 is raw QEMU); backends that drive `qemu:///system`
  run **rootful** (socket is `root:libvirt`).
- **One serial-console consumer at a time.** Real SOL and the libvirt console contend
  for the *same* QEMU serial device — and `create-node.sh` gives the node a **`--console
  pty`** today, which is claimed by whoever opens it first. The toolkit re-shapes the
  node to a **unix-socket ttyS0 the SOL bridge owns + a separate ttyS1 for `virsh
  console`** (§4a), so the two never fight. A design constraint, not a bug.
- `openipmi` (ships `ipmi_sim`) is in apt on this host; `sushy-tools 2.2.0` is on pip;
  `ipmitool`/`virsh`/`qemu`/`podman`/`genisoimage` all present. **Verified availability,
  not yet verified behavior** — the protocol surfaces (RMCP+ SOL framing, Redfish
  virtual-media mount) are the spikes.

---

## 3. Crux ① — the backend-pluggable OOB verb surface (the reusable interface)

The whole reason to lift this out of MAAS: give the repo **one OOB interface** that any
lab can call, with the protocol swappable per node. `bmc.sh` is that front door.

```
bmc.sh <node> [--backend vbmcd|ipmi_sim|redfish] <verb> [args]

  power {on|off|cycle|status}          all backends
  bootdev {pxe|disk|cdrom}             all backends (cdrom = virtual-media boot)
  sol                                  ipmi_sim (REAL) · redfish (serial console) ·
                                         vbmcd (honest libvirt-console substitute)
  insert-media <iso> | eject-media     redfish only  (virtual media — the centerpiece)
  sensors | fru | sel | identify {on|off}   ipmi_sim (real) · others → clear "unsupported"
  inspect                              print THIS node's backend + its capability table
```

- **Per-node backend registry** (`fleet-bmc.toml`): each node records which backend
  drives it and on which port/URL, so `bmc.sh node2 power on` needs no `--backend` flag
  in normal use — the toolkit looks it up. A consumer can run a **mixed fleet** (node1
  on vbmcd, node2 on redfish) behind the identical verb surface.
- **Capability model (the honesty spine).** Every backend declares which verbs it
  *faithfully* implements; an unsupported verb returns a **clear, non-zero "backend X
  does not implement Y"** — never a silent no-op or a faked success. `bmc.sh <node>
  inspect` prints the table, so a consumer (MAAS) can *ask* "does this node's BMC do
  virtual media?" before routing a deploy to it. This is the modular contract that lets
  another project import the toolkit and program against capabilities, not guesses.
- **`bmc.sh` never re-implements a protocol** — it dispatches to `ipmitool`,
  `ipmitool -I lanplus`, or **`curl` + `jq`** for Redfish (`redfishtool` isn't packaged
  on this host — candidate only — and `curl`+`jq` are present and portable, so the
  toolkit stays dependency-light; `redfishtool` is an optional human convenience the
  RUNBOOK mentions, not a requirement). Thin router, like the MAAS deploy drivers. If
  the toolkit is deleted, each backend's raw commands still work by hand (RUNBOOK
  documents them) — the house "layer is disposable" invariant.

The registry and the capability model are the two concrete artifacts a consumer
programs against — the stable API of the block:

```toml
# fleet-bmc.toml — the toolkit's OWN registry (independent of MAAS's fleet.toml, so
# the block is liftable standalone). One row per node; consumers look up the backend.
[[node]]  name = "node1"  backend = "vbmcd"     ipmi_port  = 6230
[[node]]  name = "node2"  backend = "ipmi_sim"  ipmi_port  = 6231   # real SOL here
[[node]]  name = "node3"  backend = "redfish"   redfish_url = "https://127.0.0.1:8000"
```

```console
$ bmc.sh node3 inspect
node3  backend=redfish  (sushy-emulator @ https://127.0.0.1:8000)
  power        : yes   (real → libvirt)
  bootdev      : yes   (pxe|disk|cdrom)
  sol          : yes   (Redfish serial console)
  virtual-media: yes   (InsertMedia/EjectMedia)          ← only redfish has this
  sensors/fru/sel/identify : partial (Redfish Chassis/Thermal only)
# machine-readable form for MAAS et al.:  bmc.sh node3 inspect --json → {"virtual-media": true, …}
```

A consumer asks `inspect --json` and routes on capabilities — e.g. MAAS only offers
`--driver virtual-media` for nodes whose backend reports `"virtual-media": true`.
Unsupported verbs never fake success; they exit non-zero with
`backend 'vbmcd' does not implement 'virtual-media' (try a redfish-backed node)`.

---

## 4. Crux ② — virtual media as a deploy path (the centerpiece)

IPMI can pick a *boot device*; it cannot *hand the machine an image*. **Redfish virtual
media can** — `InsertMedia` attaches an ISO to the node as a virtual CD/USB, a boot
override points at it, and `Reset` boots it. **No PXE, no DHCP, no TFTP** — the single
biggest ergonomic difference between old and new OOB, and a genuinely distinct
OS-delivery model from everything else in the repo.

```
  bmc.sh node2 insert-media almalinux.iso      # Redfish InsertMedia → virtual CD attached
  bmc.sh node2 bootdev cdrom                    # BootSourceOverride = Cd, one-time
  bmc.sh node2 power cycle                       # Reset → node boots the ISO's installer
      └─► Anaconda/live env comes up on the (Redfish) serial console — zero netboot infra
  bmc.sh node2 eject-media                        # detach when done
```

- **Flagship proof (MANUAL_TESTING signature):** a blank node boots an installer ISO
  attached *purely* over Redfish virtual media, reaching the installer's serial prompt —
  contrasted, in the same doc, against the vbmc lab's PXE-install-over-IPMI (which needs
  the whole `setup-pxe-net.sh` dnsmasq/TFTP/HTTP stack). Same outcome, radically less
  infrastructure.
- **`sushy-tools` = `sushy-emulator`**, VirtualBMC's Redfish sibling (same OpenStack
  lineage), libvirt backend. It exposes the node as a Redfish `System` with
  `VirtualMedia`, power, and boot-override. Runs as a disposable container (mirrors
  `Containerfile.vbmcd`), rootful for the same `qemu:///system` reason. **Front-end =
  `curl` + `jq`** against the Redfish REST API (no `redfishtool` dependency).
- **Mechanism (spike-confirm):** sushy-emulator's libvirt driver implements `InsertMedia`
  by **editing the domain XML to attach the ISO as a `<disk device='cdrom'>`** and
  tracking it as virtual media; the boot override sets a **one-time** `BootSourceOverride
  = Cd`. So the managed domain needs a **free cdrom slot** for virtual media (the NoCloud
  seed already uses one — the toolkit node provisions a *second* cdrom, §4a) and a
  firmware whose boot order honors a one-time CD override.
- **The 5th MAAS deploy driver, pre-built.** When MAAS wants `--driver virtual-media`,
  it's just `bmc.sh <node> insert-media … && bootdev cdrom && power cycle` against a
  redfish-backed node — the toolkit already provides it. That's the reuse payoff made
  concrete.
- **Spike to verify before claiming:** that `sushy-emulator`'s `InsertMedia` on the
  libvirt backend actually mounts a *bootable* virtual CD this QEMU/OVMF will boot from
  (UEFI vs SeaBIOS CD-boot quirks live here) — a clean documented negative on the
  BIOS/UEFI axis is acceptable; at least one firmware path must boot the ISO.

### 4a. The managed-domain shape (`create-node.sh` doesn't do this yet)

The sibling lab's `create-node.sh` defines a node with a **`--console pty` serial** and a
**BIOS** Alpine image — fine for power/bootdev, but **all three backends have opinions the
current shape doesn't satisfy**. The toolkit needs a node-definition profile (extend
`create-node.sh`, don't fork it) that is correct for every backend simultaneously:

| Need | Why | Change from today's node |
|---|---|---|
| **Serial on a unix socket** (not a pty) | the `ipmi_sim` SOL bridge must *own* the serial device (§5); a pty is claimed by whoever opens it first | `<serial type='unix'>` server socket at a known path |
| **A second `<serial>` (ttyS1) for `virsh console`** | so a human console and the SOL bridge don't fight over one device (the single-consumer rule) | add ttyS1 pty; getty stays on the SOL-bridged ttyS0 |
| **A free cdrom slot** | Redfish virtual media attaches the ISO as a cdrom; the NoCloud seed already occupies one | provision a second (empty) cdrom device |
| **A firmware choice knob** | virtual-media CD-boot + one-time override behaves differently on OVMF vs SeaBIOS (the open axis, §12) | `FIRMWARE=uefi\|bios` selecting OVMF or SeaBIOS + the matching cloud image |
| **A blank-disk variant** | the virtual-media *installer* demo wants an empty target to install onto | `DISK_SIZE=…` with no pre-baked OS (reuse the vbmc finale's blank-node path) |

This profile is the one genuinely new piece of node plumbing; everything downstream
(`bmc.sh`, the backends) assumes a node shaped this way. It's a small, well-scoped
extension — and it's why the domain-shape decisions (firmware, one vs two serials) are
called out as kickoff items in §12 rather than buried.

---

## 5. The "more real" SOL — a faithful `ipmitool sol activate` (the money shot)

**Where the repo stands today:** VirtualBMC has **no `activate_payload`**, so it speaks
no IPMI SOL; `virtualbmc-ipmi-lab` and MAAS v1 both ship the *honest substitute* —
libvirt's own `virsh console`. Correct and useful, but the bytes ride libvirt, **not**
an IPMI RMCP+ session. The user wants the real thing, and it's reachable:

- **OpenIPMI `ipmi_sim` (lanserv)** is a full IPMI BMC *simulator* that **does**
  implement SOL over RMCP+/lanplus and can **bridge the SOL payload to a serial
  device/socket/PTY**. Point its `sol` directive at the node's QEMU serial unix socket
  and `ipmitool -I lanplus -H 127.0.0.1 -p 623X -U admin -P password sol activate`
  streams the VM's **real** serial over a **genuine IPMI session** — RAKP handshake and
  all. *That* is real SOL.
- **The trade-off to resolve in the spike (documented honestly):** `ipmi_sim` is a
  *simulator*, so its chassis power/boot-device don't natively drive libvirt the way
  `vbmcd` does. Two faithful shapes, a fallback ladder:
  1. **`ipmi_sim` as the node's *whole* BMC (preferred, most real).** Wire its
     chassis-control hooks (power-on `startcmd`, power-off command) to a tiny
     **virsh-shim** (`virsh start/destroy <node>`), so *one* BMC on *one* port gives
     real power **and** real SOL over one lanplus session. This is the satisfying answer.
  2. **`ipmi_sim` *alongside* `vbmcd` (fallback).** Power/bootdev stay on `vbmcd:623X`;
     real SOL runs on `ipmi_sim:<other port>`. Clunkier (two BMCs), but isolates the new
     surface and still delivers a genuine `sol activate`.
  3. **Documented negative on RMCP+.** If the RAKP/SOL framing can't be made to bridge
     cleanly here, a clear write-up of *how far it got and where it broke* is an
     acceptable v1 outcome (house rule) — but (1)/(2) are expected to work; `ipmi_sim`
     SOL-to-PTY is a well-trodden path.
- **Serial-ownership guard (§2/§4a):** the SOL bridge must *own* the node's serial, and a
  pty is claimed by whoever opens it first — so the toolkit node routes **ttyS0 to a unix
  socket the `ipmi_sim` bridge opens**, and gives a human `virsh console` a **separate
  ttyS1** (the two-serial design in §4a). The getty lives on the SOL-bridged ttyS0 so
  `sol activate` shows a real login. `bmc.sh sol` still enforces single-ownership of the
  SOL socket and says so if it's already held (the vbmc lab's foreground-console lesson).
- **Provenance:** OpenIPMI docs → cite, don't mirror; **verify `ipmi_sim` SOL actually
  bridges before claiming it** (never enshrine an aspirational config as "working").
- *Risk: MEDIUM — RMCP+/RAKP session + SOL framing are real protocol surface. This is
  the lab's highest-risk, highest-payoff spike.*

---

## 6. The protocol-comparison tour (the teaching frame — "given a nod")

One page (RUNBOOK) drives the **same node** through **all three backends** and tabulates
what each *faithfully* implements vs. fakes vs. can't do — the honesty table that makes
this a teaching lab, not just infra:

| Verb | `vbmcd` (IPMI) | `ipmi_sim` (IPMI+) | `redfish` (sushy) |
|---|---|---|---|
| power on/off/cycle | ✅ real (→libvirt) | ✅ real (→virsh-shim) | ✅ real (→libvirt) |
| boot device | ✅ pxe/disk | ✅ pxe/disk | ✅ pxe/disk/**cd** |
| **SOL / serial** | ⚠️ libvirt-console substitute (no IPMI SOL) | ✅ **real SOL** (RMCP+) | ✅ Redfish serial console |
| **virtual media** | ❌ n/a | ❌ n/a | ✅ **InsertMedia** (centerpiece) |
| sensors / FRU / `sel` / identify | ❌ power+bootdev only | ✅ real (ipmi_sim SDR/FRU/SEL) | ⚠️ partial (Redfish Chassis/Thermal) |

Each ⚠️/❌ is a **teaching moment named in the doc**, not a gap swept under a rug — the
lab's value is precisely in being explicit about which toy diverges from real hardware
where. Note **`ipmi_sim` gives *real* sensors/FRU/SEL** (it's a proper BMC simulator),
so §11c's "stub SDR/FRU" idea is *superseded* — we get the genuine surface, clearly
flagged as a simulator's fixtures rather than a physical box's telemetry.

---

## 7. How MAAS (and others) consume it — the rip-out-and-reuse contract

- **MAAS increment 1** stops calling `vbmcd` directly and calls **`bmc.sh <node>
  power/bootdev/console`** instead — same behavior today, but its `console`/`sol` verb
  and any future virtual-media driver come "for free" the moment a node's backend is
  `redfish`/`ipmi_sim`. MAAS's deploy interface programs against `bmc.sh inspect`
  capabilities, not a hardcoded protocol.
- **Resilient-region / any future lab** needing to power-cycle or console a node imports
  the same toolkit — no BMC code of its own.
- **Standalone value:** `bmc.sh` + the three backend containers run with **zero** other
  labs present (only a libvirt domain), so it's genuinely liftable into another project
  or a real (lab-only) deployment. The README leads with the "import me" contract:
  the verb surface, the capability model, and the backend registry format are the stable
  API; everything else is internal.

---

## 8. New components & files

| File | Type | Notes |
|---|---|---|
| `BMC_TOOLKIT_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/bmc-toolkit/bmc.sh` | new | the front door: verb surface + per-node backend dispatch + capability `inspect` (§3) |
| `examples/bmc-toolkit/fleet-bmc.toml` | new | per-node backend registry (which backend/port/URL drives each node) |
| `examples/bmc-toolkit/backends/vbmcd.sh` | new (thin) | wrap the proven vbmcd path (reuses `virtualbmc-ipmi-lab` assets) |
| `examples/bmc-toolkit/backends/ipmi_sim.sh` | new | lan.conf/.emu render, chassis→virsh shim, SOL→serial-socket bridge (§5) |
| `examples/bmc-toolkit/backends/redfish.sh` | new | sushy-emulator control via `curl`+`jq`: power/boot-override/**virtual media** (§4) |
| `examples/bmc-toolkit/create-node.sh` | new (extends sibling) | the multi-backend node profile (§4a): socket ttyS0 + pty ttyS1, second cdrom, `FIRMWARE=uefi\|bios`, blank-disk variant |
| `examples/bmc-toolkit/Containerfile.ipmi_sim` | new | OpenIPMI `ipmi_sim` as a disposable container (rootful, libvirt socket) |
| `examples/bmc-toolkit/Containerfile.sushy` | new | `sushy-tools`/sushy-emulator container (pin 2.2.0), libvirt backend |
| `examples/bmc-toolkit/tests/` | new | one-verdict smokes: capability `inspect` per backend, power round-trip per backend, unsupported-verb → clear error (`REGRESSION:` on silent-no-op), SOL bridge liveness, virtual-media attach. EXIT-trap net, SKIP=77 for env-blocked |
| `examples/bmc-toolkit/{README,RUNBOOK,MANUAL_TESTING}.md` | new | README leads with the reuse contract; RUNBOOK = the protocol tour (§6) + by-hand real `ipmi_sim`/`sushy`/`ipmitool`/`redfishtool`; MANUAL_TESTING = real SOL + virtual-media transcripts |
| `examples/00-INDEX.md` | edit | one row (Phase-2 / libvirt section, next to `virtualbmc-ipmi-lab`) |
| `examples/learning-paths.toml` | edit | route as a step in the **`zero-touch-provisioning`** path (right **after `virtualbmc-ipmi-lab`** — the "now go deeper on the OOB protocols" follow-on) + add to the **`close-to-the-metal`** collection; observable checkpoints = a **real `sol activate`** session + a **virtual-media ISO boot**. Then `paths.py render && --check`. |

`virtualbmc-ipmi-lab` stays **standalone and unchanged**; this lab reuses its
`create-node.sh`/PXE assets and cites its provenance — no duplication. MAAS's plan is
trimmed (its §11a/b/c point here) but MAAS builds independently.

---

## 9. Provenance (cite-and-vendor)

- **VirtualBMC** how-tos already vendored under `virtualbmc-ipmi-lab/upstream-tutorial/`
  — cite the sibling, don't re-mirror (self-containment).
- **OpenIPMI / `ipmi_sim` / lanserv** docs, **`sushy-tools`** docs, and the **Redfish
  spec** (DMTF) → **cite, don't mirror** (URL + retrieved date): official docs / upstream
  code, not one blog post. Pin the `sushy-tools` version (2.2.0) and the `openipmi`
  package version actually built against.
- **Verify each source resolves + the behavior reproduces before hashing/claiming** —
  especially the SOL bridge and virtual-media mount (never enshrine an aspirational
  config).

---

## 10. Security posture (AUDIT.md alignment)

- **F1 (throwaway creds).** All BMCs on **loopback** — `vbmcd`/`ipmi_sim` on
  `127.0.0.1:623X`, sushy-emulator on `127.0.0.1:8000`. `admin`/`password`, Redfish
  `admin`/`password`, SOL lanplus password all lab-only. README bolds: IPMI/Redfish are
  unauthenticated-or-weak by default — **never** point a BMC at a real/networked host.
  Non-loopback `lanplus` is explicitly out of scope until the framing is tightened.
- **F7 (destructive-op guard).** Virtual media itself is non-destructive, but the ISO's
  *installer* wipes disks — so any install-to-disk step is **guarded and handed to the
  user** (`!`), never auto-run. `eject-media`/`destroy` are name-guarded.
- **Kill by PID**, never `pkill -f` — `ipmi_sim`, `sushy-emulator`, `vbmcd`, and QEMU
  share cmdline substrings (serial-socket paths, ports); resolve to a PID first.
- **Rootful backends** framed honestly (the `qemu:///system` socket is `root:libvirt`);
  the container-vs-host trade-off carried from the vbmc lab, restated per backend.
- **Serial-ownership single-consumer guard** (§2/§5) is also a safety property: no
  two consumers silently fighting over one console.

---

## 11. Build order (spikes) & verified-vs-author-run

Out-of-tree spikes de-risk the two real unknowns (SOL, virtual media) first, then
assemble behind `bmc.sh`.

1. **`bmc.sh` skeleton + `vbmcd` backend + capability model.** Wrap the ✅-proven vbmcd
   path behind the verb surface; `inspect` prints its (power+bootdev-only) capabilities;
   unsupported verbs error cleanly. *Fully headless-verifiable — pure refactor over a
   working lab.*
2. **Spike A — real SOL via `ipmi_sim` (§5, highest risk first).** lan.conf/.emu +
   chassis→virsh shim + SOL→serial-socket bridge; prove `ipmitool -I lanplus … sol
   activate` streams the live console. Resolve shape (1) whole-BMC vs (2) coexist.
   *Verifiable headless (the marquee proof); a documented negative on RMCP+ is the
   acceptable floor.*
3. **Spike B — virtual media via `sushy-tools` (§4, the centerpiece).**
   `InsertMedia` → `bootdev cdrom` → boot the ISO's installer over the Redfish console;
   resolve the UEFI/BIOS CD-boot axis. *Verifiable in QEMU; at least one firmware path
   must boot the ISO.*
4. **`ipmi_sim` richer surface** — real `sensors`/`fru`/`sel`/`identify` wired into
   `bmc.sh`. *Headless-verifiable (`ipmitool sensor`/`fru`/`sel` return real data).*
5. **Registry + mixed-fleet + `inspect` across all three; docs + routing.** A node on
   each backend, driven by the identical verb surface; the protocol-comparison tour
   (§6) captured with real transcripts. *Verifiable; anything env-blocked marked
   author-run with the exact handed-over command.*

**Verified-vs-author-run reality (stated up front, not discovered late).** Like
`virtualbmc-ipmi-lab`, this lab is **rootful libvirt + `sudo podman`** end to end, and the
agent's Bash runner cannot `sudo` — so the *protocol logic* (verb dispatch, capability
table, unsupported-verb errors, config rendering, TOML parsing) is agent-verifiable
headless, but the **live proofs** — launching the `ipmi_sim`/sushy containers, the
`qemu:///system` domain ops, the real `sol activate` session, the virtual-media boot —
are **author-run**: handed over as one-shot scripts, with their output read back and
folded into MANUAL_TESTING (the exact pattern that captured the vbmc finale). The plan
does not claim any live BMC/SOL/virtual-media result as agent-verified; each is marked
author-run with the command handed over.

Each spike ends in a POC-style writeup with real logs; the lab ships one-verdict smokes
+ EXIT-trap net; both catalogs stay green.

**Fast-follows (documented, not v1):** Redfish-driven *measured* boot (attested virtual
media, ties to systemd261); a real (non-loopback) `lanplus` variant behind hardened
framing; `bmc.sh` as MAAS increment 1's actual OOB layer (§7).

---

## 12. Decisions (resolved 2026-07-24) & open items

- **Scope:** Redfish + full IPMI + **real SOL** — all of MAAS §11a/b/c move here. ✔
- **Positioning:** reusable infra block behind a backend-pluggable `bmc.sh` verb
  surface + capability model. ✔
- **Centerpiece:** Redfish virtual-media-as-a-deploy-path; protocol tour as teaching
  frame. ✔
- **Real SOL:** targeted for v1 via `ipmi_sim` (not the libvirt-console substitute),
  with a documented fallback ladder. ✔

**Open (settle at kickoff, not blocking the plan):**
- **Managed domain firmware for virtual media** — UEFI (OVMF) vs BIOS (SeaBIOS) CD-boot;
  pick the one that boots the ISO cleanest, document the other as a known axis.
- **`ipmi_sim` SOL shape** — whole-BMC (preferred) vs coexist-with-vbmcd; decided by what
  the Spike A bridge actually supports.
- **Does MAAS re-point onto `bmc.sh` in increment 1, or after?** Leaning "after" — keep
  the toolkit and MAAS increment 1 independently buildable; wire them once both are ✅.
