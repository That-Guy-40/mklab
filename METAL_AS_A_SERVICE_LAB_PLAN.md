# Metal-as-a-Service Lab — Design Plan v2

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
> Awaiting go-ahead to start v1; plan only — no lab files created yet.

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

---

## 5. Surfacing it — Phase 6 as the control pane

- **5a. A `libvirt` inventory source** — lists `qemu:///system` domains ⋈ the
  `maas-lab` registry, so the browser tree gains a `metal (N)` group showing each
  node's **state + deploy driver** (`node2 ● active [image+measured]`). Read-only, in
  the established Phase-6 style.
- **5b. A node-actions panel** — key-bindings calling `maas-lab.sh
  inspect/provide/deploy/rescue/release`, streaming the console into the lower pane
  (mirrors the existing `c` console-attach + topology `u`/`d`); Phase-6b/web parity as
  HTMX routes. If Phase 6 is deleted, `maas-lab.sh` still drives everything (invariant).

---

## 6. New components & files

| File | Type | Notes |
|---|---|---|
| `METAL_AS_A_SERVICE_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/metal-as-a-service/maas-lab.sh` | new | control plane: full state machine + verbs + the deploy-driver dispatch |
| `examples/metal-as-a-service/drivers/{install,ramdisk,image,image-measured}.sh` | new | one file per deploy driver — each a thin router to the reused lab |
| `examples/metal-as-a-service/ramdisk-catalog.toml` | new | the `--image` registry (RAM-INFRA + micro-linux + floppinux + busybox), each with its `active`-signal marker |
| `examples/metal-as-a-service/create-fleet.sh` | new | N libvirt domains + `vbmc add` each on 623X (wraps vbmc `create-node.sh`) |
| `examples/metal-as-a-service/fleet.toml` | new | fleet spec (count, disk/RAM, PXE network) |
| `examples/metal-as-a-service/probe-init.sh` | new | inspection initramfs `/init`: POST CPU/RAM/MAC to `:8181`, power off |
| `examples/metal-as-a-service/rescue-init.sh` | new | `rescue` recovery ramdisk (reuses root-password-reset recovery idioms), IPMI-driven |
| `examples/metal-as-a-service/metadata-serve.sh` | new | per-node NoCloud user-data (hostname/SSH key) — DRY fleet from one image |
| `examples/metal-as-a-service/tests/` | new | one-verdict smokes: state transitions (dry), `cleaning` no-op vs wipe, driver dispatch; EXIT-trap net, `REGRESSION:` on the wipe-happened guard |
| `phase6-tui/lab_tui/sources/libvirt.py` + actions panel | new/edit | inventory source + node actions; 6b/web parity |
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
2. **`inspect` probe + metadata service** — RAM probe fills schedulable facts; NoCloud
   user-data. *Verifiable: `manageable → available` with real CPU/RAM facts.*
3. **`install` driver** — sequence the existing PXE install into `deploy`. *End-to-end
   verifiable (underlying install ✅); a full multi-node parallel install may be
   author-run (host load).* 
4. **`ramdisk` driver + catalog** — dispatch to RAM-INFRA / micro-linux / floppinux /
   busybox, signed + `imgverify`-gated. *Fully verifiable in QEMU per catalog entry
   (each has an existing boot signature).* 
5. **`image` driver** — dd golden image (Tier-B reuse). *Verifiable in QEMU.*
6. **Phase-6 surface** — libvirt inventory source + actions panel; 6b/web parity.
   *TUI render verifiable; live drive shown in MANUAL_TESTING.*

**Fast-follows (documented, not v1):** `image+measured` attested gate (folds option A);
`ramdisk`→region wiring so a deployed node *joins* a resilient region (folds option C).

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

## 11. Open items / decisions still to confirm

- **Node count for the fleet** — recommend **3** (enough for pool/scheduling semantics,
  light on the host); one BMC port per node (6230…).
- **Scheduler depth** — do we add flavor/tag matching ("deploy to a node with ≥4 GB")
  on top of inspection facts, or keep node-selection manual in v1? Leaning: manual v1,
  a `schedule` verb as a small stretch.
- **Probe/rescue image** — reuse `micro-linux` or a plain busybox initramfs? Leaning
  busybox for the probe (tiny, no toolchain box), `root-password-reset` idioms for rescue.
- **v1 UI** — land the Phase-6 panel in v1, or CLI-first with the panel as fast-follow?
  The state machine + drivers have standalone CLI value; leaning CLI-first.
