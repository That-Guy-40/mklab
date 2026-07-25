# metal-as-a-service — build plan & increment ladder

The design roadmap is the repo-root [`METAL_AS_A_SERVICE_LAB_PLAN.md`](../../METAL_AS_A_SERVICE_LAB_PLAN.md).
This file tracks the **build increments** and records each one's outcome as it lands.

## Increment ladder (roadmap §9 build order)

| # | Increment | Status |
|---|---|---|
| **1** | **Fleet + registry + full state machine** (`create-fleet.sh` + `maas-lab.sh`: all transitions, `power`/`bootdev`, guarded `cleaning`, `error`/`maintenance`, `rescue`) | ✅ **DONE (this increment)** — headless |
| 2 | `inspect` RAM probe + NoCloud metadata + `milestones.toml`/`watch` (feeds `tools/control-pane`) | ▫ next |
| 3 | `install` driver + **health-gated activation + A/B rollback** (§4b) | ▫ |
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
