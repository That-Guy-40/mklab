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
> milestone stream already delivers the "watchable" value without the TUI). Deferred
> vbmc/IPMI work — including a **faithful IPMI Serial-over-LAN spike** and a **Redfish
> virtual-media track** — is captured in §11 so it isn't lost. Plan only; no lab files
> created yet — ready to start v1 on the word.

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

## 5. Surfacing it — Phase 6 as the control pane

- **5a. A `libvirt` inventory source** — lists `qemu:///system` domains ⋈ the
  `maas-lab` registry, so the browser tree gains a `metal (N)` group showing each
  node's **state + deploy driver** (`node2 ● active [image+measured]`). Read-only, in
  the established Phase-6 style.
- **5b. A node-actions panel** — key-bindings calling `maas-lab.sh
  inspect/provide/deploy/rescue/release/console`, streaming the console into the lower
  pane (mirrors the existing `c` console-attach + topology `u`/`d`); Phase-6b/web parity
  as HTMX routes. If Phase 6 is deleted, `maas-lab.sh` still drives everything (invariant).
  - **`console` / `sol`** attach to the node's **libvirt serial console** — the *honest
    substitute* for IPMI SOL, since VirtualBMC has no `activate_payload` (the vbmc lab's
    RUNBOOK §6 documents this). `sol` is a deliberate alias so the ergonomics match what
    a user reaches for (`ipmitool … sol activate`), while the help text and README state
    plainly it is **libvirt's console, not IPMI SOL**. The *faithful* IPMI-SOL path is a
    deferred spike (§11). This is the same serial stream the health gate (§4b) and the
    milestone parser (§5c) consume — one console, three consumers.

- **5c. Watchable boot-progress with user-definable milestones.** Each node's serial
  console is already captured; a small tailer matches lines against an **ordered,
  user-editable milestone set** and renders a **live progress bar** per node — so you
  *watch* three nodes install in parallel instead of reading static states. Crucially
  the milestones are **not hardcoded** — they're declared in a `milestones.toml`,
  keyed by driver (and optionally overridable per `--image`), so a user adds their own
  markers for a new OS/image without touching Python:

  ```toml
  # milestones.toml — matched top-to-bottom against the console; first hit sets progress.
  [[milestone.install]]  match = "Starting partitioner"        label = "partitioning"  at = 25
  [[milestone.install]]  match = "Installing the base system"  label = "base system"   at = 55
  [[milestone.install]]  match = "Running .*post-install"      label = "post-install"  at = 85
  [[milestone.install]]  match = "login:"                      label = "first boot"    at = 100  terminal = true
  [[milestone.ramdisk]]  match = "Welcome to (u-root|floppinux)"  label = "RAM login"  at = 100  terminal = true
  ```

  Rules that keep it honest: patterns are **plain regex over console text**
  (documented, no eval); `at` is an explicit percent (no guessing between markers);
  `terminal = true` marks the "done" line; an **unmatched** console still shows a
  spinner + last line, never a fake 100%; and a milestone set with no hits within the
  driver's timeout surfaces as **stalled**, feeding the `error`/`maintenance` path
  (§3). The same `milestones.toml` is consumable headless (`maas-lab.sh watch <node>`
  prints the milestone stream), so the feature isn't Phase-6-only. This is a natural
  home for the deploy drivers' health-gate signals too (§4b): a driver's `terminal`
  milestone *is* its "reached active" marker — one declaration, two consumers.

---

## 6. New components & files

| File | Type | Notes |
|---|---|---|
| `METAL_AS_A_SERVICE_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/metal-as-a-service/maas-lab.sh` | new | control plane: full state machine + imperative verbs + deploy-driver dispatch + health-gated activation w/ A/B rollback (§4b) + `apply` reconcile (§3a) + `watch` + `console`/`sol` (libvirt serial; honest SOL substitute, §5b) |
| `examples/metal-as-a-service/drivers/{install,ramdisk,image,image-measured}.sh` | new | one file per deploy driver — each a thin router to the reused lab; declares its health-gate/`terminal` signal |
| `examples/metal-as-a-service/ramdisk-catalog.toml` | new | the `--image` registry (RAM-INFRA + micro-linux + floppinux + busybox), each with its `active`-signal marker |
| `examples/metal-as-a-service/milestones.toml` | new | user-definable, per-driver console milestones (regex → label → `at%`/`terminal`) driving the watchable progress bars (§5c) |
| `examples/metal-as-a-service/create-fleet.sh` | new | N libvirt domains + `vbmc add` each on 623X (wraps vbmc `create-node.sh`) |
| `examples/metal-as-a-service/fleet.toml` | new | the fleet: hardware spec (count, disk/RAM, PXE network) **and** the declarative desired end-state consumed by `apply` (§3a) |
| `examples/metal-as-a-service/probe-init.sh` | new | inspection initramfs `/init`: POST CPU/RAM/MAC to `:8181`, power off |
| `examples/metal-as-a-service/rescue-init.sh` | new | `rescue` recovery ramdisk (reuses root-password-reset recovery idioms), IPMI-driven |
| `examples/metal-as-a-service/metadata-serve.sh` | new | per-node NoCloud user-data (hostname/SSH key) — DRY fleet from one image |
| `examples/metal-as-a-service/tests/` | new | one-verdict smokes: state transitions (dry), `cleaning` no-op vs wipe, driver dispatch; EXIT-trap net, `REGRESSION:` on the wipe-happened guard |
| `phase6-tui/lab_tui/sources/libvirt.py` + actions panel | new/edit | inventory source + node actions + **live boot-progress bars** driven by `milestones.toml` (§5c); 6b/web parity |
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
7. **Phase-6 surface** — libvirt inventory source + actions panel + **live boot-progress
   bars** (consume `milestones.toml`); 6b/web parity. *TUI render verifiable; live drive
   shown in MANUAL_TESTING.*

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

## 11. Deferred work & explorations (vbmc · IPMI · SOL · Redfish)

Captured so it isn't lost. None of this gates v1; each is an honest, bounded follow-on,
and several inherit constraints straight from `examples/virtualbmc-ipmi-lab/`.

### 11a. A faithful IPMI Serial-over-LAN spike (the SOL exploration)

**Where v1 lands:** `console`/`sol` = libvirt's serial console (§5b) — the *honest
substitute*, because VirtualBMC has **no** `activate_payload` and never speaks IPMI SOL.
This is the ergonomically-right answer for the lab and it's what feeds the health gate +
milestone parser. But it is **not** real Serial-over-LAN: the bytes ride libvirt, not an
IPMI RMCP+ session on UDP 623.

**The faithful path (deferred spike):** OpenIPMI's **`lanserv` / `ipmi_sim`** BMC
simulator *does* implement IPMI SOL and can bridge the SOL payload to a serial device or
socket — so `ipmitool -I lanplus … sol activate` would stream the VM's *real* serial over
a genuine IPMI session. The spike would run `ipmi_sim` as the node's BMC with its `sol`
directive pointed at the QEMU/libvirt serial unix socket, and prove `sol activate` end to
end. **The honest trade-off to resolve in the spike:** `ipmi_sim` is a *simulator*, so its
chassis power/boot-device commands don't natively drive libvirt the way `vbmcd` does —
so a faithful-SOL node either (a) **replaces** `vbmcd` with `ipmi_sim` + a small
virsh-shim on its chassis-control script, or (b) runs `ipmi_sim` **alongside** `vbmcd`
(power on 6230, SOL on another port) — clunky but isolates the change. Provenance:
OpenIPMI docs → cite, don't mirror; verify `ipmi_sim` SOL actually bridges before
claiming it. *Risk: MEDIUM (RMCP+/RAKP session + SOL framing are real protocol surface);
a clean documented negative result is acceptable.*

### 11b. A Redfish / `sushy-tools` track — virtual media (a whole extra deploy path)

Modern out-of-band management is **Redfish**, not IPMI, and virtualbmc's Redfish sibling
**`sushy-tools`** (same OpenStack lineage) adds the capability IPMI here lacks: **virtual
media** — `InsertMedia` mounts an install ISO to the node and boots it, no PXE/DHCP at
all. That's a *fifth* delivery model for the deploy interface (§4): `--driver
virtual-media`. Deferred as its own track (a Redfish BMC container + a `redfishtool`/curl
front end), and it also gives the fleet a **Redfish console** option to compare against
the IPMI/libvirt one. Cite the Redfish + sushy-tools docs; reuse the repo's ISO assets.

### 11c. Richer IPMI surface (low priority, mostly "toy vs. real" honesty)

`vbmcd` implements **power + boot-device only**. A real BMC also exposes **sensors/SDR**,
**FRU** inventory, **chassis identify** (the locate LED), and **`sel`** event logs — all
absent here. Optional future polish: a stub SDR/FRU so `ipmitool sensor`/`fru` return
plausible data for teaching, clearly flagged as fabricated. Also deferred: driving the
BMC over a **real (non-loopback) network** with `lanplus` auth — kept on `127.0.0.1` by
design (F1); any move off loopback needs the security framing tightened first.

### 11d. Inherited vbmc/IPMI constraints (carried, not solved)

- **`vbmcd` is rootful** (the `qemu:///system` socket is `root:libvirt`); the
  container-vs-host trade-off is the vbmc lab's, restated in this lab's RUNBOOK.
- **One console consumer at a time**, foreground, domain must be running (vbmc RUNBOOK
  §6) — the milestone tailer must therefore *own* the console or read a captured log,
  not race a human `virsh console`. A design note for the `watch`/progress plumbing.
- **`sushy`/`ipmi_sim` and `vbmcd` may collide on port/backend** — see 11a's trade-off.
