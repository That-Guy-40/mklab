# Micro-Cloud Lab — ☁️ under construction

> **Status (2026-08-05):** slices 0–4 are **done**, and **slice 5a half (a) is done**
> — a second engine (QEMU `-M microvm`) booting the same kernel and the same rootfs,
> so the only variable is the VMM. It produced the number nobody had **and corrected
> the one everybody had**: `0.512 s` of Firecracker's canonical `0.567 s` is a kernel
> **i8042 probe** waiting out a PS/2 controller QEMU's `microvm` does not emulate. At
> their defaults QEMU looks 8× faster; on equal footing Firecracker is **1.29× faster
> in the guest and 1.49× faster wall-clock**
> ([Appendix J](../../MICRO_CLOUD_LAB_PLAN.md#j3-the-headline-that-was-false)). Half **(b)**, the fabric half, is **still owed**
> ([J.7](../../MICRO_CLOUD_LAB_PLAN.md#j7-not-run--the-fabric-half-is-still-owed)). Its brief, confounds, privilege split and break pass
> are in [`DEFERRED.md`](DEFERRED.md); the design document — and the dated
> measurement record that now makes up half of it — is
> [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md). Start there.
>
> Everything 5a consumes now exists and is verified: the fabric, `lab-fc.sh`,
> `-M microvm`, `--network-mode tap`, and `--disk-format raw`. The assumption
> most likely to have sunk it — QEMU loading Firecracker's **ELF** `vmlinux` —
> was measured and holds
> ([§18.9](../../MICRO_CLOUD_LAB_PLAN.md#189-the-assumption-most-likely-to-sink-5a-retired-before-it-was-scheduled)).

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
| **`tests/test-fabric-round-trip.sh`** | 3 | ✅ **committed 2026-08-05** — [`tests/`](tests/run-all.sh). `up` → `tap` ×2 → `status` → `down`, asserting the taps are addressless and owner-checked and that **Calico's binding, pod veth count and `ip_forward` are unchanged across the run** — derived independently of `fabric.sh`'s own comparison, so a regression in that comparison cannot hide behind it. **Needs root; SKIPs without it** — and its privileged path was **run 2026-08-05: `1 passed, 0 skipped, 0 failed`**, so none of the three skip guards fired and the assertions in between actually executed ([I.9](../../MICRO_CLOUD_LAB_PLAN.md#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass)) |
| **`bench-boot.sh`** + `tests/test-bench-boot.sh` | 5a(a) | ✅ **committed 2026-08-05** — [`bench-boot.sh`](bench-boot.sh). Four arms (each engine × i8042 probe on/off), N runs each, reporting the **spread** and both a guest-kernel and a wall-clock number. The `qemu-*` pair is the **negative control** — `microvm` has no i8042, so those two arms must agree, and the test fails by name if they ever diverge. Unprivileged; SKIPs without KVM/firecracker/QEMU |
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
├── fabric.sh                 bridge/tap/NAT/dnsmasq (slice 3) — EXISTS
├── bench-boot.sh             time-to-userspace, 2 VMMs x i8042 on/off (5a) — EXISTS
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
└── tests/                    lib.sh + run-all.sh — EXISTS (round-trip test; root-gated)
```

## Routing note

This lab is deliberately **not yet routed** into a learning path: the plan
([§11](../../MICRO_CLOUD_LAB_PLAN.md#11-catalog-routing-and-the-install-surface))
routes it at slices 9–10, with the build slices as the path's steps. Until
then it is listed in `learning-paths.toml`'s `[meta.coverage_exempt]` with this
reason, so `tools/paths.py --check` stays green without pretending the journey
exists.
