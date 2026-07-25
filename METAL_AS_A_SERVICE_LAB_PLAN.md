# Metal-as-a-Service Lab — Design Plan v2.1

> **Status**: Draft v2 — proposed 2026-07-24 (option **B** of the "what can we
> compose?" survey). Anchors on `examples/virtualbmc-ipmi-lab/` (IPMI power +
> boot-device + PXE install, all ✅ verified), the netboot PXE-install pipeline
> (`netboot/`, `examples/almalinux-pxe-lab/`, `examples/debian-pxe-lab/`), and the
> Phase-6 TUI / Phase-6b web surface.
>
> **Decisions locked (this session):**
> - **State machine = full Ironic-faithful** — not just the happy path but
>   `cleaning`, `error`/`maintenance`, and `rescue` (a recovery ramdisk over IPMI,
>   reusing `root-password-reset`).
> - **Deploy is a pluggable *interface*** with **four drivers** — `install`
>   (kickstart/preseed), `ramdisk` (RAM-boot), `image` (golden dd), and
>   `image+measured` (dd + TPM-attested activation gate, folding option A in). This
>   is the reframe that turns B into the **integration hub** for every OS-delivery
>   mechanism the repo has proven.
> - **`ramdisk` driver gets a catalog** — not only the RAM-INFRA trio but also
>   `micro-linux` (from-source kernel+initramfs) and the `tiny-linux-experiments`
>   images (floppinux, busybox). B becomes a launcher for *every RAM-bootable
>   artifact in the repo*.
> - **Build order = spine first, converge later** — v1 builds the full state machine
>   + `install` + `ramdisk` drivers; `image` follows closely (reuses systemd261
>   Tier-B); `image+measured` and full region-wiring are the documented fast-follows.
>
> **v2.1 additions (this pass) — three refinements folded in so they aren't lost:**
> - **Node-level A/B rollback + health-gated activation (v1).** `deploy` reaches
>   `active` only through a **post-deploy health gate**; a node that fails it **rolls
>   back to its `previous` image** (reuses RAM-INFRA ④) instead of dead-ending in
>   `error`. The supply-chain story completes *inside* the control plane. See §4b.
> - **Declarative `apply` / reconciliation (v1.5 stretch).** Beyond the imperative
>   verbs, a `fleet.toml` **declares desired end-state** and `maas-lab.sh apply`
>   **reconciles** to it — the control-loop real fleet managers (MAAS / Terraform /
>   Kubernetes) are built on. Imperative spine lands first; `apply` sits on top. See §3a.
> - **Boot-progress in the Phase-6 panel (polish).** Parse each node's serial console
>   for milestones (`partitioning → installing → first-boot`) → **live progress bars**,
>   so you *watch* a fleet install in parallel rather than read static states. See §5.
>
> **Build-ready (2026-07-24).** Open items settled (§11 → §10): **3-node** fleet, a
> **busybox** inspection probe + **`root-password-reset`-idiom** rescue ramdisk,
> **CLI-first v1** (Phase-6 panel is step 7 / fast-follow — the headless `watch`
> milestone stream already delivers the "watchable" value without the TUI). The
> deferred **out-of-band transport** work — a faithful IPMI **Serial-over-LAN** path,
> a **Redfish virtual-media** driver, and the **richer IPMI surface** — has been
> **lifted into its own reusable lab**, `BMC_TOOLKIT_LAB_PLAN.md`, which MAAS consumes
> for its OOB layer (see §11). Plan only; no lab files created yet — ready to start v1
> on the word.

---

## 1. What we're building

A miniature **bare-metal control plane** that treats each libvirt domain as a
**node with an Ironic-faithful lifecycle**, and — the key reframe from v1 — makes
the **deploy step a pluggable interface** so the *same* control plane can hand a bare
machine *any* of the repo's proven OS-delivery models: install-to-disk, dd-a-golden-
image, or boot-into-RAM. That single abstraction is what real metal clouds
(OpenStack **Ironic**, Canonical **MAAS**, **Tinkerbell**) are built around, and it's
what makes this lab tour the whole repo instead of wrapping one PXE installer.

```
     operator (Phase-6 panel  ·  or  maas-lab.sh)
         │  enroll · manage · inspect · provide · deploy --driver X · rescue · release
         ▼
   ┌───────────────────────── control plane ─────────────────────────────┐
   │  node registry + FULL state machine (§3)                             │  [NEW]
   │     enrolled→verifying→manageable→cleaning→available→deploying→active │
   │                    ↘ rescue ↘ error ↘ maintenance                    │
   │        │                                                             │
   │        ├─ power / bootdev ──► vbmcd ──libvirt──► domain  (✅ vbmc lab)│
   │        ├─ inspect ─► RAM probe reports CPU/RAM/NIC → schedulable facts│  [NEW]
   │        ├─ cleaning ─► wipe disk between tenants (data-remanence)      │  [NEW]
   │        └─ DEPLOY INTERFACE ──► one of four drivers (§4):              │  [NEW: crux]
   │              install · ramdisk · image · image+measured              │
   └──────────────────────────────────────────────────────────────────────┘
         ▲
   Phase-6 inventory ── reads registry + `virsh list` → each node's STATE + driver
```

**The teaching arc:** how a data centre provisions metal it can't touch — the BMC is
the out-of-band hand, a *deploy interface* abstracts "make this node run something,"
and a state machine sequences it and never lets a node skip `cleaning`. We build the
smallest honest version of all three, and name every place the toy diverges from the
real thing.

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

The headline finding, sharpened by v2: **the deploy drivers are already built** — as
separate labs. B is the *abstraction over them* + the lifecycle + the fleet.

| Capability | Status | Foundation to reuse |
|---|---|---|
| IPMI power / boot-device / console | ✅ **verified** | `virtualbmc-ipmi-lab/` (`power`/`bootdev`; console = libvirt `virsh console`, no SOL) |
| Deploy driver `install` (PXE+kickstart/preseed) | ✅ verified | vbmc PXE finale · `almalinux-pxe-lab` · `debian-pxe-lab` |
| Deploy driver `ramdisk` (boot into RAM) | ✅ verified | RAM-INFRA trio · `micro-linux/ --baked` · `tiny-linux-experiments` (floppinux, busybox) |
| Deploy driver `image` (dd golden whole-disk) | ✅ verified | `systemd261` Tier-B · `nixos-ipxe-deploy` |
| Deploy driver `image+measured` (dd + attest) | ✅ verified (parts) | `systemd261` spikes D/G (dm-verity/UKI + TPM2 attest) |
| Signed payloads for `ramdisk`/`image` | ✅ verified | `netboot/sign-payload.sh` + `--imgverify` (RAM_INFRA ①) |
| Recovery ramdisk for `rescue` | ✅ verified | `root-password-reset/` (init-shell recovery, now IPMI-driven) |
| Read-only cross-phase inventory UI | ✅ landed | `phase6-tui/`, `phase6b-web/` |
| **N-node libvirt fleet + BMC per node** | ❌ **GAP** | — invent: `create-fleet.sh` (ports 623X) |
| **Node registry + full Ironic state machine** | ❌ **GAP (crux)** | — invent: `maas-lab.sh` state file + verbs |
| **The pluggable DEPLOY INTERFACE** | ❌ **GAP (crux)** | — invent: a driver dispatch that routes to the labs above |
| **Inspection probe + `cleaning` wipe** | ❌ **GAP** | — invent: RAM probe POSTs facts; guarded disk wipe |
| **Per-node metadata / config-drive** | ❌ **GAP** | — invent: NoCloud user-data service (reuses cloud-init) |
| **Phase-6 sees libvirt domains + node state** | ❌ **GAP** | — invent: a `libvirt`/`maas` inventory source |

Host reality: this is the repo's **only libvirt** family (Phase 2 is raw QEMU);
`vbmcd` runs **rootful** (system socket is `root:libvirt`). Phase 6 has **no libvirt
awareness today** — a new inventory source is required work, not a config tweak.

---

## 3. Crux ① — a full Ironic-faithful state machine

v1's straight line skipped the parts that make provisioning *actually* hard — and each
missing state maps to a real ops/security lesson, reusing repo assets:

```
  enrolled ─manage──► verifying ─(BMC creds OK)─► manageable ◄────────────┐
                                                     │ inspect (RAM probe)  │
                                                     ▼                      │
  ┌──────────── provide ───────────────────────────────────┐               │
  │  manageable ─► cleaning (WIPE) ─► available             │               │
  └──────────────────────────────────────────────────────────┘             │
     available ─deploy --driver X─► deploying ─► active                     │
        active ─rescue──► rescuing ─► rescue ─unrescue──► active            │
        active ─release/undeploy──► deleting ─► cleaning ─► available ──────┘
     (any step can fail ─► error;  operator can flag ─► maintenance)
```

- **`cleaning` (data remanence).** A wipe between tenants — a **security boundary,
  not housekeeping**. Guarded + handed to the user (F7). Teaching contrast: the
  `ramdisk` driver persists nothing, so its "clean" is a no-op — the cleanest way to
  *show* why disk-deploy needs an explicit wipe and RAM-deploy doesn't.
- **`error` + `maintenance`.** The unhappy path most demos hide: an install that never
  completes → `error` → operator `retry` or `maintenance` (pull it out of scheduling).
  Makes the machine feel real; teaches that provisioning is a saga, not a call.
- **`rescue`.** Boot a recovery ramdisk over IPMI to fix a broken node — a direct
  reuse of `root-password-reset`'s init-shell recovery, now *driven by the BMC* instead
  of by hand at the console. The two labs cross-link.
- **`verifying`/`inspect`.** `verifying` checks the BMC creds actually work
  (`ipmitool … chassis status`); `inspect` boots a tiny RAM probe whose `/init` reads
  `/proc/cpuinfo`+`/proc/meminfo`+NIC MAC and `curl`s them back to `:8181`, populating
  **schedulable facts** (Ironic introspection, in miniature).

### 3a. Declarative `apply` — reconcile to a desired end-state (v1.5 stretch)

The imperative verbs (`deploy`, `rescue`, …) are how you *drive* a node by hand; the
concept every real fleet manager (MAAS, Terraform, Kubernetes) is actually built on is
**reconciliation** — you *declare* the end-state and the tool computes the transitions.
`maas-lab.sh apply <fleet.toml>` adds that loop on top of the same state machine:

```toml
# fleet.toml — desired end-state, not a script
[[node]]  name = "edge1"  driver = "ramdisk"  image = "anycast-dns-ram"  count = 2
[[node]]  name = "app"    driver = "image+measured"  image = "nixos-verity"  count = 1
[pool]    available = 2        # keep this many wiped + ready
```

`apply` diffs desired-vs-actual (read from the registry) and issues exactly the
missing transitions — `provide` a node from the pool, `deploy` it with the named
driver, `release` a node that's no longer wanted (→ `cleaning` → back to pool). Run it
again and it's a **no-op** (idempotent — the reconciliation invariant). It teaches the
single most important idea in modern infra: *state is declared, drift is corrected, the
same command is safe to run forever.* Sits cleanly atop v1's imperative spine, so it
lands **after** the machine is proven, not entangled with it.

---

## 4. Crux ② — the pluggable deploy interface (the integration hub)

`maas-lab.sh deploy <node> --driver {install|ramdisk|image|image+measured}`. Each
driver is mostly *routing* to a lab that already works; the abstraction is the value.

| Driver | Mechanism | Reaches `active` when | Reuses |
|---|---|---|---|
| **`install`** | `bootdev=pxe` → Anaconda/preseed writes OS to disk → installer powers off → `bootdev=disk` boot | the installed OS's serial login/SSH is up | `almalinux-pxe-lab`, `debian-pxe-lab`, vbmc finale |
| **`ramdisk`** | `bootdev=pxe` → iPXE fetches a (signed) kernel+initrd → boots into RAM, no disk write | the RAM image's health signal / login banner is up | RAM-INFRA trio · `micro-linux` · floppinux · busybox |
| **`image`** | `bootdev=pxe` → deployer ramdisk **dd's a golden whole-disk image** onto the disk → reboot | the deployed image boots to `active` | `systemd261` Tier-B · `nixos-ipxe-deploy` |
| **`image+measured`** | as `image`, but the golden image is **dm-verity/UKI**; node only advances to `active` **if TPM attestation passes** | attestation (PCR quote) verifies — else → `error` | `systemd261` spikes D/G |

### 4a. The `ramdisk` image catalog (the launcher idea)

`--driver ramdisk --image <name>` selects from a registry of RAM-bootable payloads —
so B is a single front door to every "boots entirely into RAM" artifact the repo has:

| `--image` | What boots | Observable `active` signal |
|---|---|---|
| `anycast-dns-ram` / `cdn-edge-ram` / `package-mirror-ram` | a stateless RAM-INFRA service node (**B provisions a C-tier node**) | service answers (`dig`/HTTP) + BGP announce |
| `micro-linux-x86_64` | from-source kernel + BusyBox/u-root initramfs | console login prompt (`root`/`micro`) |
| `floppinux` | the 1.44 MB floppy distro | floppinux boot banner + `root`/`lab` login |
| `busybox-netboot` | the repo's minimal busybox initramfs | serial shell prompt |

Every catalog entry can be **signed** (`sign-payload.sh`) and boot-verified
(`imgverify`), so supply-chain gating spans `ramdisk` *and* `image` — the same F2
mechanism the RAM-INFRA lab proved, now reachable through the control plane.

**Honest framing:** `image+measured` runs on **swtpm** — the wiring is faithful but
swtpm is *not* a trust anchor (anything reading its userspace forges PCRs). The gate
proves the *mechanism and the refusal path*, not a real chain (per the systemd261
lab's load-bearing caveat, restated here).

### 4b. Health-gated activation + node-level A/B rollback (v1)

`deploying → active` is **not** "the boot command returned" — it's a **health gate**.
Every driver declares a success signal (§4 table: service answers / login banner /
attestation verifies); `deploy` polls it within a timeout, and only a *pass* advances
the node to `active`. A **fail** doesn't dead-end in `error` — it triggers a
**rollback to the node's `previous` image** (the RAM-INFRA ④ A/B mechanic, applied per
node), and *that* image's health is gated too:

```
  deploy --driver X --image v2
     └─ boot v2 ─► health gate ─PASS─► active (current=v2, previous=v1)
                        └────────FAIL─► roll back ─► boot v1 ─► health gate
                                                          ├─PASS─► active (degraded: on previous)
                                                          └─FAIL─► error (both slots bad; operator)
```

So a bad image can **never** take down a node that had a good one — the worst case is
"stayed on the previous good image," not "brick." This folds the supply-chain
guarantee (a build that fails `imgverify` *or* fails its health check is refused)
straight into the lifecycle, and it's cheap because A/B + rollback already exist and
are proven. `current`/`previous` per node live in the registry; the tamper→rollback
drill (flip one initrd byte → verify fails → node stays on `previous`) is a required
MANUAL_TESTING signature, mirroring RAM-INFRA §13.

---

## 5. Surfacing it — the Control Pane (now its own reusable lab)

This section was **extracted into `CONTROL_PANE_LAB_PLAN.md`** (`examples/control-pane/`) —
a **live control surface any lab plugs into** (a live inventory source + a node-actions
panel + a user-definable `milestones.toml` progress engine, with a headless-first core so
it works with no TUI). **MAAS is its first consumer:** MAAS provides the inputs (its node
registry, each node's console, a `milestones.toml`, its verb table) and gets the surface
for free. The three pieces below now *live in the control-pane lab*; the anchors remain so
this plan's cross-references resolve.

- **5a. Live inventory source.** The control-pane `BackendRunner` lists MAAS nodes ⋈ their
  **state + deploy driver** in the Phase-6 tree (`node2 ● active [image+measured]`).
  Read-only, established Phase-6 style. (Provided by the control-pane lab.)
- **5b. Node-actions panel + `console`/`sol`.** Key-bindings call MAAS's verbs
  (`inspect/provide/deploy/rescue/release`), streaming output into the lower pane.
  **`console`/`sol`** = the node's **libvirt serial console** — the honest SOL *substitute*;
  the **faithful** `ipmitool -I lanplus … sol activate` now lives in the **bmc-toolkit lab**
  (§11), which MAAS can target for real SOL. Invariant: if Phase 6 is deleted, `maas-lab.sh`
  + `control-pane watch` still drive everything.
- **5c. Watchable boot-progress via `milestones.toml`.** The user-definable
  regex→label→`at%`/`terminal` engine (now the control-pane lab's crux): patterns are plain
  regex (no eval), `at` is explicit (no interpolation), unmatched shows a spinner (never a
  fake 100%), and a stalled set feeds the `error`/`maintenance` path (§3). A driver's
  **`terminal` milestone doubles as its health-gate "reached active" marker (§4b)** — one
  declaration, consumed by the health gate *and* the progress bars. MAAS ships
  `install`/`ramdisk`/`image` milestone **profiles**; the engine + headless `watch` come
  from the control-pane lab.

---

## 6. New components & files

| File | Type | Notes |
|---|---|---|
| `METAL_AS_A_SERVICE_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/metal-as-a-service/maas-lab.sh` | new | control plane: full state machine + imperative verbs + deploy-driver dispatch + health-gated activation w/ A/B rollback (§4b) + `apply` reconcile (§3a) + `console`/`sol` (libvirt serial; honest SOL substitute, §5b). `watch` delegates to `control-pane watch` (CONTROL_PANE_LAB_PLAN.md) |
| `examples/metal-as-a-service/drivers/{install,ramdisk,image,image-measured}.sh` | new | one file per deploy driver — each a thin router to the reused lab; declares its health-gate/`terminal` signal |
| `examples/metal-as-a-service/ramdisk-catalog.toml` | new | the `--image` registry (RAM-INFRA + micro-linux + floppinux + busybox), each with its `active`-signal marker |
| `examples/metal-as-a-service/milestones.toml` | new | MAAS's milestone **profiles** (`install`/`ramdisk`/`image`; regex → label → `at%`/`terminal`) — *consumed by the control-pane lab's engine* (`CONTROL_PANE_LAB_PLAN.md`), not a MAAS-local parser |
| `examples/metal-as-a-service/create-fleet.sh` | new | N libvirt domains + `vbmc add` each on 623X (wraps vbmc `create-node.sh`) |
| `examples/metal-as-a-service/fleet.toml` | new | the fleet: hardware spec (count, disk/RAM, PXE network) **and** the declarative desired end-state consumed by `apply` (§3a) |
| `examples/metal-as-a-service/probe-init.sh` | new | inspection initramfs `/init`: POST CPU/RAM/MAC to `:8181`, power off |
| `examples/metal-as-a-service/rescue-init.sh` | new | `rescue` recovery ramdisk (reuses root-password-reset recovery idioms), IPMI-driven |
| `examples/metal-as-a-service/metadata-serve.sh` | new | per-node NoCloud user-data (hostname/SSH key) — DRY fleet from one image |
| `examples/metal-as-a-service/tests/` | new | one-verdict smokes: state transitions (dry), `cleaning` no-op vs wipe, driver dispatch; EXIT-trap net, `REGRESSION:` on the wipe-happened guard |
| *(Phase-6 surface)* | — | **provided by the control-pane lab** (`CONTROL_PANE_LAB_PLAN.md`): the live inventory source, actions panel, and progress bars. MAAS is a consumer — its nodes appear via the control-pane inventory source; no MAAS-local TUI code |
| `examples/metal-as-a-service/{README,RUNBOOK,MANUAL_TESTING}.md` | new | concept + Ironic-state mapping + "divergences from real Ironic/MAAS" table + verified transcripts |
| `examples/00-INDEX.md` | edit | one row (Phase-2/libvirt section, near the VirtualBMC row) |
| `examples/learning-paths.toml` | edit | route as a step **after `virtualbmc-ipmi-lab`** in a "bare-metal provisioning" journey; observable checkpoint = a node reaching `active` via each driver. Then `paths.py render && --check`. |

The four source-lab families stay **standalone and unchanged**; the drivers
*reference* them (and their vendored provenance) — no duplication.

---

## 7. Provenance (cite-and-vendor)

- **VirtualBMC** how-tos already vendored under `virtualbmc-ipmi-lab/upstream-tutorial/`;
  B builds on that lab and cites it (self-containment).
- **OpenStack Ironic** *node states* + the *deploy-interface* model, and **MAAS**
  lifecycle docs → **cite, don't mirror** (URL + retrieved date): the state machine and
  driver abstraction are "official docs / upstream code," not one blog post.
- Each deploy driver cites its source lab's existing provenance; no re-mirror.

---

## 8. Security posture (AUDIT.md alignment)

- **F1 (throwaway creds).** BMC `admin`/`password` on **loopback** (`127.0.0.1:623X`);
  README bolds: IPMI-over-LAN is unauthenticated-by-default — never point a BMC at a
  real/networked host.
- **F2 (download integrity).** `ramdisk`/`image` drivers deploy **signed** payloads
  (`imgverify`); `image+measured` additionally gates on attestation.
- **F7 (destructive-op guard).** `cleaning`'s disk wipe, `release`, and `destroy` are
  **path/name-guarded and handed to the user** (`!`), never auto-run. The wipe is a
  *first-class* teaching object (data remanence), not an afterthought.
- **Kill by PID**, never `pkill -f` — `vbmcd`, QEMU/libvirt, probe/rescue VMs share
  cmdline substrings (the serial.sock footgun).
- **Rootful `vbmcd`** framed honestly (system libvirt socket); container-vs-host
  trade-off carried from the vbmc lab.

---

## 9. Build order (dependency-aware) & verified-vs-author-run

1. **Fleet + registry + full state machine** — `create-fleet.sh` + `maas-lab.sh` with
   the state file, all transitions, `power`/`bootdev`, `cleaning` (guarded), `error`/
   `maintenance`, `rescue`. *State transitions fully headless-verifiable without an
   install.*
2. **`inspect` probe + metadata service + `milestones.toml`/`watch`** — RAM probe fills
   schedulable facts; NoCloud user-data; the console-milestone parser lands here as the
   headless `maas-lab.sh watch <node>` (the same file the Phase-6 bars consume later).
   *Verifiable: `manageable → available` with real CPU/RAM facts; `watch` prints the
   milestone stream.*
3. **`install` driver + the health-gated activation loop (§4b)** — sequence the PXE
   install into `deploy`, and build the **health-gate + A/B rollback** here (the first
   driver to reach `active` needs it). *End-to-end verifiable (underlying install ✅);
   the tamper→rollback drill is headless; a full multi-node parallel install may be
   author-run (host load).* 
4. **`ramdisk` driver + catalog** — dispatch to RAM-INFRA / micro-linux / floppinux /
   busybox, signed + `imgverify`-gated, reusing step 3's health gate. *Fully verifiable
   in QEMU per catalog entry (each has an existing boot signature).* 
5. **`image` driver** — dd golden image (Tier-B reuse), same health gate. *Verifiable
   in QEMU.*
6. **`apply` reconcile (v1.5, §3a)** — the declarative loop atop the imperative spine;
   diff desired-vs-actual, issue the missing transitions, prove idempotent (second run
   = no-op). *Fully headless-verifiable (registry-level, no install needed to prove the
   diff logic).* 
7. **Phase-6 surface** — **built in the control-pane lab** (`CONTROL_PANE_LAB_PLAN.md`):
   the live inventory source + actions panel + boot-progress bars; MAAS wires in as its
   first consumer (its nodes + `milestones.toml` profiles). *TUI render verifiable there;
   MAAS's live drive shown in its MANUAL_TESTING.*

**Fast-follows (documented, not v1):** `image+measured` attested gate (folds option A);
`ramdisk`→region wiring so a deployed node *joins* a resilient region (folds option C);
a flavor/tag **scheduler** on top of `apply` (pick an available node by inspected facts).

Each step ends in a POC-style writeup with real transcripts; the lab ships one-verdict
smokes + EXIT-trap net; both catalogs stay green; anything env-blocked is marked
author-run with the exact handed-over command.

---

## 10. Decisions (resolved 2026-07-24)

- **State machine:** full Ironic-faithful (cleaning · error/maintenance · rescue). ✔
- **Deploy drivers:** all four designed in — `install` + `ramdisk` in v1, `image`
  close behind, `image+measured` as the marquee fast-follow. ✔
- **`ramdisk` catalog:** RAM-INFRA trio **+ micro-linux + floppinux + busybox**. ✔
- **Convergence:** spine first; measured-attested gate and region-join are documented
  fast-follows. ✔

**v2.1 (resolved 2026-07-24):**
- **Health-gated activation + node-level A/B rollback** — in v1; `deploy` reaches
  `active` only via a health gate, failure rolls back to `previous` (§4b). ✔
- **Declarative `apply`/reconcile** — designed in, built as a v1.5 stretch atop the
  imperative spine (§3a). ✔
- **Watchable boot-progress with user-definable milestones** — `milestones.toml`
  (regex → label → `at%`/`terminal`), consumed both by `watch` (headless) and the
  Phase-6 bars; doubles as the drivers' health-gate signal source (§5c). ✔

**Build-ready settlements (2026-07-24) — the former open items, now decided:**
- **Fleet size = 3 nodes** (enough for pool/scheduling/`apply` semantics, light on the
  host); BMC ports 6230–6232. ✔
- **Inspection probe = a plain busybox initramfs** (tiny, no toolchain box); **rescue
  ramdisk = `root-password-reset` init-shell idioms**, IPMI-driven. ✔
- **CLI-first v1** — the state machine + drivers + `apply` + `watch` are the v1
  deliverable; the Phase-6 panel/progress-bars are step 7 (fast-follow). The headless
  `watch` milestone stream already delivers "watchable" without the TUI. ✔
- **`console`/`sol` verb** = libvirt serial (honest SOL substitute); faithful IPMI-SOL
  deferred to §11. ✔

## 11. Out-of-band transport — now a reusable lab (`BMC_TOOLKIT_LAB_PLAN.md`)

The deferred vbmc/IPMI/SOL/Redfish explorations that used to live here have been
**lifted into their own reusable infra lab** — `BMC_TOOLKIT_LAB_PLAN.md`
(`examples/bmc-toolkit/`) — a protocol-agnostic OOB verb surface (`bmc.sh <node>
power/bootdev/sol/insert-media/…`) over three interchangeable backends (`vbmcd`,
`ipmi_sim`, `redfish`/`sushy-tools`). MAAS **consumes** it rather than embedding it:

- **Faithful IPMI Serial-over-LAN** — real `ipmitool -I lanplus … sol activate` over
  RMCP+ via OpenIPMI `ipmi_sim`, superseding v1's honest libvirt-console substitute.
  When the toolkit lands, MAAS's `console`/`sol` verb (§5b) simply targets an
  `ipmi_sim`-backed node and gets *real* SOL for free.
- **Redfish virtual media** — `InsertMedia` → boot an ISO with no PXE/DHCP; this is the
  toolkit's centerpiece and drops in as MAAS's **5th deploy driver** (`--driver
  virtual-media`) once available.
- **Richer IPMI surface** — real sensors/FRU/`sel`/chassis-identify (ipmi_sim provides
  them genuinely, so the old "stub SDR/FRU" idea is superseded).

**Inherited constraints that remain MAAS's to honor** (carried, not solved):
- **Rootful BMC backends** (the `qemu:///system` socket is `root:libvirt`) — the
  container-vs-host trade-off, restated in this lab's RUNBOOK.
- **One serial-console consumer at a time**, foreground, domain running (vbmc RUNBOOK
  §6) — MAAS's milestone tailer (§5c) must therefore *own* the console or read a
  captured log, never race a human `virsh console` or the toolkit's SOL bridge. A design
  note for the `watch`/progress plumbing, now shared with the toolkit's serial-ownership
  guard.

Nothing here gates MAAS v1: MAAS v1 uses the ✅-proven `vbmcd` path (via the toolkit's
`vbmcd` backend, or directly), and the toolkit + MAAS build independently — they wire
together once both are green.
