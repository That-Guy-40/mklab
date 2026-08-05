# Micro-Cloud Lab — ☁️ under construction

> **Status (2026-08-03):** slices 0–4 of the build are **done**; this directory
> is being staged. The design document — and the dated measurement record that
> now makes up half of it — is
> [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md). Start there.
> The work queue lives here, in [`DEFERRED.md`](DEFERRED.md).

Strip the marketing and a cloud is **one image format, several things that can
run it, a network they share, a service that tells each one who it is, and a
loop that keeps reality matching a declaration.** This lab assembles the phases
this repo already has into exactly that, on a single host — with a **Phase-1
chroot as the universal userspace** every compute type imports, and
**Firecracker microVMs** (`phase7-firecracker/`) as the fourth compute type
beside QEMU VMs, containers, and LXD system containers.

## What exists today, and where

| artifact | slice | where it lives |
|---|---|---|
| `lab-fc.sh` + its 5-test suite | 4 | [`phase7-firecracker/`](../../phase7-firecracker/lab-fc.sh) — **committed** |
| P1 / P2 assumption preflights | 0 | [`tools/micro-cloud-preflight.sh`](../../tools/micro-cloud-preflight.sh), [`tools/micro-cloud-preflight-p2.sh`](../../tools/micro-cloud-preflight-p2.sh) — committed |
| FORWARD-surface probe | 3 | [`tools/micro-cloud-fabric-probe.sh`](../../tools/micro-cloud-fabric-probe.sh) — committed |
| wizard walkthrough harness | 0 | [`tools/wizard-walkthrough.sh`](../../tools/wizard-walkthrough.sh) — committed |
| the measurements (Appendices A–H) | 0–4 | [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md) — committed |
| **`fabric.sh`** (`up`/`tap`/`retap`/`status`/`down`) | 3 | ✅ **committed 2026-08-04** — [`fabric.sh`](fabric.sh). It was **not** in the host workdir this table originally named; recovered from the session transcript instead ([plan §18.1](../../MICRO_CLOUD_LAB_PLAN.md#181-the-precursor-nobody-recorded--fabricsh-is-not-in-the-repo)). **re-verified 2026-08-04**: `up`/`tap`/`status`/`down` all green against the live host, teardown's Calico comparison matching the moved binding ([I.7](../../MICRO_CLOUD_LAB_PLAN.md#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)). The **slice-3 exercise** — two microVMs, DHCP, name resolution — is **not** re-run |
| slice 1/2 configs, boot logs, images | 1–2 | ⛔ host workdirs `micro-cloud-s1/`, `micro-cloud-s2/` — [`DEFERRED.md`](DEFERRED.md) §17.0 item 2. **These really are there** (verified 2026-08-04); it was only the *scripts* that were not |

> ⚠️ **Do not reimplement `fabric.sh` from Appendix G's description.** The
> appendix records measurements of *that* script — the teardown assertion that
> caught [F.6](../../MICRO_CLOUD_LAB_PLAN.md#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel),
> the four defects found inside its own safety checks. A rewrite would leave the
> record describing an artifact it never measured — this repo's bug class #1
> (a record that outlives the thing it describes). Commit the measured file.

## Target layout

The plan's [§9.1](../../MICRO_CLOUD_LAB_PLAN.md#9-the-lab--examplesmicro-cloud)
layout, reproduced here as the **target**, not the current state:

```text
examples/micro-cloud/
├── README.md                 ← you are here
├── DEFERRED.md               ← the work queue (moved from plan §17) — EXISTS
├── micro-cloud.toml          ONE spec: chroot + microvms + vm + containers
├── fabric.sh                 bridge/tap/NAT/dnsmasq (slice 3 — commit from workdir)
├── micro-cloud.sh            up | down | status — orders the phase tools
├── preserve.sh               two tiers + derivation manifest
├── install-catalog.toml      names the lab that owns each install method
├── images/                   .gitignore'd build output (vmlinux, *.ext4)
├── hand-walk/                Containerfile + RUNBOOK
├── RUNBOOK-*.md              build-images · first-microvm · micro-cloud · fleet · preserve
├── LEDGER.md                 the running defect/surprise ledger
├── CLONES.md                 every fork, with the constraint that justified it
├── UPSTREAM.md               cite-don't-mirror provenance
├── MANUAL_TESTING.md         observed vs merely generated
└── tests/                    lib.sh + run-all.sh + host-safe checks
```

## Routing note

This lab is deliberately **not yet routed** into a learning path: the plan
([§11](../../MICRO_CLOUD_LAB_PLAN.md#11-catalog-routing-and-the-install-surface))
routes it at slices 9–10, with the build slices as the path's steps. Until
then it is listed in `learning-paths.toml`'s `[meta.coverage_exempt]` with this
reason, so `tools/paths.py --check` stays green without pretending the journey
exists.
