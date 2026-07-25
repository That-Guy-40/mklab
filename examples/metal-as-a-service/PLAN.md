# metal-as-a-service — build plan & increment ladder

The design roadmap is the repo-root [`METAL_AS_A_SERVICE_LAB_PLAN.md`](../../METAL_AS_A_SERVICE_LAB_PLAN.md).
This file tracks the **build increments** and records each one's outcome as it lands.

## Increment ladder (roadmap §9 build order)

| # | Increment | Status |
|---|---|---|
| **1** | **Fleet + registry + full state machine** (`create-fleet.sh` + `maas-lab.sh`: all transitions, `power`/`bootdev`, guarded `cleaning`, `error`/`maintenance`, `rescue`) | ✅ **DONE** — headless |
| **2** | **`inspect` RAM probe + NoCloud metadata + `milestones.toml`/`watch`** (feeds `tools/control-pane`) | ✅ **DONE** — headless |
| **3** | **`install` driver + health-gated activation + A/B rollback (§4b)** + F2 verify gate | ✅ **DONE (this increment)** — headless (real install author-run) |
| 4 | `ramdisk` driver + catalog (RAM-INFRA / micro-linux / floppinux / busybox), signed + `imgverify` | ▫ |
| 5 | `image` driver (dd golden whole-disk, Tier-B reuse) | ▫ |
| 6 | `apply` declarative reconcile (§3a) — diff desired-vs-actual, idempotent | ▫ |
| 7 | Phase-6 surface — **provided by `tools/control-pane`**; MAAS is its first consumer | ▫ |

Fast-follows (documented, not v1): `image+measured` attested gate; `ramdisk`→region
wiring; a flavor/tag scheduler atop `apply`.

## Increment 1 — outcome (2026-07-25)

**Built:** the control-plane spine, fully headless.

- `maas-lab.sh` — a **directory-tree registry** (`$MAAS_STATE/<node>/`: one small,
  atomically-written file per field + an append-only `history.log`) and the **12-state
  Ironic-faithful machine** as pure transitions. Every verb validates its precondition
  and refuses an illegal transition with a message that **names the required state**.
- **The BMC seam** (`MAAS_BMC` → `bmc.sh <node> <verb>`): `maas-lab.sh` never calls
  `ipmitool`; it shells out to [`bmc-toolkit`](../bmc-toolkit/README.md) using a
  `fleet-bmc.toml` it **regenerates from the registry on `enroll`**. Tests point the seam
  at `tests/mock-bmc.sh`, so the whole lifecycle drives with no libvirt/root.
- `create-fleet.sh` — `enroll` (headless registry population, verifiable) and `up`/`down`
  (author-run, rootful) that **wrap the sibling `virtualbmc-ipmi-lab`** (`create-node.sh`
  + `vbmc-lab.sh`) — 3 domains + one `vbmcd` hosting BMCs on 6230–6232.
- `fleet.toml` + `lib/fleet.py` — the hand-edited fleet spec (hardware + declared
  end-state for `apply`) and its stdlib TOML projector.

**Design decisions this increment:**
1. **Registry = a directory of single-value files**, not one TOML blob. Atomic writes
   (tmp + `mv`) keep `state` always readable; trivially greppable; no TOML writer in bash.
2. **One injectable seam** for every out-of-band effect. This is what makes "fully
   headless-verifiable without an install" (roadmap §9 step 1) literally true.
3. **`cleaning` never auto-wipes.** A node with a real backing disk **stays in
   `cleaning`** until the operator runs the handed-over `blkdiscard`/`dd` and re-runs
   with `--wiped`; a disk outside the lab allow-list is **refused**. F7, enforced + tested.
4. **Honest stand-ins.** `inspect` (facts) and `deploy` (boot) are transitions whose real
   mechanisms are later increments — each prints that it's state-only rather than faking
   success.

**Verified (headless, this host, 2026-07-25):** `tests/run-all.sh` → **3 passed, 0
skipped, 0 failed**; `shellcheck -S warning` clean; the generated `fleet-bmc.toml`
**round-trips through bmc-toolkit's real `registry.py`**. Transcripts in
[MANUAL_TESTING.md](MANUAL_TESTING.md).

**Author-run (handed over):** `create-fleet.sh up` / `down` (rootful libvirt + podman) —
the real IPMI round-trip through the fleet. Command + expected signature in
MANUAL_TESTING.md §2.

## Increment 2 — outcome (2026-07-25)

**Built:** hardware introspection, per-node metadata, and watchable progress — the
`manageable → available` path now carries **real schedulable facts**, and the fleet
lights up in `tools/control-pane`.

- **The inspection probe.** `probe-init.sh` is a busybox `/init` that reads
  cpus/mem/MAC from `/proc`+`/sys`, POSTs them as JSON to the metadata service, and
  powers off (`maas.node=`/`maas.md=` on the kernel cmdline give it identity + sink).
  `build-probe-initramfs.sh` packages it into a bootable, diskless initramfs
  (rootless `find | cpio | gzip`; static busybox). HTTP client = busybox
  `wget --post-data` (no curl in these images) — the sink reads the raw body, so the
  form-urlencoded content-type is a non-issue.
- **The metadata service.** `lib/metadata.py` (+ `metadata-serve.sh`) serves NoCloud
  `meta-data`/`user-data` per node (DRY fleet from one image) **and** is the
  introspection sink: `POST /facts/<node>` → atomic `facts.json` + a `facts.received`
  marker. Binds loopback (F1); refuses a POST for an un-enrolled node.
- **`inspect` gains three modes.** `--facts F` (headless inject), `--from-metadata`
  (ingest what the probe POSTed — the headless integration path), `--boot` (the REAL
  probe over the BMC: bootdev pxe → power on → await `facts.received` → power off;
  author-run). Any mode distils a **schedulable summary** (`cpus=N mem_mb=M mac=…`)
  into the registry for `show`/scheduling.
- **`watch` wires MAAS into `tools/control-pane`.** MAAS ships the milestone
  **profiles** (`milestones.toml`: `probe`/`install`/`ramdisk`/`image`); `watch`
  picks one from the node's deploy driver, **registers the node under the
  control-pane fleet dir** (`node.toml` → Phase-6 surfaces it with a live bar), and
  delegates streaming to `control-pane watch`. The engine is the repo tool, not
  MAAS-local code — one declaration drives the headless stream *and* the Phase-6 bars.

**Design decisions this increment:**
1. **Metadata sink on :8282, NOT :8181.** `:8181` is the netboot nginx (read-only
   static kernel/initrd delivery); `:8080` is SABnzbd on this host (CLAUDE.md). A
   POST-capable sink must be a separate listener — kernel/initrd off `:8181`, facts to
   `:8282`. (The port-refactor discipline: verify what the host actually uses first.)
2. **The engine stays in `tools/control-pane`.** `watch` shells out to the CLI (no
   Python import across the boundary), exactly as the plan settled — MAAS is a consumer.
3. **`probe-init.sh` has a `--emit` test seam.** The fact-gathering runs against
   `$PROC_ROOT`/`$SYS_ROOT` fixtures, so the exact `/init` that ships is unit-tested
   without a boot.

**Verified (headless, this host, 2026-07-25):** `tests/run-all.sh` → **6 passed, 0
skipped, 0 failed** (the 3 spine smokes + `test-inspect-metadata.sh`,
`test-watch.sh`, `test-probe-build.sh`). The probe's facts round-trip through a live
metadata service; `watch` drives MAAS's `milestones.toml` through the real
control-pane engine to its terminal milestone; the built initramfs contains a runnable
probe `/init`. Transcripts in MANUAL_TESTING.md §3.

**Author-run (handed over):** the real `inspect <node> --boot` (PXE-boot the probe on
a live fleet) — serve the initramfs + a kernel over `:8181`, run `metadata-serve.sh`,
then `inspect --boot`. Steps in MANUAL_TESTING.md §3c.

## Increment 3 — outcome (2026-07-25)

**Built:** `deploy` stops being a state-only stub. It is now a **pluggable, health-
gated, verify-gated activation** with **A/B rollback** — the crux of §4b.

- **Driver interface.** A driver is `drivers/<name>.sh` implementing
  `verify`/`deploy`/`health`/`describe`; `maas-lab.sh` dispatches to it (context via
  env). `install.sh` is the real driver (PXE kickstart/preseed → boot from disk;
  wraps the `virtualbmc-ipmi-lab` finale; **author-run**). `ramdisk`/`image` are
  honest not-yet (deploy names the build step). `MAAS_DRIVER_DIR` lets tests inject
  `tests/mock.sh`.
- **The health gate.** `deploying → active` is **not** "the boot command returned" —
  every driver declares a success signal and `deploy` polls it. For `install` the
  signal is the installed OS's **`login:`** on the node console — the *same* line
  `watch`'s terminal milestone renders (§5c: the terminal milestone doubles as the
  health-gate marker). Only a pass advances to `active`.
- **A/B rollback.** `current`/`previous` image slots per node. A new image that fails
  **verify or health** rolls the node back to its previous good image (**degraded but
  up**) instead of bricking; **both** slots bad → `error`; no previous → `error`.
  `deploy` is allowed from `available` (fresh) *and* `active` (A/B upgrade-in-place).
- **F2 verify gate.** `drivers/verify-lib.sh` signs/verifies payloads with **OpenSSL
  CMS** (detached, DER, `-binary -noattr`, codeSigning EKU) — the exact format
  `netboot/sign-payload.sh` produces for iPXE `imgverify`. Host-side verify is the
  deploy-time gate; iPXE's in-firmware `imgverify` is the author-run boot complement.
  A tampered image **fails verification and is never activated** (the required
  tamper→rollback drill, mirroring RAM-INFRA §13).

**Design decisions this increment:**
1. **One `gate()` = verify → deploy → health**, reused for the new image *and* the
   rollback image, so both slots are held to the same bar.
2. **Verify-fail and health-fail both trigger rollback** (worst case = "stayed on the
   previous good image", never "booted an untrusted/broken image over a working one").
   A hard `--no-verify` escape hatch exists and the test proves the gate was load-bearing.
3. **Own the F2 crypto, cite the tool.** A small self-contained `verify-lib.sh` (repo
   self-containment) in the *same* CMS format as `netboot/sign-payload.sh`, which it
   cites as the production/iPXE-side companion rather than duplicating.

**Verified (headless, this host, 2026-07-25):** `tests/run-all.sh` → **8 passed, 0
skipped, 0 failed** — added `test-deploy-rollback.sh` (healthy→active, fail→previous
degraded, both-bad→error, no-prev→error, unimplemented-driver refusal) and
`test-verify-tamper.sh` (**real OpenSSL CMS**: clean verifies, a flipped byte fails,
tampered image never activated, `--no-verify` bypass). `test-state-machine.sh`'s
deploy step now drives the real gate via the mock driver. shellcheck clean.

**Author-run (handed over):** a real `install` deploy end-to-end (PXE kickstart on a
live fleet, health = the OS `login:`). Steps + expected signature in MANUAL_TESTING §4.
