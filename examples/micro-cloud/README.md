# Micro-Cloud Lab — ☁️ under construction

> **Status (2026-08-19):** slices **0–4, 5a (both halves), 5b, 5c, 6, 7 and 8's fleet half are done.**
> Slice 6 is the control plane — [`reconcile.py`](../../phase6-tui/lab_tui/reconcile.py) (declared vs
> derived, issuing nothing) and [`apply.py`](../../phase6-tui/lab_tui/apply.py) (the half that issues, acting
> on 2 of the 6 diff kinds and holding the rest), with a 6-layer graded chaos matrix that
> found a **LIED** on its first run. Slice 7 is **preserve** —
> [`preserve.sh`](preserve.sh) + [`RUNBOOK-preserve.md`](RUNBOOK-preserve.md): two tiers, a
> `derivation.toml`, and a restore that refuses a changed artifact **by name, with both
> digests, before importing anything**. Slice 8's fleet half is **`lab-fc.sh clone`** +
> [`RUNBOOK-fleet.md`](RUNBOOK-fleet.md): five warm clones from **one** memory image
> (shared `MAP_PRIVATE`, proved by its digest being unchanged after five guests ran on it),
> each with its own disk — and the clone hazard measured rather than asserted. Slice 8's jailer tier
> (`start --jailer`) is **built and verified as far as an unprivileged shell can take it** —
> the live plain-vs-jailed diff needs `CAP_SYS_ADMIN` and is **author-run**. **Slices 9–10
> remain.** What follows is the 5b write-up, kept because the
> finding is the point:
>
> **slice 5b** — a second engine (QEMU `-M microvm`) booting the same kernel and the same rootfs,
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
| `lab-fc.sh` + its test suite | 4 | [`phase7-firecracker/`](../../phase7-firecracker/lab-fc.sh) — **committed** |
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
| **`preserve.sh`** + `tests/test-preserve-gate.sh` + `test-preserve-round-trip.sh` + `test-preserve-capability-table.sh` | 7 | ✅ **GREEN 2026-08-18** — [§9.5](../../MICRO_CLOUD_LAB_PLAN.md#95-preserve--two-tiers-and-a-derivation)'s two tiers and the `derivation.toml` that makes a backup able to say what built it. Walkthrough: [`RUNBOOK-preserve.md`](RUNBOOK-preserve.md). The break-it row is the point — a **one-byte** change to an artifact is refused **by name, with both digests, before anything is imported** — and it is asserted alongside its two neighbours, because an artifact nobody could read must come back **UNKNOWN**, not CHANGED and not a pass. **The gate and the capability table need no engine and no root** (phase 1's `export-tarball` takes a plain path), so the assertion this lab most needs runs in CI; the live round trip drives real rootless podman and SKIPs without it. Two findings: §9.5's fast tier does **not** preserve running state for phase 2 (`qemu-img` internal snapshots are refused against a live disk), and tier 2 loses the **image configuration** as well as running state — `podman export` writes no OCI config, so a restored image has no `CMD` and the drivers' own advertised `run --tarball` round trip dies at the last inch |
| **`lab-fc.sh snapshot`** + `phase7-firecracker/tests/test-snapshot-{refusals,round-trip}.sh` | 7 → unblocks 8 | ✅ **GREEN 2026-08-18** — Firecracker snapshot+memory, the dependency [slice 8](../../MICRO_CLOUD_LAB_PLAN.md#14-build-order--vertical-slices) bottoms out on. **The blocker was `--no-api`**, not a missing verb: pause / `snapshot/create` / `snapshot/load` are API-only, so `start` now passes `--api-sock` beside the config file. A snapshot carries **memory, devices AND the disk from one pause**, because restoring memory over a rootfs that has moved on is filesystem corruption with a clean exit code — and `restore` refuses a changed snapshot by name with both digests. Proved to be a RESTORE and not a reboot by a guest that prints a monotonic counter: snapshot at tick 4, live VM ran to 8, restored resumed at **5**, no kernel banner (the console is append-only across restores, so it is read from a recorded byte offset). `preserve.sh --tier fast` reaches it through the same `snapshot create\|list\|restore\|delete` shape phase 2 uses |
| **`lab-fc.sh clone`** + `tests/test-fleet-clones.sh` + `test-clone-entropy.sh` + `phase7-firecracker/tests/test-clone-refusals.sh` | 8 | ✅ **GREEN 2026-08-19** — §5.8's fleet: **five warm clones from ONE memory image**, in 2.1 s against ~0.5 s to boot one. Walkthrough: [`RUNBOOK-fleet.md`](RUNBOOK-fleet.md). The memory image is genuinely **shared** — Firecracker maps a `File` backend `MAP_PRIVATE`, and the test proves it by sha256ing that file before and after five guests have run and written on it — while each clone gets **its own disk**, because a snapshot's rootfs is one instant of one filesystem and two guests on one copy corrupt it on the first write. So `clone` is `load(resume_vm:false)` → `PATCH /drives/rootfs` → resume, and the PATCH is a **hard gate**: a clone that loaded but was not re-pointed would run on the source's disk with exit code 0 throughout. **The clone hazard turned out to need a 2×2 to see at all** — §5.8's prescribed demonstration (`head -c8 /dev/urandom` matching across clones) does **not** reproduce here, for two independent reasons that had been conflated: the guest kernel already implements §5.8's fix (**VMGenID** → `random: crng reseeded due to virtual machine fork`), *and* the window is only a **handful of reads** wide (1, 3 and 20 across runs here — a fraction of a second), so any probe that pauses before looking misses it. Disable VMGenID and read tightly and the clones are byte-identical, exactly as §5.8 says. In **both** configurations every clone keeps the source's `boot_id` and any secret already derived from the pool — **reseeding on resume fixes the randomness not yet asked for, never the identity already minted from it** |
| **`lab-fc.sh start --jailer`** + `phase7-firecracker/tests/test-jailer-staging.sh` + `tests/test-jailer-isolation.sh` | 8 | ◐ **BUILT 2026-08-19; the live diff NOT YET RUN** — [§5.6](../../MICRO_CLOUD_LAB_PLAN.md#56-the-jailer-tier--phase-1-closes-the-loop)'s isolation tier: chroot + a uid/gid switch around the VMM, closing the loop to Phase 1. **`jailer` unshares a mount namespace, so it needs CAP_SYS_ADMIN** — the plain-vs-jailed comparison SKIPs by name everywhere else, and that SKIP is an **UNKNOWN about §5.6, not a pass**. The half that needs no privilege *is* verified and runs in CI: §5.6's sharp edge is that **every path in `config.json` is relative to the new chroot**, so `--jailer` stages the kernel and rootfs inside the jail (the rootfs **hard-linked**, so one guest disk cannot become two mutable images) and writes a second, in-chroot config — asserted, because a Firecracker that cannot open its root device fails in a way that reads like a corrupt image rather than a bad path. Three findings: the rewrite's first version matched only the whitespace `gen_config` happens to emit and silently rewrote **nothing** against any other formatting; **P7-5 arrived a third time** — a jailed VMM's argv carries no host path at all, so identity now comes from **`/proc/<pid>/root`**, which is stronger than an argv match and is the isolation boundary itself; and **two of the three things §5.6 says to diff are expected not to differ** (the jailer *joins* a netns rather than creating one, and Firecracker seccomps itself in either tier), so the test reports those and asserts only the chroot and the uid drop |
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
├── preserve.sh               two tiers + derivation manifest (slice 7) — EXISTS
├── install-catalog.toml      names the lab that owns each install method
├── images/                   .gitignore'd build output (vmlinux, *.ext4)
├── hand-walk/                Containerfile + RUNBOOK
├── RUNBOOK-*.md              build-images · first-microvm · micro-cloud ·
│                             [fleet](RUNBOOK-fleet.md) · [preserve](RUNBOOK-preserve.md) — EXISTS
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
