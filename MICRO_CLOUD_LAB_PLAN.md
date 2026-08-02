# Micro-Cloud Lab — Design Plan v3

> **Status**: draft v3 (2026-07-29) — **decision document, nothing built yet.**
> Scope: assemble the phases this repo already has into one single-host
> **micro cloud**, and add **Firecracker microVMs** as a fourth compute type
> alongside chroots, QEMU VMs, and containers.
>
> Sibling design docs: [`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
> [`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md),
> [`KALI_LLM_LAB_PLAN.md`](KALI_LLM_LAB_PLAN.md),
> [`METAL_AS_A_SERVICE_LAB_PLAN.md`](METAL_AS_A_SERVICE_LAB_PLAN.md).

## What changed from v2

v2 corrected v1's false constraints and re-filed Metal-as-a-Service. v3 changes the
document's **spine**, adds an audience, and replaces prediction with measurement.

1. **New spine (§2).** The organising principle is now *"a chroot is the universal
   userspace, and every compute type imports it"* — stated as a **non-negotiable
   requirement** by the user, 2026-07-29. Measurement then showed **five of its six cells
   already exist in this repo.** That principle is strictly better than v2's
   seven-subsystem mapping table, for a reason §3 explains: one image format with N
   consumers is not an analogy for an image service, it *is* one.
2. **A second audience (§0.2).** The lab will also be handed to friends learning Linux.
   The user's framing: *"here is 'A' path safely through the capabilities of this lab, but
   it doesn't HAVE to be 'THE' path."* That resolves into one invariant, and it turns out
   to cost nothing.
3. **Assumptions measured, not predicted (Appendix A).** A preflight spike (**P1**) checked
   30 of this plan's assumptions on this host: **19 PASS, 2 FAIL, 6 expected-gap XFAIL,
   3 UNKNOWN.** Six of v1/v2's claims are now *evidence* rather than *belief*, two are
   refuted, and three are explicitly "not checked" rather than quietly assumed.
4. **Six decisions settled** (§4, nos. 13–18): catalog-not-absorb; two preserve tiers;
   wizards already exist and pass; a hardline reuse ladder; two entry points with one
   implementation; and the two install gaps scheduled *after* slice 4 so they consume
   `export-rootfs` and the catalog rather than predating both.
5. **§7 rewritten.** This host runs a **live Kubernetes with a Calico overlay**. The
   fabric cannot be designed as though it owns the host's networking.

---

## 0. TL;DR

A cloud is not a mystery box. Strip the marketing and it is **one image format, several
things that can run it, a network they share, a service that tells each one who it is, and
a loop that keeps reality matching a declaration.**

This repo already implements almost all of that, scattered across six phases and ~65
examples. Nobody has ever stood them up at the same time and called the result what it is.

v3 does four things:

1. **Completes the image matrix** (§2). A Phase-1 chroot already becomes an OCI container,
   a netboot initrd, a bootable QEMU disk, and an LXD system container. **One cell is
   missing** — the raw ext4 that Firecracker boots — and it is the only one that needs no
   privilege at all. §6 builds it.
2. **Adds the missing compute type** — `phase7-firecracker/lab-fc.sh` (§5). Firecracker
   makes instances cheap enough (~125 ms boot, <5 MiB overhead) that "spawn twelve" is a
   lab step rather than an afternoon.
3. **Closes the loop backwards** (§9.5). If everything comes *from* a chroot, everything
   should go *back* to one — plus a manifest recording what built it. That is the
   difference between a backup and a **derivation**.
4. **Wires one fabric, two paths, and one control loop** (§7, §0.2, §8).

### 0.1 How this lab is built differs from the others

The other labs here were built to *work*, and their teaching came out of the write-up
afterwards. This one is built to be *understood while it is being built* — the user's
stated goal, 2026-07-29:

> *"The idea is NOT to churn it out as fast as possible to meet the goals of the moment…
> I want to use this build to understand these technologies as well as how to use them,
> more deeply than I do. I want to be actively in both building and exercising this micro
> cloud."*

Three rules follow, and they override the usual component-ladder instinct:

1. **Vertical slices, not components.** Every increment boots something and is exercisable
   the day it lands. v1's M0→M7 built the image bridge, then the kernel, then the driver —
   **nothing booted until M3 and nothing was exercisable until M5.** §14 replaces it.
2. **Hand-walk, then automate, then diff what the tool hides.** v1 had the instinct in one
   place (boot a microVM by hand over the REST API before `lab-fc.sh` exists). Here it is
   the rule for *every* subsystem, with a third step: after the tool works, **name what it
   silently started doing for you.** The understanding lands in that diff, and it is only
   available in that order.
3. **Every increment ships a break-it pass.** Not a final milestone.
   [`metal-as-a-service`](examples/metal-as-a-service/)'s most valuable artifact is not its
   working control plane, it is its
   [**16-defect ledger**](examples/metal-as-a-service/DEFERRED.md) — and every entry came
   from pointing something real at a suite that was green.

**Corollary — a scope rule.** A learning goal makes scope creep *worse*, not better,
because every subsystem is interesting on purpose. So §15's five-instance transcript is
**demoted from the goal to a late milestone**: while it is the goal, the answer to "should
I stop and break this?" is always no.

### 0.2 Two paths, one implementation

The lab has two audiences that appear to want opposite things. The user wants sharp edges
exposed — *"I want the ability to shoot myself in the foot, as in be able to run commands
or driver scripts manually."* Friends learning Linux need a path that is hard to misuse.

The resolution is the user's own framing:

> *"Here is 'A' path safely through the capabilities of this lab, but it doesn't HAVE to be
> 'THE' path."*

Which becomes a single invariant, and the invariant is what makes "I want it all" free:

> ### The guided path is a **view** of the raw path, never a parallel implementation.

Concretely:

| | guided path | raw path |
|---|---|---|
| entry | a wizard, a learning-path step, `micro-cloud.sh up` | any phase tool, any driver script, `curl` at a REST socket |
| what it does | **emits a spec**, or **invokes a command you could type** | is that command |
| destructive verbs | present, but confirmed and explained | present, and immediate |
| audience | someone finding their feet | someone deliberately breaking things |

Three consequences worth stating, because they are what stop this from becoming two
systems:

- **Wizards generate; they never execute.** This is already true of the five that exist
  (§8.2) and it is why a novice cannot destroy anything with one — the worst case is a
  text file. It also makes the wizard a *teaching ladder*: fill a form → watch the TOML
  materialise → save it → run the real command. They graduate off it.
- **A guided step must name the exact command it runs**, and that command must be
  invocable by hand. This is [`metal-as-a-service`](examples/metal-as-a-service/)'s
  actions-panel invariant generalised: there, every declared action's `argv[0]` must be
  `maas-lab.sh`, so *delete Phase 6 and nothing is lost*. Here: delete the guided path and
  nothing is lost.
- **Cliffs get marked, not removed.** `cleaning` wipes a disk; `destroy` destroys. The
  guided path warns and confirms; the raw path just does it. Neither path gets a *different
  implementation* of the dangerous thing — that is how the two versions drift and one of
  them starts lying.

**Mechanical guard**, in the spirit of the chaos-coverage and clone-ledger guards: a test
asserts that every guided step's declared command resolves to a real verb of a real tool.
A guided path that can do something the CLI cannot is the failure this invariant exists to
catch.

---

## 1. What we're building

```text
                          ┌─────────────────────────────────────────────┐
   TWO PATHS (§0.2)       │  guided: wizards · learning path · up/down  │
   one implementation     │  raw:    every phase tool + driver, by hand │
                          └───────────────┬─────────────────────────────┘
                                          │  the guided path is a VIEW of the raw one
   ┌──────────────────────────────────────┼──────────────────────────────────┐
   │                   micro-cloud.toml   │   (one file, every phase)        │
   └──────────────────────────────────────┼──────────────────────────────────┘
                                          │
  THE IMAGE MATRIX (§2) ───────────────┐  │  ┌──────────────────────────────┐
  phase1-chroot: ONE userspace         │  │  │  COMPUTE (4 flavors)         │
    ├─ export-rootfs   → raw ext4   NEW┼──┼─▶│  fc      Firecracker µVM  NEW│
    ├─ (lab-vm from-chroot) → qcow2  ✓ ┼──┼─▶│  vm      QEMU full VM        │
    ├─ export-tarball  → OCI        ✓  ┼──┼─▶│  ctr     podman / docker     │
    ├─ export-tarball  → LXD image  ✓  ┼──┼─▶│  sys     LXD/Incus container │
    └─ export-initrd   → netboot RAM ✓ ┘  │  └───────────────┬──────────────┘
  micro-linux/mlbuild.sh → vmlinux        │                  │
                                          │                  │ tap devices
  PRESERVE (§9.5) ── back to a chroot ────┤                  ▼
    + a derivation manifest (sha256s)     │   ┌──────────────────────────────┐
                                          │   │  NETWORK FABRIC (§7)         │
  METADATA (§5.7)                         │   │  br-mc0  10.71.0.0/24 (free) │
    MMDS @ 169.254.169.254 ───────────────┼──▶│  ⚠ SHARES the host with a    │
    cloud-init NoCloud (QEMU)             │   │    LIVE Calico/k8s overlay   │
    MAAS metadata.py :8282 (a 3rd way)    │   └──────────────────────────────┘
                                          │
  INSTALL METHODS (§11.1) ────────────────┘   catalog, builds nothing:
    kickstart · preseed · autoinstall(NEW) · iPXE/HTTP(S) · dd golden · clonezilla-like(NEW)
```

---

## 2. The spine — a chroot is the universal userspace

**The user's non-negotiable, 2026-07-29:** *"we can create a chroot and import it, as the
userspace, into EVERYTHING we build including Firecracker VMs."*

This is not one feature. It is a **matrix**, one cell per consumer — and it is the right
spine for the whole lab because a cell is either filled or it is not. No analogy, no
hand-waving. Measured on this host (P1, Appendix A):

| chroot → | mechanism that exists **today** | privilege | status |
|---|---|---|---|
| chroot | it *is* one | — | — |
| **OCI container** (podman/docker) | `lab-chroot.sh export-tarball` → `import` | rootless | ✅ P1 PASS |
| **netboot RAM** | `lab-chroot.sh export-initrd` → `cpio.gz` | rootless | ✅ P1 PASS |
| **QEMU VM, bootable** | **`lab-vm.sh` `from-chroot` backend** — partition → `mkfs.ext4` → **mount** → rsync → bootloader (`lab-vm.sh:6`, `:1739`) | **root** (loop) | ✅ P1 PASS |
| **LXD/Incus system container** | `export-tarball` → **`from-tarball` backend**, wraps it with a generated `metadata.yaml`, `image import` | rootless-ish | ✅ P1 PASS |
| **Firecracker raw ext4** | — | *rootless* | ⛔ **the only gap** — §6 |

**Five of six already exist.** v2 wrongly treated "bootable disk from a chroot" as an
unnoticed gap; `lab-vm.sh` has had `from-chroot` all along. That is the "dare to reuse what
we have built" instruction cashing out before a line was written.

### 2.1 The lesson hiding in the matrix

The missing cell is the *easiest* one, and the reason is worth the whole slice:

**Firecracker injects the kernel.** No partition table, no bootloader, no BIOS handoff — so
its image is *just a filesystem*, and `mkfs.ext4 -d <dir>` populates one with **no loop
mount and no privilege** (P1 verified the round-trip: wrote a tree, read
`/etc/hostname` back with `debugfs`). The `from-chroot` QEMU path needs root **precisely
because being bootable requires loop devices and a bootloader**.

> **"What does being bootable actually cost?"** — answered by diffing two cells of your own
> matrix. That is a better lesson than any paragraph about boot protocols, and it is only
> available because both cells exist side by side.

### 2.2 Where Metal-as-a-Service fits, and what does NOT transfer

v1 filed [`metal-as-a-service`](examples/metal-as-a-service/) under §"orchestration",
implying the micro cloud inherits a control plane. **Wrong slot.**

MAAS is the **Ironic rung, built faithfully** — and Ironic's abstraction is *a machine you
do not own*. Its seam discipline enforces exactly that: the control plane reaches a node
**only** through the BMC and its console, policed by a refusing `virsh` stub on `PATH`,
because a machine in a rack has no hypervisor to ask. A cloud compute API is the
**inverse**: `nova boot` *conjures* the instance, and Firecracker's REST socket is not an
out-of-band channel — it **is** the instance's existence.

**Transfers:**

| what | why |
|---|---|
| **`apply`, the reconcile loop** | declare end-state → diff → issue the *minimum* transitions → converge → **no-op on pass two**. The core loop of Terraform and Kubernetes both, carrying the hard-won rule that **it must not trust its own registry** |
| **The deploy drivers themselves** | see §2.3 — this is bigger than a pattern |
| **The driver + catalog shape** | the catalog names the lab that owns each artifact and the exact command that builds it, and **builds nothing** |
| **The metadata service** | [`lib/metadata.py`](examples/metal-as-a-service/lib/metadata.py) is a working NoCloud source *and* a POST sink with DER validation |
| **The chaos ladder** | ABSORBED / DEGRADED / HALTED / STRANDED / LIED. The highest-value import for a learning goal |
| **Registry-as-cache discipline** | derive the fact; if you must cache it, bind it to its subject's identity and refuse a mismatch **by name** |
| **The preflight ordering rule** | refuse before the irreversible step — §5.9 |

**Does NOT transfer:**

| what | why not |
|---|---|
| **Lifecycle ownership** | MAAS never creates a machine; here `destroy` really destroys. Different states: there is a `building` with no BMC analogue |
| **The seam** | MAAS has **one** seam (`bmc.sh <node> <verb>`) because every rack machine answers the same five IPMI verbs. §8.3 |
| **Networking as a subsystem** | MAAS consumes a pre-existing PXE net. §7 is new ground |
| **The console as sole witness** | MAAS reads a serial log because it is all a rack machine offers. A microVM you own can be *asked* (vsock — P1 confirms `/dev/vhost-vsock` present). Keeping the console habit would cargo-cult a constraint that no longer applies |

### 2.3 Two kinds of driver — the reuse that matters most

MAAS's drivers **already are** most of the automated-install surface this lab wants:
`install.sh` is kickstart/preseed-over-PXE (proven live, end to end, on real hardware),
`image.sh` is the `dd` golden image, `ramdisk.sh` is RAM boot. So micro-cloud needs **two
driver kinds, not one**:

| kind | answers | source |
|---|---|---|
| **deploy** drivers | *"what OS goes onto this thing, and how?"* | **reuse MAAS's** — `install` / `image` / `ramdisk`, by **invocation** (§4 rung 1) |
| **lifecycle** drivers | *"how does this thing come into and go out of existence?"* | **new**, one per engine — and this is the four-seam problem, §8.3 |

Keeping them separate is what stops MAAS's seam shape from leaking into the lifecycle
question by momentum.

---

## 3. The cloud-subsystem mapping — context, not spine

v2 made this table the centrepiece. **v3 demotes it**, for an honest reason: it is a
*conceptual* correspondence sold as an architectural one. `export-tarball` is not Glance —
Glance is a service with an API, a database, and multi-tenancy; `export-tarball` is a
command that writes a file. The table is genuinely the best way to *see* what a cloud is
made of, and it is also the fastest way to believe you have built one.

| Cloud subsystem | OpenStack / AWS | What exists here | Gap |
|---|---|---|---|
| **Image service** | Glance / AMI | the §2 matrix; [`micro-linux/mlbuild.sh`](micro-linux/mlbuild.sh) builds kernels from source | **`export-rootfs`** — §6 |
| **Compute — VM** | Nova / EC2 | [`lab-vm.sh`](phase2-qemu-vm/lab-vm.sh) — 6 arches, cloud-init, snapshots | — |
| **Compute — microVM** | Lambda / Fargate | *(QEMU's `microvm` machine is closest)* | **`phase7-firecracker`** — §5 |
| **Compute — container** | ECS / Nova-LXD | [`phase3`](phase3-docker/lab-docker.sh), [`phase4`](phase4-podman/lab-podman.sh), [`phase5`](phase5-lxd/lab-lxd.sh) | — |
| **Network** | Neutron / VPC | bridge/tap in `lab-vm.sh`; dnsmasq in [`podman-pxe-dhcp.toml`](examples/podman-pxe-dhcp.toml); routing/DNS in [`tiny-internet-project`](examples/tiny-internet-project/README.md) | **one fabric** — §7 |
| **Metadata** | config-drive / IMDS | NoCloud seeds (26 labs reference cloud-init); [`metadata.py`](examples/metal-as-a-service/lib/metadata.py) | **MMDS** — §5.7 |
| **Identity / PKI** | Keystone / ACM | [`lab-ca`](examples/lab-ca/README.md) | wire it in |
| **Orchestration** | Heat / `nova boot` | [`phase6-tui`](phase6-tui/README.md) + [`phase6b-web`](phase6b-web/README.md), ABC + 5 backends, **5 working wizards** | **the four-seam problem** — §8.3 |
| **Block storage** | Cinder / EBS snap | qcow2 snapshots; ZFS BEs in [`zfsbootmenu-boot-environments`](examples/zfsbootmenu-boot-environments/README.md) | FC snapshot — §5.8; **preserve** — §9.5 |
| **Bare metal** | **Ironic** | [`metal-as-a-service`](examples/metal-as-a-service/) — built, v1 complete | not a gap — §2.2 |

### 3.1 The honest sentence this table needs

> **This lab builds six subsystems and exactly ONE tenant.**

Nearly everything genuinely hard about clouds lives in what is deliberately excluded:
scheduling under contention, quota enforcement, tenant isolation, API authentication, and a
*shared* control plane degrading under load. Stating that is not a disclaimer — it is the
lesson. A reader who finishes this lab knowing precisely which hard parts they have *not*
done understands more than one who thinks they built AWS.

### 3.2 And what "single host" costs

Decision 1 (single host, no clustering) is not a free scope cut. It removes consensus,
partition tolerance, placement, and live migration — and with them **the reason a control
plane exists separately from a hypervisor.** On one box `micro-cloud.sh up` is a shell
script, and that is *sufficient*, which means this lab structurally cannot teach why
control planes exist.

Fortunately the counter-example is already on the host: a **live Calico/Kubernetes**
(§7.1). "Compare your fabric to the CNI running next to it" is a better capstone question
than "can five instances ping each other."

---

## 4. Decisions

### Settled

| # | Question | Answer |
|---|---|---|
| 1 | Scope | **Single host, no clustering.** With §3.2's cost stated. |
| 2 | New phase dir | **`phase7-firecracker/lab-fc.sh`** — a new compute *rung*. (`phase2b-` rejected: `6b` means "same thing, different UI"; Firecracker is a different thing.) |
| 3 | Instance identity | one `micro-cloud.toml`, every instance a `[[…]]` block with `lab = "micro-cloud"`, so all existing `list --lab` surfaces work unchanged |
| 4 | FC launch mode | **Both**, and **API-by-hand comes FIRST** (slice 1) |
| 5 | Rootfs format | **raw ext4** via `mkfs.ext4 -d` — no loop, no root (P1 verified) |
| 6 | Kernel | pinned FC CI `vmlinux` fast path; `mlbuild.sh` → `vmlinux` as the own-it path (§6.3) |
| 7 | Fabric | one bridge + one tap per instance; **`10.71.0.0/24` — verified unclaimed** (P1) |
| 8 | Addressing | static `ip=` for Firecracker, dnsmasq DHCP for QEMU/LXD; one fabric serves both |
| 9 | Isolation tier | plain `firecracker` first, `jailer` second — it *is* chroot + cgroup + netns + seccomp, closing the loop to Phase 1 |
| 10 | ~~partitioned verification~~ | **superseded** — §10 |
| A | Release | **`v1.16.1`**; asset **`firecracker-v1.16.1-x86_64.tgz`** with an upstream **`.sha256.txt`** (P1) — pin *their* hash, not one we computed |
| 11 | Build shape | **vertical slices with a break-it pass each** — §14 |
| 12 | Hand-walk | **yes** — P1 proved a container can use `--device /dev/kvm` |
| **13** | **Install methods: own or route?** | **Catalog, don't absorb.** 15 install labs already exist; micro-cloud ships a table naming the lab that owns each method and the exact command, and **builds nothing** — MAAS's catalog rule. Plus fill the **two real gaps** as their own small labs (§11.1) |
| **14** | **Preserve** | **Two tiers** — §9.5. Fast/engine-native keeps *running state*; portable/round-trip keeps *reproducibility*, and carries a **derivation manifest** (source spec + artifact `sha256`s + tool versions + date). *A backup that cannot tell you what built it is a record that will outlive its subject.* |
| **15** | **Wizards** | **They already exist and pass** — 5 implementations, `base.py`, **28 tests green** (P1). Work is *extension*, not invention: the **web UI has none**, and phase 7 needs one. Invariant: **wizards generate specs, never execute** (§0.2) |
| **16** | **Reuse discipline** | **Hardline four-rung ladder + an enforced ledger** — §4.1 |
| **17** | **Two entry points** | **Yes** — §0.2, with the guided path a *view* of the raw one |
| **18** | **When do the two install gaps land?** | **After slice 4**, as their own small labs (§11.1). They are independently useful, so the temptation is to start them early — but built *before* `export-rootfs` and the catalog shape exist, each would have to invent its own image plumbing and its own way of being discovered, and then be retrofitted. Landing them after means they *consume* both, and become reusable building blocks rather than one-offs |
| C | vsock agent? | **Available now** — P1 found `/dev/vhost-vsock`. Still start with SSH; the vsock agent is the cleanest counter-example to MAAS's console-only habit |
| D | Bare metal in v1? | **No** — and for a better reason than v1 gave: not "it doubles the surface" but *"it is a different abstraction"* (§2.2). Cross-linked sibling, §9.4 |

### 4.1 Decision 16 — the reuse ladder, hardline

The user's instruction was to *"dare to re-use what it can… and dare to reshape or clone and
bend things that don't"*, with the containment idea that a bend can live in **a wrapper
script or service**. Formalised cheapest-first; **you must justify moving down a rung**:

| rung | move | rule |
|---|---|---|
| **1** | **Invoke** | call the existing tool unchanged. The default. |
| **2** | **Wrap** | a thin adapter translating our vocabulary to theirs **and nothing else**. *A wrapper that reimplements logic is a clone in disguise.* |
| **3** | **Extend upstream** | add a verb or backend to the original so **both** labs benefit. Preferred over wrapping whenever the gap is general rather than ours. |
| **4** | **Clone** | only when the original's constraint is **load-bearing AND wrong for us**. The clone's header must name the original file and the specific constraint it rejects. |

**Made enforceable**, in the spirit of the chaos-coverage guard: a **`CLONES.md`** ledger,
plus a test that **fails when a file declares a fork in its header and is not listed**, or
is listed without naming a constraint. Otherwise the rule decays into a comment nobody
checks.

Applied immediately: the **deploy drivers are rung 1** (invoke MAAS's), the **lifecycle
drivers are new code** (not a clone — there is no original), and **§8.4** records the one
genuinely hard reuse call.

### 4.2 Still open

| # | Question | Recommendation |
|---|---|---|
| B | Does `extract-vmlinux` on a Debian `bzImage` boot under FC? | Still unverified — P1 could not even find the script (it ships in the kernel source tree). Slice 1 can *try it and watch*, so this stops being a decision and becomes an experiment |
| **E** | **What is the control-plane seam?** | **Defer to after slice 5** — §8.3. Deciding now yields an interface shaped by whichever engine was imagined most vividly |
| F | Guest distro | **both**; Alpine default (a 40 MB rootfs makes "spawn twelve" real). Slice 1 builds both and the size/boot-time delta *is* the observation |
| **G** | **How to reuse MAAS's registry/`apply` core?** | **§8.4** — three options, and I recommend not extracting a shared library yet |

---

## 5. New component A — `phase7-firecracker/lab-fc.sh`

The contract every phase tool honours: one self-contained bash script, TOML-or-flags input,
a per-resource state dir with a `manifest.toml`, `--json` on read verbs, `--lab` filtering,
and `tests/` whose every file prints exactly one `PASS`/`FAIL`/`SKIP` line.

> **Sequencing.** Nothing in §5 is written until **slice 4**. Slices 1–3 boot microVMs *by
> hand*. The tool exists to remove typing, and you cannot see what it removed unless you
> did the typing first.

### 5.1 CLI surface

```bash
lab-fc.sh preflight --config examples/micro-cloud/micro-cloud.toml   # §5.9
lab-fc.sh create   --config examples/micro-cloud/micro-cloud.toml
lab-fc.sh create   --name api1 --rootfs images/debian.ext4 --kernel images/vmlinux \
                   --memory 256M --vcpus 1
lab-fc.sh start    api1              # spawn firecracker, wait for the boot banner
lab-fc.sh console  api1              # attach to the serial console
lab-fc.sh ssh      api1
lab-fc.sh list     [--lab micro-cloud] [--json]
lab-fc.sh inspect  api1 [--json]     # manifest + live pid/tap/ip/uptime
lab-fc.sh stop     api1 [--force]    # graceful: SendCtrlAltDel; --force: SIGKILL by PID
lab-fc.sh destroy  api1 [--force]    # stop + delete tap + delete state dir
lab-fc.sh snapshot api1 --tag warm   # pause → snapshot → resume
lab-fc.sh restore  api2 --from api1:warm
lab-fc.sh preserve api1 --tier portable   # §9.5
lab-fc.sh mmds     api1 --set '{"instance-id":"api1"}' | --get
```

> ⚠️ **`destroy` does NOT delete the tap — corrected 2026-08-02, see
> [H.5](#h5-the-83-tripwire-held--and-51-needs-a-correction).** Slice 3 gave tap lifecycle to
> the fabric, and two owners for one resource is this plan's most-repeated bug. In
> `lab-fc.sh` the tap is an **input**: validated, never manufactured or destroyed.

`stop`/`destroy` **resolve to a PID and `kill` it** — never `pkill -f`. The per-VM socket
paths appear in the `firecracker` argv, so a pattern kill would match the very process it
names plus any sibling tooling. This is the footgun that once killed a QEMU VM *and the
agent's own shell* with exit 144; the fix is `fc.pid`.

### 5.2 `[[microvm]]` TOML schema — **deferred to slice 4**

v1 and v2 both specified this schema up front. **v3 deliberately does not**, because slices
1–3 are hand-driven and need no TOML, and a schema authored before its subject exists is a
mild instance of the exact bug class this repo hunts: an interface that outlives — or in
this case *predates* — the thing it describes.

The schema will be **derived from what slices 1–3 actually needed**, and will keep Phase-2
spelling for shared fields (`name`, `lab`, `memory`, `kernel`) so Phase-6 backends read
either without special-casing. The v2 draft is preserved in git history as a starting point,
not a commitment.

**DERIVED AND IMPLEMENTED 2026-08-02 — see [H.2](#h2-the-schema-derived--and-the-two-fields-that-are-refusals).**
The schema is now real, and two of its constraints are enforced as *refusals* rather than
offered as options.

**First derived constraint, from slice 1 — the schema must not expose `root=`.** Firecracker
appends its own `root=/dev/vda` after whatever `boot_args` we supply, and the kernel honours
the last one, so a user-set `root=` is silently ignored whenever `is_root_device: true`
(§5.4 hole 3, [E.4](#e4-two-findings-the-plan-did-not-anticipate)). A field that appears to
work and does nothing is worse than no field. This is what "derived from what the slices
needed" is *for*: a schema authored up front would have offered `root=` because the
Firecracker docs describe `boot_args` as free-form.

### 5.3 State directory

`$LAB_STATE_DIR/fc/<name>/`, mirroring `$LAB_STATE_DIR/vms/<name>/`:

```text
manifest.toml   the resolved spec (what Phase 6 reads)
derivation.toml the PRESERVE manifest — source spec, artifact sha256s, tool versions (§9.5)
config.json     the generated Firecracker machine config (§5.4)
api.sock        Firecracker's REST socket (API mode)
console.sock    serial console (unix socket; one client at a time)
fc.pid          the VMM pid — the ONLY thing stop/destroy signals
fc.log          Firecracker's log fifo, drained to a file (tailable by the TUI)
rootfs.ext4     per-instance copy or CoW overlay
tap             the tap device name, so teardown is deterministic
snapshots/<tag>/{snapshot.bin,memory.bin,config.json}
```

### 5.4 The generated `config.json`

`--no-api --config-file` makes the entire boot a function of the spec:

```json
{
  "boot-source": {
    "kernel_image_path": "…/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=10.71.0.11::10.71.0.1:255.255.255.0:api1:eth0:off"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "…/rootfs.ext4",
      "is_root_device": true, "is_read_only": false }
  ],
  "network-interfaces": [
    { "iface_id": "eth0", "host_dev_name": "mc-api1", "guest_mac": "52:54:00:mc:00:11" }
  ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256, "smt": false },
  "mmds-config": { "version": "V2", "network_interfaces": ["eth0"] },
  "vsock": { "guest_cid": 11, "uds_path": "…/vsock.sock" }
}
```

`tests/test-fc-config-json.sh` asserts: exactly one root drive; `reboot=k panic=1` present;
`ip=` octets match; `host_dev_name` matches the planned tap; MMDS block iff `mmds` set.

**Four holes v2 did not name — holes 1–2 are the mechanism-vs-outcome trap; 3–4 were found
by slice 1 doing it by hand ([Appendix E](#appendix-e--slice-1-one-microvm-by-hand-2026-08-01)):**

1. ~~**`panic=1` being *present* is not evidence that a panic *exits*.**~~ — **OBSERVED
   2026-08-01, [E.3](#e3-the-panic1-hole-closed-by-watching-it).** Same induced panic, one
   variable: with `panic=1` Firecracker exited on its own in **1.63 s**; without it the VM
   **hung until killed at 20 s**. The assertion now guards a behaviour somebody watched.
2. **A config is not a pure function of the spec — it is a function of the spec *and the
   files it points at*.** A generator test passes happily with a nonexistent kernel, or a
   `bzImage` where an ELF is required, validating a document about an imaginary machine. So
   the generator tests must also assert the referenced paths **exist and are the right
   kind** (`file` says ELF, not `bzImage`). Confirmed in slice 1: Firecracker's loader is
   ELF-only and answers a `vmlinuz` with `Elf(InvalidElfMagicNumber)`. **`vmlinuz` is the
   compressed bzImage a bootloader loads; `vmlinux` is the uncompressed ELF Firecracker
   requires** — `extract-vmlinux` converts the former to the latter, which is decision B.
3. **Firecracker APPENDS its own boot args, and the kernel honours the LAST `root=`.**
   Measured ([E.4](#e4-two-findings-the-plan-did-not-anticipate)) — the guest actually saw:

   ```
   console=ttyS0 … root=/dev/vdb rw   pci=off root=/dev/vda rw virtio_mmio.device=…
   ^ ours                             ^ Firecracker's, appended, and it wins
   ```

   So **a `root=` in `boot_args` is silently ignored whenever `is_root_device: true`.**
   §5.2's derived schema **must not expose `root=` as a knob**, because it is not ours to
   set; and any test that induces a root-mount failure must set `is_root_device: false`,
   or Firecracker will quietly repair the fault and the test will pass for the wrong
   reason. That is exactly how slice 1's first `panic=1` run reported "no difference".
4. **A stray `ip=` with no NIC costs ~12 s and says nothing.** Measured: identical rootfs
   and kernel, one added `ip=…` with no `network-interfaces` entry, and userspace start
   went **0.55 s → 12.84 s** — a 23× regression spent in the kernel's IP autoconfiguration
   waiting for a device that never appears, entirely *before* the root mount, with **no
   `IP-Config` line and no error anywhere in dmesg**. Slice 2 owns the guard: **assert
   `ip=` is present in `boot_args` if and only if a `network-interfaces` entry exists.**

### 5.5 API mode is the lesson, config mode is the default

Slice 1's centrepiece: boot one microVM by hand, with `curl`, over a Unix socket — because
that is what a cloud's compute API does when you click "launch instance".

```bash
firecracker --api-sock /tmp/fc.sock &
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/boot-source' \
     -H 'Content-Type: application/json' \
     -d '{"kernel_image_path":"vmlinux","boot_args":"console=ttyS0 reboot=k panic=1 pci=off"}'
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/drives/rootfs' \
     -d '{"drive_id":"rootfs","path_on_host":"rootfs.ext4","is_root_device":true,"is_read_only":false}'
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/actions' \
     -d '{"action_type":"InstanceStart"}'
```

Then the same boot via `lab-fc.sh start`, and the point lands: the tool is a config
generator and a process babysitter, nothing more.

### 5.6 The jailer tier — Phase 1 closes the loop

```bash
jailer --id api1 --exec-file /usr/bin/firecracker \
       --uid 30000 --gid 30000 --chroot-base-dir /srv/jail --netns /var/run/netns/mc-api1 \
       -- --config-file config.json
```

Every noun there is something an earlier phase taught: chroot (Phase 1), namespaces and
cgroups ([`exploring-containers`](examples/exploring-containers/)) — now wrapped *around a
hypervisor*. The step: boot the same microVM plain and jailed, then diff
`/proc/<pid>/root`, `/proc/<pid>/ns/net`, and `/proc/<pid>/status`'s `Seccomp` line. Sharp
edge: under the jailer every path in `config.json` is **relative to the new chroot**, so
kernel and rootfs must be hard-linked or bind-mounted in first.

### 5.7 MMDS — a real 169.254.169.254

Firecracker's Microvm Metadata Service is a genuine link-local endpoint served by the VMM.
The guest curls `169.254.169.254` and gets what the host `PUT` in — *exactly* the EC2/GCE
IMDS contract, V2 token handshake included:

```bash
TOKEN=$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-metadata-token-ttl-seconds: 60')
curl -s -H "X-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
```

The same magic IP you have hit on every EC2 box, on your laptop, served by a process you
started, with contents you can read on disk.

> **Observed 2026-08-01, slice 2 ([Appendix F](#appendix-f--slice-2-the-microvm-gets-an-identity-2026-08-01)).**
> Token `len=48`; `instance-id` read inside the guest matched the host's `PUT`; the same GET
> **without** a token returned **`401`**, and a key nobody `PUT` returned **`404`**. The whole
> probe cost 0.01 s.
>
> **One prerequisite the section did not name:** MMDS V2 needs an HTTP **`PUT`**, and busybox
> wget has only `--post-data`/`--post-file`. A stock Alpine minirootfs therefore **cannot do
> the V2 handshake at all**. Running it from the host instead would test a different seam and
> prove nothing about the guest, so the guest image needs a real client — a constraint for
> §5.2's schema at slice 4, not a detail of one spike. It also grounds the security lesson: MMDS V2's
token exists because V1 plus an SSRF bug is how cloud credentials get stolen.

**Three ways to do metadata, all present here** — config-drive (NoCloud seed, QEMU), IMDS
(MMDS, VMM-served), and [`metadata.py`](examples/metal-as-a-service/lib/metadata.py) serving
NoCloud over HTTP on `:8282` to *a machine it does not own*. The third is the one a cloud
cannot use, and saying why is the exercise.

### 5.8 Snapshot / restore — and the deepest lesson in the plan

```bash
lab-fc.sh snapshot api1 --tag warm
for n in 1 2 3 4 5; do lab-fc.sh restore "w$n" --from api1:warm; done
```

Five warm instances from one memory image, in about the time one would take to boot. That
is literally how Lambda serves a cold start.

**v2 called MMDS "the highest-value teaching artifact." v3 disagrees.** MMDS is the most
*delightful*, but it is a ~30-line contract. The deepest lesson is the **clone hazard**:
every restored clone resumes with the same entropy pool, the same in-memory secrets, the
same MAC, the same clock. Which teaches something no document can:

> **Identity is not a property of an image. It is a property of a running thing — and
> copying memory copies identity.**

That transfers to every cloud primitive. Demonstrate the hazard (`head -c8 /dev/urandom |
xxd` matching across clones), then fix it by re-seeding on resume — which is why real fleets
treat restore as requiring explicit re-personalisation.

Note the ladder position: a fleet of clones that all believe they are the same instance is
**LIED**, not HALTED. Nothing errors. That is why it outranks a crash.

### 5.9 `preflight` — the ordering rule, ported

`create` copies a multi-hundred-megabyte rootfs; `start` creates a tap. Both are effects.
Every gate that can refuse — `/dev/kvm` usable, `firecracker` present at the pinned version,
kernel is an ELF not a bzImage, rootfs exists and has `/sbin/init`, tap name free, no IP
collision — is answerable **before** any of it. And `preflight` must be **the same function
`create` calls first**, not a second implementation that predicts what `create` will do.
Precedent and negative-control shape:
[`test-fleet-preflight.sh`](examples/metal-as-a-service/tests/test-fleet-preflight.sh).

---

## 6. New component B — `lab-chroot.sh export-rootfs`

The one missing matrix cell. Exact analogue of `export-initrd` (cpio.gz) and
`export-tarball` (OCI) — **both P1-verified present**.

### 6.1 CLI

```bash
sudo phase1-chroot/lab-chroot.sh export-rootfs micro-cloud-base \
    --output /var/lib/mklab/images/debian.ext4 \
    --size 1G                # default: du(tree) × 1.4, rounded up
    [--label rootfs] [--strip-modules] [--fstype ext4|squashfs]
```

### 6.2 Internals — and why no loop mount

```text
1. resolve name → target tree            (reuse resolve_target_and_manager)
2. size = --size, else du -sb × 1.4       (ext4 metadata + slack)
3. truncate -s "$size" "$out"
4. mkfs.ext4 -F -L "$label" -d "$target" "$out"     ← populates from a DIRECTORY
5. chown to $SUDO_UID:$SUDO_GID          (same rootless handoff as export-tarball)
6. verify: debugfs -R "ls -l /sbin" "$out"  → assert init is present
```

Step 4 is the trick: **`mke2fs -d <dir>` builds a populated filesystem without ever mounting
it** — no loop device, no `CAP_SYS_ADMIN`, no privileged container. Usable rootlessly
wherever the tree is readable, and verifiable with no mount privileges because `debugfs -R`
reads straight out of the image.

> **P1 re-verified this on 2026-07-29**, not inherited from v1's note: built a 16 MiB ext4
> from a directory tree with `truncate` + `mkfs.ext4 -d`, then read `/etc/hostname` back
> with `debugfs` and matched the expected string.

**Slice 1 gap:** P1's negative control confirms **there are no chroots** under this host's
state dir, so the first `export-rootfs` needs `lab-chroot.sh create` first — sudo-gated, and
the honest first line of slice 1's runbook.

### 6.3 The kernel

FC takes an **uncompressed ELF `vmlinux`** on x86_64 — not the `bzImage` QEMU boots — and a
PE-format `Image` on aarch64.

| # | Source | Verdict |
|---|---|---|
| a | Upstream FC CI kernel artifacts, pinned + `sha256` | **Fast path.** ⚠️ P1 marked the bucket URL **UNKNOWN** rather than guess one — slice 1 pins it |
| b | [`mlbuild.sh`](micro-linux/mlbuild.sh) + an FC-minimal `.config` | **The good path.** It already builds pinned, PGP-verified kernels per arch, and `kernel_image()` **already returns bare `vmlinux` for ppc64le** (`mlbuild.sh:238`) — so x86_64-for-FC is small and well-precedented. P1 confirms x86_64 returns `bzImage` today, naming the exact work. Needs virtio-mmio/blk/net + 8250 + KVM guest, can drop nearly all of PCI — an instructive kconfig exercise |
| c | `scripts/extract-vmlinux` on a distro `bzImage` | **Unverified** (decision B). P1 could not find the script — it ships in the kernel source tree. An experiment for slice 1, not a documented path |

---

## 7. New component C — the network fabric

```text
up:
  ip link add br-mc0 type bridge          # the "VPC"
  ip addr add 10.71.0.1/24 dev br-mc0     # host = gateway   (P1: /24 verified free)
  ip link set br-mc0 up
  nft add table ip mklab-mc               # OUR table, additive — see §7.1
  nft … oifname enx00051b8eb138 ip saddr 10.71.0.0/24 masquerade
  # ip_forward: RECORD the old value, set only if needed  — see §7.1
  dnsmasq --interface=br-mc0 --dhcp-range=10.71.0.100,10.71.0.200 \
          --domain=mc.lab --conf-file=… --pid-file=…
per instance:
  ip tuntap add mc-<name> mode tap
  ip link set mc-<name> master br-mc0 up
down:
  reverse ONLY WHAT WE CHANGED, then assert absence of br-mc0 and every mc-* tap
```

Address plan: `.1` host/gateway/DNS, `.11–.49` static (Firecracker via `ip=`), `.100–.200`
DHCP (QEMU cloud images, LXD). Phase 3/4 containers join through their own engine networks
and reach the fabric via the host — the runbook is explicit that this asymmetry exists and
*why* (rootless podman has no business enslaving a host bridge).

### 7.1 This host is not empty — and one v2 line was a real defect

Measured 2026-07-29. v1 and v2 both designed as though the fabric owns the host's
networking. It does not:

| interface | subnet | owner | verdict |
|---|---|---|---|
| `enx00051b8eb138` | 192.168.1.106/24 | **physical uplink** (USB NIC) | the masquerade target |
| `virbr-vbmc` | 192.168.123.0/24 | libvirt `vbmc-pxe` | **in use by MAAS** — do not touch |
| `virbr0` | 192.168.122.0/24 | libvirt `default` | leave |
| `docker0` | 172.17.0.0/16 | docker (**two** daemons: system + snap) | leave |
| `br-a7bf99683c8d` | 172.18.0.0/16 | docker net `lab-ttd122729-front` | leave |
| ~~`lxdbr0`~~ | **10.216.67.0/24** | ~~LXD — **and the k8s VXLAN underlay**~~ — **wrong, corrected 2026-08-01, see [D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one)**. Carries one veth: mklab's own leftover test container | leave |
| `incusbr0` | **10.45.178.0/24** | Incus — **and Calico's VXLAN tunnel endpoint** (`local 10.45.178.1 dev incusbr0`). **Zero enslaved members** | leave, **load-bearing** |
| `vxlan.calico` | 10.1.24.128/32 (+ blackhole /26) | **live Calico CNI** — microk8s v1.32.13, on the **host** | leave, load-bearing |

**`10.71.0.0/24` is genuinely free** — verified, not guessed. Three consequences it did
*not* survive:

1. **`net.ipv4.ip_forward` is already `1`.** v2's *"down: reverse"* would revert a global
   that a **running Kubernetes depends on**. The rule is now: **record what you changed and
   revert only that.** This is the same shape as MAAS's `error_reason` defect — a path that
   changes state without recording that it did.
2. ~~**Calico owns firewall rules** we cannot even read unprivileged~~ — **corrected
   2026-07-30 by P2, see [B.1](#b1-the-correction--71-consequence-2-was-wrong-about-where-calicos-rules-are).**
   The host ruleset has **no `cali-*` chains at all**; its owners are Docker, libvirt and
   LXD. Calico leaves only `vxlan.calico`, `cali*` veths, and two pod-CIDR accepts in
   `FORWARD`. The conclusion survives its own premise being wrong — our table must still be
   **additive and separately named**, teardown must delete only `mklab-mc` — but the model
   to copy is now specific: **`inet lxd`'s per-bridge chain layout**, and the ruleset is
   **re-read at `up`**, never cached.
3. ~~**§9.2 puts `db` on LXD** — the same LXD hosting the Kubernetes.~~ — **corrected
   2026-08-01, see [D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one).**
   LXD hosts **no** Kubernetes; microk8s runs on the host. The real constraint points the
   **other way**: it is **`incusbr0`** that carries Calico's tunnel endpoint, while
   `lxdbr0` carries nothing but this repo's own test debris. So `db` on **LXD** is the
   safe placement, and the engine `lab-lxd.sh` reaches for by default — Incus — is the
   one to be careful with.

> ⚠️ **FALSIFIED 2026-08-01 by slice 2 — see
> [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel).** Creating one
> tap, with one address, setting no global, still caused the live cluster's VXLAN tunnel
> endpoint to migrate onto it; deleting the tap removed `vxlan.calico`, restarted
> `kubelite`/`calico-node`, and recreated the pods. It self-healed in under a minute, and it
> was still an outage we caused. **Additive is not the same as inert** — a new interface is
> an event a live CNI reacts to. Slice 3 creates a *bridge*, a larger surface than one tap;
> it must record Calico's tunnel binding at pre-flight and compare it at teardown (which is
> the only reason this was caught at all), and it must either use an address Calico will not
> adopt or have the operator pin `IP_AUTODETECTION_METHOD`.
>
> **RESOLVED 2026-08-01 — the rule was derived from the running binary, and §7's existing
> naming already satisfies it. See
> [F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it).** Two constraints, now
> explicit rather than lucky: **the fabric bridge must be named `br-*`** (Calico v3.28.1
> excludes `^br-.*`, and §7 already calls it `br-mc0`), and **taps must carry no IPv4
> address** — an interface without one is never a `first-found` candidate. Slice 2 violated
> the second only because it had no bridge to hold the address. **No operator change to the
> cluster is required.**

**And the upside is larger than the risk.** There is already a real cloud control plane with
a real CNI on this box. Comparing your fabric to Calico's overlay, side by side, on one
host, is a far better capstone than "five instances ping each other" — and it partially
repairs §3.2's structural gap.

### 7.2 Teardown is a test, not a cleanup

`down` asserts absence afterwards and fails loudly otherwise, because a leaked bridge with a
stale `10.71.0.1` quietly breaks the *next* lab. And per §7.1 it must distinguish *what we
created* from *what we found* — a teardown that reverts someone else's global is not a
cleanup, it is an outage.

---

## 8. Control plane — surfacing, wizards, and the four-seam problem

### 8.1 The mechanical half — surfacing

[`phase6-tui/lab_tui/backends/`](phase6-tui/) has `base.py` plus `chroot.py`, `docker.py`,
`lxd.py`, `podman.py`, `vm.py` (+ `control_pane.py`). A sixth is a known shape:

- `backends/fc.py` — `FCBackend(BackendRunner)`, `name = "fc"`, `state_paths() →
  $LAB_STATE_DIR/fc`, `list_resources()` reading each `manifest.toml` + `fc.pid` liveness
  (the `_pid_alive` pattern `vm.py` uses), `inspect()` preferring `lab-fc.sh inspect --json`,
  `console_command → lab-fc.sh console <name>`.
- `BackendName` literal and `ALL_BACKENDS` gain `"fc"`.
- `topology.py` — an `"fc"` `PhaseSlot`. Ordering is a **dependency**, not a preference:
  Phase 1 → export-rootfs → fabric up → fc/vm/containers → fabric down last.
- Phase 6b picks it up for free (`base.py` is framework-agnostic).

### 8.2 Wizards — they exist, they pass, and their shape is already right

P1 measured it: **five wizards** (`wizards/base.py` + `phase1.py`…`phase5.py`,
`wizard_select.py`) with **28 tests passing**. Not stale.

The architecture, from `base.py`: a modal with a form on the left and a **live TOML preview
on the right** that updates as you type; buttons *Save to file* and *Close*; subclasses
override `compose_form()` and `generate_toml()`.

**They generate specs. They never execute.** That is exactly the §0.2 invariant, already
implemented, and it is why they are safe to hand to someone learning Linux — worst case is a
text file. It also makes each one a teaching ladder: form → watch the TOML appear → save →
run the real command → stop needing the wizard.

One detail worth citing to anyone who doubts the framework's care: `_toml_str` carries a
fixed defect (`F-01/T3`, `REVIEW-phase6`) where a multi-line paste **wrote a broken spec to
disk while the preview said "(invalid input)"** — this repo's signature bug, the record
disagreeing with reality, already found and fixed *inside* the wizard code.

**Two gaps, both extension rather than invention:**

| gap | evidence | work |
|---|---|---|
| **`phase6b-web` has zero wizards** | P1 XFAIL — no wizard refs under `phase6b-web/` | port the form→preview→save flow to the web UI; `base.py`'s split makes this mostly a view layer |
| **no `microvm` wizard** | phase 7 does not exist yet | a sixth subclass, after §5.2's schema is *derived* in slice 4 |

Also worth a separate staleness pass: the five **`START_HERE_*_WIZARD.md`** documents, which
a novice reads *before* touching the TUI. Sampled check: all 18 verbs cited across phases
1/2/5 still exist in their tools — but that verifies verb *existence*, not that each
walkthrough succeeds end to end. The latter is a slice-0 exercise for a real beginner.

> **Superseded 2026-08-01 — and the sampled check was reassuring about the wrong thing.**
> Every verb did exist (36/36 across all five phases, not just 18 across three). What the
> verb check could not see was that **Option A — the *recommended* path, the first command
> in all five documents — had never worked**, and that wizard 3's quickstart returned
> HTTP 200 from an unrelated service while the container it claimed to test failed to
> start. Four defects, measured and fixed; see **Appendix C**.

### 8.3 The unsolved half — one seam, or four?

MAAS has **one** seam because every rack machine answers the same five IPMI verbs.
Micro-cloud has four engines whose lifecycle *is* their control surface:

| engine | control surface | "stop" means | has no concept of |
|---|---|---|---|
| Firecracker | REST over a unix socket | `SendCtrlAltDel`, or SIGKILL the VMM | `exec` |
| QEMU (Phase 2) | libvirt/`virsh`, or raw process + monitor | ACPI shutdown, or destroy | — |
| podman (Phase 4) | CLI, rootless | SIGTERM the entrypoint | "power" |
| LXD/Incus (Phase 5) | CLI / REST | `incus stop` | a kernel of its own |

| | shape | attraction | objection |
|---|---|---|---|
| **(a)** | one `instance.sh <name> <verb>` seam, per-engine backends — mirrors `bmc.sh` | one vocabulary; `apply` works unchanged | the verbs **do not mean the same thing**. A seam that forces four engines into one vocabulary lies about three |
| **(b)** | per-engine drivers, common *contract*, engine-specific verbs; the control plane speaks the **intersection** | honest about difference | the intersection may be too small (`create`/`destroy`/`status`) to be interesting |
| **(c)** | don't unify — `micro-cloud.sh` orchestrates existing phase tools; one pane is read-only | zero new abstraction; v1's implicit answer | no `apply`, so MAAS's best contribution doesn't transfer |

**Decision E: choose after slice 5**, when two engines are actually running. Shape (a) is
*seductive* precisely because MAAS just proved it — for a case that isn't this one. Adopting
it by momentum would produce an interface that describes one engine and lies about three.

**Tripwire for slice 4:** `lab-fc.sh` must not grow a verb justified by *"the other engines
will need this too."* That sentence is the drift, and it should be caught in review.

### 8.4 Decision G — how to reuse MAAS's registry and `apply`

`apply`'s reconcile loop is the single best thing to inherit. But the registry's fields are
`bmc_port`, `domain`, `firmware`, `console` — and an instance has none of those. Three
options, judged by the §4.1 ladder:

| | option | ladder rung | assessment |
|---|---|---|---|
| 1 | **invoke `maas-lab.sh`** for what fits | 1 | correct for the **deploy drivers** (§2.3). Wrong for lifecycle — a micro-cloud instance is not a MAAS node |
| 2 | **extract a shared core** both labs import | 3 | correct by the rule, but it means editing a lab that is finished, tested, and live. Extracting an abstraction from **one** example yields an abstraction shaped by that example — the decision-E trap again |
| 3 | **two registries**, sharing the *pattern* not the code | — | duplicates a discipline, not a codebase |

**Recommendation: 1 for the deploy drivers, 3 initially for the registry, 2 as a later
refactor once micro-cloud's schema has stopped moving.** Revisit at slice 6.

---

## 9. The lab — `examples/micro-cloud/`

### 9.1 Layout

```text
examples/micro-cloud/
├── README.md                 the §2 matrix; what a cloud is; §3.1's one-tenant sentence
├── micro-cloud.toml          ONE spec: chroot + microvms + vm + containers
├── fabric.sh                 bridge/tap/NAT/dnsmasq  (§7)
├── micro-cloud.sh            up | down | status — orders the phase tools
├── preserve.sh               the two tiers + derivation manifest (§9.5)
├── install-catalog.toml      names the lab that owns each install method (§11.1)
├── images/                   .gitignore'd build output (vmlinux, *.ext4)
├── hand-walk/                Containerfile + RUNBOOK — P1 proved --device /dev/kvm works
├── RUNBOOK-build-images.md   chroot → export-rootfs → vmlinux (§6)
├── RUNBOOK-first-microvm.md  boot one FC by hand over the REST API (§5.5)
├── RUNBOOK-micro-cloud.md    the full bring-up, instance by instance
├── RUNBOOK-fleet.md          snapshot → restore ×5 + the clone hazards (§5.8)
├── RUNBOOK-preserve.md       back up a lab you liked, and restore it elsewhere (§9.5)
├── LEDGER.md                 the running defect/surprise ledger (§0.1 rule 3)
├── CLONES.md                 every fork, with the constraint that justified it (§4.1)
├── UPSTREAM.md               cite-don't-mirror provenance (§12)
├── MANUAL_TESTING.md         observed vs merely generated (§10)
└── tests/                    lib.sh + run-all.sh + host-safe checks (§10)
```

### 9.2 The instances

| Instance | Type | Role | Why this type |
|---|---|---|---|
| `edge` | QEMU VM | TLS reverse proxy, cert from [`lab-ca`](examples/lab-ca/README.md) | full network stack + cloud-init; the fidelity case |
| `api1`, `api2` | **Firecracker** | two identical app microVMs behind `edge` | the density case; MMDS gives each its own identity from one image |
| `db` | **LXD (`lxc`), pinned** | stateful "pet" with its own init | the system-container case. **Not Incus** — `incusbr0` carries Calico's VXLAN endpoint ([D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one)); `lab-lxd.sh` prefers Incus, so this must be pinned, not probed |
| `metrics` | podman | rootless sidecar | the OCI case, rootless |

### 9.3 The capstone question — isolation, not ping

v2 assumed heterogeneity-on-one-L2 was the payload. **v3 disagrees.** Two microVMs on a
bridge is a *networking* exercise. A microVM beside a **rootless container** on the same
fabric is a *security* exercise, and the four compute types differ far more in their
isolation boundaries than in their network attachment.

So the capstone is not "can they ping" — it is:

> **What can each of these four things see of the others, and what did each boundary cost?**

`/proc`, `/sys`, the process table, the network namespace, `dmesg`, the clock, `/dev/kvm`
itself. §7's rootless-podman asymmetry stops being a footnote and becomes the exhibit.

### 9.4 Sibling, not stretch arm — the bare-metal tier

v1 listed a deferred sixth instance provisioned like bare metal. **v3 reclassifies it:** bare
metal is not a harder version of the same thing, it is a *different abstraction* (§2.2), and
it is already built. It stays a **cross-linked sibling** — micro-cloud's README points at
[`metal-as-a-service`](examples/metal-as-a-service/) for the Ironic row, and MAAS's README
gains a "the cloud-side counterpart" pointer. Absorbing it would flatten the one distinction
this plan most wants a reader to see.

### 9.5 Preserve — two tiers, and a derivation

The user's requirement: *"I MAY also want to back up and preserve the labs, containers, VMs,
or chroots I like."*

| tier | mechanism | preserves | costs |
|---|---|---|---|
| **fast / engine-native** | qcow2 snapshot · FC snapshot+memory · LXD snapshot · `podman commit` | **running state** | non-portable, version- and engine-locked |
| **portable / round-trip** | back to a tarball or chroot **+ `derivation.toml`**: source spec, artifact `sha256`s, tool versions, date | **reproducibility** | loses running state |

The manifest is the MAAS lesson made mechanical:

> **A backup that cannot tell you what built it is a record that will outlive its subject.**

And the tier-2 direction closes the §2 loop: if everything comes *from* a chroot, everything
should go *back* to one. P1 measured that direction too:

| running thing → portable artifact | verb | status |
|---|---|---|
| podman | `export` | ✅ |
| docker | `export`, `export-tarball` | ✅ |
| LXD/Incus | `export` | ✅ |
| **QEMU VM** | **only `snapshot`** | ⛔ **gap** — and pleasingly, it is the exact inverse of the `from-chroot` backend that already exists |

---

## 10. Verification — observed vs merely generated

v1 partitioned verification because nothing could boot here. **It can** (P1: `KVM_CREATE_VM`
returned `api=12`, a real VM fd). So the honesty burden **moves** rather than disappearing.
The old question was *"which claims are untested?"* The new, harder one:

> **Which claims were tested by observation, and which only by reading a config?**

That is the mechanism-vs-outcome trap and it is the single failure mode most likely to make
this lab *feel* understood while it is not.

Per CLAUDE.md, every test prints exactly one verdict line (`PASS`/`FAIL`/`SKIP`, exit
0/1/77), arms an `EXIT` trap printing `FAIL: test exited early (rc=N)` for any rc outside
`{0,77}`, and wraps `die`-ing calls in a subshell.

**Generator tests — assert the artifact, no KVM needed, gate CI:**

| Test | Asserts | ⚠️ does NOT prove |
|---|---|---|
| `test-fc-config-json.sh` | one root drive; `reboot=k panic=1`; `ip=` octets; `host_dev_name` matches the tap; MMDS iff `mmds` — **and that every referenced path exists and is the right kind** (§5.4 hole 2) | that a panic actually exits |
| `test-fc-argv.sh` | `firecracker`/`jailer` argv per spec (sourced-function unit test, modelled on [`test-microvm-argv.sh`](phase2-qemu-vm/tests/test-microvm-argv.sh)) | that the VMM accepts it |
| `test-export-rootfs.sh` | valid ext4 whose `/sbin/init` is present, read back with `debugfs` — no mount, no KVM | that the kernel can **boot** it |
| `test-fabric-plan.sh` | `fabric.sh --dry-run` emits the exact plan; no IP collisions; **every `up` line has a matching `down` line, and `down` touches only what `up` created** (§7.1) | that the bridge forwards a packet |
| `test-fc-preflight.sh` | every §5.9 gate refuses **before** the rootfs copy and the tap, with a tripwire negative control | — |
| `test-guided-path-is-a-view.sh` | **§0.2's invariant**: every guided step's declared command resolves to a real verb of a real tool | — |
| `test-clones-ledgered.sh` | **§4.1**: any file declaring a fork is in `CLONES.md` and names its constraint | — |
| `test-spec-validation.sh` | `micro-cloud.toml` parses; addresses unique; every `[[microvm]]` names a kernel + rootfs | — |
| `test-no-pattern-kill.sh` | no `pkill -f`/`killall` in the new scripts | — |

**Behaviour tests — need KVM, and now RUN here:**

| Test | Observes |
|---|---|
| `test-fc-boots.sh` | a microVM reaches a login prompt; records wall-clock boot time |
| `test-fc-panic-exits.sh` | **the `panic=1` negative control** — with it a panic exits the VMM; without it the VM hangs. Watched, not read |
| `test-mmds-from-guest.sh` | `169.254.169.254` answers *inside* the guest, V2 token handshake included |
| `test-fabric-forwards.sh` | two microVMs on `br-mc0` reach each other; teardown asserts absence |
| `test-clone-entropy.sh` | §5.8's hazard: clones produce identical `/dev/urandom` reads — then don't, after re-seeding |
| `test-isolation-matrix.sh` | §9.3's capstone: what each compute type can see of the others |

**Still author-run / sudo-gated:** `lab-chroot.sh create` (debootstrap needs root), the
fabric's `ip`/`nft` (needs `CAP_NET_ADMIN`), `nft list tables`, and the pinned `firecracker`
download (the agent's runner gates fetch-then-execute of prebuilt binaries — the author
fetches, the agent verifies against **upstream's published `.sha256.txt`**).

`lab-fc.sh` still gets `--dry-run` — not because KVM is missing, but because a plan you can
**diff against the hand-walk** is §0.1 rule 2 made mechanical.

---

## 11. Catalog routing and the install surface

Both gates must stay green (`tools/link_check.py`, `tools/paths.py --check`):

- **[`examples/00-INDEX.md`](examples/00-INDEX.md)** — a `## ☁️ Micro cloud` section, a
  Phase-1 row for the `export-rootfs` spec, and `## 🔥 Firecracker microVMs — Phase 7`.
- **[`examples/learning-paths.toml`](examples/learning-paths.toml)** — a new
  `[[path]] id = "micro-cloud"` (🔴 deep, ⏱ half-day+) whose **steps are §14's slices, in
  order**. Build order and reading order are one sequence, so the path is not a
  retrospective narration. Every step needs an **observable** checkpoint. Also add it to
  `close-to-the-metal`.
- New phase dirs want `README.md` + `SHOWCASE.md` + `MANUAL_TESTING.md` to match phases 1–5,
  and a row in the root [`README.md`](README.md) status table.

**Discoverability is a deliverable.** A reader landing on the lab README should answer *"what
is a cloud made of"* from §2's matrix alone, then *"which of these can I go type right now"*
from the path steps. `LEDGER.md` is part of that surface: it is the file that says *this was
harder than it looks, here is where*.

### 11.1 The install catalog — decision 13

This repo already ships **15 automated-install labs** and **26 labs referencing cloud-init**.
So micro-cloud **catalogs, it does not absorb** — `install-catalog.toml` names, per method,
the lab that owns it and the exact command, and builds nothing (MAAS's rule).

| method | owner today | status |
|---|---|---|
| kickstart | [`almalinux-kickstart-gallery`](examples/almalinux-kickstart-gallery/), [`rocky-kickstart-gallery`](examples/rocky-kickstart-gallery/), MAAS `install.sh` (**live-proven**) | ✅ |
| preseed | [`debian-preseed-gallery`](examples/debian-preseed-gallery/), [`kali-preseed-gallery`](examples/kali-preseed-gallery/), [`debian-pxe-lab`](examples/debian-pxe-lab/) | ✅ |
| iPXE over HTTP / HTTPS | [`debian-http-boot`](examples/debian-http-boot/), [`libvirt-ipxe-http-pxe`](examples/libvirt-ipxe-http-pxe/) | ✅ |
| golden image via `dd` | MAAS [`drivers/image.sh`](examples/metal-as-a-service/drivers/image.sh) | ✅ |
| RAM boot | MAAS [`drivers/ramdisk.sh`](examples/metal-as-a-service/drivers/ramdisk.sh) | ✅ |
| **Ubuntu autoinstall (subiquity)** | — | ⛔ **gap** — genuinely absent (an earlier grep hit was `dkms autoinstall`, a false positive) |
| **Clonezilla-style whole-disk capture** (`ddrescue`, partclone) | — | ⛔ **gap** — and it is the natural tier-1 counterpart to §9.5 |

Both gaps become **their own small labs** — scheduled **after slice 4** (decision 18), so
each consumes `export-rootfs` and this catalog rather than inventing its own image plumbing
and its own route into the docs. Reusable building blocks, not features buried
inside micro-cloud.

### 11.2 Cloud-init: consolidate, don't invent

26 labs already touch cloud-init, and **nowhere teaches it as a subsystem.** The
micro-cloud need is *consolidation*: one runbook putting the three metadata deliveries side
by side (§5.7) and one place that explains NoCloud vs IMDS vs a network metadata service —
citing the labs that already exercise each.

---

## 12. Provenance — and the hand-walk, now proven

Firecracker is **official multi-page docs plus upstream code**, so this is the
**cite-don't-mirror** tier, like
[`zfsbootmenu-boot-environments/UPSTREAM.md`](examples/zfsbootmenu-boot-environments/UPSTREAM.md).
`UPSTREAM.md` records exact URLs (getting-started, network setup, jailer, MMDS, snapshotting,
the API spec) with a **retrieved date**, the pinned tag + `sha256` for every downloaded
artifact, and one line per source on what this lab adapted.

**v1 refused a `hand-walk/`; v3 builds one, and P1 proved the vehicle.** v1's reasoning — *"a
container cannot host a KVM microVM here"* — was downstream of the no-KVM premise. P1 ran
`podman run --rm --device /dev/kvm alpine` and the guest saw `/dev/kvm`. Networking needs
`CAP_NET_ADMIN` and comes later — exactly the partition
[`phase1-chroot/hand-walk/`](phase1-chroot/hand-walk/) already documents for `binfmt`.

That matters more here than in any other lab, because the hand-walk *is* §0.1 rule 2's
vehicle **and** §0.2's guided path in its safest form: a disposable container reproducing the
environment, with a RUNBOOK that says **why** at each step.

---

## 13. Risks and honest constraints

| Risk | Reality | Mitigation |
|---|---|---|
| **A live Kubernetes + Calico shares this host** | **microk8s v1.32.13 on the host** (`kubelite`, `k8s-dqlite`, `calico-node`/`felix`); `vxlan.calico` up over **`incusbr0`**, ~~`lxdbr0`~~ ([D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one)); `ip_forward` already `1`; 140 Calico rules in **legacy xtables** ([B.2](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it)) | §7.1/§7.2: additive nft table scoped by `iifname`, revert only what we set, teardown asserts absence of *our* objects only. **Do not reconfigure `incusbr0`.** **New top risk in v3** |
| ~~No KVM~~ / ~~egress blocked~~ | **Void** — P1: `KVM_CREATE_VM` ok; releases API 200 | pin upstream's `.sha256.txt`; the *fetch* stays author-run |
| **Scope creep into mini-OpenStack** | Very real, and a learning goal makes it **worse** — every subsystem is interesting on purpose | §0.1's slice rule; §15 demoted; one fabric, no scheduler, no multi-tenancy, no HA |
| **Understanding the config instead of the machine** | The likeliest way this feels done while not being understood | §10 splits generator from behaviour tests and names what each does *not* prove; a break-it pass per slice |
| **Two paths becoming two systems** | A guided layer that can do something the CLI cannot | §0.2's invariant + `test-guided-path-is-a-view.sh` |
| **"Dare to bend" becoming six near-identical scripts** | Permission granted; entropy is free | §4.1's four rungs + `CLONES.md` + `test-clones-ledgered.sh` |
| **The seam decided by accident** | Shape (a) is seductive because MAAS just proved it, for a different case | Decision E + slice 4's tripwire |
| **Novices meeting a sharp edge unmarked** | `destroy` destroys; `cleaning` wipes | Cliffs marked, not removed (§0.2); wizards never execute |
| **Root needed for the fabric** | bridge/tap/nft need `CAP_NET_ADMIN` | separate script, own confirmation, teardown *test*; the image half stays rootless |
| **FC's minimal device model surprises people** | No UEFI/PXE/TPM; a panic hangs forever without `panic=1` | make the limits a lesson (§3 note); **observe** the hang (§5.4) |
| **Clone identity duplication** | same entropy, MAC, secrets, clock | demonstrate then fix; it is a **LIED** on the ladder (§5.8) |
| **Phase 7 bit-rots against 1–6** | six tools share conventions by hand | reuse manifest/`--json`/`--lab` verbatim; the Phase-6 backend is the forcing function |

---

## 14. Build order — vertical slices

Every slice boots something and is exercisable the day it lands. Every slice has **build ·
exercise · break**, and the break pass writes into `LEDGER.md`.

| # | Slice | Build | Exercise | Break it |
|---|---|---|---|---|
| **0** | **Preflight** | **P1 done** (Appendix A). **P2**: `nft list tables`, debootstrap a chroot, tap create/delete, fetch+verify FC `v1.16.1` | the assumption table is filled in; 3 UNKNOWNs resolved | a beginner walks one `START_HERE_*_WIZARD.md` end to end and reports where it lies |
| **1** ✅ | **One microVM, by hand** — **DONE 2026-08-01, [Appendix E](#appendix-e--slice-1-one-microvm-by-hand-2026-08-01)** | ext4 from a chroot (Alpine **and** Debian); a `vmlinux`; boot with `--no-api --config-file`; boot again over the REST API with `curl` | **login prompt at 0.55 s**, zero variance over 4 runs; Alpine 8.2 MB tree / 64 MB image and Debian 215 MB / 363 MB — **26× the size, identical boot time** | all four run: `panic=1` dropped → **hung until killed (1.63 s vs 20 s+)**; `is_root_device` flipped → **found FC's arg append**; `ip=` bent → **23× silent regression**; `extract-vmlinux` → **decision B = yes** |
| **2** ✅ | **The microVM gets an identity** — **DONE 2026-08-01, [Appendix F](#appendix-f--slice-2-the-microvm-gets-an-identity-2026-08-01)** | one tap, no bridge (root only for `ip tuntap add`; FC opened it unprivileged); MMDS `PUT` over the API socket | **V2 token handshake by hand from inside the guest** (`len=48`), `instance-id` read at `169.254.169.254` matching the host's `PUT`; boot **0.57 s** with the NIC | **no-token GET → `401`** (the SSRF lesson, observed); never-`PUT` key → `404`; **NIC dropped with `ip=` kept → 12.84 s, 22.5×**, the guard's tripwire reproduced on a second rootfs |
| **3** ✅ | **Two microVMs that reach each other** — **DONE 2026-08-02, [Appendix G](#appendix-g--slice-3-the-fabric-2026-08-02)**; build + exercise + teardown green, break pass **3 of 5** (the two deferred are named in [G.9](#g9-not-run--recorded-as-unknown-not-as-pass), both requiring a host without a live cluster or a config change) | `fabric.sh up/down/retap/status` — additive nft scoped by `iifname`, recorded `ip_forward`, dnsmasq as DHCP **and** DNS. **Bridge MUST be named `br-mc0`** (Calico v3.28.1 excludes `^br-.*`) and **taps MUST carry no IPv4 address** — [F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it) | `api1` pings `api2` **by name**; `down` asserts absence of *our* objects only; **pre-flight records Calico's tunnel binding and teardown compares it** — the assertion that caught [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel) | delete the bridge under a running VM; exhaust the DHCP pool; leave a stale tap; **confirm Calico still works** — and give a tap an address on purpose to watch it become an autodetection candidate |
| **4** ✅ | **The tool, and what it hides** — **DONE 2026-08-02, [Appendix H](#appendix-h--slice-4-the-tool-and-what-it-hides-2026-08-02)** | `lab-fc.sh` + `preflight`; **derive** §5.2's schema from slices 1–3 | one command, same boot; `--dry-run` diffed against slice 1's hand-written `config.json` | the preflight tripwire; **name what the tool silently started doing for you** — that list is the deliverable. Watch for the §8.3 verb tripwire |
| **5** | **A second engine on one fabric** | add the QEMU `edge` (Phase 2 already does bridge mode) | two engines, one L2, one `--lab` view | kill one engine's daemon, see what the other reports. **Answer decision E** |
| **6** | **The control plane** | whichever §8.3 shape slice 5 argued for; `fc.py` backend + topology slot; revisit decision G | all instances in one tree; `apply` a no-op on pass two, if the seam supports it | make the registry disagree with reality — MAAS's registry-layer fault, ported |
| **7** | **Preserve** | `preserve.sh`, both tiers, `derivation.toml`; **`lab-vm.sh export`** (the §9.5 gap) | back up a lab, destroy it, restore it, prove it is the same | restore with a **changed** artifact hash and confirm it refuses **by name** |
| **8** | **The fleet** | snapshot/restore; the jailer tier | five warm clones from one memory image | clone-entropy hazard then re-seeding; diff `/proc/<pid>/root`, `ns/net`, `Seccomp` plain vs jailed |
| **9** | **Two paths, finished** | web wizards (§8.2 gap); a `microvm` wizard; the learning path | a beginner reaches a booted microVM guided-only; you reach one raw-only | `test-guided-path-is-a-view.sh` bites when a guided step does something the CLI cannot |
| **10** | **The demo** | `micro-cloud.sh up`, five instances, §15's transcript; catalog routing | the transcript reproduces; §9.3's isolation matrix | teardown leaves **nothing of ours** and **everything of Calico's** |

**Natural stopping points, and they are real:** slice 2 is a complete lesson (a real IMDS on
your own box). Slice 4 gives a usable Firecracker phase with no micro cloud at all. Slice 7
gives you the backups you asked for. Slice 6 is where it becomes a *cloud* rather than
several things on a bridge. 8–10 are the flourish.

---

## 15. Exit criteria

**A milestone, not the goal** (§0.1). Slice 10's target:

```text
$ examples/micro-cloud/micro-cloud.sh up
  ✓ fabric br-mc0 up, 10.71.0.1/24, NAT via enx00051b8eb138, dnsmasq pid …
  ✓ images: debian.ext4 (412M), vmlinux (ELF, 5.2M)
  ✓ api1  (firecracker)  10.71.0.11  boot 0.13s
  ✓ api2  (firecracker)  10.71.0.12  boot 0.12s
  ✓ edge  (qemu vm)      10.71.0.101
  ✓ db    (lxd)          10.71.0.102
  ✓ metrics (podman)     rootless, host-side
$ ssh api1 'curl -s -H "X-metadata-token: $T" 169.254.169.254/latest/meta-data/instance-id'
api1
$ ssh api1 'ping -c1 db.mc.lab'      # 0% loss — heterogeneous instances, one L2
$ examples/micro-cloud/micro-cloud.sh down
  ✓ no br-mc0, no mc-* taps, no fc pids, no state dirs left
  ✓ calico/k8s untouched: vxlan.calico still up, ip_forward still 1
```

Plus `run-all.sh` green in both new test dirs, and both catalog gates green.

**And the three criteria v1 could not have:**

1. **`LEDGER.md` is not empty**, and every entry names something **observed** rather than
   predicted. A micro cloud that came up first try taught nobody anything.
2. **A beginner reaches a booted microVM using only the guided path** — and can then show
   you the exact command it ran.
3. **You reach the same microVM using only the raw path**, and nothing in the guided path
   was required to exist.

---

## 16. Open questions

Resolved since v2: install methods (**catalog, don't absorb**), preserve (**two tiers +
derivation**), wizards (**they exist and pass; extend to web + phase 7**), reuse (**hardline
four-rung ladder + ledger**), entry points (**two, one implementation**), **when the two
install gaps land** (*after slice 4* — decision 18), the release asset and its upstream
hash, vsock availability, and the subnet.

Still open:

1. **Where to stop.** Slices 2, 4, 6, or 7 are all honest stopping points (§14).
2. **Decision E — the seam** (§8.3). Recommendation: defer to slice 5, with slice 4's
   tripwire.
3. **Decision G — MAAS registry reuse** (§8.4). Recommendation: invoke for deploy drivers,
   separate registry initially, revisit at slice 6.
4. **Decision B — `extract-vmlinux`** (§6.3c). An experiment for slice 1, not a decision.
5. **Should slice 0's break-it pass — a real beginner walking a `START_HERE` doc — happen
   before slice 1?** It is the only test of the novice path that cannot be faked, and it
   costs a friend an afternoon.

---

## 17. Deferred work — pick up here next session

> Written 2026-07-29 at the end of the planning session that produced v2 and v3.
> **This section moves to `examples/micro-cloud/DEFERRED.md` once that directory exists**
> — it lives here only because creating a lab dir with nothing but a DEFERRED.md in it
> would trip `paths.py --check`'s coverage gate (an unrouted lab unit fails CI).

### 17.1 First thing: spike P2 — the privileged half (AUTHOR-RUN) — **DONE 2026-07-30**

> **Result: [Appendix B](#appendix-b--p2-assumption-preflight-2026-07-30).** 11 PASS ·
> 0 FAIL · 1 XFAIL · 0 UNKNOWN, rc=0 — all four checks green, all three of P1's `UNKNOWN`
> rows resolved, and both missing inputs now on disk (`mc-p2-trixie`, 215 MB;
> `firecracker v1.16.1` + `jailer`). It also **falsified §7.1 consequence 2** and produced
> one honest new `UNKNOWN` — where Calico's dataplane actually lives. **Slice 1 is
> unblocked.** The rest of this subsection is the original brief, kept as written.

P1 (Appendix A) checked everything reachable without privilege. **P2 resolves its three
`UNKNOWN` rows and flips its two "expected gap" rows that are merely missing inputs.**
It is sudo-gated and involves a fetch, so it is a hand-off, not an agent task — the
agent's runner gates fetch-then-execute of prebuilt binaries.

Four checks, in dependency order:

| # | check | why it must be P2 | what it unblocks |
|---|---|---|---|
| 1 | **`nft list tables`** — who owns the firewall next to Calico | needs root | §7's "additive, separately named table" plan is currently an *intention*; this makes it a design against a known ruleset |
| 2 | **`debootstrap` one small chroot** | needs root | P1's negative control (*no chroot exists*) is slice 1's missing input. Nothing in §2's matrix can be exercised without a tree |
| 3 | **create + delete one tap on a throwaway bridge** | needs `CAP_NET_ADMIN` | proves the fabric's primitive **without building the fabric** — the cheapest possible de-risk of §7 |
| 4 | **fetch `firecracker-v1.16.1-x86_64.tgz`, verify against upstream's `.sha256.txt`** | fetch+exec gate | slice 1 cannot start without the binary. P1 confirmed the asset **and** the published hash exist |

Then, on the same run: **`firecracker --version`, and one no-op boot attempt**, because
Firecracker's own testing skews Intel and this host is **AMD-V (`svm`)**. "It runs on this
CPU" is an outcome nobody has observed yet.

Deliverable: P1's table re-printed with 0 `UNKNOWN`, plus a one-line note per row that
changed. The write-up belongs in Appendix A as a second dated column, **not** as an edit
to the first — the point of a dated measurement is that it stays a record of what was true
then.

### 17.2 Then slice 1 — one microVM, by hand — **DONE 2026-08-01**

Per §14. What makes it the right next build step is not that it is first on a list, but
that it **converts three arguments into observations**:

- **Decision B** (§6.3c): does `extract-vmlinux` on a Debian `bzImage` actually boot under
  FC? P1 could not even find the script — it ships inside the kernel source tree.
- **Decision F**: Alpine vs Debian. Build both; the size and boot-time delta *is* the
  answer, and it decides whether "spawn twelve" is real.
- **§5.4's first hole**: drop `panic=1` and **watch the VM hang forever**. Until somebody
  sees that, the config assertion guards a string rather than a behaviour.

> **All three converted, and the slice paid for itself twice over — see
> [Appendix E](#appendix-e--slice-1-one-microvm-by-hand-2026-08-01).**
>
> - **B = yes.** The host's own kernel, extracted, boots FC in 0.62 s against the
>   purpose-built CI kernel's 0.55 s. Micro-cloud need not ship or fetch a kernel.
> - **F = the question was mis-framed.** 26× the size, *identical* boot time (0.55 s, zero
>   variance, 4 runs each). Alpine-vs-Debian is a **footprint** decision, not a speed one.
> - **§5.4 hole 1 = observed.** 1.63 s clean exit with `panic=1`; hung until killed without.
>
> And **two holes nobody had named** (§5.4 holes 3–4): Firecracker appends its own boot args
> so a user `root=` is silently ignored, and a stray `ip=` costs 12.3 s in total silence.
> The first was found *because* the `panic=1` experiment showed no difference and the fault
> was checked rather than the result believed.

### 17.3 The one test I cannot run from this side — **HALF DONE 2026-08-01**

**§16 question 5.** A real beginner walking one `START_HERE_*_WIZARD.md` end to end.

I verified that all 18 verbs cited across phases 1/2/5 still exist in their tools. That is
**verb existence, not walkthrough success** — the same mechanism-vs-outcome gap this plan
is organised around, and I cannot close it by reading more carefully. It needs somebody who
does not already know the answer.

It is worth doing **before** slice 1 rather than at slice 9, for a reason that is easy to
get backwards: the novice path is the part most likely to be quietly broken, because nobody
who can fix it has needed it in a long time. Cost: a friend, an afternoon, and a
willingness to hear that the docs lie.

> **The machine-checkable half is now done, and the prediction was right.**
> [`tools/wizard-walkthrough.sh`](tools/wizard-walkthrough.sh) executes every instruction
> the five wizards give instead of reading them. First run: **8 PASS · 4 FAIL · 1 XFAIL ·
> 1 UNKNOWN**, two of the failures blocking a beginner outright — including a launch
> command that **had never worked in the entire history of the repository**. Full table
> and fixes in **Appendix C**.
>
> **This does not close §17.3, and the harness says so on every run.** It carries a
> standing `UNKNOWN` row — *"a beginner who does not know the answer got through it"* —
> that is structurally incapable of becoming `PASS`. A script can prove a command exits
> non-zero. It cannot notice that step 3 assumes knowledge the reader does not have, that
> the prose says "the wizard writes a TOML" without saying where, or that a novice who
> hits `EADDRINUSE` has no idea what to do next. **Do not let a green run retire this
> item.** The friend and the afternoon are still owed.

### 17.4 Open questions

Carried from §16, unchanged:

1. **Where to stop.** Slices 2, 4, 6, or 7 are all honest stopping points.
2. **Decision E — the seam** (§8.3). Recommendation: defer to slice 5; slice 4 carries the
   tripwire.
3. **Decision G — MAAS registry reuse** (§8.4). Recommendation: invoke for deploy drivers,
   separate registry initially, revisit at slice 6.
4. **Decision B — `extract-vmlinux`** (§6.3c). An experiment for slice 1.
5. **The beginner walkthrough** — §17.3.

New, surfaced while writing v3 and not yet decided:

6. **Where does the P1 spike finally live?** It is now kept at
   [`tools/micro-cloud-preflight.sh`](tools/micro-cloud-preflight.sh) — a **provisional**
   home, chosen so the instrument that produced Appendix A survives the session that wrote
   it. *A measurement whose harness is gone cannot be re-run, and an un-re-runnable
   measurement quietly becomes a belief again.* Re-run it any time with
   `tools/micro-cloud-preflight.sh` (exit 0 = no unexpected slice-1 blockers; exit 1 = a
   blocker **or** no `XFAIL` fired). Still to decide: (a) leave it in `tools/`;
   (b) move it to `examples/micro-cloud/tests/test-assumptions.sh` so drift is caught by
   the suite; (c) let it seed `lab-fc.sh preflight` (§5.9), whose host-capability gates are
   mostly these checks. **(c) is probably right, but only at slice 4** — before then there
   is no tool for it to be part of. Until then it is a spike that was kept, not shipped
   tooling, and its header says so.
7. **How does the fabric *record* what it changed?** §7.1 says teardown must revert only
   what `up` set (because `ip_forward` was already `1` and a live Kubernetes depends on it).
   That needs a mechanism — a statefile in the fabric's state dir naming each global it
   touched and the prior value. Small, but it is load-bearing and currently unspecified.
8. ~~**`incus` or `lxc`?**~~ — **SETTLED 2026-08-01: `lxc` (LXD), pinned explicitly.**
   See [D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one).
   They are genuinely separate installs (snap LXD 5.21.5 vs deb Incus 7.2), and the
   premise in the original question — that LXD hosts the Kubernetes — was **false**.
   The decisive fact is the opposite one: **Calico's VXLAN tunnel endpoint lives on
   `incusbr0`** (`local 10.45.178.1 dev incusbr0`), while `lxdbr0` carries nothing but
   this repo's own leftover test container. **Pin it**, do not let `probe_engine` choose:
   `lab-lxd.sh` prefers Incus whenever its daemon answers, so the default is the engine
   we least want to disturb.

   > ⚠️ **REVERSED 2026-08-01, later the same day —
   > [F.8](#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose).** This answer
   > was reasoned from *what rides on each bridge*, which was right as far as it went and
   > was not the deciding factor. **`lxdbr0` is an autodetection candidate at index 9;
   > `incusbr0` is one at index 17.** `^lxcbr.*` does not match `lxdbr0`. So bringing
   > `lxdbr0` **up** — which is exactly what targeting LXD does — inserts a *lower-index*
   > candidate ahead of the interface Calico currently uses, and the next `calico-node`
   > restart can migrate the cluster's node IP to `10.216.67.1`.
   >
   > **Revised answer: target `incus`, pinned.** Not because Incus is better, but because
   > `incusbr0` is *already* the chosen interface, so using it changes nothing. The rule
   > generalises past this host: **prefer the engine whose bridge the CNI has already
   > selected, because that is the one choice guaranteed not to move it.**
9. ~~**Does `db` on LXD still make sense (§9.2)?**~~ — **DISSOLVED 2026-08-01.** The
   question existed only because LXD was believed to be "running someone else's cluster."
   It is not. `db` on LXD is the *safe* placement, and it is now pinned in §9.2. The
   coexistence lesson the question was reaching for is still real — it just lives
   somewhere else: **microk8s on the host**, whose Calico dataplane is 140 rules in legacy
   xtables ([B.2](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it)) and
   whose tunnel endpoint is on a container-engine bridge nobody put it on deliberately.
10. **How do the web wizards share code with the TUI's?** (§8.2's gap.) If the web port
    reimplements `generate_toml()`, there are **two spec generators that can disagree** —
    this repo's signature bug, in a place a novice would meet it first. The port should
    share the generator and re-implement only the *view*. Needs confirming against
    `wizards/base.py`'s actual split before any work starts.
11. **Which Ubuntu release, and does autoinstall need a different netboot path?** (§11.1's
    first gap.) `debian-pxe-lab`'s preseed chain may or may not carry over to subiquity's
    `autoinstall.yaml` + cloud-init datasource model.
12. **Clonezilla-style capture: `partclone`, `ddrescue`, or plain `dd`?** (§11.1's second
    gap.) And where does it sit relative to §9.5's tier 1 — is whole-disk capture a third
    preserve tier, or tier 1 for machines rather than instances?
13. **`preserve` for a chroot itself.** A chroot is already a tree, so tier 2 is presumably
    "tarball + `derivation.toml`" and tier 1 does not exist for it. Probably trivial; worth
    one line so it is not an accidental gap.

### 17.5 One loose thread that is not this plan's

The **CI shell-suite failure** seen on `2018985` (2026-07-30). Proven environmental by the
correct control — *same commit, no changes, re-run passed* (fail at 59s, pass at 2m13s) —
but the cause is **unidentified**, because `gh run view --log` returned empty for the failed
job and the output was never captured. It is the first such failure *after* #113's
`crun` SKIP guard landed, where the three before it were the `crun` era.

**Action if it recurs: capture the log while it is still retrievable**, before re-running.
One data point is not a trend, and a re-run destroys the evidence that would make it one.

---

## Appendix A — P1 assumption preflight, 2026-07-29

**Instrument:** [`tools/micro-cloud-preflight.sh`](tools/micro-cloud-preflight.sh) — kept so
this table can be *re-derived* rather than merely believed. Re-run it with
`tools/micro-cloud-preflight.sh`; its final home is §17.4 question 6.

Run unprivileged on the mklab host. **19 PASS · 2 FAIL · 6 XFAIL (expected gaps) · 3
UNKNOWN**, rc=0, no unexpected slice-1 blockers. `XFAIL` rows are the harness's own negative
control: a preflight reporting all-PASS is indistinguishable from one that checks nothing,
so the script **exits non-zero if no XFAIL fires.**

| verdict | § | assumption | evidence |
|---|---|---|---|
| PASS | §10 | KVM can actually **create** a VM (ioctl, not just open) | `api=12 vm_fd=4` |
| PASS | §5.2,C | vsock available for a no-network agent | `/dev/vhost-vsock` is a char device |
| PASS | §12 | a container can use `--device /dev/kvm` | guest printed `kvm-visible` |
| PASS | §2 | matrix: chroot → OCI container | `export-tarball` in `lab-chroot.sh` |
| PASS | §2 | matrix: chroot → netboot RAM | `export-initrd` in `lab-chroot.sh` |
| PASS | §2 | matrix: chroot → QEMU bootable disk | `from-chroot` in `lab-vm.sh` |
| PASS | §2 | matrix: chroot → LXD/Incus | `from-tarball` in `lab-lxd.sh` |
| **XFAIL** | §6 | matrix: chroot → Firecracker raw ext4 | **expected gap — what §6 builds** |
| PASS | §6.2 | `mkfs.ext4 -d` populates a fs, no mount, no root | `debugfs` read back `microcloud-p1` |
| PASS | §new | preserve: podman → portable | `export` verb present |
| PASS | §new | preserve: docker → portable | `export` verb present |
| PASS | §new | preserve: LXD → portable | `export` verb present |
| **XFAIL** | §new | preserve: QEMU VM → portable | **expected gap — only `snapshot`** |
| **XFAIL** | §6.3b | `mlbuild.sh` emits `vmlinux` for x86_64 | **expected gap — `bzImage` today; ppc64le precedent returns `vmlinux`** |
| UNKNOWN | §6.3c | `extract-vmlinux` available | not on PATH; ships in the kernel source tree |
| PASS | §4A | v1.16.1 publishes an x86_64 asset | `firecracker-v1.16.1-x86_64.tgz` **+ `.sha256.txt`** |
| UNKNOWN | §6.3a | FC CI **kernel** artifact URL | **NOT PINNED — I will not guess a bucket path and report a verdict on it** |
| PASS | §7 | `10.71.0.0/24` unclaimed | no route, no bridge |
| **FAIL** | §7 | `ip_forward` is ours to set **and revert** | **already `1`** — teardown must not revert what it did not set |
| **FAIL** | §7,§13 | the forwarding path has no other owner | **5 live `calico-node`; `vxlan.calico` over `lxdbr0`** — the *verdict* stands; the underlay device is **wrong**, it is `incusbr0` ([D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one)) |
| UNKNOWN | §7,§13 | who owns the nftables ruleset | `nft list tables` needs root — P2 |
| PASS | §9.2 | engines reachable | `qemu-system-x86_64`, `podman`, `docker`, `incus`, `lxc` |
| PASS | §8.1 | the phase1–5 wizards still pass | **28 passed** |
| **XFAIL** | §8.1 | the web UI has wizards | **expected gap — zero refs in `phase6b-web/`** |
| **XFAIL** | §13 | the `firecracker` binary is installed | **expected — author-run fetch** |
| **XFAIL** | §6 | a chroot exists to export | **NEGATIVE CONTROL — none; slice 1 must debootstrap first** |

**P2 (author-run, sudo + fetch) resolves the three UNKNOWNs** and flips the chroot and
firecracker rows. → **[Appendix B](#appendix-b--p2-assumption-preflight-2026-07-30)**, run
the following day. The table above is left exactly as measured on 07-29.

---

## Appendix B — P2 assumption preflight, 2026-07-30

**Instrument:** [`tools/micro-cloud-preflight-p2.sh`](tools/micro-cloud-preflight-p2.sh) —
`sudo tools/micro-cloud-preflight-p2.sh`. The privileged half of Appendix A: it resolves
P1's three `UNKNOWN` rows and flips the two `XFAIL` rows that were merely missing inputs.

Run as root on the mklab host, 22:38 local. **11 PASS · 0 FAIL · 1 XFAIL · 0 UNKNOWN**,
rc=0, no slice-1 blockers.

| verdict | § | assumption | evidence |
|---|---|---|---|
| PASS | §7.1 | the nftables ruleset is readable and recorded | 8 tables, 226 lines — **owners are Docker, libvirt, LXD**; see the correction below |
| PASS | §7.1 | `mklab-mc` is a free table name | no table by that name in any family |
| PASS | §7 | a tap can be created and enslaved to a bridge | `mcp2tap0 master mcp2br0`, both up |
| PASS | §7 | the **unprivileged** user can `TUNSETIFF` that tap | `TUNSETIFF-ok` as `sqs` — the ioctl Firecracker itself issues |
| PASS | §7.2 | teardown **actually** removed both devices | neither device resolves after `ip link del` |
| PASS | §6 | a chroot exists **and executes** | `mc-p2-trixie`, **215 MB** — decision F's Debian datapoint |
| PASS | §4A | the FC tarball matches its **published** sha256 | `382a02a869e4d6d5…` == upstream `.sha256.txt` |
| **XFAIL** | §4A | **CONTROL** — sha verification rejects a wrong digest | **expected mismatch; the verifier bites, so the row above means something** |
| PASS | §13 | the `firecracker` binary runs as `sqs` | `Firecracker v1.16.1`; **`jailer` present too** (§5.6) |
| PASS | §13 | Firecracker reaches the kernel loader **on AMD-V** | `ConfigureSystem(KernelLoader(Elf(InvalidElfMagicNumber)))` — see the caveat below |
| PASS | §6.3c | `extract-vmlinux` turns a distro `bzImage` into ELF | **64 MB ELF** from `/boot/vmlinuz-6.8.0-136-generic`, `unzstd` at offset 21197 |
| PASS | §6.3a | the FC CI kernel URL, **enumerated not guessed** | `…/firecracker-ci/v1.15/x86_64/vmlinux-6.1.155` (newest prefix is **v1.15**, not v1.16 — the bucket lags the binary) |

**The AMD-V row proves less than "Firecracker works here", and says so.** Booting a
megabyte of zeros gets through config parse, `KVM_CREATE_VM` and guest-memory setup, then
fails *at the ELF loader* — which is exactly the diagnosis wanted. `KVM_CREATE_VCPU` and
`KVM_RUN` come after the kernel loads, so this run never reached them.

**But they are not in doubt, and it would be wrong to imply they are.** `phase2-qemu-vm`
selects `accel=kvm` whenever host arch == guest arch and `/dev/kvm` is r+w
([`lab-vm.sh:155`](phase2-qemu-vm/lab-vm.sh)), and every phase-2 VM and every
Metal-as-a-Service node on this box has been executing guest code through `kvm_amd` for
months. **Guest execution under AMD-V is thoroughly observed. The residual is narrower:**
Firecracker does its own vCPU setup — CPUID normalization, MSR handling, CPU templates —
and upstream's AMD support targets **EPYC Milan/Genoa**, while this host is a desktop
**Zen 5 (Ryzen 9 9950X3D)**. So what slice 1 observes for the first time is not "does KVM
work on AMD" but *"does Firecracker's CPUID/MSR setup work on a part upstream does not
test"*. Different question, much smaller, and still worth watching for on the first boot.

### B.1 The correction — §7.1 consequence 2 was wrong about *where* Calico's rules are

v3 said Calico owns firewall rules we could not read unprivileged. Measured with root:
**the host nftables ruleset contains zero `cali-*` or `felix-*` chains.** Every chain
belongs to Docker (`DOCKER-USER`, `DOCKER-FORWARD`, …), libvirt (`LIBVIRT_FW*`,
`LIBVIRT_PRT`), or LXD (`inet lxd`). Calico's footprint in the host netns is three things
and no rules: `vxlan.calico`, per-pod `cali*` veths with `/32` routes, and **two bare
accepts for the pod CIDR** in `FORWARD`:

```text
ip saddr 10.1.0.0/16  counter accept
ip daddr 10.1.0.0/16  counter accept
```

Felix **is** running (`calico-node -felix`, 5 processes) and this **is** the k8s node's
netns. So the dataplane it programs is somewhere P2 could not see: not nftables, and not
eBPF either — the `cali*` veths carry `qdisc noqueue`, with no `clsact` and no tc-BPF
filters, which a Calico eBPF dataplane requires. `/sys/fs/bpf` is `Permission denied`.

> **RESOLVED the same evening — see [B.2](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it).**
> The dataplane was in **legacy xtables** the whole time. The paragraph above is kept
> exactly as written because the *reasoning* is the instructive part: it is this repo's
> "the cheap check is not the real check" lesson, caught in the act, by the harness whose
> job is to catch it.

**This is a new UNKNOWN that P2 created by measuring, and it is more useful than the one it
resolved.** Three design consequences:

1. **Copy LXD's shape, not iptables'.** `inet lxd` is a separate family+table with per-bridge
   chains named `pstrt.lxdbr0` / `fwd.lxdbr0` / `in.lxdbr0` / `out.lxdbr0` — precisely the
   additive pattern §7 wants. Ours becomes **`inet mklab-mc`** with `pstrt.br-mc0`,
   `fwd.br-mc0`, `in.br-mc0`, and teardown deletes that table and nothing else.
2. **Do not shadow the pod-CIDR accepts.** Our masquerade excludes `10.1.0.0/16` the same
   way LXD's excludes its own subnet.
3. **This table list is a record that can outlive its subject** — the repo's bug class #1.
   A Felix restart could program a dataplane between now and `up`. So the fabric **re-reads
   the ruleset at `up` time and refuses on a `mklab-mc` collision**; it never caches this
   appendix.

### B.2 The second firewall — and the bug P2 committed while hunting it

**Measured 2026-07-30, same evening.** B.1's UNKNOWN had a third answer neither of its two
candidates covered:

```console
$ sudo iptables-legacy-save | grep -cE 'cali|felix'
140
$ sudo iptables-legacy-save | grep -E '^:cali'
:cali-OUTPUT   :cali-PREROUTING   :cali-from-host-endpoint   :cali-rpf-skip
:cali-to-host-endpoint   :cali-POSTROUTING   :cali-fip-dnat   :cali-fip-snat   …
```

Felix is in its ordinary iptables dataplane — **140 rules across raw, nat, filter and
mangle** — in the **legacy xtables** backend. Corroborated by the module table:
`ip_tables` is loaded with **refcount 4**, holding `iptable_filter`, `iptable_nat`,
`iptable_mangle` and `iptable_raw`, none of which load unless something has actually
created a legacy table.

**Why P2 could not see them, which is the part worth keeping.** `/usr/sbin/iptables` is an
alternatives symlink to `xtables-nft-multi` on this host, so **both** of P2's probes —
`nft list ruleset` *and* `iptables-save` — read the **nf_tables** backend. Legacy xtables
is a structurally separate kernel subsystem; nothing on the nft side can see into it. P2
read one of two live firewalls and reported it as "the ruleset".

That is precisely the failure this plan is organised around, committed by its own
instrument: **the check asserted a mechanism** (*"`nft list ruleset` succeeded"*) **and let
it stand for the outcome** (*"these are the rules the kernel will evaluate at these
hooks"*). It reported `PASS`, and the `PASS` was worse than a `FAIL` would have been,
because it retired a question that was still open. The harness is fixed: check 1 now reads
**both** backends, names the owners it finds in legacy, and treats `ip_tables` being loaded
with no way to enumerate it as `UNKNOWN` rather than silence.

**What this changes for §7 — and it is not "pick the other backend".** Both backends
register at the same netfilter hooks. Two `filter`/`forward` hooks at equal priority are
ordered by *registration order*, which is a boot-time accident, not a design. So a fabric
that depends on running before or after Calico's rules would be depending on luck.

The rule that removes the dependency entirely: **scope every rule we install to our own
interface by name** — `iifname "br-mc0"` / `oifname "br-mc0"` — exactly as `inet lxd` does
for `lxdbr0`. A rule that can only match our own bridge cannot shadow Calico's pod rules
and cannot be shadowed by them, whichever backend either lives in and whichever registered
first. This is why LXD and Calico have coexisted on this host without incident despite
sitting in different backends at the same hooks, and it is the property §7 should copy.

B.1's three consequences all stand; consequence 3 gains a sharper form: **`up` must read
both backends before claiming `mklab-mc` is free**, because "I checked the firewall" is a
claim about a host, not about a command.

---

## Appendix C — the novice on-ramp, walked by machine, 2026-08-01

**Instrument:** [`tools/wizard-walkthrough.sh`](tools/wizard-walkthrough.sh) — the same
`row`/verdict contract as Appendices A and B, pointed at a completely different subject.
That reuse is the point: what was worth keeping from the P1/P2 spikes was never the
scripts, it was the **contract** — `UNKNOWN` as a verdict distinct from `PASS`, assertions
on outcomes rather than mechanisms, and *exit non-zero if no `XFAIL` fired*.

§8.2 had recorded a sampled check of the five `START_HERE_*_WIZARD.md` documents: the
verbs they cite still exist. That is a **mechanism** assertion — the exact failure shape
this plan is organised around — made about the one document set written for readers who
cannot debug it when it is wrong. §17.3 named the real test and could not schedule it.

This is the half a machine can do: execute every instruction, literally, and report where
the document and the host disagree.

### C.1 First run — 8 PASS · 4 FAIL · 1 XFAIL · 1 UNKNOWN (rc=1)

| verdict | wizard | blocks? | the instruction under test | evidence |
|---|---|---|---|---|
| **FAIL** | all 5 | **YES** | Option A: `python3 -m lab_tui` from the repo root | `ModuleNotFoundError` — the package is `phase6-tui/lab_tui`, *and* bare `python3` has no `textual` |
| **FAIL** | all 5 | **YES** | Option A fallback: `python3 phase6-tui/main.py` | no such file — **0 commits in all of `git log --all` ever touched that path** |
| **FAIL** | 3 | **YES** | wizard 3's quickstart port (8080) is bindable | `EADDRINUSE`, **and its own check `curl localhost:8080` returned HTTP 303 from another service** |
| **FAIL** | 4 | no | `lab-podman.sh --help` exits 0 | rc=1 on all five tools; only the bare `help` verb worked |
| XFAIL | web | no | `phase6b-web` has a START_HERE wizard | absent, as §8.2 records — extension work, not a regression |
| UNKNOWN | all 5 | no | a beginner who does not know the answer got through it | not observable from here — §17.3 stays open |
| PASS ×8 | — | — | 26/26 example TOMLs · 36/36 verbs · 15/15 apt package names · 10/10 quoted names/ports/users · phase 4 Option B end to end | — |

### C.2 What the failures actually were

**Option A had never worked.** All five wizards opened with `cd <the author's absolute
path>` then `python3 -m lab_tui  # or: python3 phase6-tui/main.py`. Three independent
defects in two lines: the wrong directory (the package is under `phase6-tui/`), the wrong
interpreter (`phase6-tui` is a `uv` project — bare `python3` has no `textual`), and a
fallback file that **never existed at any commit**. Meanwhile `phase6-tui/README.md`,
`SHOWCASE.md` and `MANUAL_TESTING.md` had all been printing the correct three lines the
entire time. The wizards did not go stale against the code; they **drifted from a sibling
document that stayed right** — which is why no test caught it. Fixed to the README's own
form, which also removes the hard-coded author path from five files.

**Wizard 3's quickstart was a false success, not a failure.** `--ports 8080:80` cannot
bind on this host (SABnzbd owns 8080), so the container never starts — and then the
document's own verification, `curl http://localhost:8080/`, returns **HTTP 303 from
SABnzbd**. The check passes while nothing the reader launched is running. This is the
**LIED** rung on §0's ladder, sitting in the first document a newcomer opens, and the repo
already knew the fact: `CLAUDE.md` records netboot using 8181 *because* 8080 is occupied,
and the phase-4 quickstart uses 18080 and works. Fixed to **18080** (matching phase 4) in
both places the recipe appears — the wizard and `phase3-docker/README.md` — plus a note
explaining why, since the reasoning is the transferable part.

**`--help` was documented and broken on all five tools.** Each already handled `-h|--help`
in its *per-verb* option loop, but the top-level dispatch had only a bare `help)` arm, so
`lab-chroot.sh --help` printed usage and *then* died with `unknown subcommand: --help`,
rc=1. One-line fix per tool (`help|-h|--help)`), with the unknown-subcommand arm
re-verified so a typo still fails loudly.

### C.3 Two suspicions that died on contact with evidence

Worth recording, because they are the reason the checks were run rather than reasoned:

- `psql -U lab` looked like a lie — the anatomy snippet shows only `POSTGRES_PASSWORD`.
  The real TOML sets `POSTGRES_USER = "lab"`. **The doc was right.**
- `apt-get install yq` looked like the classic wrong-`yq` trap: Debian ships *kislyuk's*,
  and the tools reject it by name (`grep -qi mikefarah`). But that package also installs
  `/usr/bin/tomlq`, which is `toml_to_json()`'s **first** choice. **The instruction works**,
  by a path the document never explains.

### C.4 After the fixes — 12 PASS · 0 FAIL · 1 XFAIL · 1 UNKNOWN (rc=0)

Then the control, because a harness that stops complaining has proved nothing: both
defects were **re-injected** and the run re-checked. All three assertions bit — the drift
check reported two distinct Option A variants, the path check named `phase6-tui/main.py`
with its zero-commit history, and the port check reported `8080` **read out of the
document**, not from a literal in the script. Restored, green again.

That last detail is the harness holding itself to the standard it enforces: its checks
parse the port and the launch block *from the wizard*, so they cannot pass by matching a
string the author happened to write today, and cannot fail when someone improves the doc.

### C.5 Side findings, for §17.4

- **Question 8 (`incus` or `lxc`?)** now has a measurement. `incus` has a `default` zfs
  pool and **zero instances**; LXD has **3 instances across 8 projects, one RUNNING**.
  `lab-lxd.sh` prefers `incus` when both are present — so **the tool defaults to the empty
  daemon while the live workload is on LXD.** This also bears directly on question 9.
- Wizard 5 step 1 tells a beginner to run `sudo incus admin init --auto` on a host where
  incus is **already initialised**. Not executed here (sudo, and mutating). It needs either
  a verified "it refuses harmlessly" line or a skip-if-initialised note — currently the
  document asks a novice to re-initialise a live daemon and says nothing about it.

---

## Appendix D — where the Kubernetes actually is, 2026-08-01

Appendix C's side findings (§C.5) reported that `lab-lxd.sh` prefers Incus, which had a
storage pool and **zero instances**, while LXD carried three instances with one running —
and concluded the tool "reaches for the empty daemon." That framing was about to settle
§17.4 questions 8 and 9 in exactly the wrong direction.

**Instance count is a mechanism reading.** It says nothing about what a daemon's *bridge*
carries. Measuring that inverted the answer.

### D.1 The correction — the VXLAN underlay is `incusbr0`, and the empty daemon is the load-bearing one

Three separate beliefs were wrong, each of them a cached fact nobody had re-derived:

| the belief | the measurement |
|---|---|
| "LXD is hosting the live Kubernetes on this host" | **No Kubernetes in LXD at all.** It is **microk8s v1.32.13** (snap, classic) running **directly on the host**: `kubelite`, `k8s-dqlite`, `kube-controllers`, `calico-node`/`felix`. There is no `kubelet` process because microk8s bundles the control plane into one binary — which is why a `pgrep kubelet` says "no cluster here" |
| "`vxlan.calico` rides over `lxdbr0`" (§7.1, §13, Appendix A) | **It rides over `incusbr0`.** `ip -d link show vxlan.calico` → `vxlan id 4096 local 10.45.178.1 dev incusbr0`, and `incusbr0` is `10.45.178.1/24`. Two independent facts agreeing |
| "LXD carries a third-party workload" | **Every instance and project on both daemons is this repo's own test debris.** `test-profiles-projects.sh` names its project `ppp$$` and `test-vm-lifecycle.sh` names its lab `vlc$$` — `$$` being the shell PID, which is exactly the shape of `ppp292988` / `vlc280967`. The one RUNNING instance is an **Alpine 3.21** container on the `default` profile; its `volatile.eth0.host_name` is `veth7b329ffe`, the single veth enslaved to `lxdbr0` |

So the live picture is the reverse of the plan's:

| bridge | address | enslaved members | what depends on it |
|---|---|---|---|
| **`incusbr0`** | 10.45.178.1/24 | **none** | **Calico's VXLAN tunnel endpoint** — the running cluster |
| `lxdbr0` | 10.216.67.1/24 | `veth7b329ffe` — mklab's leftover Alpine | nothing |

**Why this happened, and why it is a latent hazard beyond this plan.** Calico
auto-detects its node IP, and it picked a *container-engine bridge* — `incusbr0`'s
address — with no container on it and no human intent behind the choice. That binding is
current, not architectural: Calico would re-detect after a restart and might land
somewhere else. But right now, live, deleting or renumbering `incusbr0` breaks pod-to-pod
VXLAN, and **an Incus daemon restart flaps the cluster's tunnel endpoint.**

### D.2 What it settles

- **Question 8 — `lxc` (LXD), pinned explicitly.** Not because LXD is better, but because
  `lxdbr0` is the bridge with nothing riding on it. `lab-lxd.sh`'s `probe_engine` prefers
  Incus whenever its daemon answers, so **the default is the engine we least want to
  disturb** — micro-cloud must set the engine, not probe for it.
- **Question 9 — dissolved.** Its premise ("the engine currently running someone else's
  cluster") was false. `db` on LXD is the safe placement.
- **§7's design rule is untouched and better justified.** The thing not to collide with is
  on the *host* — microk8s + Calico, 140 rules in legacy xtables ([B.2](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it)) —
  not inside a container engine. Interface-scoped rules on our own `br-mc0` remain the
  answer, and **`incusbr0` gains an explicit do-not-reconfigure.**

### D.3 The pattern, for the third time

P2 asserted *"`nft list ruleset` succeeded"* and let it stand for *"these are the rules
the kernel evaluates"* ([B.2](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it)).
Appendix C found five wizards asserting *"the verbs exist"* as *"the walkthrough works."*
This is the same move a third time: **"zero instances" asserted as "nothing depends on
it."** In all three the check was true and the conclusion drawn from it was false, and in
all three the fix was to measure the thing actually being claimed — the rules the kernel
evaluates, the command a reader types, the traffic a bridge carries.

The cheap reading is not a weaker version of the real one. It is a different question that
happens to be easier to ask.

### D.4 Housekeeping, not this plan's

Both leaking tests **do** have `EXIT` traps that delete their project/lab, so the debris is
from runs killed hard (a trap does not fire on `SIGKILL`), not a missing-cleanup bug. Left
behind across both daemons: ~17 empty projects, 3 instances, and one **running** Alpine
container. Harmless, but it is noise in exactly the place slice 3 will be reading, and the
running one holds the only veth on `lxdbr0`. Worth a deliberate sweep before slice 1 —
listed here rather than done, because deleting instances is the operator's call.

---

## Appendix E — slice 1, one microVM by hand, 2026-08-01

**Workdir:** `~/.local/state/lab-create/micro-cloud-s1/` — every config, boot log and both
images are still there, so each number below can be re-derived rather than believed.
**Binary:** Firecracker v1.16.1, fetched and sha-verified by P2. **Nothing here needed root
except reading P2's root-owned Debian tree** (see E.2).

### E.1 What booted

| run | kernel | rootfs | to userspace |
|---|---|---|---|
| control | FC CI `vmlinux-6.1.155` (44 MB ELF) | Alpine 3.21.7 | **0.55 s** |
| **decision B** | `extract-vmlinux` on this host's own bzImage (66 MB ELF) | Alpine 3.21.7 | **0.62 s** |
| REST API | CI kernel, 4× `curl PUT` → `204` | Alpine 3.21.7 | 0.55 s |
| decision F | CI kernel | Debian 13 trixie | **0.55 s** |

Boot time is the **guest's own** `/proc/uptime` at first userspace line, printed by an
inittab marker, so it excludes host-side Firecracker startup and is comparable across runs.

### E.2 Decision B — yes, with one condition worth stating

`extract-vmlinux` output boots Firecracker. The guest reported
`Kernel 6.8.0-136-generic on an x86_64` — **this host's own distro kernel, running inside
the microVM** — for a 0.07 s penalty over the purpose-built CI kernel.

**The condition, checked before booting rather than discovered after:** the host kernel
must have `CONFIG_VIRTIO_MMIO`, `CONFIG_VIRTIO_BLK`, `CONFIG_EXT4_FS` and
`CONFIG_SERIAL_8250_CONSOLE` built **`=y`**, not `=m` — Firecracker boots with no initramfs,
so a modular driver is a driver that will never load. Ubuntu 6.8.0-136 has all four built
in. A distro that ships them modular fails, and the failure would look like a hang.

**Naming, because it is the whole point of this decision:** `vmlinuz` is the *compressed*
bzImage a bootloader loads; `vmlinux` is the *uncompressed ELF* Firecracker requires. FC's
loader answers anything else with `Elf(InvalidElfMagicNumber)`. `extract-vmlinux` converts
one to the other.

**Root was needed once, and not where expected.** `mkfs.ext4 -d` populates an image with no
mount and no loop device, so the Alpine rootfs was built **entirely unprivileged** — and
booted fine despite every file being owned by uid 1000, because the kernel runs init as
root regardless of file ownership. The Debian image needed `sudo` only for the **read**
side: 10 of P2's 4492 files (`/etc/shadow`, `/etc/gshadow`, `/etc/.pwd.lock`, `/root`, …)
are unreadable to a normal user, and `mke2fs` aborts on the first one.

### E.3 The `panic=1` hole, closed by watching it

Same induced panic in both runs — `root=` pointed at a device that does not exist — with
`panic=1` as the only variable:

| `panic=1` | fc rc | wall | outcome |
|---|---|---|---|
| present | 0 | **1.63 s** | rebooted; Firecracker exited on its own |
| absent | 124 | 20.03 s | **hung until killed** |

Both logged `Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)`,
so the fault is identical and the difference is attributable. §5.4's assertion now guards a
behaviour somebody watched.

### E.4 Two findings the plan did not anticipate

**Firecracker appends its own boot args, and the kernel honours the last `root=`.** The
guest actually received:

```
console=ttyS0 reboot=k pci=off root=/dev/vdb rw  pci=off root=/dev/vda rw virtio_mmio.device=4K@0xc0001000:5
                                ^ ours                   ^ Firecracker's, appended, and it wins
```

So a `root=` in `boot_args` is **silently ignored** whenever `is_root_device: true`. Two
consequences, both now recorded in §5.2 and §5.4 hole 3: the derived schema must not offer
`root=` as a knob, and any test inducing a root-mount failure must set
`is_root_device: false` or Firecracker repairs the fault and the test passes for the wrong
reason.

**How it was found is the point.** The first `panic=1` run showed *no difference* — both
variants booted normally. Reporting that would have published "panic=1 changes nothing,"
which is false and would have removed a real guard. Checking whether the fault had actually
landed — reading the cmdline the kernel received — showed it never had. **The negative
control is not a formality; here it was the entire result.**

**A stray `ip=` costs 12.3 seconds and says nothing.** Identical kernel and rootfs, one
added `ip=192.168.99.50::…:eth0:off` with no `network-interfaces` entry:

```
[    0.563361] input: AT Raw Set 2 keyboard …
[   12.851075] clk: Disabling unused clocks          <-- +12.29 s, nothing in between
[   12.852597] VFS: Mounted root (ext4 filesystem)
```

Userspace start moved **0.55 s → 12.84 s**, a 23× regression, spent in the kernel's IP
autoconfiguration waiting for a device that never appears — entirely *before* the root
mount, with **no `IP-Config` line and no error anywhere in dmesg**. It does not fail; it is
just slow, silently. Slice 2 carries the guard: assert `ip=` appears **iff** a
`network-interfaces` entry exists.

### E.5 Decision F — the question was mis-framed

| | tree | ext4 image | to userspace |
|---|---|---|---|
| Alpine 3.21.7 minirootfs | 8.2 MB | 64 MB | 0.55 s |
| Debian 13 trixie (P2's) | 215 MB | 363 MB | 0.55 s |

**26× the size; identical boot time; zero variance across four runs each.** So the choice is
about **footprint — disk and page cache — not latency**, and "spawn twelve" is bounded by
memory and storage rather than by how fast a guest reaches userspace.

**Scope limit, stated rather than implied:** both images run **busybox init**, which is what
makes the comparison fair — same init, different userspace size. A systemd Debian would not
look like this, and this measurement says nothing about that case.

---

## Appendix F — slice 2, the microVM gets an identity, 2026-08-01

**Workdir:** `~/.local/state/lab-create/micro-cloud-s2/`. **One privileged step in the whole
slice** — creating the tap. Everything else, including opening that tap, ran unprivileged.

### F.1 The tap, and why only this needed root

`ip tuntap add dev mc-tap0 mode tap user sqs` + one address + `link set up`. Creating a tap
is `CAP_NET_ADMIN`; **owning** it is not, so Firecracker then opened it via `TUNSETIFF` as
an ordinary user — the outcome P2 measured rather than assumed (Appendix B).

Built to §7.1 because that constraint is live on this host: it **refuses before the
irreversible step** (exits if `mc-tap0` exists, or if anything already routes
`10.71.0.0/24`), creates exactly one interface with one address, sets **no global**, and
*records* `ip_forward=1` instead. Teardown asserts absence and re-checks Calico, per §7.2.

> ⚠️ **And "sets no global" turned out not to mean "is harmless" — see
> [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel).** Creating the
> interface was itself an event the live Calico reacted to. §7.1's central assumption did
> not survive slice 2.

**Unplanned negative control:** the operator ran `up` twice. The second run refused —
`SKIP: mc-tap0 already exists` — instead of clobbering a device it had not created.

### F.2 MMDS V2, by hand, from inside the guest

Host `PUT`s over the API socket, guest reads `169.254.169.254`:

```
MICROVM-UP uptime=0.57s
  addr: 10.71.0.11/24
  V2 token: len=48
  V2 instance-id: [api1]
  V1-style no-token HTTP: 401
  never-PUT key HTTP: 404
MMDS-PROBE-END uptime=0.58s
```

Every §5.7 claim, observed: the token handshake works by hand; `instance-id` read inside the
guest matches what the host `PUT`; **the same GET without a token is refused `401`** — that
is the V1-plus-SSRF lesson made concrete rather than described; and a key nobody `PUT`
returns `404` rather than something invented. The whole probe cost **0.01 s**.

### F.3 The guest could not speak V2 — and the fix was not a better host-side tool

**Measured before building anything:** MMDS V2 requires `PUT /latest/api/token`, and
busybox wget offers only `--post-data`/`--post-file`. **No PUT.** The Alpine minirootfs has
no other client, so the stock guest *cannot* do the V2 handshake at all.

The tempting fix — run the handshake from the host with the host's curl — tests **a
different seam** and proves nothing about the guest (CLAUDE.md: *drive the client the
machine actually has*). So the client went **into the guest**: `podman run alpine → apk add
curl → podman export`, i.e. Phase 4's engine at reuse-ladder rung 1, rootless, producing a
96 MB image with curl 8.14.1. **A microVM guest image needs a real HTTP client if metadata
is part of its contract**, and that belongs in the §5.2 schema discussion at slice 4.

### F.4 The `ip=` guard now has a tripwire, observed twice

Same config, the only difference being whether a `network-interfaces` entry exists:

| | with NIC | without NIC, `ip=` kept |
|---|---|---|
| to userspace | **0.57 s** | **12.84 s** |
| stall | — | `+12.29 s` after `t=0.5647 s` |
| `addr:` | `10.71.0.11/24` | *(empty)* |
| MMDS token | `len=48` | `len=0` |

22.5×, and the stall sits at the identical point slice 1 found it (§5.4 hole 4) — now
reproduced on a **different rootfs**, so it is a property of the kernel's IP
autoconfiguration and not of one image. `ip=` **with** a NIC costs ~0.02 s, so the guard is
correctly stated as *iff a `network-interfaces` entry exists*.

**A guest CAN tell the difference, if it checks the status code:**

| condition | HTTP |
|---|---|
| MMDS reachable, no token | `401` |
| MMDS reachable, key never `PUT` | `404` |
| **MMDS unreachable (no NIC)** | **`000`** (curl could not connect) |

So "metadata is missing" and "metadata is empty" are distinguishable — but only by reading
the code. A consumer that takes the body and ignores the status sees an empty string in all
three cases, which is the stale-record failure in miniature.

### F.5 The instrument killed its own shell

Cleaning up, `pgrep -f 'firecracker-v1.16.1'` was run from a shell whose own command text
contained that literal string. **pgrep matched the searcher**, reported it as a stray, and
killing that PID terminated the session's shell — **exit 144, the second time in this
repo's history**, and in the same session that promoted "kill by PID, never by pattern" to
the global rules.

There were **zero** real Firecracker processes. The recorded `$!` PIDs had reaped correctly
all along; the "strays" were an artifact of the measurement.

The sharper rule, now recorded: **`pgrep -f` is unsafe for a name you are also typing** —
the match set always includes the process doing the search. Use the executable, not a
substring of a command line:

```bash
for p in /proc/[0-9]*; do
  exe="$(readlink "$p/exe" 2>/dev/null)" || continue
  case "$exe" in *firecracker*) echo "${p#/proc/} $exe";; esac
done
```

It is the same lesson as every other appendix here, pointed at the tool instead of the
subject: **the cheap check answers a different question than the one being asked.**

### F.6 "Additive" was not safe — the tap captured a live cluster's tunnel

**This is the most important result in slice 2, and it falsifies §7.1's central assumption.**

`up` recorded, at creation time:

```
  calico: local 10.45.178.1 dev incusbr0
```

`down`, run later, recorded **before** deleting anything:

```
  FAIL: calico moved: 'local 10.71.0.1 dev mc' -> ''
```

`10.71.0.1 dev mc-tap0` **is our tap** (the evidence string is truncated by a regex bug,
below). So between `up` and `down`, **the live cluster's VXLAN tunnel endpoint migrated off
`incusbr0` and onto the interface we had just created** — and deleting that interface took
`vxlan.calico` with it, because removing a VXLAN's underlay device removes the VXLAN.

**Measured impact, on someone else's running Kubernetes:**

| | |
|---|---|
| `kubelite` restarted | 18:31:59 |
| `calico-node` restarted | 18:32:05 |
| pod addresses | `10.1.24.161`/`.179` → `10.1.24.169`/`.173` — **the pods were recreated** |
| recovery | self-healed; `vxlan.calico` rebound to `incusbr0`, stable on resample |

It recovered on its own inside a minute. It was still an outage we caused.

**What this does to §7.1.** The rule was *"be additive, touch no global, revert only what you
set."* We obeyed all three — one interface, one address, `ip_forward` recorded and never
written — and still disrupted the cluster, because **creating an interface is itself an
event a live CNI reacts to.** Calico re-detects its node IP, and a new interface is a
candidate. Additive is not the same as inert.

**Established vs inferred, kept apart.** *Established:* the tunnel was on `mc-tap0` before
teardown, it vanished with the tap, and the control plane restarted. *Not established:* why
Calico selected `mc-tap0` — its default `first-found` autodetection should prefer the
lower-index `incusbr0`, so either the method here is not the default or a re-detection was
triggered by something we have not identified. The mechanism is proven; the selection rule
is not, and slice 3 must not assume it.

**Consequences for slice 3, which is the fabric slice:**

1. **The pre-flight must record Calico's tunnel binding, and teardown must compare it** —
   which this script already did, and it is the only reason we know any of this.
2. **A new interface needs an address Calico will not adopt**, or Calico's
   `IP_AUTODETECTION_METHOD` must be pinned. Pinning is changing someone else's config, so
   it is a decision for the operator, not a default the fabric takes.
3. **§7.2 is vindicated exactly as written.** "Teardown asserts absence afterwards and fails
   loudly otherwise" caught a live-system incident that a cleanup returning 0 would have
   hidden completely. The assertion was worth more than the feature.
4. **Do this work on a host without a live cluster, or accept it will bite again.** The plan
   called coexistence "the upside" (§7.1). It is also the risk, and slice 3 creates a
   *bridge*, which is a larger surface than one tap.

**A real bug in the instrument, too.** `calico_state()` matched `dev [a-z0-9]*`, which
cannot match the `-` in `mc-tap0`, so the evidence printed `dev mc`. The *comparison* was
sound — before ≠ after — so the assertion fired correctly, but the string it showed the
operator was wrong. Fixed to `[a-z0-9.-]*`. A truncated fact in a failure message is how a
correct alarm gets dismissed as a glitch.

### F.7 The selection rule, derived — and §7 already satisfied it

[F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel) left the mechanism
proven and the **selection rule** unknown, and warned slice 3 not to assume it. It is now
derived, from the deployment rather than from documentation — which matters, because the
documented default is what the observation appeared to contradict.

**The setting (read from the DaemonSet):** `IP_AUTODETECTION_METHOD = first-found`,
`IP = autodetect`, image `docker.io/calico/node:v3.28.1`. Calico's own node annotation reads
`projectcalico.org/IPv4Address: 10.45.178.1/24` — `incusbr0`.

**The exclusion list, extracted from that exact binary** (`podman cp` out of
`calico/node:v3.28.1`; `kubectl exec` was blocked by a pre-existing kubelet cert mismatch —
the serving cert is valid for `192.168.1.177` while the node is `192.168.1.106`):

```
^br-.*   ^cali.*   ^cbr.*   ^cni.*   ^docker.*   ^dummy.*   ^flannel.*
^kube-ipvs.*   ^lxcbr.*   ^nodelocaldns.*   ^podman.*   ^tunl.*   ^veth.*   ^virbr.*
```

Two entries are worth pausing on: `^br-.*` and `^podman.*` (a newer addition), and — a trap
for a host like this one — **`^lxcbr.*` does not match `lxdbr0`**, so LXD's bridge is a
candidate while libvirt's `virbr0` is not.

**The host, scored against it:**

| idx | iface | state | address | candidate? |
|---|---|---|---|---|
| 1 | `lo` | — | 127.0.0.1/8 | no (loopback) |
| **2** | `enx00051b8eb138` | **UP** | 192.168.1.106/24 | **yes** |
| 5 | `docker0` | UP | 172.17.0.1/16 | no — `^docker.*` |
| 6, 7 | `virbr0`, `virbr-vbmc` | DOWN | … | no — `^virbr.*` |
| 9 | `lxdbr0` | **DOWN** | 10.216.67.1/24 | no — not UP |
| 17 | `incusbr0` | **UP** | 10.45.178.1/24 | **yes** ← chosen |

**Rule:** lowest-index interface that is **UP**, carries an **IPv4 address**, and matches
**no** exclusion pattern.

> ⚠️ **The ordering half of this rule is FALSIFIED — see
> [G.3](#g3-f7s-ordering-rule-does-not-explain-f6--the-correction) (2026-08-02).** It fails
> to explain F.6, the very incident it was derived from: a freshly created tap has the
> *highest* ifindex, so under "lowest index wins" `mc-tap0` could never have been selected,
> and it was. Together with the `enx00051b8eb138` puzzle below that is **two** unexplained
> observations, one of them the origin. **The exclusion half stands** (it is a direct read of
> the v3.28.1 binary); the ordering half must not be relied on. Both of
> [F.7.1](#f71-the-constraint-slice-3-actually-needs)'s constraints happen to be
> ordering-*independent*, so the fabric design survives intact — but by construction, not by
> this rule being right.

**Confirmed from Calico's own log, 2026-08-01** — readable only after the kubelet cert was
repaired ([F.9](#f9-an-environmental-fault-this-work-surfaced-not-ours-worth-fixing)), which
is why F.7 originally had to infer this:

```
2026-08-01 22:32:05.662 [INFO][9] startup/autodetection_methods.go 103:
  Using autodetected IPv4 address on interface incusbr0: 10.45.178.1/24
```

**22:32:05 is the F.6 incident to the second** — Calico logging its re-detection at the
moment `calico-node` restarted after the tap was deleted, and landing back on `incusbr0`.
So the mechanism is now the vendor's own record rather than our reconstruction: this *is*
`first-found`, in `autodetection_methods.go`, re-running exactly when F.6 said it did.

**What is still not explained, and is left as such:** `enx00051b8eb138` is index 2, UP, and
not excluded, so it should have won and did not — and the log records only the *winner*, not
the rejected candidates. The most likely reading remains that the candidate set here is
**volatile** (a *USB* NIC; both bridges drop to `DOWN` when memberless), so the node IP is
settled by whichever candidates were UP at the last detection. **Still inference** — the
measurement that would close it is a `calico-node` restart with every candidate's state
recorded at that instant, which is not worth causing deliberately on a live cluster.

### F.7.1 The constraint slice 3 actually needs

Two rules, and §7 already satisfies both — by luck, which is precisely why they are being
written down:

1. **The fabric bridge must be named `br-*`.** §7 already calls it **`br-mc0`**, which
   matches `^br-.*` and is therefore *structurally* invisible to autodetection. Docker's own
   `br-a7bf99683c8d` is excluded by the same rule.
2. **Taps must carry no IPv4 address.** An interface without one is never a candidate,
   whatever it is called. Slice 2's `mc-tap0` was a candidate **only because slice 2 has no
   bridge** — the tap had to hold `10.71.0.1` itself. That configuration is the exception,
   and it is the one that bit us.

**No change to the operator's cluster is required.** Pinning `IP_AUTODETECTION_METHOD` was
the fallback in F.6; it is not needed, which is the better outcome — a lab that has to
reconfigure someone else's CNI to be safe is not a lab you can hand to anyone else.

**And the pre-flight/teardown comparison stays**, regardless. The rule above is derived from
one host at one version; the assertion that caught F.6 costs nothing and does not depend on
the rule being right.

> **Both constraints CONFIRMED by slice 3, and for a better reason than luck — see
> [G.3](#g3-f7s-ordering-rule-does-not-explain-f6--the-correction).** F.7's ordering rule
> turned out not to explain F.6 at all, so "§7 already satisfies the rule" was never the
> sound argument. The sound one is that neither constraint *depends* on ordering: an
> excluded name is never a candidate at any position, and an interface with no IPv4 cannot
> supply one. Slice 3 built `br-mc0` with two addressless taps, ran two microVMs on it, and
> Calico's tunnel binding and pod veth count were **unchanged** — where slice 2's single
> addressed tap captured the tunnel. The "by luck" note above is therefore withdrawn: the
> constraints are right, the reasoning underneath them was not.

### F.8 `lxdbr0` is a candidate, and it outranks the one Calico chose

[F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it) listed `^lxcbr.*` among
the exclusions. It is easy to read that as "LXD's bridge is covered". **It is not.**
`^lxcbr.*` matches `lxcbr0` — the *old LXC* bridge — and does **not** match `lxdbr0`.
Tested against the actual patterns rather than eyeballed:

| interface | verdict |
|---|---|
| `lxcbr0` | EXCLUDED by `^lxcbr.*` |
| **`lxdbr0`** | **CANDIDATE — no pattern matches** |
| `incusbr0` | **CANDIDATE — no pattern matches** |
| `virbr0` | EXCLUDED by `^virbr.*` |
| `docker0` | EXCLUDED by `^docker.*` |
| `br-a7bf99683c8d` | EXCLUDED by `^br-.*` |
| `mc-tap0` | **CANDIDATE** — which is why F.6 happened |

**And the index order is the problem:**

| candidate | idx | state |
|---|---|---|
| `enx00051b8eb138` | 2 | UP |
| **`lxdbr0`** | **9** | **DOWN — memberless** |
| `incusbr0` | 17 | UP ← currently chosen |

`lxdbr0` is DOWN only because it has no members. **Start one LXD container and it comes up
at index 9 — ahead of `incusbr0` at 17.** On the next `calico-node` restart the node IP can
migrate to `10.216.67.1`, which is F.6 again with a different interface.

**The trigger is narrower than first written, and that is measured now.** Repairing the
kubelet cert ([F.9](#f9-an-environmental-fault-this-work-surfaced-not-ours-worth-fixing))
restarted `snap.microk8s.daemon-kubelite` on a live cluster, and Calico did **not** move:

| | before | after a `kubelite` restart |
|---|---|---|
| tunnel | `local 10.45.178.1 dev incusbr0` | **unchanged** |
| pod addresses | `10.1.24.169`, `10.1.24.173` | **unchanged — pods not recreated** |

So **a control-plane restart alone does not re-run autodetection.** It is a `calico-node`
restart that does, and in F.6 that restart was itself caused by the interface disappearing.
The hazard therefore needs *both*: a lower-index candidate present **and** something that
restarts `calico-node`. That is a smaller window than "any LXD container is dangerous" — but
it is not a safe one, because deleting the interface is exactly what causes the restart, so
the two conditions arrive together.

**This repo's own phase-5 suite can create that condition.** `lab-lxd.sh`'s `probe_engine`
prefers Incus, so today's runs land on `incusbr0` and change nothing — but the fallback
path (Incus unreachable → LXD) brings `lxdbr0` up. The hazard is one daemon outage away,
and nothing in the suite would report it.

**It also reverses §17.4 question 8.** That answer picked LXD by asking *what rides on each
bridge* — true, and not the deciding factor. The deciding factor is *index order among
candidates*, and by that measure LXD is the riskier choice on this host. **Target `incus`,
pinned** — not because Incus is better, but because `incusbr0` is already the selected
interface, so using it moves nothing.

The general rule, worth more than either engine: **prefer the engine whose bridge the CNI
has already chosen.** It is the only option guaranteed not to relocate the node IP.

### F.9 An environmental fault this work surfaced (not ours, worth fixing)

`kubectl exec` and `kubectl logs` both fail against this cluster:

```
tls: failed to verify certificate: x509: certificate is valid for 192.168.1.177,
172.17.0.1, …, not 192.168.1.106
```

The kubelet's serving cert, read off the wire:

| | |
|---|---|
| subject | `CN=system:node:badass-box` |
| issued | **2025-03-23 02:46:25 UTC** — the cluster's own creation timestamp |
| SANs | `badass-box`, **`192.168.1.177`**, `172.17.0.1`, 3× IPv6 |
| node InternalIP today | **`192.168.1.106`** |

**The host's address changed since the cluster was built and the cert was never
regenerated.** Workloads, networking and Calico are unaffected; everything that reaches the
node through the kubelet's `:10250` is not — `logs`, `exec`, `port-forward`, node proxy
(`ServiceUnavailable`), and `top node` (`Metrics API not available`).

**`refresh-certs` cannot fix it.** `-e` accepts only `ca.crt`, `server.crt` and
`front-proxy-client.crt`; `kubelet.crt` is not on that list. Running
`refresh-certs -e server.crt` reissued the *apiserver's* cert (subject `CN=127.0.0.1`,
`notBefore` moved to 2026-08-01) and left `kubelet.crt` at its 2025 date — the error after
it was byte-identical. **No invocation of `refresh-certs` would ever have worked**, which is
worth stating because it was my first recommendation and it was wrong.

**FIXED 2026-08-01.** The kubelet runs `--cert-dir=$SNAP_DATA/certs` with no
`--tls-cert-file`, so it serves `certs/kubelet.crt`. That was reissued against the cluster
CA **reusing the existing key**, with SANs taken from microk8s's own `csr.conf` — which
already carried `IP.3 = 192.168.1.106` plus every bridge, so nothing was invented:

```
notBefore=Aug 2 00:15:47 2026
SAN: DNS:badass-box, …, IP:192.168.1.106, IP:172.17.0.1, IP:192.168.122.1,
     IP:192.168.123.1, IP:10.216.67.1, IP:10.45.178.1, + 5 IPv6
kubectl logs : WORKS
```

Verified in the order that matters: the artifact chained to the CA and matched the existing
public key *before* installation; the served cert was re-read *off the wire* after the
restart; and finally `kubectl logs` was run, because a certificate that verifies is not the
same claim as a cluster you can debug. Backup at
`certs/certs-backup-kubelet/20260801-201547/`.

**Sixteen months.** The cert dated 2025-03-23 and the address moved at some point after;
`logs`, `exec`, `port-forward` and `top` were dead the whole time and nothing reported it.
The new cert covers every current address including both container bridges, so it survives
the node IP moving *between* them — which, per [F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it),
is a thing that happens here.

**Two reasons it belongs in this appendix rather than a footnote.** It is corroboration for
F.7's volatile-candidate reading — this host's address *has* moved before, on a USB NIC. And
it caused a **wrong conclusion of mine earlier in this session**: `kubectl logs … | grep
autodetect` printed nothing, and I read that as "the log has no autodetection line." The
command had *failed*; the error went to stderr and `grep` only saw an empty stdout. A silent
failure read as a negative result — the same class of error every other appendix here is
about, committed by the person writing them.

## Appendix G — slice 3, the fabric, 2026-08-02

Slice 3 built `fabric.sh` (`up` / `tap` / `retap` / `status` / `down`) and booted two
microVMs that found each other **by name**. The exercise passed. The four things worth
keeping are a correction to [F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it),
a measurement taken *before* the bridge existed, four defects — three of them inside the
safety checks themselves — and one experiment deliberately not run.

### G.1 The exercise, and what it proves

```
SLICE3-BEGIN name=api1 peer=api2 uptime=0.55s
  dhcp rc=0
  addr   : 10.71.0.101/24
  route  : default via 10.71.0.1 dev eth0 metric 202
  resolv : search mc.lab nameserver 10.71.0.1
  gw ping: OK
SLICE3-PING-BY-NAME OK name=api1 peer=api2 after=0s
  64 bytes from 10.71.0.102: seq=0 ttl=127 time=0.066 ms
SLICE3-END name=api1 uptime=2.63s
```

Symmetric on `api2` (`10.71.0.102`, `0.341 ms`). Both guests reached userspace at **0.55 s**
— identical to slices 1 and 2, so DHCP, a bridge and a second VM cost nothing measurable at
boot; the DHCP round trip and both pings fit inside the 2.6 s to `SLICE3-END`.

**And Calico did not move.** A bridge, two taps and two running microVMs left
`local 10.45.178.1 dev incusbr0` and the pod veth count exactly as pre-flight recorded —
which slice 2 could not manage with a *single* tap. That is [F.7.1](#f71-the-constraint-slice-3-actually-needs)'s
two constraints working: the bridge is named `br-mc0`, and it — not the taps — holds
`10.71.0.1`.

**Guest identity comes from the kernel command line** (`mc_name=`, `mc_peer=`), so one
rootfs tree builds both images and neither contains a hardcoded name that could drift out of
date. The runner **derives** the MAC agreement between dnsmasq's `dhcp-hosts` and each
Firecracker config rather than trusting that both were written consistently: a mismatch
means no lease, and no lease means the name never resolves.

### G.2 The FORWARD question, asked before the bridge existed

**Instrument:** [`tools/micro-cloud-fabric-probe.sh`](tools/micro-cloud-fabric-probe.sh) —
read-only, kept for the same reason as the P1/P2 preflights: this is a *derivable* fact
about a host, and a cached answer to it would go stale the moment Docker or LXD reloads.
Re-run it on any host before building the fabric there.

`br_netfilter` is active with `bridge-nf-call-iptables=1`, so `api1 → api2` — two ports on
*one* bridge — is **not** switched silently in L2; it is handed to the FORWARD hook and
filtered. A DROP at a hook beats an ACCEPT in a different table at the same hook, so §7's
"our own additive table with `policy accept`" could not have rescued a packet that Docker's
chain dropped. Measured first, both backends separately:

| | policy | contents |
|---|---|---|
| nft `ip filter FORWARD` | **accept** | jumps to `DOCKER-USER`, `DOCKER-FORWARD`, `LIBVIRT_FWX/FWI/FWO`, + Calico's two `10.1.0.0/16` accepts |
| legacy `FORWARD` | **ACCEPT** | 9 rules incl. `cali-FORWARD`, `KUBE-PROXY-FIREWALL`, `KUBE-FORWARD` (**149 legacy rules total**) |

Both accept, so the own-table design holds and **nothing was inserted into a chain someone
else owns**. The legacy column is the point: `nft list ruleset` cannot see any of it, and
`iptables-save` is nft-backed here so it is not a second opinion either. `up` now records
the whole FORWARD surface into `preflight`, because if a later ping fails this is the first
thing to diff and it is unreadable from a shell that cannot sudo.

One correction taken from LXD's `pstrt.lxdbr0`: the masquerade rule gained an
`ip daddr != 10.71.0.0/24` guard, so intra-fabric traffic is never NAT'd.

### G.3 **F.7's ordering rule does not explain F.6** — the correction

[F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it) derived: *lowest-index
interface that is UP, has an IPv4, and matches no exclusion.* It flagged one thing that rule
failed to explain (`enx00051b8eb138` at index 2 should have won and did not). **It did not
notice that the rule fails to explain [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel)
either** — and F.6 is the incident it was derived from. A freshly created tap has the
*highest* ifindex on the box. Under "lowest index wins" `mc-tap0` could never have been
selected. It was.

So the rule now has **two observations it cannot account for, including its own origin.**
The honest statement: the *exclusion* half is a direct read of the v3.28.1 binary and stands;
the *ordering* half is unsupported and should not be relied on.

**What survives, and why the design is still safe.** Both of F.7.1's constraints are
ordering-**independent**:

| constraint | why ordering cannot affect it |
|---|---|
| bridge named `br-*` | `^br-.*` is in the extracted exclusion list — an excluded interface is never a candidate at *any* position |
| taps carry no IPv4 | an interface with no IPv4 cannot supply one to a method whose entire job is finding an IPv4 |

`br-mc0` is therefore safe on grounds that hold whatever the ordering turns out to be, and
slice 3's clean Calico comparison is consistent with that. **The pre-flight/teardown
comparison remains non-negotiable precisely because the rule is incomplete** — it is the
only instrument that does not depend on understanding the selection at all.

#### G.3.1 The pattern, named — a conclusion that outlived its own argument

The specific error above is worth generalising, because it is the shape of nearly every
correction in these appendices and it is **not** a coding mistake:

> **A rule derived from an incident, never checked back against that incident.**

F.7 did the hard part — pulled the exclusion list out of the running v3.28.1 binary — and
then wrote an ordering rule that it never re-ran against F.6. It even noticed *one*
observation the rule could not explain (`enx00051b8eb138`) and filed it as a curiosity,
rather than reading it as evidence against the rule itself. One anomaly looks like an
exception; two, one of them the origin, is a refutation.

**The conclusion survived and the argument for it did not**, which is the dangerous
combination — a right answer resting on a wrong reason keeps being right only for as long as
conditions happen to hold, and nothing announces the moment they stop. F.7.1's "§7 already
satisfies the rule — by luck, which is precisely why they are being written down" was
closer to correct than the rule it appealed to.

It is the same shape as the rest of this document, restated once so it is findable:

| appendix | the conclusion | the argument that turned out to be wrong |
|---|---|---|
| [B.1](#b1-the-correction--71-consequence-2-was-wrong-about-where-calicos-rules-are) | the nft table must be additive and separately named | *"because Calico owns rules we cannot read"* — it has no `cali-*` chains on the host at all |
| [D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one) | keep the fabric away from the k8s underlay | *"the underlay is `lxdbr0`"* — it is `incusbr0`, and the daemon with zero instances is the load-bearing one |
| [E.5](#e5-decision-f--the-question-was-mis-framed) | Alpine is the right default rootfs | the question as posed (size) was not the deciding property; boot time was identical |
| **G.3** | `br-mc0`, addressless taps | *"because §7 satisfies first-found's ordering"* — the ordering rule does not even explain F.6 |

**The check this implies, and it is cheap:** after deriving any rule from an observation,
**re-run the rule against that observation before writing it down.** If it does not predict
the thing it came from, it is a hypothesis, not a rule — and everything downstream must be
justified on grounds that do not depend on it.

### G.4 Four defects, three of them inside the safety checks

| defect | how it presented | fix |
|---|---|---|
| `lsmod \| grep -q` under `pipefail` | probe printed `br_netfilter: no` on a host where it was `Live` — **deterministic, 5/5** | read the state directly; no pipeline between question and answer |
| `ip -4 -o addr show $tap \| grep -q inet` (in **both** scripts) | would silently **false-PASS** a tap that *had* an address | capture to a variable, then test |
| `OWNER="${SUDO_USER:-sqs}"` | `sudo` from a **root shell** sets `SUDO_USER=root` → `mc-api2` created owned by uid 0 | refuse a root-owned tap by name; `MC_OWNER=` override; new `retap` verb |
| dnsmasq missing `--domain-needed` | see [G.5](#g5-a-dns-gap-the-passing-run-contained) | `--domain-needed --bogus-priv` |

Three of the four are **one root cause**: piping a command whose exit status is the gate.
`grep -q` exits on first match and closes the pipe; the upstream command dies on SIGPIPE;
`pipefail` reports the *pipeline* as failed. In the probe that produced a false negative. In
the tap checks it would have produced a **false pass on the exact F.6 mechanism** — the
check written to catch an addressed tap, walking one past.

The ownership defect is [Appendix B](#appendix-b--p2-assumption-preflight-2026-07-30)'s
lesson repeating: **`ip tuntap add` exiting 0 says nothing about the `TUNSETIFF` the consumer
will issue.** Both scripts now read ownership back from `/sys/class/net/<dev>/owner` instead
of trusting the flag they passed, and `make_tap` **deletes the device** if either property
fails — a half-made tap nobody refuses is worse than none.

Worth naming separately: `fabric.sh` **printed** `owner root` in its success output and
carried on. It told the truth and did not refuse. Printing is not refusing.

### G.5 A DNS gap the passing run contained

`nslookup` returned the right answer *and* an error, inside a run that passed:

```
Name: api2      Address: 10.71.0.102
** server can't find api2: SERVFAIL
```

Queried directly against dnsmasq afterwards, the fault is narrow and exact:

| query | status | answer |
|---|---|---|
| `api1.mc.lab` A | NOERROR | `10.71.0.101` |
| `api1.mc.lab` AAAA | NOERROR | *(correct NODATA — authoritative via `--local=/mc.lab/`)* |
| `api1` A | NOERROR | `10.71.0.101` |
| **`api1` AAAA** | **SERVFAIL** | — |
| `example.com` A | NOERROR | upstream forwarding works |

**Single-label `AAAA` queries leak upstream.** A bare `api1` is outside `mc.lab`, so dnsmasq
forwards to `127.0.0.53`; systemd-resolved refuses a single-label query; SERVFAIL comes
back. busybox `nslookup` asks both types, so it prints the A answer *then* the failure.
Fixed with `--domain-needed` (never forward a name without a dot) and `--bogus-priv`. The
ping passed throughout because it used the A record — **which is the point**: a green
exercise contained a real defect, and only querying the resolver directly surfaced it.

### G.6 A hazard our own cleanup armed

At pre-flight, Calico was bound to `incusbr0` — and `incusbr0` was **DOWN and memberless**,
because that morning's `tools/lab-sweep.sh` had removed the last Incus instances. The
selected interface was no longer a valid candidate, so **the next `calico-node` restart will
relocate the node IP whoever causes it.** Per [F.8](#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose)
a control-plane restart alone will not do it, so this is latent rather than imminent.

This is why `up` records the **whole candidate set**, not just the binding. A teardown
comparing only `bound to incusbr0` would report a migration and implicate the fabric for a
hazard armed hours earlier by an unrelated cleanup. The pre-flight prints the finding at the
time it is cheap:

```
⚠ NOTE, not caused by us: Calico is bound to 'incusbr0', which is currently 'down'.
```

### G.7 The teardown assertion, proven in both directions

The constraint this slice was granted on was that pre-flight records Calico's binding and
teardown compares it. Writing that assertion is not the same as knowing it works: **an
assertion never observed failing may be matching a string that is always present.** So a tap
the recorded state knows nothing about was injected, and `down` was required to fail on it —
then the fault was removed and the *identical* command required to pass.

| | injected `mc-orphan` | fault removed |
|---|---|---|
| `br-mc0` absent | ok | ok |
| **`mc-*` taps** | **FAIL: mc-* taps survived: mc-orphan** | ok: no mc-* taps left |
| nft `mklab-mc` absent | ok | ok |
| no `10.71.0.0/24` route | ok | ok |
| our dnsmasq gone | ok | ok |
| calico tunnel | ok — unchanged | ok — unchanged |
| cali\* veth count | ok — 2, pods not recreated | ok — 2 |
| **verdict** | **FAIL (rc=1), `preflight` KEPT** | **PASS** |

Both directions observed on the real thing, which is what makes the PASS worth anything: the
failure was **the fault**, not a harness that always fails. Two details earn their place —
teardown finds leftovers by **searching** rather than only deleting what it recorded (a
record-only teardown would have reported a clean PASS here), and it **keeps `preflight` on
failure** so the diagnosis survives the run.

Note also what the FAIL column shows about scope: the orphan tripped the assertion while
**every Calico row stayed green**. A teardown that failed loudly without distinguishing ours
from theirs would have been indistinguishable from the F.6 incident it exists to detect.

### G.8 Deleting the bridge under a running microVM — **HALTED (honest)**, and one surprise

`br-mc0` was deleted with `api1` running and demonstrably reachable. The guest's own
timeline, read only past a console byte offset recorded at injection:

```
WATCH t=0s gw=OK   addr=10.71.0.101/24 link=up carrier=1     <- before
── br-mc0 deleted ──
WATCH t=2s gw=DOWN addr=10.71.0.101/24 link=up carrier=1
WATCH t=4s gw=DOWN addr=10.71.0.101/24 link=up carrier=1
```

| | after the fault |
|---|---|
| `br-mc0` | absent |
| **`mc-api1`** | **PRESENT, `master=none`** — orphaned, not destroyed |
| firecracker | **alive** |
| nft `mklab-mc` | PRESENT (correct — only the bridge was deleted) |
| `10.71.0.0/24` route | gone with the bridge |
| **calico tunnel / veths** | **`local 10.45.178.1 dev incusbr0` / 2 → 2 — untouched** |

**RUNG: HALTED, honestly.** The guest lost the gateway and *said so*; the VM stayed up; the
neighbours were undisturbed; and the state is recoverable by ordinary verbs. Not STRANDED
(every object still accepted `down`), and not LIED.

**The surprise, and it is the finding worth keeping: `link=up carrier=1` for the entire
outage.** The guest's interface never noticed. A tap's carrier reflects whether a process
holds the device open — Firecracker did — **not whether the bridge it was enslaved to still
exists**. So a guest watching `operstate`/`carrier` to decide "am I connected?" would have
reported perfect health throughout a total loss of connectivity, and this fault class is
invisible to link-state monitoring. **Only attempted traffic revealed it.** That is
[the mechanism-vs-outcome rule](#g31-the-pattern-named--a-conclusion-that-outlived-its-own-argument)
in one line: `carrier=1` is a mechanism; reaching the gateway is the outcome, and here they
disagreed for the whole run.

Second, smaller: **deleting a bridge does not delete its ports.** `mc-api1` survived,
unenslaved (`master=none`). The residue of this fault is a leaked tap, not a vanished one —
which is exactly what a search-based teardown catches and a record-replay teardown would
also have caught here, since this tap *was* in the record.

**And teardown was run from the broken state, which is the second test in this scenario.**
`fabric.sh down` against a fabric whose bridge was *already gone* found and removed the
orphaned tap, removed the nft table, and passed every assertion including all three Calico
comparisons. **A teardown that only works from the happy path is not a teardown**; this one
was never exercised from a damaged state until now.

### G.9 Not run — recorded as UNKNOWN, not as PASS

- **Give a tap an address on purpose and watch it become a candidate.** This is re-running
  F.6 — an outage on a live cluster — and per [G.3](#g3-f7s-ordering-rule-does-not-explain-f6--the-correction)
  it is no longer even *predictable*: with the ordering unexplained we cannot claim the tap
  would lose. F.7's own closing judgement was that the equivalent measurement is not worth
  causing deliberately. **Deferred to a host without a live cluster.**
- **DHCP pool exhaustion** (`.100–.200` = 101 leases) — needs a shrinkable range for a
  tractable test.
**Break coverage: 3 of 5.** Done: *leave a stale tap*
([G.7](#g7-the-teardown-assertion-proven-in-both-directions)), *delete the bridge under a
running VM* ([G.8](#g8-deleting-the-bridge-under-a-running-microvm--halted-honest-and-one-surprise)),
and *confirm Calico still works* — green in all three, across five independent samples. The
two above are named rather than left implicit: a layer with no scenario is a layer nobody
has watched fall over.


## Appendix H — slice 4, the tool and what it hides, 2026-08-02

`phase7-firecracker/lab-fc.sh` + `preflight`, with §5.2's schema **derived** from what
slices 1–3 actually needed. The slice's stated deliverable is *"name what the tool silently
started doing for you"* — so the tool produces that list itself, rather than an author
remembering to write one.

### H.1 The deliverable, generated rather than recalled

`create --dry-run` prints the config **and** a provenance row for every field, tagged
`YOURS` / `DEFAULT` / `DERIVED` / `APPENDED` / `REFUSED`. For the minimal slice-1 spec
(`--name --kernel --rootfs --memory`), **nine fields came from somewhere other than the
spec**:

| where from | field | why |
|---|---|---|
| DEFAULT | `boot_args: console=ttyS0` | without it the guest boots silently and nothing is debuggable |
| DEFAULT | `boot_args: reboot=k` | a microVM has no ACPI; without this a reboot hangs |
| DEFAULT | `boot_args: panic=1` | **measured** ([E.3](#e3-the-panic1-hole-closed-by-watching-it)): exits in 1.63 s vs hanging until killed at 20 s |
| DEFAULT | `boot_args: pci=off` | there is no PCI bus to probe |
| DEFAULT | `smt = false` | whole cores, no hyperthread siblings |
| DEFAULT | `vcpu_count`, `mem_size_mib` | supplied when you don't say; FC's own default is 128 MiB |
| DERIVED | `is_root_device = true` | and *this* is what makes Firecracker append its `root=` |
| **APPENDED** | **`root=/dev/vda rw`** | **Firecracker adds it after ours; the kernel honours the LAST one** |
| **REFUSED** | `root=<yours>` | not offered as a knob — it would be silently overridden ([E.4](#e4-two-findings-the-plan-did-not-anticipate)) |

The last two are the point. A tool that merely *worked* would show neither.

### H.2 The schema, derived — and the two fields that are refusals

`[[microvm]]`: `name`, `kernel`, `rootfs`, `memory`, `vcpus`, `tap`, `mac`, `ip`, `gateway`,
`netmask`, `mmds`, `append`, `lab`. Keys the parser does not know are **refused by name**,
not ignored — a silently dropped key is a field that appears to work and does nothing.

Two constraints are enforced as refusals rather than offered as options, each traceable to a
measurement:

1. **`root=` in `append` is refused** ([E.4](#e4-two-findings-the-plan-did-not-anticipate)).
2. **`ip=` without a tap is refused** ([F.4](#f4-the-ip-guard-now-has-a-tripwire-observed-twice)) — the
   silent 23× boot regression, with no `IP-Config` line and no error anywhere in dmesg.

`preflight` is **the same function `create` runs first**, not a second implementation.
[`test-preflight-is-one-function.sh`](phase7-firecracker/tests/test-preflight-is-one-function.sh)
asserts that structurally: the gate lines both verbs print must be **byte-identical** (8 rows
today), and `create` must refuse *before* copying a multi-hundred-megabyte rootfs.

### H.3 The diff against slice 1's hand-written config

Normalised to basenames, `lab-fc.sh` vs the config typed by hand in slice 1:

```diff
-    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw",
+    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off",
     "mem_size_mib": 128,
+    "smt": false,
```

**Slice 1's hand-written config carried `root=/dev/vda rw` redundantly.** Firecracker was
appending an identical `root=/dev/vda rw` after it the entire time; it was harmless only
because the two happened to agree. E.4 is what that looks like when they don't. The tool
drops it and *says why* — one line of the provenance table replaces a fact nobody knew.

Boot verified through the tool: `create` → `start` → `Run /sbin/init as init process`,
kernel done at **0.564930 s** — the same 0.55 s as slices 1–3. One command, same boot.

### H.4 Two defects, both in the safety machinery

**The `/sbin/init` gate lied on first contact.** It grepped `debugfs` output for `Inode:`
and read its absence as "the file is missing". Run against a **dirty** image — one a guest
had booted `rw` and been SIGKILLed on, so the bitmap checksums were stale — `debugfs` never
opened the filesystem at all, and the tool reported *"rootfs has no /sbin/init"* about an
image that had booted minutes earlier. **"I could not look" is not "I looked and it is
missing."** The gate now has three outcomes, and
[`test-unknown-is-not-pass.sh`](phase7-firecracker/tests/test-unknown-is-not-pass.sh) asserts
all three, including that it does not invent a specific defect. This is the *mirror* of the
usual error — UNKNOWN rendered as FAIL rather than as PASS — and still a liar.

**The EXIT-trap safety net was present and inert.** Every test opened with
`trap 'rm -rf "$tmp"' EXIT`, and bash keeps **one** EXIT trap per shell, so each test
silently replaced `lib.sh`'s "print FAIL if the test exits without a verdict" net. Proven by
fault injection: an injected generator defect produced a Python traceback, `rc=1`, and **no
`FAIL:` line**. Cleanup now registers into `TMPDIRS` and the shared trap does both jobs;
re-injecting the same defect now prints the traceback *and* `FAIL: test exited early`.

**All four tests were fault-injected and all four bit**, each naming its own defect — the
suite's own negative control, since an all-PASS run is otherwise indistinguishable from one
that checks nothing. Headless (no `firecracker`, no `debugfs`) the suite is 2 PASS / 2 SKIP
/ 0 FAIL, which is the CI path; `phase7-firecracker` is now in both CI lists.

### H.5 The §8.3 tripwire held — and §5.1 needs a correction

No verb was added because "the other engines will need this too." Provenance did **not**
become an `explain` verb: it belongs to the thing that generates the config, so it is a flag
on `create`.

**§5.1 says `destroy` = "stop + delete tap + delete state dir". That is now wrong.** Slice 3
gave tap lifecycle to the fabric (`fabric.sh tap` / `retap`), and **two owners for one
resource is this plan's most-repeated bug**: whichever deletes it first leaves the other's
record describing something gone. So in `lab-fc.sh` the tap is an **input** — validated
(exists, owned by the caller's uid, carries no IPv4) and never manufactured or destroyed.
`destroy` says so explicitly rather than silently not doing it.

The tap gates are slice 3's findings ported into a tool: ownership is read back from
`/sys/class/net/<dev>/owner`, because `ip tuntap add` exiting 0 says nothing about the
`TUNSETIFF` the VMM will issue.

### H.7 A second pass over slice 4 — three defects the green suite did not see

Slice 4 is the foundation slices 5–10 stack on, so it was reviewed again after it went
green. **Four defects, three of them real, and the suite was passing throughout.**

| defect | what it did | severity |
|---|---|---|
| `config.json` named the **source** rootfs while the manifest named the per-instance **copy** | the 128 MB copy was dead weight, the manifest described a file the VM never touched, and two instances from one source image would both boot it read-write | **critical** |
| an unknown schema key printed a refusal and **carried on** | `awk`'s `exit 3` was inside a process substitution feeding `mapfile`, which **discards the producer's status** | real |
| `stop` reported `PASS` having only *sent* a signal | `kill(2)` returning 0 means the signal was delivered, not that the VM stopped | mechanism-not-outcome |
| `--help` printed a drifting line range | `sed -n '3,25p'` no longer aligned with the header | cosmetic |

**The first is the plan's own headline bug class, in the plan's own tool** — a record that
misdescribes its subject, readable and false, with the failure surfacing far downstream as
mysterious cross-instance corruption. `create` now copies **first**, re-points the record at
the copy, generates from that, and then **asserts** that the path in `config.json` is the
copy before writing the manifest. The manifest also records `rootfs_source` and
`rootfs_source_sha256`, so a re-staged source image is detectable instead of silent.

**And the second was passed by a test written to catch it.**
`test-derived-guards.sh` asserted that a refusal was *printed*, not that the run was
*refused* — a mechanism assertion, in the guard against exactly that mistake. It now asserts
the outcome: non-zero exit **and** no gate lines after the refusal. Re-injecting the process
substitution makes it fail with `REGRESSION: gates ran AFTER the unknown-key refusal`.

**Two flaws in the harness itself**, both found while checking that the new guards bite:

- The rootfs guard first failed with *"create refused a spec built from the caller's own good
  artifacts"* while `lab-fc.sh` was shouting the precise path mismatch. A failure message
  that misattributes its cause is how a correct alarm gets dismissed as a glitch — the same
  defect [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel) found in
  its own instrument. It now surfaces the tool's own `REGRESSION:` line.
- The EXIT net fired *in addition to* a verdict the test had already printed, training a
  reader to skip it. It is now gated on `_VERDICT`, and **both directions were re-checked**:
  a test that exits silently still gets the net; a test that says `FAIL` does not get a
  second line.

Suite is now **5 PASS** locally, **2 PASS / 3 SKIP** headless, and every guard has been
observed failing on the real defect it names.

### H.6 Not done in this slice

`console`, `ssh`, `snapshot`, `restore`, `preserve`, `mmds` and the jailer tier (§5.6) are
**not implemented** — they belong to slices 7–8 and to decision E, and adding them now would
be the §8.3 drift wearing a schedule as a disguise. `lab-fc.sh --help` lists only what
exists.
