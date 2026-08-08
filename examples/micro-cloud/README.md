# Micro-Cloud Lab — ☁️ under construction

> **Status (2026-08-06):** slices 0–4 are **done**, **slice 5a is done — both halves**, and **slice 5b is done**
> — a second engine (QEMU `-M microvm`) booting the same kernel and the same rootfs,
> so the only variable is the VMM. It produced the number nobody had **and corrected
> the one everybody had**: `0.512 s` of Firecracker's canonical `0.567 s` is a kernel
> **i8042 probe** waiting out a PS/2 controller QEMU's `microvm` does not emulate. At
> their defaults QEMU looks 8× faster; on equal footing Firecracker is **1.29× faster
> in the guest and 1.49× faster wall-clock**
> ([Appendix J](../../MICRO_CLOUD_LAB_PLAN.md#j3-the-headline-that-was-false)). And half **(b)**: both engines on `br-mc0` at once, distinct DHCP
> leases from one dnsmasq, **each engine's guest resolving the other's by name**, and the
> live cluster untouched — which fills in §18.4's seam table and settles **decision E as
> §8.3 shape (b)** ([Appendix K](../../MICRO_CLOUD_LAB_PLAN.md#k2-decision-e-answered--184s-table-filled-in-from-what-the-two-lifecycles-needed)). Its brief, confounds, privilege split and break pass
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
| **`tests/test-dhcp-exhaustion.sh`** | 3 (break pass) | ✅ **GREEN at root 2026-08-06** — §14's *"exhaust the DHCP pool"*, deferred since slice 3 because `.100–.200` is 101 leases. The pool is now `MC_DHCP_LO`/`MC_DHCP_HI` and a five-address one fills in seconds. Grades **both** layers that can run out — reservation time (our code refuses by name **before** the tap exists) and lease time (dnsmasq) — and asserts the inverse of 5b's property: with the dynamic pool empty a **reserved** instance still gets **its own** address, with an unreserved client at the same instant getting nothing as the control. Fake guests are veth pairs whose far end lives in a netns, so no leased address is ever visible to Calico ([M.8](../../MICRO_CLOUD_LAB_PLAN.md#m8-the-cheaper-half-of-g9-built--and-the-defect-the-knob-uncovered-2026-08-06)). **Needs root; SKIPs without it** — run 2026-08-06: **all ten assertions**, layer 1 ABSORBED · layer 2 HALTED honestly · the reserved instance still holding `10.71.0.101` from an exhausted pool. The first run had failed its 9th, and **the fabric was right**: `down` refused to call teardown clean while the test's own fake clients were still on the bridge. Two harness defects fixed (the worse one: `dhcp_ask` in a command substitution, so its cleanup bookkeeping went to a subshell and the trap reaped nothing) |
| `lab-fc.sh` + its 5-test suite | 4 | [`phase7-firecracker/`](../../phase7-firecracker/lab-fc.sh) — **committed** |
| P1 / P2 assumption preflights | 0 | [`tools/micro-cloud-preflight.sh`](../../tools/micro-cloud-preflight.sh), [`tools/micro-cloud-preflight-p2.sh`](../../tools/micro-cloud-preflight-p2.sh) — committed |
| FORWARD-surface probe | 3 | [`tools/micro-cloud-fabric-probe.sh`](../../tools/micro-cloud-fabric-probe.sh) — committed |
| wizard walkthrough harness | 0 | [`tools/wizard-walkthrough.sh`](../../tools/wizard-walkthrough.sh) — committed |
| the measurements (Appendices A–H) | 0–4 | [`MICRO_CLOUD_LAB_PLAN.md`](../../MICRO_CLOUD_LAB_PLAN.md) — committed |
| **`fabric.sh`** (`up`/`tap`/`retap`/`status`/`down`) | 3 | ✅ **committed 2026-08-04** — [`fabric.sh`](fabric.sh). It was **not** in the host workdir this table originally named; recovered from the session transcript instead ([plan §18.1](../../MICRO_CLOUD_LAB_PLAN.md#181-the-precursor-nobody-recorded--fabricsh-is-not-in-the-repo)). **re-verified 2026-08-04**: `up`/`tap`/`status`/`down` all green against the live host, teardown's Calico comparison matching the moved binding ([I.7](../../MICRO_CLOUD_LAB_PLAN.md#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)). The **slice-3 exercise** — two microVMs, DHCP, name resolution — is **not** re-run |
| **`tests/test-fabric-round-trip.sh`** | 3 | ✅ **committed 2026-08-05** — [`tests/`](tests/run-all.sh). `up` → `tap` ×2 → `status` → `down`, asserting the taps are addressless and owner-checked and that **Calico's binding, pod veth count and `ip_forward` are unchanged across the run** — derived independently of `fabric.sh`'s own comparison, so a regression in that comparison cannot hide behind it. **Needs root; SKIPs without it** — and its privileged path was **run 2026-08-05: `1 passed, 0 skipped, 0 failed`**, so none of the three skip guards fired and the assertions in between actually executed ([I.9](../../MICRO_CLOUD_LAB_PLAN.md#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass)) |
| **`bench-boot.sh`** + `tests/test-bench-boot.sh` | 5a(a) | ✅ **committed 2026-08-05** — [`bench-boot.sh`](bench-boot.sh). Four arms (each engine × i8042 probe on/off), N runs each, reporting the **spread** and both a guest-kernel and a wall-clock number. The `qemu-*` pair is the **negative control** — `microvm` has no i8042, so those two arms must agree, and the test fails by name if they ever diverge. Unprivileged; SKIPs without KVM/firecracker/QEMU |
| **`tests/test-two-engines-one-fabric.sh`** | 5a(b) | ✅ **committed 2026-08-05** — Firecracker + QEMU `-M microvm` on two `fabric.sh` taps, **both dropped to uid 1000 with `runuser`** so the tap-ownership assertion means something (a root VMM can open any tap). Asserts the guests' own `SLICE3-PING-BY-NAME OK` marker, not scraped ping text. **Needs root; SKIPs without it** — run 2026-08-05: **3 passed, 0 skipped** |
| **`tests/test-retap-recovers-a-root-owned-tap.sh`** | 3 (break pass) | ✅ **GREEN 2026-08-07 — `retap` is closed.** `TUNSETIFF-FAILED errno=1` on a tap with owner uid **0** → `retap` → `TUNSETIFF-OK`, the DHCP reservation **byte-identical and still single**, the tap addressless on `br-mc0`, both verbs refusing the other's case, and Calico's binding + pod-veth count unmoved. **Three privileged runs, two harness defects, zero defects in `fabric.sh`** — the test caught itself twice: an owner-**less** tap is attachable by *anyone* (so run 1's "break" was never a break), and §5 asserted a *message* where the tool was right. [Appendix P](../../MICRO_CLOUD_LAB_PLAN.md#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07) |
| **`edge.toml`** + `tests/test-edge-on-the-fabric.sh` | 5b | ✅ **GREEN 2026-08-06** ([M.1](../../MICRO_CLOUD_LAB_PLAN.md#appendix-m--slice-5b-the-fidelity-case-joins-the-fabric-2026-08-06)) — The fidelity case: a stock Debian cloud image on `-M q35` with cloud-init, on a `fabric.sh` tap beside a Firecracker microVM, asserting it takes the lease the fabric **reserved** (not merely *an* address from the pool) and reaches `api1` by name. `api1` is booted **through `lab-fc.sh`**, which no previous slice did — that is the seam [Appendix L](../../MICRO_CLOUD_LAB_PLAN.md#appendix-l--slice-5bs-first-finding-before-a-line-of-it-was-built-the-two-tools-could-never-agree-2026-08-05) fixed. **Needs root; SKIPs without it** — run 2026-08-06: the edge took its **reserved** lease `10.71.0.102` and reached `api1` by name |
| **`vsock-agent.c`** + **`make-vsock-rootfs.sh`** + **`vsock-probe.py`** + `tests/test-vsock-both-engines.sh` | 5c | ✅ **GREEN 2026-08-07** — vsock, the first channel that is **not the fabric**. The gap was never plumbing (every host-side fact checked out; the kernel has `CONFIG_VSOCKETS`/`VIRTIO_VSOCK` **built in**, which matters because Firecracker boots with no initramfs): it was **userspace** — `strings api1.ext4 \| grep -ci vsock` was **0**, and busybox `nc` has no `AF_VSOCK`. So [`vsock-agent.c`](vsock-agent.c) is a static musl agent, injected by [`make-vsock-rootfs.sh`](make-vsock-rootfs.sh) with `debugfs` (**no loop mount, no sudo** — the `mke2fs -d` family of trick) and verified by reading it back out. **The only boot test here that needs neither root nor a fabric**, which is the thesis rather than a convenience: it asserts `br-mc0`'s *absence*. Findings in [Appendix N](../../MICRO_CLOUD_LAB_PLAN.md#appendix-n--slice-5c-vsock-the-first-channel-that-is-not-the-fabric-2026-08-07) |
| **`tests/test-vsock-chaos.sh`** | 5c (break pass) | ✅ **GREEN** — **micro-cloud's first chaos matrix**, **six rows** (five on 2026-08-07; the stalled-client row 2026-08-08), **unprivileged**, graded on `CLAUDE.md`'s ladder and written as a *regression guard*: each row records the rung it was measured at and the test fails when a rung **moves**, in either direction. Severing the guest's **entire network** is **ABSORBED** (vsock really is not the fabric — and the guest's own `MC-LINK carrier=0` proves the fault landed, after a no-op injector was found passing the row); a reserved CID is **ABSORBED** at device creation; killing the VMM **HALTS** both engines in 0 s with a named errno. The **critical is not ours**: `rm`-ing Firecracker's host socket leaves a running, healthy guest permanently unreachable — its API answers *"not supported after starting the microVM"* — and **QEMU cannot suffer the fault at all**, because its host end is not a file. [N.8](../../MICRO_CLOUD_LAB_PLAN.md#n8-the-break-pass-micro-clouds-first-chaos-matrix-and-a-critical-that-is-not-ours) |
| slice 1/2 configs, boot logs, images | 1–2 | ⛔ host workdirs `micro-cloud-s1/`, `micro-cloud-s2/` — [`DEFERRED.md`](DEFERRED.md) §17.0 item 2. **These really are there** (verified 2026-08-04); it was only the *scripts* that were not |

> ⚠️ **Do not reimplement `fabric.sh` from Appendix G's description.** The
> appendix records measurements of *that* script — the teardown assertion that
> caught [F.6](../../MICRO_CLOUD_LAB_PLAN.md#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel),
> the four defects found inside its own safety checks. A rewrite would leave the
> record describing an artifact it never measured — this repo's bug class #1
> (a record that outlives the thing it describes). Commit the measured file.

> ✅ **`retap` is measured, not read.** The verb added for the root-owned-tap defect on
> 2026-08-02 went five days without being called by anything. It now has a green privileged
> run — and it took **three** of them, because the test failed twice and was **right both
> times**: first on its own fixture (a bare `ip tuntap add` leaves the owner *unset*, and an
> owner-less tap is attachable by anyone, so the "break" was never a break), then on
> asserting a refusal's *wording* where `fabric.sh` was correct. Zero defects in the tool.
> [Appendix P](../../MICRO_CLOUD_LAB_PLAN.md#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07)

> 📋 **Queued as its own lab unit: [`nested-calico-sandbox/`](DEFERRED.md#queued--nested-calico-sandbox-a-disposable-cluster-to-break-on-purpose)**
> — a throwaway microk8s inside a phase-2 VM. `fabric.sh`'s two safety rules (the `^br-.*`
> exclusion; an addressed interface becomes a candidate) are **derived from one host at one
> Calico version** and cannot be falsified here without breaking a live cluster. A cluster
> we may destroy turns them into measurements — and is a safe host for the **whole**
> slice-3 break pass. (`retap` is no longer part of that debt — **green 2026-08-07**.)

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
├── edge.toml                 the §9.2 `edge`: cloud image on q35, one spec (5b) — EXISTS
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
