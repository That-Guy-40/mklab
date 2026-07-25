# PLAN — bmc-toolkit

Roadmap: [`../../BMC_TOOLKIT_LAB_PLAN.md`](../../BMC_TOOLKIT_LAB_PLAN.md) (the design doc,
extracted from `METAL_AS_A_SERVICE_LAB_PLAN.md` §11). This file records what the build
actually delivered vs. the plan.

## Delivered (v1)

- **The reusable verb surface + capability model** (`bmc.sh`, `fleet-bmc.toml`,
  `backends/common.sh`) — plan §3. `inspect --json` is the consumer-facing contract;
  unsupported verbs are refused loudly. ✅ verified headless (`tests/test-dispatch.sh`).
- **`ipmi_sim` backend — REAL SOL** over RMCP+/lanplus — plan §5 / [POC-A](POC-A-real-sol.md).
  ✅ verified headless & rootless (`tests/test-ipmi_sim-sol.sh`).
- **`redfish` backend — virtual media** (`InsertMedia` → boot an ISO, no PXE) — the
  centerpiece, plan §4 / [POC-B](POC-B-redfish-vmedia.md). ✅ verified headless & rootless
  (`tests/test-redfish-vmedia.sh`).
- **`vbmcd` backend — IPMI power/bootdev**, reusing `../virtualbmc-ipmi-lab/`. Live use is
  rootful → author-run (`tests/test-vbmcd.sh` SKIPs unless a BMC is up).

## Decisions settled during the build

- **`ipmi_sim` power = coexist** (plan §5 fallback 2): chassis-control returns `0xCC` in
  1.0.13, so `ipmi_sim` does SOL and `vbmcd` does power. The capability model makes the
  split invisible to a consumer.
- **UEFI/BIOS axis:** v1 uses **BIOS** for the vmedia node (no OVMF loader needed); UEFI
  works via a `SUSHY_EMULATOR_BOOT_LOADER_MAP` override (host OVMF path ≠ sushy default).
- **Plan §4a correction:** sushy **adds** the cdrom itself — no pre-provisioned second
  cdrom slot is needed (the node just needs an IDE controller).

## Open follow-ups (documented, not v1)

- **Whole-BMC power via `ipmi_sim`** — why does Chassis Control return `0xCC`, and what
  emu/lan.conf power setup clears it? Would collapse coexist into one BMC/session.
- **UEFI virtual-media** path with the OVMF loader-map override, secure-boot variants.
- **Richer IPMI surface** (real SDR/FRU/SEL via `ipmi_sim` config) — currently `partial`
  passthroughs.
- **Consumer wiring:** `METAL_AS_A_SERVICE` increment routing its `console`/`sol` and a
  `virtual-media` deploy driver through `bmc.sh inspect` capabilities.
