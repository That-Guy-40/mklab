# Micro-Cloud Lab — ☁️

> **Status (2026-08-20):** **all ten build slices have landed.**
>
> **Slice 10 is the demo**, and it is one spec and one verb away from being typed:
> [`micro-cloud.toml`](micro-cloud.toml) declares the whole lab — a chroot, two Firecracker
> microVMs, a QEMU VM, an LXD system container and a rootless podman sidecar — using only
> blocks the phase drivers already parse, so nothing here is a fifth schema.
> [`micro-cloud.sh`](micro-cloud.sh) orders them, and its first verb is the one worth
> knowing: **`plan` prints the entire lab as a pasteable shell script and runs nothing.**
> The order comes from [`lab_tui.topology`](../../phase6-tui/lab_tui/topology.py) rather
> than from this script — asking for it is what turned up
> [L10-3](LEDGER.md), where the module that answers *which commands do I type* could not be
> imported without a file-watching library. The capstone is
> [§9.3](../../MICRO_CLOUD_LAB_PLAN.md#93-the-capstone-question--isolation-not-ping)'s
> isolation matrix: *what can each of these four things see of the others?* — measured, with
> the rows nobody could measure printed as **UNKNOWN by name**. Start at
> [`RUNBOOK-micro-cloud.md`](RUNBOOK-micro-cloud.md), keep
> [`MANUAL_TESTING.md`](MANUAL_TESTING.md) open for the privileged half, and read
> [`LEDGER.md`](LEDGER.md) first if your host runs anything that owns its own networking.
> The install methods this repo already covers are catalogued — never rebuilt — in
> [`install-catalog.toml`](install-catalog.toml).
>
> **Slices 0–8:**
> Slice 6 is the control plane — [`reconcile.py`](../../phase6-tui/lab_tui/reconcile.py) (declared vs
> derived, issuing nothing) and [`apply.py`](../../phase6-tui/lab_tui/apply.py) (the half that issues, acting
> on 2 of the 6 diff kinds and holding the rest), with a 6-layer graded chaos matrix that
> found a **LIED** on its first run. Slice 7 is **preserve** —
> [`preserve.sh`](preserve.sh) + [`RUNBOOK-preserve.md`](RUNBOOK-preserve.md): two tiers, a
> `derivation.toml`, and a restore that refuses a changed artifact **by name, with both
> digests, before importing anything**. Slice 8's fleet half is **`lab-fc.sh clone`** +
> [`RUNBOOK-first-microvm.md`](RUNBOOK-first-microvm.md): slice 1, by hand — a JSON file, a
> `vmlinux`, `MICROVM-UP uptime=0.55s`, then the **same** boot driven over the REST socket
> with four `curl -X PUT`s. Start here if you want to know what `lab-fc.sh` is generating
> before you let it generate it.
>
> [`RUNBOOK-fleet.md`](RUNBOOK-fleet.md): five warm clones from **one** memory image
> (shared `MAP_PRIVATE`, proved by its digest being unchanged after five guests ran on it),
> each with its own disk — and the clone hazard measured rather than asserted. Slice 8's jailer tier
> (`start --jailer`) is **done and green**, on its sixth privileged run — the five failures
> before it are the argument for author-run rows, and one of them was §5.6's own instruction
> being unanswerable from the host. **Slices 9 and 10 have since landed too** — this
> block is the slices-0–8 write-up and stopped being a status line when they did; the
> status is the header above and [§14](../../MICRO_CLOUD_LAB_PLAN.md#14-build-order--vertical-slices).
> *(It read "**Slices 9–10 remain**" until 2026-08-21, forty lines under a header saying all
> ten had landed — and it survived the sweep in `0b6a382` that fixed seven other stale status
> lines, which is the useful part: fixing seven instances of a class is not closing it.)*
> What follows is the 5b write-up, kept because the finding is the point:
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
| **`vsock-agent.c`** + **`make-vsock-rootfs.sh`** + **`vsock-probe.py`** + `tests/test-vsock-both-engines.sh` | 5c | ✅ **GREEN 2026-08-07** — vsock, the first channel that is **not the fabric**. The gap was never plumbing (every host-side fact checked out; the kernel has `CONFIG_VSOCKETS`/`VIRTIO_VSOCK` **built in**, which matters because Firecracker boots with no initramfs): it was **userspace** — `strings api1.ext4 \| grep -ci vsock` was **0**, and busybox `nc` has no `AF_VSOCK`. So [`vsock-agent.c`](vsock-agent.c) is a static musl agent, injected by [`make-vsock-rootfs.sh`](make-vsock-rootfs.sh) with `debugfs` (**no loop mount, no sudo** — the `mke2fs -d` family of trick) and verified by reading it back out. **The only boot test here that needs neither root nor a fabric**, which is the thesis rather than a convenience: it asserts `br-mc0`'s *absence*. Findings in [Appendix N](../../MICRO_CLOUD_LAB_PLAN.md#appendix-n--slice-5c-vsock-the-first-channel-that-is-not-the-fabric-2026-08-07). **2026-08-20:** the agent also answers `EXEC <cmd>` with that command's stdout, which is what closed §9.3's microVM row — the matrix's integrity is that *one* probe implementation runs in every context, so the guest had to run the same shell commands every other row runs rather than answer bespoke replies. **That means this image carries a remote shell reachable over vsock.** It is not an escalation — vsock is host-to-guest only, unrouted, and the host already owns the guest's memory, disk and CPU — but it is a surface, and it lives only in the image built to *be* probed |
| **`tests/test-vsock-chaos.sh`** | 5c (break pass) | ✅ **GREEN** — **micro-cloud's first chaos matrix**, **six rows** (five on 2026-08-07; the stalled-client row 2026-08-08), **unprivileged**, graded on `CLAUDE.md`'s ladder and written as a *regression guard*: each row records the rung it was measured at and the test fails when a rung **moves**, in either direction. Severing the guest's **entire network** is **ABSORBED** (vsock really is not the fabric — and the guest's own `MC-LINK carrier=0` proves the fault landed, after a no-op injector was found passing the row); a reserved CID is **ABSORBED** at device creation; killing the VMM **HALTS** both engines in 0 s with a named errno. The **critical is not ours**: `rm`-ing Firecracker's host socket leaves a running, healthy guest permanently unreachable — its API answers *"not supported after starting the microVM"* — and **QEMU cannot suffer the fault at all**, because its host end is not a file. [N.8](../../MICRO_CLOUD_LAB_PLAN.md#n8-the-break-pass-micro-clouds-first-chaos-matrix-and-a-critical-that-is-not-ours) |
| **`preserve.sh`** + `tests/test-preserve-gate.sh` + `test-preserve-round-trip.sh` + `test-preserve-capability-table.sh` | 7 | ✅ **GREEN 2026-08-18** — [§9.5](../../MICRO_CLOUD_LAB_PLAN.md#95-preserve--two-tiers-and-a-derivation)'s two tiers and the `derivation.toml` that makes a backup able to say what built it. Walkthrough: [`RUNBOOK-preserve.md`](RUNBOOK-preserve.md). The break-it row is the point — a **one-byte** change to an artifact is refused **by name, with both digests, before anything is imported** — and it is asserted alongside its two neighbours, because an artifact nobody could read must come back **UNKNOWN**, not CHANGED and not a pass. **The gate and the capability table need no engine and no root** (phase 1's `export-tarball` takes a plain path), so the assertion this lab most needs runs in CI; the live round trip drives real rootless podman and SKIPs without it. Two findings: §9.5's fast tier does **not** preserve running state for phase 2 (`qemu-img` internal snapshots are refused against a live disk), and tier 2 loses the **image configuration** as well as running state — `podman export` writes no OCI config, so a restored image has no `CMD` and the drivers' own advertised `run --tarball` round trip dies at the last inch |
| **`lab-fc.sh snapshot`** + `phase7-firecracker/tests/test-snapshot-{refusals,round-trip}.sh` | 7 → unblocks 8 | ✅ **GREEN 2026-08-18** — Firecracker snapshot+memory, the dependency [slice 8](../../MICRO_CLOUD_LAB_PLAN.md#14-build-order--vertical-slices) bottoms out on. **The blocker was `--no-api`**, not a missing verb: pause / `snapshot/create` / `snapshot/load` are API-only, so `start` now passes `--api-sock` beside the config file. A snapshot carries **memory, devices AND the disk from one pause**, because restoring memory over a rootfs that has moved on is filesystem corruption with a clean exit code — and `restore` refuses a changed snapshot by name with both digests. Proved to be a RESTORE and not a reboot by a guest that prints a monotonic counter: snapshot at tick 4, live VM ran to 8, restored resumed at **5**, no kernel banner (the console is append-only across restores, so it is read from a recorded byte offset). `preserve.sh --tier fast` reaches it through the same `snapshot create\|list\|restore\|delete` shape phase 2 uses |
| **`lab-fc.sh clone`** + `tests/test-fleet-clones.sh` + `test-clone-entropy.sh` + `phase7-firecracker/tests/test-clone-refusals.sh` | 8 | ✅ **GREEN 2026-08-19** — §5.8's fleet: **five warm clones from ONE memory image**, in 2.1 s against ~0.5 s to boot one. Walkthrough: [`RUNBOOK-fleet.md`](RUNBOOK-fleet.md). The memory image is genuinely **shared** — Firecracker maps a `File` backend `MAP_PRIVATE`, and the test proves it by sha256ing that file before and after five guests have run and written on it — while each clone gets **its own disk**, because a snapshot's rootfs is one instant of one filesystem and two guests on one copy corrupt it on the first write. So `clone` is `load(resume_vm:false)` → `PATCH /drives/rootfs` → resume, and the PATCH is a **hard gate**: a clone that loaded but was not re-pointed would run on the source's disk with exit code 0 throughout. **The clone hazard turned out to need a 2×2 to see at all** — §5.8's prescribed demonstration (`head -c8 /dev/urandom` matching across clones) does **not** reproduce here, for two independent reasons that had been conflated: the guest kernel already implements §5.8's fix (**VMGenID** → `random: crng reseeded due to virtual machine fork`), *and* the window is only a **handful of reads** wide (1, 3 and 20 across runs here — a fraction of a second), so any probe that pauses before looking misses it. Disable VMGenID and read tightly and the clones are byte-identical, exactly as §5.8 says. In **both** configurations every clone keeps the source's `boot_id` and any secret already derived from the pool — **reseeding on resume fixes the randomness not yet asked for, never the identity already minted from it** |
| **`lab-fc.sh start --jailer`** + `phase7-firecracker/tests/test-jailer-staging.sh` + `tests/test-jailer-isolation.sh` | 8 | ✅ **GREEN 2026-08-19, on its SIXTH privileged run** — [§5.6](../../MICRO_CLOUD_LAB_PLAN.md#56-the-jailer-tier--phase-1-closes-the-loop)'s isolation tier: chroot + a uid/gid switch around the VMM, closing the loop to Phase 1. **`jailer` unshares a mount namespace, so it needs CAP_SYS_ADMIN** — the plain-vs-jailed comparison SKIPs by name everywhere else, and that SKIP is an **UNKNOWN about §5.6, not a pass**. **The five failed runs are the argument for author-run rows**: every defect was on the privileged side. In order — `jailer` chowns only what *it* creates, so the staged disk was unopenable by the uid the VMM drops to; the test's own fixture booted a guest that exits; then **three successive wrong answers to "which process is the jailed VMM"**, each an inference about how the kernel *renders* something (`/proc/<pid>/root`, then a `/proc` scan with a cwd fallback, then `stat -c %i` on the socket — which is the socket FILE's inode, not the socket's). The answer that is not an inference: **ask the VMM who it is** (`GET /` returns the instance id), with `/proc/net/unix` joining the bound path to a socket inode when a pid is needed. **And the fifth failure was §5.6's own instruction**: `/proc/<pid>/root` renders as `/` for a jailed VMM exactly as for a plain one, so the field it names cannot distinguish the tiers — the mechanism was present, correct and useless, which is this repo's own rule turning up in the *plan* rather than in a test. Measured green instead: **different mount namespaces** (`mnt:[4026531841]` vs `mnt:[4026535173]`), **the same guest disk open as `/rootfs.ext4` inside the jail and as its host path outside** — the chroot in one line of output — and **uid 30000 vs 0**. Three fields are *reported* rather than asserted because the tier does not claim them: `/proc/<pid>/root`, `ns/net` (jailer *joins* a netns given with `--netns`; it does not create one) and `Seccomp` (2 in both; Firecracker filters itself either way). The half that needs no privilege runs in CI: §5.6's sharp edge is that **every path in `config.json` is relative to the new chroot**, so `--jailer` stages the kernel and rootfs inside the jail (the rootfs **hard-linked**, so one guest disk cannot become two mutable images — which in turn means a jailed start takes ownership of the instance's disk, and a later plain `start` names that and the way back) and writes a second, in-chroot config, asserted rather than trusted. **P7-5 arrived a third time** — a jailed VMM's argv carries no host path at all. |
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

> ✅ **Built and routed as its own lab unit: [`nested-calico-sandbox/`](../nested-calico-sandbox/README.md)**
> — a throwaway microk8s inside a phase-2 VM. `fabric.sh`'s two safety rules (the `^br-.*`
> exclusion; an addressed interface becomes a candidate) are **derived from one host at one
> Calico version** and could not be falsified here without breaking a live cluster. A cluster
> we may destroy turned them into measurements: **G.9 is closed on the real artifact** — a
> genuine `fabric.sh` tap captured the guest cluster's tunnel once it was addressed, which is
> [F.6](../../MICRO_CLOUD_LAB_PLAN.md#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel)
> reproduced on purpose ([Appendix Q](../../MICRO_CLOUD_LAB_PLAN.md#appendix-q--the-sandbox-packaged-g9-closed-on-the-real-artifact-2026-08-07)).
> **The caveat that motivated it survives the closure:** the sandbox answers about Calico
> **v3.29.3** and this host runs **v3.28.1**, so its harness stamps the version it observed
> and refuses to generalise across a mismatch.
>
> *This callout said "📋 Queued" until 2026-08-21 — two weeks after the lab shipped, and while
> [`DEFERRED.md`](DEFERRED.md) (the queue that owns the item) already said it was done. The
> queue was right; the README that advertises it was not, which is the worse direction.*

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
├── RUNBOOK-*.md              [first-microvm](RUNBOOK-first-microvm.md) ·
│                             [micro-cloud](RUNBOOK-micro-cloud.md) ·
│                             [fleet](RUNBOOK-fleet.md) · [preserve](RUNBOOK-preserve.md)
├── LEDGER.md                 the running defect/surprise ledger
├── MANUAL_TESTING.md         observed vs merely generated
└── tests/                    lib.sh + run-all.sh (round-trip test; root-gated)
```

**Built 2026-08-23:** [`CLONES.md`](CLONES.md) (the §4.1 reuse ledger — no rung-4 clones, and
that is a `git grep` result rather than an aspiration) and [`UPSTREAM.md`](UPSTREAM.md)
(cite-don't-mirror provenance; every URL fetched and 200 before it was written down, and the
staged binary's sha256 computed from its bytes).

**Also built 2026-08-23:** [`hand-walk/`](hand-walk/RUNBOOK.md) — the disposable box that boots
a microVM **by hand** over the REST API, verified to an Alpine login at `uptime=0.04s` inside a
rootless container. Networking stays author-run: a tap needs `CAP_NET_ADMIN` the box will not take.

**Not to be built:** `RUNBOOK-build-images.md` should
**not** be built: its content is
[step 0](RUNBOOK-micro-cloud.md#step-0--the-spine-and-the-two-things-made-from-it-root-once),
and a second copy is the duplicate-doc defect. Tracked as [TODO](../../TODO.md) **A.5**.

*This class is now checkable rather than only annotated:*
[`tools/check-tree-diagrams.sh`](../../tools/check-tree-diagrams.sh) reads the ASCII trees in
every tracked document and fails when an entry names something that does not exist — the
mechanical form of the question below.

*Found 2026-08-20 while fixing two of the four.* Both this tree and the plan's are **ASCII
art inside a code fence**, so `tools/link_check.py` cannot see them — a filename in a tree
diagram is not a link, exactly as a filename in prose is not. That is the same blind spot
twice in one file, and it is why the entries are now a sentence rather than tree rows.

## Doc audit

**2026-08-21** — the prose of this lab and of
[`metal-as-a-service/`](../metal-as-a-service/README.md) was audited against the tools it
describes: [`REVIEW-docs-micro-cloud-maas.md`](../../REVIEW-docs-micro-cloud-maas.md). Nine
defects, **all nine in sentences written in the present tense** — the dated records
(`LEDGER.md`, `DEFERRED.md`, the plan's appendices) came through clean. Four of the nine
were in this file and in [`MANUAL_TESTING.md`](MANUAL_TESTING.md); three were in
[the plan](../../MICRO_CLOUD_LAB_PLAN.md)'s design sections, including a "CLI surface" whose
lines named five verbs `lab-fc.sh` refuses. All fixed.

## Routing note

**Routed 2026-08-19, exactly as the plan said it would be at slices 9–10**
([§11](../../MICRO_CLOUD_LAB_PLAN.md#11-catalog-routing-and-the-install-surface)):
the journey is [**Build a cloud small enough to hold in your
head**](../learning-paths/path-micro-cloud.md), and its eleven steps *are* the
build slices, in order, each with the checkpoint that slice was exercised
against.

> **This note said the opposite until 2026-08-20**, and it is worth keeping the
> correction visible rather than quietly overwriting it. It claimed the lab was
> *"deliberately not yet routed"* and *"listed in `learning-paths.toml`'s
> `[meta.coverage_exempt]` with this reason"* — both false: the path had existed
> for a day, and `coverage_exempt` holds exactly one entry, `learning-paths.toml`
> itself. **Both gates stayed green the whole time**, because the routing was
> real; `tools/paths.py --check` verifies the *routing*, and no checker reads the
> prose that denies it. A record that outlived its subject, in the one file a
> reader consults to find the journey.
