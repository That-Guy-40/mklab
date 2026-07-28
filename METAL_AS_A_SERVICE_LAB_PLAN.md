# Metal-as-a-Service Lab — Design Plan v2.1

> **Status**: v2.1 — **in build, increments 1–4 of 7 shipped** (see the build-status box
> below). Proposed 2026-07-24 as option **B** of the "what can we compose?" survey; the
> design below is unchanged except where the build corrected it, and every such
> correction is called out inline rather than quietly rewritten. Anchors on `examples/virtualbmc-ipmi-lab/` (IPMI power +
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
> for its OOB layer (see §11).

> ## 🏗️ Build status — **increments 1–4 of 7 shipped** (last updated 2026-07-27)
>
> The lab exists: **[`examples/metal-as-a-service/`](examples/metal-as-a-service/)**, with
> its own increment ledger in [`PLAN.md`](examples/metal-as-a-service/PLAN.md) (per-increment
> outcomes + design decisions) and transcripts in
> [`MANUAL_TESTING.md`](examples/metal-as-a-service/MANUAL_TESTING.md).
>
> | # | Increment (§9 build order) | Status |
> |---|---|---|
> | **1** | Fleet + registry + **full 12-state Ironic machine** (`create-fleet.sh`, `maas-lab.sh`, guarded `cleaning`, `error`/`maintenance`, `rescue`) | ✅ **merged** — PR #56 |
> | **2** | `inspect` **RAM probe** + NoCloud **metadata service** + `milestones.toml`/`watch` | ✅ **merged** — PR #57 |
> | **3** | **`install` driver + health-gated activation + A/B rollback (§4b)** + F2 verify gate | ✅ **merged** — PR #58 |
> | **4** | **`ramdisk` driver + catalog** (RAM-INFRA / micro-linux / floppinux / busybox), signed + `imgverify` | ✅ **merged** — PR #87 |
> | 5 | `image` driver (dd golden whole-disk, Tier-B reuse) | ⬜ **next** |
> | 6 | `apply` declarative reconcile (§3a) | ⬜ |
> | 7 | Phase-6 surface — **already provided** by `tools/control-pane`; MAAS wires in per-increment | 🔶 partially live (see §5) |
>
> **Verified headless, re-run 2026-07-27:** `examples/metal-as-a-service/tests/run-all.sh`
> → **10 passed, 0 skipped, 0 failed** — with a **mock BMC** and a **mock driver**, but
> **real** OpenSSL CMS crypto, the **real** control-pane engine, and the **real**
> `bmc-toolkit` registry parser. No libvirt, no root, no install. Two of those tests
> now drive the **real** `install` and `ramdisk` drivers rather than the mock one, and
> the `ramdisk` test stages + signs + verifies every catalog payload this host has
> actually built (`micro-linux-x86_64` does so here).
>
> **A seam leak was found and fixed on the way (PR #86).** `drivers/install.sh` asked
> `virsh domstate` whether the installer had finished — reaching around the BMC into the
> hypervisor, a capability no real control plane has, and the one call no seam could
> intercept (which is exactly why that driver had never been tested). It now observes
> the node powering *itself* off via `chassis power status`, and a refusing `virsh` stub
> on `PATH` keeps the leak from returning.
>
> **The two dependencies MAAS was waiting on both landed first**, so nothing is blocked:
> `tools/control-pane` (PR #54, the promoted repo tool — §5) and
> `examples/bmc-toolkit/` (PR #46 + spikes, all three backends — §11).
>
> **Still author-run (correctly, not skipped):** `create-fleet.sh up`/`down` (rootful
> libvirt + `vbmcd`), `inspect --boot` (real PXE probe), and a real `install` deploy.
> Each is handed over with the exact command in MANUAL_TESTING.
>
> **Routed:** `examples/00-INDEX.md` (Phase-2 row) + `learning-paths.toml`
> (`zero-touch-provisioning` step with a `verify_host` checkpoint that runs the suite,
> plus `close-to-the-metal`). Both catalog checkers green.

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
| **N-node libvirt fleet + BMC per node** | ✅ **built** (inc. 1) | `create-fleet.sh` — wraps `virtualbmc-ipmi-lab`; 3 domains + one `vbmcd` on 6230–6232 (`up`/`down` author-run) |
| **Node registry + full Ironic state machine** | ✅ **built** (inc. 1) | `maas-lab.sh` — directory-tree registry (atomic single-value files + `history.log`) + 12 states as pure transitions |
| **The pluggable DEPLOY INTERFACE** | ✅ **built** (inc. 3) | `drivers/<name>.sh` (`verify`/`deploy`/`health`/`describe`) dispatched by `maas-lab.sh`; `install.sh` real, `ramdisk`/`image` are honest not-yets |
| **Inspection probe + `cleaning` wipe** | ✅ **built** (inc. 1–2) | `probe-init.sh` + `build-probe-initramfs.sh`; `cleaning` **hands the wipe to the operator** (F7) rather than running it |
| **Per-node metadata / config-drive** | ✅ **built** (inc. 2) | `lib/metadata.py` + `metadata-serve.sh` — NoCloud user-data **and** the facts sink, on **:8282** |
| **Phase-6 sees node state + live progress** | ✅ **built** (inc. 2) | not a MAAS-local source after all: `maas-lab.sh watch` registers the node under `tools/control-pane`'s fleet dir → TUI + web bars for free |
| **Health-gated activation + A/B rollback (§4b)** | ✅ **built** (inc. 3) | one `gate()` = verify → deploy → health, applied to the new *and* the rollback slot |
| **F2 supply-chain gate at deploy time** | ✅ **built** (inc. 3) | `drivers/verify-lib.sh` — OpenSSL CMS in the same format `netboot/sign-payload.sh` produces for iPXE `imgverify` |
| **`ramdisk` driver + payload catalog** | ✅ **built** (inc. 4) | `drivers/ramdisk.sh` + `ramdisk-catalog.toml` + `lib/catalog.py` — routes to the RAM-INFRA trio / micro-linux / floppinux / busybox; the catalog **builds nothing**, it names each owning lab's build command |
| **`image` driver · `apply` reconcile** | ❌ **remaining** | increments 5–6 (§9) |

Host reality: this is the repo's **only libvirt** family (Phase 2 is raw QEMU);
`vbmcd` runs **rootful** (system socket is `root:libvirt`) — which is why every live
fleet operation is author-run and every *logic* test drives a mock BMC.

**How the last row was actually solved** (worth recording, because it inverted the
plan): Phase 6 still has no libvirt awareness, and it no longer needs any. Rather than
writing a `libvirt`/`maas` inventory source, `tools/control-pane` landed **first** as a
generic source, and `maas-lab.sh watch` simply **registers a node into its fleet dir**.
MAAS contributes a `node.toml` and a milestone profile; the TUI, the web UI, and the SSE
progress bars come for free — and no MAAS-specific code lives in Phase 6.

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

This section was **extracted into `CONTROL_PANE_LAB_PLAN.md`**, and its engine + runner then
**promoted to a first-class repo tool — [`tools/control-pane`](tools/control-pane)** (PR #54,
`tools/control_pane/` = engine/cli/milestones, `tools/tests/` = its tests). The tool is a
**live control surface any lab plugs into** (a live inventory source + a node-actions panel +
a user-definable `milestones.toml` progress engine, with a headless-first, stdlib-only core so
it works with no TUI). `examples/control-pane/` is now the tool's **demo/teaching consumer**,
not where the code lives. **MAAS is its first real consumer:** MAAS provides the inputs (its
node registry, each node's console, a `milestones.toml`, its verb table) and gets the surface
for free. The three pieces below are all **provided by `tools/control-pane`**; the anchors
remain so this plan's cross-references resolve.

- **5a. Live inventory source.** The control-pane `BackendRunner`
  (`phase6-tui/lab_tui/backends/control_pane.py`, which **shells out to `tools/control-pane`**)
  lists MAAS nodes ⋈ their **state + deploy driver** in the Phase-6 tree
  (`node2 ● active [image+measured]`). Read-only, established Phase-6 style.
  (Provided by `tools/control-pane`.)
**Status (2026-07-27):** the tool shipped (PR #54) and MAAS consumes it. **5a** and **5c**
are **live** — `maas-lab.sh watch <node>` picks a profile from the node's driver, writes
the node's `node.toml` into the control-pane fleet dir, and delegates the stream; the
node then appears with a live bar in the TUI *and* the web UI. **5b**'s `console`/`sol`
verb exists and routes through the BMC seam. The remaining piece is the **actions panel**
(key-bindings that *call* MAAS verbs) — step 7, and by design not a v1 blocker.

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
  from **`tools/control-pane`** (the repo tool, not MAAS-local code).

---

## 6. New components & files

The **Built** column is the ground truth as of 2026-07-27; `ls examples/metal-as-a-service/`
is the check. Two planned files turned out **not** to be needed in the shape the plan
imagined — noted inline rather than silently dropped.

| File | Built | Type | Notes |
|---|---|---|---|
| `METAL_AS_A_SERVICE_LAB_PLAN.md` | ✅ | **this doc** | roadmap |
| `examples/metal-as-a-service/PLAN.md` | ✅ | *(unplanned, added)* | the per-increment ledger — outcome + design decisions + what was verified vs. handed over, one section per increment |
| `examples/metal-as-a-service/maas-lab.sh` | ✅ inc. 1–3 | new | control plane: full state machine + imperative verbs + deploy-driver dispatch + health-gated activation w/ A/B rollback (§4b) + `console`/`sol` (§5b) + `watch` (delegates to `tools/control-pane watch`). **`apply` is not in it yet** — increment 6 |
| `examples/metal-as-a-service/drivers/install.sh` | ✅ inc. 3 | new | the real driver: PXE kickstart/preseed → boot from disk, wrapping `virtualbmc-ipmi-lab`; declares its health-gate signal (the OS `login:`). Author-run to *run*; its dispatch is headless-tested |
| `examples/metal-as-a-service/drivers/ramdisk.sh` | ✅ inc. 4 | new | netboot a payload into RAM: `describe`/`stage`/`verify`/`deploy`/`health`. **No `bootdev disk` and no wait for a poweroff** — the two things that separate it from `install`, both asserted |
| `…/drivers/{image,image-measured}.sh` | ⬜ inc. 5 | new | not stubs-that-lie: `deploy --driver image` today **refuses and names the build step** |
| `examples/metal-as-a-service/drivers/verify-lib.sh` | ✅ inc. 3 | *(unplanned, added)* | the F2 gate — OpenSSL CMS sign/verify in `netboot/sign-payload.sh`'s exact format. Not foreseen as a separate file; it is shared by every driver |
| `examples/metal-as-a-service/tests/mock{,-bmc}.sh` | ✅ inc. 1, 3 | *(unplanned, added)* | the two injectable seams made concrete — a mock BMC and a mock driver. **These are why the suite is headless**, and they are the reason `MAAS_BMC`/`MAAS_DRIVER_DIR` exist |
| `examples/metal-as-a-service/lib/{fleet,metadata}.py` | ✅ inc. 1–2 | *(unplanned, added)* | stdlib TOML projector for `fleet.toml`; the NoCloud + facts-sink service. Bash reads TOML through these rather than parsing it |
| `examples/metal-as-a-service/ramdisk-catalog.toml` | ✅ inc. 4 | new | the `--image` registry (RAM-INFRA + micro-linux + floppinux + busybox): owning lab, its build command, kernel/initrd, and the `active` signal (`console`/`http`/`dns`, validated by `lib/catalog.py check`) |
| `examples/metal-as-a-service/milestones.toml` | ✅ inc. 2 | new | MAAS's milestone **profiles** (`probe`/`install`/`ramdisk`/`image`; regex → label → `at%`/`terminal`) — *consumed by `tools/control-pane`'s engine*, not a MAAS-local parser |
| `examples/metal-as-a-service/create-fleet.sh` | ✅ inc. 1 | new | 3 libvirt domains + `vbmc add` each on 6230–6232 (wraps vbmc `create-node.sh`). `enroll` is headless; `up`/`down` are author-run (rootful) |
| `examples/metal-as-a-service/fleet.toml` | ✅ inc. 1 | new | the fleet: hardware spec (count, disk/RAM, PXE network) **and** the declarative desired end-state — the latter is *declared* but not yet *consumed* (`apply`, inc. 6) |
| `examples/metal-as-a-service/probe-init.sh` | ✅ inc. 2 | new | inspection initramfs `/init`: POST CPU/RAM/MAC, power off. **Port corrected during the build: `:8282`, not `:8181`** — the netboot nginx on :8181 is read-only static delivery, so a POST sink must be a separate listener |
| `examples/metal-as-a-service/build-probe-initramfs.sh` | ✅ inc. 2 | *(unplanned, added)* | packs the probe into a bootable initramfs, rootless (`find \| cpio \| gzip`, static busybox) |
| `examples/metal-as-a-service/rescue-init.sh` | ⬜ deferred | new | `rescue` recovery ramdisk (root-password-reset idioms), IPMI-driven. **The `rescue`/`unrescue` *states* shipped in inc. 1**; the ramdisk that makes them do something real is still to build — the same honest-stand-in treatment `ramdisk`/`image` get |
| `examples/metal-as-a-service/metadata-serve.sh` | ✅ inc. 2 | new | per-node NoCloud user-data (hostname/SSH key) — DRY fleet from one image — **and** the introspection facts sink |
| `examples/metal-as-a-service/tests/` | ✅ inc. 1–3 | new | 8 one-verdict smokes + EXIT-trap net: registry, state machine, `cleaning` guard, inspect/metadata, probe build, `watch`, deploy A/B rollback, verify-tamper |
| *(Phase-6 surface)* | 🔶 | — | **provided by `tools/control-pane`** (PR #54; demoed in `examples/control-pane/`). Inventory + live bars are wired (via `watch`); the **actions panel** is step 7 |
| `examples/metal-as-a-service/{README,MANUAL_TESTING}.md` | ✅ | new | concept + Ironic-state mapping + "divergences from real Ironic/MAAS" + verified transcripts |
| `examples/metal-as-a-service/RUNBOOK.md` | ⬜ | new | not yet written — README + MANUAL_TESTING carry the tour today; worth adding at v1 completion |
| `examples/00-INDEX.md` | ✅ | edit | one row (Phase-2/libvirt section, near the VirtualBMC row) |
| `examples/learning-paths.toml` | ✅ | edit | routed into `zero-touch-provisioning` (after `virtualbmc-ipmi-lab`) + `close-to-the-metal`; checkpoint is a `verify_host` marker that **runs the suite**. Per-driver `active` checkpoints follow the drivers |

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

Steps 1–3 are **done and merged** (PRs #56/#57/#58 — see the build-status box at the top
and the per-increment outcomes in [`examples/metal-as-a-service/PLAN.md`](examples/metal-as-a-service/PLAN.md));
**step 4 is next**. The ✅/⬜ marks below are the same ledger, kept in place so the
dependency reasoning that produced this order stays readable.

1. ✅ **Fleet + registry + full state machine** — `create-fleet.sh` + `maas-lab.sh` with
   the state file, all transitions, `power`/`bootdev`, `cleaning` (guarded), `error`/
   `maintenance`, `rescue`. *State transitions fully headless-verifiable without an
   install.*
2. ✅ **`inspect` probe + metadata service + `milestones.toml`/`watch`** — RAM probe fills
   schedulable facts; NoCloud user-data; the console-milestone parser lands here as the
   headless `maas-lab.sh watch <node>` (the same file the Phase-6 bars consume later).
   *Verifiable: `manageable → available` with real CPU/RAM facts; `watch` prints the
   milestone stream.*
3. ✅ **`install` driver + the health-gated activation loop (§4b)** — sequence the PXE
   install into `deploy`, and build the **health-gate + A/B rollback** here (the first
   driver to reach `active` needs it). *End-to-end verifiable (underlying install ✅);
   the tamper→rollback drill is headless; a full multi-node parallel install may be
   author-run (host load).* 
4. ✅ **`ramdisk` driver + catalog** — dispatch to RAM-INFRA / micro-linux / floppinux /
   busybox, signed + `imgverify`-gated, reusing step 3's health gate. *Fully verifiable
   in QEMU per catalog entry (each has an existing boot signature).* 
5. ⬜ **`image` driver** ← next — dd golden image (Tier-B reuse), same health gate. *Verifiable
   in QEMU.*
6. ⬜ **`apply` reconcile (v1.5, §3a)** — the declarative loop atop the imperative spine;
   diff desired-vs-actual, issue the missing transitions, prove idempotent (second run
   = no-op). *Fully headless-verifiable (registry-level, no install needed to prove the
   diff logic).* 
7. 🔶 **Phase-6 surface** — **provided by `tools/control-pane`** (the repo tool; demoed in
   `examples/control-pane/`): the live inventory source + actions panel + boot-progress bars;
   MAAS wires in as its first consumer (its nodes + `milestones.toml` profiles). *TUI render
   verifiable there; MAAS's live drive shown in its MANUAL_TESTING.*

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

**Status (2026-07-27) — the toolkit shipped, and MAAS already consumes it.**
`examples/bmc-toolkit/` is built with all three backends: `vbmcd` (power/bootdev,
author-run rootful), **`ipmi_sim` with REAL SOL** over RMCP+ (POC-A, verified headless
and rootless), and **`redfish`/sushy-tools virtual media** (POC-B, `InsertMedia` → boot
an ISO with no PXE, verified headless and rootless). Two consequences for this plan:

- **The seam is live.** `maas-lab.sh` reaches every out-of-band effect through
  `MAAS_BMC` → `bmc.sh <node> <verb>`, using a `fleet-bmc.toml` it regenerates from its
  own registry on `enroll` — and that file **round-trips through the toolkit's real
  `registry.py`** as part of MAAS's headless suite. `console`/`sol` (§5b) is already
  routed through it, so pointing a node at the `ipmi_sim` backend yields *real* SOL with
  no MAAS change.
- **The 5th driver is unblocked.** `--driver virtual-media` (§11, second bullet) can be
  built whenever we want it — the mechanism it needs is proven in POC-B. It stays a
  fast-follow behind increments 4–6 only because the `ramdisk` catalog is the bigger
  teaching payload.

One toolkit finding *changes* an assumption above: `ipmi_sim` 1.0.13 returns `0xCC` for
chassis control, so power and SOL are split across two backends (`vbmcd` powers,
`ipmi_sim` does SOL). The capability model (`bmc.sh inspect --json`) makes that split
invisible to MAAS — which is exactly what the contract was for.
