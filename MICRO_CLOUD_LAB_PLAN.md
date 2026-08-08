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

> ✅ **BUILT 2026-08-05** ([§18.6](#186-order-of-work) item 3), with
> [`tests/test-export-rootfs.sh`](phase1-chroot/tests/test-export-rootfs.sh) — one positive
> case and **five negative controls**, every one of them observed failing on the defect it
> names. Four things below changed on contact with the implementation; see
> [§6.4](#64-what-the-implementation-changed--and-the-ext4-vs-xfs-question-measured).

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


### 6.4 What the implementation changed — and the ext4-vs-XFS question, measured

**1. The size rule was wrong, and slice 1's own numbers said so.** §6.2 specified
`du × 1.4`. Slice 1 built an 8.2 MB Alpine tree into a **64 MB** image (×7.8) and a 215 MB
Debian tree into a **363 MB** one (×1.69) — because ext4's overhead is not a flat
percentage. Inode tables are sized from the *byte* count while a tree's inode *need* comes
from its file count, and the journal plus superblock backups are near-fixed. Implemented as
**`du × 1.5 + 32 MiB`, floored at 64 MiB**, with mkfs's own "no space" failure translated
into an actionable message and the partial image removed.

**2. Two options became refusals, in the [H.2](#h2-the-schema-derived--and-the-two-fields-that-are-refusals) pattern.**
`--fstype squashfs|xfs` is refused **by name with its reason** rather than silently
ignored. For XFS the reason is a capability gap, not a preference — all three measured on
this host (xfsprogs 6.6.0, e2fsprogs 1.47.0):

| | ext4 | XFS |
|---|---|---|
| **populate from a directory, no mount** | `mke2fs -d root-directory` | **none.** `mkfs.xfs -d` is *data-subvolume* options (agcount, agsize, su/sw); its only populate path is `-p protofile`, an IRIX-era manifest, not a tree |
| **minimum size** | built 64M / 128M / 256M / 300M | **refused below 300M** — slice 1's Alpine rootfs is a **64 MB** image |
| **offline inspection** | `debugfs -R`, which this repo's verify chain, `lab-fc.sh`'s init gate and the tests all speak | `xfs_db`, a different tool and language |
| **journalling** | metadata (`data=ordered`); *can* do `data=journal` | metadata only, always |

So XFS would require a loop mount and `CAP_SYS_ADMIN` — precisely what §6.2 exists to avoid
— and could not hold the smallest image the plan actually uses. Journalling is a wash: both
journal metadata only by default, and a microVM rootfs that gets SIGKILLed is left dirty
either way (that dirt is what made `debugfs` refuse an image
[H.4](#h4-two-defects-both-in-the-safety-machinery) then wrongly reported as empty). XFS's
real strengths — allocation-group parallelism, large-file streaming — appear at sizes and
concurrency a 64–512 MB single-writer boot volume never reaches.

> **Where XFS *would* pay, and it is not this verb.** Per-instance rootfs copies
> ([H.7](#h7-a-second-pass-over-slice-4--three-defects-the-green-suite-did-not-see)) are a
> full 128 MB `cp` each; on a **host** filesystem with reflink they would be O(1) and free.
> ext4 has no `FICLONE`. Measured on this host: `/` is ext4 on LVM and
> `cp --reflink=always` returns `Operation not supported`. That makes it a **slice 8**
> question (five warm clones), about the *host* filesystem, not the guest image format.

**3. A readability gate was added, before the allocation.** `mke2fs -d` is honest about
unreadable sources — measured: it exits 1 naming the file — but only *after* allocating and
partly populating. A chroot built by `sudo lab-chroot create` has root-only files, so the
verb now refuses up front, names them, and prints the `sudo` form. *A gate after the `dd`
is a post-mortem.*

**4. Verification has three outcomes, not two.** `debugfs` absent or unable to open the
image reports **UNKNOWN**, never a pass — the mirror of H.4's defect, where "I could not
look" was rendered as "I looked and it is missing."

### 6.5 Four silent exits in one function, and what the negative controls actually proved

The verb was written, passed its test, and then failed against the **real** 202 MB Debian
tree with `rc=1` and **not one byte of output** — the failure mode CLAUDE.md exists to
forbid. Four candidate causes were found by reading; **re-injecting each one** sorted them
into what they really were:

| suspect | re-injected → | verdict |
|---|---|---|
| `mke2fs -h \| grep -q -- '-d root-directory'` | reported "no `-d` support" on a tool that has it | **real** — `grep -q` closes the pipe, `mke2fs` dies on SIGPIPE, `pipefail` reports the *pipeline* as failed. **Third instance of this exact inversion in this repo** |
| `mke2fs -h` has no `-h` (exits 1) | silent death *after* the capability was correctly detected | **real** |
| `find … \| head -20` unguarded | **silent, 0 bytes of output** | **real** — `find` exits non-zero on an unreadable *directory* |
| `(( bytes < 64M )) && bytes=…` | **test still passed** | **NOT a bug here.** Errexit exempts the left side of an `&&` list in a non-final position. It bites when the arithmetic stands alone, or is a function's last statement |

The fourth is the one worth keeping. It was asserted from *reading* the code, written into a
comment as fact, and was false — the same mechanism-not-outcome error this plan is organised
around, committed in a comment justifying a fix. The comment now states the measured rule.

**And the test was blind to the bug that mattered.** Its synthetic tree was 3 MB, so the
64 MiB floor always applied and the size branch under suspicion never ran; its unreadable
fixture was a `chmod 000` *file*, which does not make `find` exit non-zero. Both were
corrected — a 24 MB tree and an unreadable *directory* — and only then did the suite bite on
the guard that was genuinely load-bearing. *A negative control that cannot construct the
condition is not a negative control.*

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
| ~~`incusbr0`~~ | ~~10.45.178.0/24~~ | ~~Incus — **and Calico's VXLAN tunnel endpoint**~~ | ⚠️ **GONE 2026-08-04 — [I.1](#i1-the-measurement)**. Interface absent, daemon inactive since a reboot; **Calico moved to `enx00051b8eb138`** |
| `vxlan.calico` | 10.1.24.128/32 (+ blackhole /26) | **live Calico CNI** — microk8s v1.32.13, on the **host** | leave, load-bearing |

> ⚠️ **This table is a dated measurement (2026-07-29) and one row has since expired.** As of
> **2026-08-04** the Calico tunnel endpoint is `local 192.168.1.106 dev enx00051b8eb138` —
> **the physical uplink, the same interface this fabric masquerades out of** — and both
> `incusbr0` and `lxdbr0` are absent. See
> [Appendix I](#appendix-i--calico-moved-no-lab-caused-it-and-the-trigger-is-a-60-second-poll-2026-08-04).
> **Re-derive the binding at pre-flight; never read it from this table.**

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
| `db` | **LXD (`lxc`), pinned** | stateful "pet" with its own init | the system-container case. **Still pinned, but the reason has expired** — the original was that `incusbr0` carried Calico's VXLAN endpoint ([D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one)); as of 2026-08-04 **both daemons are inactive and both bridges are gone** ([I.2](#i2-what-this-invalidates)), so starting *either* manufactures a fresh autodetection candidate under a live cluster. Pinning still matters (`lab-lxd.sh` probes); **which** engine must be re-derived when this instance is actually built |
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
| **A live Kubernetes + Calico shares this host** | **microk8s v1.32.13 on the host** (`kubelite`, `k8s-dqlite`, `calico-node`/`felix`); `vxlan.calico` up over ~~`incusbr0`~~ ~~`lxdbr0`~~ → **`enx00051b8eb138`, the physical uplink** since 2026-08-04 ([I.1](#i1-the-measurement)); `ip_forward` already `1`; 140 Calico rules in **legacy xtables** ([B.2](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it)) | §7.1/§7.2: additive nft table scoped by `iifname`, revert only what we set, teardown asserts absence of *our* objects only. **Never name the CNI's interface in a doc or a constant — re-derive it at pre-flight** ([I.6](#i6-the-methodological-point-for-the-third-time-in-this-plan)). **New top risk in v3, and worse since [I.3](#i3-the-hazard-did-not-go-away--it-got-worse)** |
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
| **3** ⚠️ | **Two microVMs that reach each other** — **EXERCISED 2026-08-02, [Appendix G](#appendix-g--slice-3-the-fabric-2026-08-02), but the deliverable was never landed — see [§18.1](#181-the-precursor-nobody-recorded--fabricsh-is-not-in-the-repo)**; build + exercise + teardown green, break pass **3 of 5** (the two deferred are named in [G.9](#g9-not-run--recorded-as-unknown-not-as-pass), and they do **not** share a blocker: the tap-address one wants a live Calico that may be broken — a **nested QEMU guest with a disposable microk8s is one**, per G.9's 2026-08-03 addendum — while DHCP exhaustion needs only a shrinkable range and could run here today. See [M.7](#m7-a-correction-this-appendix-inherited-the-g9-blocker-was-lifted-three-days-before-it-was-restated)) | `fabric.sh up/down/retap/status` — additive nft scoped by `iifname`, recorded `ip_forward`, dnsmasq as DHCP **and** DNS. **Bridge MUST be named `br-mc0`** (Calico v3.28.1 excludes `^br-.*`) and **taps MUST carry no IPv4 address** — [F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it) | `api1` pings `api2` **by name**; `down` asserts absence of *our* objects only; **pre-flight records Calico's tunnel binding and teardown compares it** — the assertion that caught [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel) | delete the bridge under a running VM; exhaust the DHCP pool; leave a stale tap; **confirm Calico still works** — and give a tap an address on purpose to watch it become an autodetection candidate |
| **4** ✅ | **The tool, and what it hides** — **DONE 2026-08-02, [Appendix H](#appendix-h--slice-4-the-tool-and-what-it-hides-2026-08-02)** | `lab-fc.sh` + `preflight`; **derive** §5.2's schema from slices 1–3 | one command, same boot; `--dry-run` diffed against slice 1's hand-written `config.json` | the preflight tripwire; **name what the tool silently started doing for you** — that list is the deliverable. Watch for the §8.3 verb tripwire |
| **5a** ✅ | **A second engine on one fabric — the controlled comparison** ([§18](#18-slice-5--the-brief)). **DONE 2026-08-05** — (a) the boot comparison, [Appendix J](#appendix-j--slice-5a-a-the-second-engine-the-number-nobody-had-and-the-number-everybody-had-was-wrong-2026-08-05); (b) two engines on one fabric, [Appendix K](#appendix-k--slice-5a-b-two-engines-on-one-fabric-and-decision-e-answered-from-what-the-lifecycles-actually-needed-2026-08-05) | QEMU `-M microvm` and Firecracker on the same `vmlinux` + the same `.ext4`, taps from **one** fabric verb, both VMMs at uid 1000 | 0.055 s vs 0.071 s once the i8042 probe is out of the way ([J.3](#j3-the-headline-that-was-false)); distinct DHCP leases from one dnsmasq; **each engine's guest resolved the other's BY NAME**; Calico unmoved throughout | **§18.4's seam table filled in — §8.3 shape (b)** ([K.2](#k2-decision-e-answered--184s-table-filled-in-from-what-the-two-lifecycles-needed)), and the `stop` seam turns out to be what costs 90% of the boot ([K.3](#k3-the-seams-are-not-independent-of-the-performance-story)) | QEMU **`-M microvm`** (Phase 2 already has virtio-mmio + qboot) consuming **the same `vmlinux` and the same `.ext4`** Firecracker boots, on a `fabric.sh`-made tap. ~~"Phase 2 already does bridge mode"~~ — **`--network-mode tap`, not `bridge`**: [§18.3](#183-two-corrections-to-14s-one-line-brief) | two engines, one L2, one `--lab` view — **and a boot-time number where the only variable is the VMM** | kill one engine's process and see what the other reports; kill the **fabric** under both. **Answer decision E** |
| **5b** ✅ | **…and the fidelity case** — **DONE 2026-08-06, [Appendix M](#appendix-m--slice-5b-the-fidelity-case-joins-the-fabric-2026-08-06)** | the §9.2 `edge`: a stock Debian 12 cloud image on `-M q35`, from [`edge.toml`](examples/micro-cloud/edge.toml), on a `fabric.sh` tap **beside a Firecracker microVM** | cloud-init ran; `edge` took the lease the fabric **RESERVED** (`10.71.0.102`, not merely an address from the pool) and reached `api1` **by name** | seven defects on the way, **all in the harness or the phase tools, none in the lab** — including `inspect` exiting 1 silently on any running VM, and a `: ` in a `runcmd` cancelling every `runcmd` |
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
2. **Decision E — the seam** (§8.3). ~~defer to slice 5~~ → **being answered in slice 5a**;
   the evidence table is [§18.4](#184-what-slice-5-must-answer) and the slice-4 tripwire
   stays armed.
3. **Decision G — MAAS registry reuse** (§8.4). Recommendation: invoke for deploy drivers,
   separate registry initially, revisit at slice 6.
4. ~~**Decision B — `extract-vmlinux`**~~ — **ANSWERED 2026-08-01: yes.** The host's own
   kernel, extracted, booted FC in 0.62 s against the CI kernel's 0.55 s
   ([Appendix E](#appendix-e--slice-1-one-microvm-by-hand-2026-08-01)). Listed as open here
   through v3 by oversight.
5. **Should slice 0's break-it pass — a real beginner walking a `START_HERE` doc — happen
   before slice 1?** It is the only test of the novice path that cannot be faked, and it
   costs a friend an afternoon. **Still owed** ([§17.3](examples/micro-cloud/DEFERRED.md#173-the-one-test-i-cannot-run-from-this-side--half-done-2026-08-01)).
6. **NEW, and it is not a design question:** *what else in this document describes something
   that does not exist?* [§18.1](#181-the-precursor-nobody-recorded--fabricsh-is-not-in-the-repo)
   and [§18.2](#182-two-more-components-that-are-written-up-and-do-not-exist) found three by
   looking — a merged slice deliverable, `export-rootfs`, and `CLONES.md`. Nothing in CI can
   see this class of gap, so it needs a periodic **derive-don't-cache pass** over §§5–9
   against `git ls-files`.

---

## 17. Deferred work — moved

> **Moved 2026-08-03 to
> [`examples/micro-cloud/DEFERRED.md`](examples/micro-cloud/DEFERRED.md)** —
> exactly as this section's original note said it would once that directory
> existed. It now does (with a [`README.md`](examples/micro-cloud/README.md)
> staging the lab, so `paths.py --check`'s coverage gate is satisfied by an
> exempt-with-reason entry rather than tripped). The §17.1–§17.5 numbering is
> preserved there, so the appendices' citations of §17.3 and §17.4 resolve
> unchanged — and it gains a §17.0: committing slice 3's `fabric.sh`, which
> still exists only in a host workdir.
>
> **And the live pick-up point is now [§18](#18-slice-5--the-brief)** (added 2026-08-04),
> which carries slice 5's brief plus the precursor work it depends on. `DEFERRED.md` remains
> the work queue; §18 is the brief for the item at the front of it.

---

## 18. Slice 5 — the brief

> Written 2026-08-04, planning the next slice. Two things had to be established first: what
> the host is doing now ([Appendix I](#appendix-i--calico-moved-no-lab-caused-it-and-the-trigger-is-a-60-second-poll-2026-08-04))
> and what the repo actually contains (§18.1). Both turned out to disagree with the plan.

### 18.1 The precursor nobody recorded — `fabric.sh` is not in the repo

§14 row 3 said ✅. [Appendix G](#appendix-g--slice-3-the-fabric-2026-08-02) describes the
tool's behaviour across nine subsections. §9.1's layout lists it. And:

```console
$ git ls-files | grep micro-cloud
tools/micro-cloud-preflight.sh
tools/micro-cloud-preflight-p2.sh
tools/micro-cloud-fabric-probe.sh
```

**PR #129 landed 307 lines of appendix and the read-only probe. It did not land
`fabric.sh`.** The tool — `up` / `tap` / `retap` / `status` / `down`, the addressless-tap
assertions, the Calico pre-flight record, the `ip_forward` change-log — was written to a
session scratchpad under `/tmp` and was never added to git. That directory is gone.

Slice 5 is *"a second engine on one fabric."* **There is no fabric.**

This is the plan's own headline bug class — *a record that outlives the thing it describes* —
committed by this plan against itself, and it is worth being precise about how it hid:

- **Nothing errored.** The appendix is readable, accurate about what happened, and false only
  about what survived.
- **Both catalog gates were green**, because neither has any opinion about a tool that isn't
  there. `link_check.py` validates links between files that exist; `paths.py --check` gates
  lab units under `examples/`. A deliverable that exists in prose and nowhere else is
  invisible to both.
- **The verification that would have caught it is the one this plan keeps recommending**:
  assert the outcome (*the tool is in the tree and runs*), not the mechanism (*the PR is
  merged and CI is green*).

**Recovery — done 2026-08-04, and the first count of it was wrong.** The transcript holds a
17,564-byte `Write` and **eleven** `Edit`s, not the three first reported here: the initial
count came from a `grep` for `make_tap|mklab-mc`, which only matched the edits whose *text*
happened to contain those strings. **A search that finds some of a thing is not a census of
it** — and the error was in the safe direction only by luck; recovering 3 of 12 operations
would have produced a file that was syntactically valid and quietly missing the ownership
assertions. Replayed with the two checks that make it a recovery rather than a guess:

- **every operation's `tool_result` was checked for `is_error`** — a `tool_use` block in a
  transcript records that a call was *attempted*, not that it *succeeded*, and replaying a
  failed edit corrupts the file;
- **every `old_string` was asserted to occur exactly once** before replacing, so a replay
  cannot silently apply to the wrong site.

12 operations, 0 failed, all unique → **22,467 bytes / 420 lines** (28% larger than the
initial `Write`). Installed at `examples/micro-cloud/fabric.sh`; `bash -n` and the CI
shellcheck invocation both clean.

**It re-derives Appendix I on its own.** The unprivileged `status` verb, run against today's
host, reports `local 192.168.1.106 dev enx00051b8eb138` and a candidate set of exactly one
(index 2) — computed live from Calico's own exclusion list by code written on 2026-08-02
that knew nothing of the reboot. A second, independent derivation of I.1 from a different
instrument.

**Two cached facts were corrected in its header before install** — it asserted in the present
tense that Calico *is* bound to `incusbr0`, and it repeated F.8's restart-only trigger. Both
are now dated observations with [I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)'s
correction attached, and the operator-facing hazard note printed by `up` says "every 60s"
rather than "the next restart". *The tool that exists to defeat stale records had two in its
own header.*

The guest artifacts all survived under `~/.local/state/lab-create/micro-cloud-s{1,2,3}/`
(`firecracker`, `vmlinux`, `api1.ext4`, `api2.ext4`); only the scripts were lost.

**The privileged round trip — RUN 2026-08-04 23:39, and it PASSES.** `up` → `tap api1` →
`tap api2` → `status` → `down`, author-run because it needs `CAP_NET_ADMIN`. Teardown's
comparison matched against the **new** binding, which it had recorded at pre-flight by
deriving it. Full result and its limits in
[I.7](#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass); the run also
turned up [I.8](#i8-a-bridge-with-members-can-be-down--and-it-sharpens-f7s-volatility-guess).
**The UNKNOWN this section carried is now closed for the fabric — and explicitly not for the
slice-3 exercise**, which booted no microVM here and stays unre-run.

**Independently found on 2026-08-03, by a session that could not fix it.** PR #131 staged
[`examples/micro-cloud/`](examples/micro-cloud/) and made this
[`DEFERRED.md`](examples/micro-cloud/DEFERRED.md) §17.0's top item, with the right
instruction attached — *do not reimplement it from Appendix G's description; a rewrite would
leave the record describing an artifact it never measured.* **Its one wrong detail is the
instructive part:** it said the file was in `~/.local/state/lab-create/micro-cloud-s3/`. That
workdir holds the images, boot logs and configs — **and no `.sh` files at all**. So the
operator action as written could never have succeeded. *A recovery plan that names a location
nobody re-checked is itself a stale record*, and it is the third one this document has found
in a week.

**Home:** `examples/micro-cloud/fabric.sh` — the target layout's own slot, reachable now
that #131 staged the directory with a README and a `coverage_exempt` entry, so
`paths.py --check` stays green. (An earlier draft of this section proposed
`tools/micro-cloud-fabric.sh` on the grounds that `examples/` would trip the coverage gate —
true on 2026-08-02, false since 2026-08-03. Recorded because it is the same class of error
the section is about, made while writing the section about it.)

**Free consequence:** committing it closes
[§17.4 q7](examples/micro-cloud/DEFERRED.md#174-open-questions) — *"how does the fabric record
what it changed?"* — which slice 3 answered in code (`/run/mklab-mc/preflight`) while the
document still called it unspecified, **because the code was not in the repository.** The
open question and the missing file were the same fact wearing two hats.

### 18.2 Two more components that are written up and do not exist

| component | plan says | reality |
|---|---|---|
| **`lab-chroot.sh export-rootfs`** (§6, "new component B") | full CLI, internals, P1-verified `mkfs.ext4 -d` technique | ~~the verb does not exist~~ → **BUILT 2026-08-05**, and four of §6's specifics changed on contact ([§6.4](#64-what-the-implementation-changed--and-the-ext4-vs-xfs-question-measured)) |
| **`CLONES.md` + `test-clones-ledgered.sh`** (§4.1) | the enforcement that stops decision 16 decaying "into a comment nobody checks" | **neither exists.** The ladder is currently a comment nobody checks |

The first had a scheduling consequence nobody noticed: **decision 18's precondition was
unmet.** The two install-gap labs (§11.1) were scheduled *after slice 4* specifically so each
would *consume* `export-rootfs` rather than invent its own image plumbing. There was nothing
to consume, so starting them then would have produced exactly the outcome decision 18 exists
to prevent.

> ✅ **Met 2026-08-05.** `export-rootfs` is built and tested
> ([§6.4](#64-what-the-implementation-changed--and-the-ext4-vs-xfs-question-measured)), so
> the two install-gap labs now have the image plumbing decision 18 wanted them to consume.
> They remain **out of scope for slice 5** — they are separate labs, not a step in it.

### 18.3 Two corrections to §14's one-line brief

§14 row 5 read: *"add the QEMU `edge` (Phase 2 already does bridge mode)"*.

**1. Bridge mode is the wrong door.** `lab-vm.sh --network-mode bridge` emits
`-netdev bridge,br=…`, which runs the setuid `qemu-bridge-helper` and requires
`/etc/qemu/bridge.conf` to grant the bridge by name. Measured on this host: the helper exists
at `/usr/lib/qemu/qemu-bridge-helper`, **`/etc/qemu/bridge.conf` does not** — so bridge mode
needs a host configuration change, applied globally, to run a lab.

`--network-mode tap` takes a **pre-created tap by name** (`-netdev tap,ifname=…,script=no`).
That is:

- exactly what `fabric.sh tap` produces,
- exactly how Firecracker consumes one,
- exactly the rule [H.5](#h5-the-83-tripwire-held--and-51-needs-a-correction) established —
  *the tap is an input, validated but never manufactured or destroyed* — arrived at because
  two owners for one resource is this plan's most-repeated bug,
- and needs **no root** in either engine.

**One fabric verb serves both engines and neither is privileged.** That is not a convenience;
it is the first real evidence for decision E, because it says the engines' *network* seam
genuinely is common while their *lifecycle* seam is not.

**2. Phase 2 already has `-M microvm`** — virtio-mmio, qboot, transport-aware
`virtio-*-device` selection (`lab-vm.sh` `arch_map … microvm-supported`), an Alpine microvm
builder, and `test-microvm-argv.sh`. So slice 5 does not have to compare a microVM against a
full cloud VM. It can hold everything else fixed:

| | Firecracker | QEMU `-M microvm` |
|---|---|---|
| kernel | `vmlinux` (slice 3's) | **the same file** |
| rootfs | `api1.ext4` | **the same bytes** |
| network | tap on `br-mc0`, addressless, owner-checked | **identical** |
| **variable** | — | **the VMM, and nothing else** |

Slices 1–4 established 0.55 s to userspace, with zero variance across four runs and across a
26× rootfs size difference. **Nobody has the other number.** The density argument the whole
plan rests on is currently one measurement wide.

> **Answered 2026-08-05 — and the number above turned out to be mostly an artefact.**
> [Appendix J](#appendix-j--slice-5a-a-the-second-engine-the-number-nobody-had-and-the-number-everybody-had-was-wrong-2026-08-05): **0.512 s of Firecracker's 0.567 s is a kernel i8042 probe**, waiting out
> a PS/2 controller QEMU's `microvm` does not emulate at all. At their defaults QEMU looks
> **8× faster**; on equal footing **Firecracker is 1.29× faster in the guest and 1.49×
> faster wall-clock**. Both readings come from the same two engines — which is exactly why
> one engine could never have produced either. The figure to quote now is **0.055 s**.

**Known cost, and it is a §4.1 ladder decision, not a footnote:** `build_qemu_argv` hardcodes
`format=qcow2` on the data disk, so booting the same **raw** ext4 needs a `disk_format` field.
That is **rung 3 — extend upstream** (both labs benefit; `lab-vm.sh` gains the ability to boot
a raw image, which `export-rootfs` will produce for everyone). It is not a wrap and not a
clone, so it does not trip §4.1 — but it is the first time the ladder has been walked
deliberately in this plan, and it should be recorded as such.

### 18.4 What slice 5 must answer

**Decision E** (§8.3), with two engines actually running rather than one imagined vividly:

| seam | Firecracker | QEMU | shape it argues for |
|---|---|---|---|
| **network attachment** | pre-made tap, by name | pre-made tap, by name | **common** |
| **create** | `config.json` + `--no-api` | argv + manifest | common *contract*, different artifact |
| **start** | spawn VMM, watch serial | spawn VMM, watch serial | common |
| **stop** | `SendCtrlAltDel` over a unix REST socket, else SIGKILL by pid | ACPI via monitor socket, else SIGKILL by pid | **same intent, different channel** |
| **console** | one client per `console.sock` | one client per serial socket | common, and the same footgun |
| **`exec`** | **does not exist** | does not exist | the intersection's edge |
| **vsock** ✅ 5c | unix socket + a `CONNECT <port>` handshake; addressed by `uds_path` | raw `AF_VSOCK`; addressed by `guest-cid=` | **identical guest contract, host APIs different in kind** — [Appendix N](#appendix-n--slice-5c-vsock-the-first-channel-that-is-not-the-fabric-2026-08-07) |

> The vsock row was added 2026-08-07 and is the **sharpest** one here: every other row
> compares two host-side lifecycles, while this one holds the *guest* side byte-identical
> (one static binary, no engine `#ifdef`) and lets only the host differ. It also carries the
> row's first finding with a consequence: `guest_cid` is a **host-kernel allocation** under
> QEMU (a duplicate is refused at device creation) and an **advisory label** under
> Firecracker (three guests ran as CID 43 at once). One field name, two meanings, and
> nothing reports the difference — see [N.5](#n5-the-consequence-nothing-reports-guest_cid-is-not-one-thing).

If the intersection is `create`/`start`/`stop`/`status`/`destroy` and the *differences* are
all in the channel rather than the meaning, §8.3 shape **(b)** is right and the plan should
say so with the table above as evidence. If the differences turn out to be semantic —
"stop" meaning genuinely different things — then **(c)**, and `micro-cloud.sh` orchestrates
without unifying. **The tripwire from slice 4 stays armed**: no verb may be added to either
tool justified by *"the other engine will need this too."*

### 18.5 The pre-flight this slice inherits, and why it is not optional

Appendix I changed the stakes rather than the design:

- Calico's node IP is on the **physical uplink**, not a memberless bridge. F.6 self-healed in
  under a minute because it moved between two memberless bridges; there is no equivalent
  cheap failure mode now.
- Autodetection re-runs **every 60 seconds** ([I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)),
  so a run is exposed for its whole duration, not at its boundaries. Slice 5 creates **two**
  taps and runs **two** VMMs, so it is the longest-running slice so far.
- The fabric masquerades `oifname enx00051b8eb138` — now the **same interface** Calico's
  tunnel binds to. The rules do not overlap (ours matches `ip saddr 10.71.0.0/24` only), but
  it is the first slice where our rule set and the CNI's endpoint share an interface, and
  that should be *stated and checked* rather than assumed benign.

So the non-negotiable from slice 3 is inherited verbatim and **strengthened**: the pre-flight
records Calico's binding *by derivation* and the teardown compares it. It must remain a
derived value — [I.6](#i6-the-methodological-point-for-the-third-time-in-this-plan) is the
argument, and it is not hypothetical: had slice 3 hard-coded `incusbr0` as the expected value
on 2026-08-02, the very next run on this host would have blamed the fabric for a migration a
reboot caused.

### 18.6 Order of work

| # | item | why here | gate |
|---|---|---|---|
| 1 | ~~recover `fabric.sh`~~ ~~**re-run it**~~ → **DONE 2026-08-04** ([I.7](#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)) | slice 5 has nothing to attach to; §18.1 | ✅ `up`/`tap`/`status`/`down` all green, and the teardown comparison matched the **new** binding it derived at pre-flight. **Not** proven: `retap`, any microVM, the comparison's negative direction — 5a re-runs the exercise |
| 2 | Appendix I's markers | a reader must not act on the stale `incusbr0` claims | this section |
| 3 | ~~`lab-chroot.sh export-rootfs`~~ → **DONE 2026-08-05** ([§6.4](#64-what-the-implementation-changed--and-the-ext4-vs-xfs-question-measured), [§6.5](#65-four-silent-exits-in-one-function-and-what-the-negative-controls-actually-proved)) | the one written-up component with a real downstream (decision 18); makes the slice-5 images reproducible instead of hand-built | `test-export-rootfs.sh` — valid ext4, `/sbin/init` read back with `debugfs`, **and the UNKNOWN case** [H.4](#h4-two-defects-both-in-the-safety-machinery) found |
| 4 | ~~fold the preflight instruments~~ → **DONE 2026-08-05, and the answer was not a fold** ([§18.7](#187-item-4s-premise-tested-the-four-instruments-agree--and-one-of-them-was-lying)) | four instruments that can disagree about host capability is [§0.1](#01-how-this-lab-is-built-differs-from-the-others)'s bug class waiting to happen | the gate lines are identical to `lab-fc.sh preflight`'s, asserted structurally as [H.2](#h2-the-schema-derived--and-the-two-fields-that-are-refusals) does |
| 5 | ~~`disk_format` in `lab-vm.sh`~~ → **DONE 2026-08-05**, and it was two changes ([§18.8](#188-item-5-was-two-changes--and-the-gate-had-the-bug-it-exists-to-catch)) | 5a cannot boot the same bytes without it | `test-microvm-argv.sh` extended **+** [`test-disk-format.sh`](phase2-qemu-vm/tests/test-disk-format.sh) |
| 6 | **slice 5a** — build · exercise · break ← **NEXT**, queued in [`DEFERRED.md`](examples/micro-cloud/DEFERRED.md) with its confounds, privilege split and break pass | §18.3, §18.4, and the ELF-kernel risk now **retired** ([§18.9](#189-the-assumption-most-likely-to-sink-5a-retired-before-it-was-scheduled)) | the boot-time number **with its spread**; decision E argued from the table in §18.4 |
| 7 | **slice 5b** — the §9.2 `edge` | fidelity case, feeds §9.3's capstone | cloud-init runs; `edge` resolves `api1` by name |


### 18.7 Item 4's premise, tested: the four instruments agree — and one of them was lying

[§17.4 q6](examples/micro-cloud/DEFERRED.md#174-open-questions) worried that four
instruments could **disagree about the same host**, and scheduled a fold. The premise was
measured first, because a refactor justified by an untested worry is how an interface gets
shaped by whichever failure was imagined most vividly.

**Where they genuinely overlap is three capabilities, not everything:**

| capability | P1 | P2 | fabric-probe | fabric.sh | lab-fc.sh |
|---|---|---|---|---|---|
| `/dev/kvm` | ✓ | ✓ | · | · | ✓ |
| `firecracker` presence + pinned version | ✓ | ✓ | · | · | ✓ |
| ext4 read-back via `debugfs` | ✓ | · | · | · | ✓ (+ `export-rootfs` = a 4th) |

**Run side by side, they agree.** `/dev/kvm`: P1 `PASS` (a real `KVM_CREATE_VM` ioctl),
lab-fc `ok`. Firecracker: P1 `XFAIL` *"author-run fetch"*, lab-fc `FAIL not on PATH` — the
same fact — and with the binary on `PATH`, `ok firecracker v1.16.1 (pinned)`. The ext4 gate
even disagrees *correctly*: P1 passes on an image it just built, lab-fc returns **UNKNOWN**
on slice 3's `api1.ext4` because a guest booted it `rw` and was SIGKILLed, so `debugfs`
cannot open it — [H.4](#h4-two-defects-both-in-the-safety-machinery)'s fix working exactly
as designed.

**Exactly one disagreement was real, and it was not a divergent implementation.** It was a
cached string, in the oldest instrument:

```text
tools/micro-cloud-preflight.sh, printed live on 2026-08-05:
  FAIL  §7,§13  this host's forwarding path has no other owner
                5 live calico-node procs; vxlan.calico over lxdbr0
```

The process count is derived. **The interface name is a literal** — already wrong on
2026-08-01 ([D.1](#d1-the-correction--the-vxlan-underlay-is-incusbr0-and-the-empty-daemon-is-the-load-bearing-one):
it was `incusbr0`) and wrong again on 2026-08-04
([I.1](#i1-the-measurement): it is the physical uplink). **An instrument that runs today and
prints a fact from 2026-07-29 is not a dated record — it is a liar with a fresh timestamp**,
and by this plan's own ladder that outranks an honest failure.

**So the answer to q6 is not a fold.** q6 itself requires the dated spikes stay *runnable*,
and merging them would destroy the harness that produced Appendices A and B. The distinction
that resolves it:

> **The appendix is the record and is immutable. The instrument is code, and code has to be
> true when it runs.**

Two instruments were corrected to *derive* rather than name — P1's Calico row, and the
fabric probe's `for b in virbr0 lxdbr0 incusbr0 docker0`, which was accurate on 2026-08-02
and by 2026-08-04 was printing *"0 nft rules"* for two interfaces that **no longer existed**.
That is the quiet failure mode of a hard-coded list: it does not error, it reports the
absent thing as unused. It now enumerates `/sys/class/net/*/bridge`.

And the rule is enforced rather than remembered:
[`tools/tests/test-no-cached-host-facts.sh`](tools/tests/test-no-cached-host-facts.sh) fails
when any instrument names one of this host's volatile interfaces or addresses outside a
comment — comments are exempt on purpose, because *"[2026-08-02] Calico was bound to
`incusbr0`"* is precisely the record worth keeping. It carries its own negative control (the
detector is proven to fire on the incident's exact line, and to exempt a dated comment
mentioning the same name) and it was re-injected against the real defect in P1, where it
failed with the file and line. `br-mc0` and `10.71.0.0/24` are deliberately **not** banned —
those are ours, chosen by the fabric, and constant by design.

**What this cost, and what a fold would have cost.** Two derivation fixes and a 90-line
guard, versus a refactor of two frozen spikes to solve a disagreement that measurement says
does not exist.


### 18.8 Item 5 was two changes — and the gate had the bug it exists to catch

§18.3 costed this as *"`build_qemu_argv` hardcodes `format=qcow2`, so booting the same raw
ext4 needs a `disk_format` field"*. Measuring first found a **second** blocker on the same
path, and it was the harder one.

**`--image <raw>` could not reach QEMU at all.** Both overlay builders passed `-F qcow2` for
the *backing* file, so pointing `kernel+initrd` at slice 3's `api1.ext4` died at
`qemu-img create` with `Image is not in qcow2 format` — a loud failure, but one that closed
the path before the drive line was ever reached. The backing format is now **derived**
(`qemu-img` already knows) rather than turned into a second knob that could disagree with
the file.

**And `disk_format = "raw"` copies rather than overlays.** An overlay was the obvious
implementation and would have been a confound: Firecracker gives each instance a full
per-instance copy ([§5.3](#53-state-directory)), so a QEMU guest on a CoW overlay is not
running the same storage stack, and slice 5a's entire claim is that **the VMM is the only
variable**. `raw` therefore copies the image to the per-instance disk — the same semantics
`lab-fc.sh` uses, and the source is never mutated.

**The gate shipped with the exact defect it exists to catch.** `disk_format` is *declared*
rather than probed (QEMU probing a raw image whose contents resemble another format is a
known hardening hole), so a declaration that disagrees with the file is a record that
misdescribes its subject — and QEMU only catches it at `start`, long after `create` reported
success and wrote a manifest. The gate binds the two. Its first implementation read the
first `"format"` out of `qemu-img info --output=json`, which for a raw file is the nested
child block's **`"file"`** — the protocol driver — not the top-level `"raw"`. So the gate
refused a correctly-declared raw image, naming a format QEMU has no such concept of.

It passed every fixture. It failed instantly against slice 3's real `api1.ext4`. *A test
that builds its own subject can only find the bugs its author already imagined.*

Both guards were then re-injected and both bit:
[`test-microvm-argv.sh`](phase2-qemu-vm/tests/test-microvm-argv.sh) fails when the drive
line's format is hardcoded again, and asserts that **explicit `qcow2` is byte-identical to
the default** — the negative control for the whole change, since the one thing this must not
do is alter what a pre-existing VM emits.
[`test-disk-format.sh`](phase2-qemu-vm/tests/test-disk-format.sh) fails with
`a raw image derived as 'file', not 'raw'` when the JSON parse regresses, and asserts that an
unreadable file yields **UNKNOWN** — the gate must decline to refuse rather than invent a
mismatch.


### 18.9 The assumption most likely to sink 5a, retired before it was scheduled

5a's whole claim is *"the same kernel, the same rootfs, the VMM is the only
variable."* One thing could have made the first half impossible: **Firecracker is
ELF-only** ([§6.3](#63-the-kernel)) and answers a `vmlinuz` with
`Elf(InvalidElfMagicNumber)`, while QEMU's x86 `-kernel` is built around the bzImage
boot protocol. If QEMU could not load the ELF `vmlinux`, "the same kernel" would have
had to become "the same *build*, two formats" — a materially weaker comparison, and one
that should be discovered before the slice is scheduled rather than during it.

Measured 2026-08-05, `-M microvm` + KVM, no disk:

```text
[    0.000000] Linux version 6.1.155+ … Command line: console=ttyS0 reboot=k panic=1
[    0.048xxx] VFS: Cannot open root device …
[    0.048690] Rebooting in 1 seconds..
```

**It loads.** The same ELF binary Firecracker boots, reaching root-mount in ~48 ms and
then rebooting — `panic=1` doing exactly what
[E.3](#e3-the-panic1-hole-closed-by-watching-it) measured on the other engine. The
kernel half is real.

**What this does NOT establish**, and the distinction is the whole point of §10: that a
guest finds its root disk on the **virtio-mmio** bus. No disk was attached, so the run
above proves the loader and nothing about storage. That is 5a's first real gate, not a
detail — and it is the reason `--disk-format raw` attaches a per-instance copy rather
than a CoW overlay ([§18.8](#188-item-5-was-two-changes--and-the-gate-had-the-bug-it-exists-to-catch)).

**And one asymmetry the slice must handle rather than paper over.**
[E.4](#e4-two-findings-the-plan-did-not-anticipate) found Firecracker *appends*
`root=/dev/vda rw` after the user's `boot_args`, which is why `lab-fc.sh` refuses a
user-supplied `root=`. QEMU appends nothing, so 5a must **supply** it. One spec cannot
serve both engines verbatim — and that is not friction to be smoothed away, it is
**decision-E evidence arriving early**: two engines whose network attachment is
genuinely identical and whose boot contract is genuinely not.

**Explicitly not in this slice:** `CLONES.md` (slice 5 makes no rung-4 move, so the ledger has
nothing to record yet — building it now would be enforcement in search of a violation);
`backends/fc.py` (§8.1 — complementary, and it is *better* written after decision E rather
than before, since a read-only pane is itself shape (c)); the two install-gap labs (§18.2 —
precondition unmet until item 3 lands); [G.9](#g9-not-run--recorded-as-unknown-not-as-pass)'s
tap-with-an-address experiment (still UNKNOWN, and [I.3](#i3-the-hazard-did-not-go-away--it-got-worse)
made it **more** expensive here, not less).

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

> ⚠️ **The specific hazard here is VOID as of 2026-08-04, and what replaced it is worse —
> [I.3](#i3-the-hazard-did-not-go-away--it-got-worse).** `lxdbr0` and `incusbr0` are both
> **absent**; the node IP now sits on the **physical uplink**. The *class* of hazard is
> unchanged and the reasoning below is still the right reasoning — only its subject moved.
> Also note the trigger correction in [I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll):
> autodetection is **not** restart-only, it re-runs every **60 seconds**.

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
at index 9 — ahead of `incusbr0` at 17.** On the next `calico-node` restart — **or within 60
seconds, [I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)** —
the node IP can migrate to `10.216.67.1`, which is F.6 again with a different interface.

**The trigger is narrower than first written, and that is measured now.** Repairing the
kubelet cert ([F.9](#f9-an-environmental-fault-this-work-surfaced-not-ours-worth-fixing))
restarted `snap.microk8s.daemon-kubelite` on a live cluster, and Calico did **not** move:

| | before | after a `kubelite` restart |
|---|---|---|
| tunnel | `local 10.45.178.1 dev incusbr0` | **unchanged** |
| pod addresses | `10.1.24.169`, `10.1.24.173` | **unchanged — pods not recreated** |

So **a control-plane restart alone does not re-run autodetection.** It is a `calico-node`
restart that does, and in F.6 that restart was itself caused by the interface disappearing.

> ⚠️ **The second sentence is FALSIFIED 2026-08-04 —
> [I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll).**
> Autodetection re-runs **every 60 seconds** from `monitor-addresses/`, not only from
> `startup/`. The *observation* above survives untouched — a `kubelite` restart moved
> nothing — but it never discriminated: the candidate set did not change during it, so a
> poll of any frequency would have returned the same answer. **"Nothing moved" was read as
> "nothing looked."** The hazard therefore does **not** need something to restart
> `calico-node`; a lower-index candidate appearing is sufficient on its own, within a
> minute. That is also the most likely explanation for the half of
> [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel) that has no log
> line: the *adoption* of the tap.
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

  > ✅ **DONE 2026-08-06 — GREEN at root, all ten assertions.** The range is now `MC_DHCP_LO`/`MC_DHCP_HI`, and
  > [`tests/test-dhcp-exhaustion.sh`](examples/micro-cloud/tests/run-all.sh) fills a
  > five-address pool in seconds. It grades **both** layers that can run out — reservation
  > time (our code) and lease time (dnsmasq) — and its load-bearing assertion is the
  > inverse of slice 5b's: with the dynamic pool empty, a **reserved** instance must still
  > receive **its own** address, with an unreserved client at the same instant receiving
  > nothing as the built-in control. Fixing the knob also exposed a latent defect: the
  > reservation address was computed as `10.71.0.$((100 + IDX))` with the base hard-coded,
  > so any pool not starting at `.100` would have marched reservations **outside the
  > range** — addresses dnsmasq was never told to serve — while creating the tap anyway.
  > It now derives from `DHCP_LO`, and `tap` refuses the overflowing reservation by name
  > *before* the tap exists. See [M.8](#m8-the-cheaper-half-of-g9-built--and-the-defect-the-knob-uncovered-2026-08-06).

**And the nested host is now a queued lab unit in its own right** *(added 2026-08-06)*:
[`nested-calico-sandbox/`](examples/micro-cloud/DEFERRED.md#queued--nested-calico-sandbox-a-disposable-cluster-to-break-on-purpose).
It is worth more than this one scenario — a cluster we may destroy is a safe host for the
**whole** slice-3 break pass. (`retap` itself is no longer part of that debt — it was
**proven 2026-08-07** against a deliberately root-owned tap,
[Appendix P](#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07).)

> **Partly answered, and the distinction matters** *(2026-08-07,
> [Appendix O](#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07))*.
> The *property* above — an addressed interface becomes a first-found candidate and Calico
> migrates to it on the poll — **was measured**, in a disposable microk8s, at Calico
> **v3.29.3**. What was **not** run is this scenario as written: a **`fabric.sh` tap** given
> an address beside a cluster whose loss would matter. A dummy interface in a guest and a
> tap on `br-mc0` are not the same subject, and the sandbox result is a statement about the
> selection algorithm at a named version rather than about this host. Recorded as
> **partly** closed, not closed.

**The host without a live cluster need not be another machine** *(added 2026-08-03)*: a
nested QEMU VM from phase 2 (`lab-vm.sh`) can *be* it. Boot a throwaway VM, install a
disposable microk8s + Calico inside it, and re-run F.6 there on purpose — the tap-address
experiment needs only a live Calico to watch and `CAP_NET_ADMIN`, both available inside
the guest, and the only cluster at risk is one installed to be broken. The DHCP-exhaustion
test fits the same box with a shrunken range. Booting Firecracker microVMs *inside* the
guest would additionally need nested KVM (`kvm_amd`/`kvm_intel` `nested=1`), but neither
deferred scenario requires a microVM — dummy interfaces and the guest's own DHCP clients
suffice, so the experiment does not depend on nested virt being enabled.

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

---

## Appendix I — Calico moved, no lab caused it, and the trigger is a 60-second poll, 2026-08-04

Measured at the start of the slice-5 planning session, before any work. Nothing in this
appendix was caused by this repo. It is here because **three sessions of this plan are built
on a fact that has since stopped being true**, and because re-deriving it turned up the
mechanism [F.7](#f7-the-selection-rule-derived--and-7-already-satisfied-it) left unexplained.

> **Addendum, 2026-08-05:** [I.9](#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass)
> is one day later than the rest of this appendix — the run that turned
> [I.7](#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass)'s one-shot into
> a committed test and then *executed that test's privileged path*.

### I.1 The measurement

```text
date            2026-08-04T22:15:45-04:00
uptime since    2026-08-04 21:31:05          ← the host rebooted
calico-node     5 procs, all started 21:31:44
snap.lxd.daemon inactive
incus           inactive
```

| # | interface | state | IPv4 | v3.28.1 exclusion | candidate? |
|---|---|---|---|---|---|
| 2 | `enx00051b8eb138` | **up** | 192.168.1.106/24 | none matches | **YES ← chosen** |
| 3 | `wlp15s0` | down | — | none matches | no (down, no v4) |
| 4 | `virbr-vbmc` | down | 192.168.123.1/24 | `^virbr` | no |
| 5 | `virbr0` | down | 192.168.122.1/24 | `^virbr` | no |
| 6 | `docker0` | up | 172.17.0.1/16 | `^docker` | no |
| 7 | `veth21f6335` | up | — | `^veth` | no |
| 11 | `vxlan.calico` | unknown | 10.1.24.128/32 | **none matches** — see I.4 | (Calico's own) |
| 13, 14 | `cali*` | up | — | `^cali` | no |
| — | `incusbr0` | **ABSENT** | — | — | — |
| — | `lxdbr0` | **ABSENT** | — | — | — |

Three independent records agree, and none of them is ours:

```text
node annotation   projectcalico.org/IPv4Address: 192.168.1.106/24     (was 10.45.178.1/24)
tunnel binding    local 192.168.1.106 dev enx00051b8eb138             (was … dev incusbr0)
calico-node log   Using autodetected IPv4 address on interface enx00051b8eb138: 192.168.1.106/24
```

**Cause, and it is mundane:** the host rebooted; neither LXD nor Incus came back up; neither
bridge was created; `calico-node` started 39 s later and found **exactly one** eligible
candidate. No ordering inference is needed or possible — the candidate set has size 1.

### I.2 What this invalidates

`incusbr0` appears **37 times** in this document. Every occurrence inside a dated appendix
stays as written — a measurement is a record of what was true then, and rewriting it would
destroy the only thing it is for. What must be marked is every place the document tells a
**future reader to act** on it:

| location | claim | status |
|---|---|---|
| §7.1 interface table | `incusbr0` — "leave, **load-bearing**" | **stale**: the interface does not exist |
| §13 risk table | "`vxlan.calico` up over `incusbr0`" | **stale** |
| §9.2 | `db` on LXD, *"not Incus — `incusbr0` carries Calico's VXLAN endpoint"* | **premise gone**; the placement may still be right, the reason is not |
| §17.4 q8 revised answer | *"target `incus`, pinned, because `incusbr0` is already the chosen interface"* | **inoperative** — it names a bridge that does not exist, and starting either daemon now **creates a new candidate on a live cluster** |
| [F.8](#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose) | `lxdbr0` outranks the chosen interface | **void** — and replaced by something worse, I.3 |

**The generalised rule from q8 survives, restated:** *prefer the engine whose bridge the CNI
has already selected, because that is the one choice guaranteed not to move it.* When the CNI
has selected **no** bridge — as now — the rule says the opposite of what it said in July:
**start neither daemon**, because each would manufacture a fresh candidate under a running
cluster. The rule did not change. Its answer did, and nothing in the repo noticed.

### I.3 The hazard did not go away — it got worse

F.8's concern was that `lxdbr0` could pull the node IP off `incusbr0`: a **memberless bridge
to a memberless bridge**, which is why F.6 self-healed in under a minute. The node IP now
lives on the **physical uplink**. A migration off `enx00051b8eb138` moves the cluster's node
address off the box's actual NIC.

Both [F.7.1](#f71-the-constraint-slice-3-actually-needs) constraints still hold and are still
ordering-independent — `br-mc0` matches `^br-.*`, and an addressless tap can never supply an
address. Nothing about the fabric design needs to change. What changes is the **cost of being
wrong**, and therefore the standing of the pre-flight/teardown comparison: it stops being
prudent and becomes the only thing standing between a slice and a real outage.

### I.4 The finding that outlives the migration — autodetection is a 60-second poll

Eight consecutive log lines, 60.001 s apart:

```text
02:08:45.238 [INFO][61] monitor-addresses/autodetection_methods.go 103: Using autodetected …
02:09:45.239 [INFO][61] monitor-addresses/autodetection_methods.go 103: Using autodetected …
…
02:15:45.243 [INFO][61] monitor-addresses/autodetection_methods.go 103: Using autodetected …
```

F.7's log line — the one that replaced its inference — came from **`startup/`**
`autodetection_methods.go:103`. Today's come from **`monitor-addresses/`**, same file, same
line. **The same detection function has (at least) two callers: once at startup, and again
every 60 seconds for the lifetime of the process.**

This document has consistently written the trigger as a restart:

> *"On the next `calico-node` restart the node IP can migrate to `10.216.67.1`"* — F.8
> *"a control-plane restart alone does not re-run autodetection. **It is a `calico-node`
> restart that does**"* — F.8
> *"The hazard therefore needs **both**: a lower-index candidate present **and** something
> that restarts `calico-node`"* — F.8

**That understates the exposure by an unbounded factor**, and the middle claim is now
falsified outright: `monitor-addresses` re-runs the same function on a one-minute timer
whether or not anything restarts. F.8's supporting *observation* — a `kubelite` restart moved
nothing — is intact and was never evidence for the inference drawn from it: **the candidate
set did not change during that experiment, so a poll at any frequency would have returned the
same answer.** "Nothing moved" was read as "nothing looked". It is the mechanism-not-outcome
trap, in a paragraph whose subject is a mechanism. If `monitor-addresses` acts on what
it detects, the window is not "whenever somebody restarts `calico-node`" — it is **sixty
seconds, continuously, forever**. A lab that creates an interface is exposed for its entire
run, not at its boundaries.

It is also the best available explanation for **the half of F.6 that was never explained**.
F.6 has a log line for the *recovery* (a `startup/` detection landing back on `incusbr0` when
`calico-node` restarted after the tap was deleted) and **no log line for the adoption** — the
moment a freshly created tap captured the tunnel. A 60-second monitor is exactly the shape of
thing that would do that silently, with no restart in the story at all.

**Recorded as a lead, not a conclusion.** What is measured: two distinct callers, and a
60.00 s cadence. What is *not* measured: that `monitor-addresses` writes the node resource
when the address changes, rather than only logging it. The measurement that would close it is
the F.6 experiment — create an addressed interface and watch — which
[G.9](#g9-not-run--recorded-as-unknown-not-as-pass) already defers to a host without a live
cluster, and I.3 has just made *more* expensive here, not less.

**Free correction available now, and it should be taken:** every place this plan says
"restart" as the trigger should say "**startup, or the 60-second monitor**", because the
narrower wording invites a reader to believe a lab is safe between restarts.

### I.5 What did not resolve

`enx00051b8eb138` won today, which confirms it is **eligible** — the half of the F.7 puzzle
that was genuinely in doubt. It does **not** resolve the ordering puzzle: with a candidate
set of one, today's boot cannot discriminate between any two orderings. F.7's question stands
exactly as written — index 2, UP, unexcluded, and it lost to `incusbr0` in July.

### I.6 The methodological point, for the third time in this plan

This was found by running `ip -o link` before planning, not by reading the plan. Every
statement it invalidated was true when written, sourced, and dated. The plan's own rule —
*derive the fact, don't cache it; a fact asserted three sessions ago is a cache entry* — was
written **about MAAS**, and this document was its next victim.

The part that generalises: the **teardown assertion caught F.6 because it re-derives Calico's
binding at run time rather than comparing against a constant.** Had slice 3 hard-coded
`incusbr0` as the expected value — which was the obvious, correct-looking thing to do on
2026-08-02 — the very next run on this host would have reported a migration the fabric did
not cause, and the instrument would have become the liar.

### I.7 The recovered fabric, re-verified against the moved binding — **PASS**

Run 2026-08-04 23:39, the round trip `up` → `tap api1` → `tap api2` → `status` → `down`.
Nothing was booted; this is the fabric alone. The question it exists to answer is narrow:
**does the instrument still work now that its subject moved?**

```text
1. PRE-FLIGHT  calico tunnel : local 192.168.1.106 dev enx00051b8eb138
               candidate set : 2 enx00051b8eb138 192.168.1.106/24 CANDIDATE
   …
3. COMPARISON  ok: calico tunnel unchanged (local 192.168.1.106 dev enx00051b8eb138)
               ok: cali* veth count unchanged (2) — pods were not recreated
               ok: ip_forward back at 1
   PASS: teardown left nothing of ours and nothing of theirs
```

**Yes.** The pre-flight recorded the *new* binding because it derives it; teardown compared
against what pre-flight recorded, not against a constant, and matched. A version of this
script with `incusbr0` written into it would have failed here on a host where nothing was
wrong. That is [I.6](#i6-the-methodological-point-for-the-third-time-in-this-plan) shown
rather than argued — and it is the **third** independent derivation of I.1's binding, after
the `status` verb and the node annotation.

Also green: `ip_forward` recorded as pre-existing and therefore never reverted; both taps
**addressless and owned by uid 1000**, read back from `/sys/class/net/*/owner` rather than
believed; the five absence assertions; dnsmasq killed by a PID verified against its own
cmdline.

**Scope — what this run did NOT prove.** It is a fabric test, not slice 3:

| not exercised | why it matters |
|---|---|
| **`retap`** | ✅ **PROVEN 2026-08-07** — [Appendix P](#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07). `TUNSETIFF-FAILED errno=1` on a tap with owner uid 0 → `retap` → `TUNSETIFF-OK`, reservation byte-identical and still single, tap addressless on `br-mc0`, both verbs refusing the other's case, Calico unmoved. It took **three privileged runs and two harness defects**, both of which the test caught itself: an owner-**less** tap is attachable by anyone (so the first break was never a break), and §5 asserted a *message* where `fabric.sh` was right. |
| **any microVM** | no lease was requested, no name resolved, no packet crossed the bridge. **dnsmasq started and re-read its files; it never served anybody.** |
| **the teardown comparison's negative direction** | [G.7](#g7-the-teardown-assertion-proven-in-both-directions) proved it bites on 2026-08-02; that was not re-run |

So: **the fabric is re-verified; the slice-3 exercise is not.** The artifacts to re-run the
full exercise survive in `micro-cloud-s3/`, and slice 5a will do it anyway with a second
engine attached.

### I.8 A bridge with members can be "DOWN" — and it sharpens F.7's volatility guess

Two lines from the same run, twenty seconds apart:

```text
# step 2, bridge just created, NO members:
35: br-mc0: <BROADCAST,MULTICAST,UP,LOWER_UP> … state UNKNOWN
# `status`, TWO taps enslaved, no VMM running:
35: br-mc0: <NO-CARRIER,BROADCAST,MULTICAST,UP> … state DOWN
```

**Enslaving two working taps made the bridge go DOWN.** A bridge's carrier follows its
ports; a tap has no carrier until a VMM opens it (the
[`carrier=1` gotcha](#g8-deleting-the-bridge-under-a-running-microvm--halted-honest-and-one-surprise)
from the other direction), so a fabric with members and no guests reports worse health than
an empty one. Nothing is wrong — but a reader who greps `state DOWN` will think so, and
slice 5 doubles the number of taps sitting idle between runs.

**It also corrects a detail in F.7.** F.7 guessed the candidate set is volatile because
*"both bridges drop to `DOWN` when memberless"*. The mechanism is the opposite of
memberlessness: **an empty bridge is `LOWER_UP`; it drops when it gains a port with no
carrier.** `candidate_set()` filters on `operstate == up`, so candidacy is not a property of
a bridge — it is a property of **whether a VMM happens to be running at the instant
autodetection polls**, which per
[I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll) is
every 60 seconds. F.7's hypothesis was right and its stated reason was not.

Harmless here — `br-mc0` is excluded by name at any operstate, which is exactly why rule 1
is the safety property and rule 2's addresslessness is the backstop. Recorded because the
next person to build a fabric on this host may not name it `br-*`.

### I.9 The one-shot became a test, and the test's root path ran — **PASS**

[I.7](#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass) was a one-shot.
Landing it as
[`tests/test-fabric-round-trip.sh`](examples/micro-cloud/tests/test-fabric-round-trip.sh)
made it re-runnable, and added three guards a one-shot did not need (not-root → SKIP; a
fabric already up → SKIP and touch nothing; a root-owned checkout → SKIP). But **a landed
test is not an executed one**, and every guard it gained is a *new* way for it to exit 77
without asserting anything. CI runs unprivileged and can therefore only ever exercise the
first skip. So the state on the day it merged was: one PASS, and an **UNKNOWN** about
whether the file in the repo still reproduced it.

Author-run 2026-08-05, `sudo bash examples/micro-cloud/tests/run-all.sh`:

```text
=== test-fabric-round-trip.sh ===
  - before: calico=local 192.168.1.106 dev enx00051b8eb138 veths=2 ip_forward=1
  - up: br-mc0 + 10.71.0.1/24 + nft mklab-mc + dnsmasq 55429
  - taps: 2 created, both addressless, both owned by uid 1000, both on br-mc0
  - down: bridge, taps, nft table, route and dnsmasq all absent
  - calico binding, pod veth count and ip_forward all unchanged across the round trip
PASS: fabric round trip: up/tap/status/down green, and the live cluster was untouched

=== summary: 1 passed, 0 skipped, 0 failed ===
```

**`1 passed, 0 skipped`** is the line that closes the UNKNOWN: none of the three guards
fired, so the assertions between them actually ran. An all-SKIP run would have printed the
same `PASS`-free green-looking summary with `0 passed` — which is why `run-all.sh` says so
out loud rather than exiting 0 in silence.

What it independently re-derives, one day and one process later: **I.1's binding is still
`enx00051b8eb138`** (a fourth derivation, and the first from a committed artifact rather
than a scratch one), the veth count and `ip_forward` are unchanged, and the taps are
**addressless and uid-1000-owned** read back from `/sys/class/net/*/owner`. The bridge
carrier oddity in [I.8](#i8-a-bridge-with-members-can-be-down--and-it-sharpens-f7s-volatility-guess)
is invisible here because the test asserts *membership* (`ip -o link show master br-mc0`),
not operstate — assert the outcome, not the mechanism.

**Scope is unchanged from I.7 and is not quietly widened by having a test file:** `retap` is
still never called, **no microVM boots** (dnsmasq serves nobody), and the teardown
comparison's negative direction is still the 2026-08-02 proof in
[G.7](#g7-the-teardown-assertion-proven-in-both-directions), not a re-run. Slice 5a is where
those get exercised.

## Appendix J — slice 5a (a), the second engine: the number nobody had, and the number everybody had was wrong, 2026-08-05

Slice 5a's **unprivileged half** — no fabric, no tap, no network, no root. One kernel
(`vmlinux`, `e20e46d0…`), one rootfs (`api1.ext4`, `2e308e0b…`, copied per run), two VMMs,
5 runs per arm. Harness: [`bench-boot.sh`](examples/micro-cloud/bench-boot.sh); regression
guard: [`tests/test-bench-boot.sh`](examples/micro-cloud/tests/test-bench-boot.sh).

### J.1 The ELF-kernel risk, and the one that mattered instead

[§18.9](#189-the-assumption-most-likely-to-sink-5a-retired-before-it-was-scheduled) retired
the assumption most likely to sink the slice — QEMU loading Firecracker's ELF `vmlinux` —
and left one thing unverified: *the guest finding its root disk on the **mmio** bus.* It
finds it, first try:

```text
[    0.066516] EXT4-fs (vda): recovery complete
[    0.067479] VFS: Mounted root (ext4 filesystem) on device 254:0.
[    0.069558] Run /sbin/init as init process
SLICE3-BEGIN name= peer= uptime=0.05s
```

Same kernel, same bytes, `-M microvm` + `virtio-blk-device`, and slice 3's init script runs.
The comparison is real, and the interesting problem was somewhere else entirely.

### J.2 The measurement

`K` = the guest kernel's own timestamp on `Run /sbin/init as init process` — the marker
slices 1–4 timed, so these are comparable to Appendices E–H. It **excludes** VMM startup and
firmware. `W` = host wall clock from `exec` to that line; it **includes** both.

| arm | K min | **K median** | K max | W median | K spread |
|---|---|---|---|---|---|
| `fc-default` | 0.567032 | **0.567145** | 0.567488 | 0.6183 | 0.46 ms |
| `fc-noi8042` | 0.054149 | **0.054905** | 0.055454 | 0.1041 | 1.31 ms |
| `qemu-default` | 0.069474 | **0.070918** | 0.072158 | 0.1554 | 2.68 ms |
| `qemu-noi8042` | 0.070696 | **0.072407** | 0.073372 | 0.1552 | 2.68 ms |

`fc-default` **reproduces the historical figure to four decimal places** — 0.567145 against
[H.3](#h3-the-diff-against-slice-1s-hand-written-config)'s 0.564930 and
[G](#appendix-g--slice-3-the-fabric-2026-08-02)'s 0.571730, measured three days and one host
reboot apart. Slice 1's "zero variance" claim also survives contact: every arm's spread is
under 3 ms.

### J.3 The headline that was false

The first QEMU boot came back at **0.070 s against Firecracker's 0.567 s** and the obvious
conclusion — *QEMU `-M microvm` reaches userspace 8× faster than Firecracker* — is **wrong**.
The gap is not the hypervisor. It is **one device probe**, and it is visible as a single
stall in the boot log:

```text
[    0.051399] clk: Disabling unused clocks           ← the same instant in both engines
[    0.563440] input: AT Raw Set 2 keyboard as …/i8042/serio0/input/input0   ← FC, 0.512 s later
[    0.052645] EXT4-fs (vda): recovery complete       ← same kernel, i8042 probing off
```

Firecracker emulates an **i8042 PS/2 controller** — it is how `SendCtrlAltDel` reaches the
guest, i.e. it exists to serve the `stop` verb in [§18.4](#184-what-slice-5-must-answer)'s
table. QEMU's `microvm` machine emulates none. The kernel waits out a probe on hardware that
never answers, and on this kernel that wait is **0.512 s of Firecracker's 0.567 s — 90.3% of
the number this plan's density argument has rested on since slice 1.**

**Four `i8042.*` flags are the folk remedy; two of them do nothing.** Measured one at a time,
because "add these four flags" is advice nobody can check:

| flag | K | |
|---|---|---|
| `i8042.nopnp` | **0.0598** | ← the stall is the **PnP** probe |
| `i8042.dumbkbd` | **0.0562** | ← skips the keyboard command handshake |
| `i8042.noaux` | 0.5681 | no effect |
| `i8042.nomux` | 0.5672 | no effect |
| `i8042.notimeout` | 0.5670 | no effect — note the name; it is not the timeout being waited on |

### J.4 The control, and why the finding would be worthless without it

`qemu-default` vs `qemu-noi8042` is the **negative control**: `microvm` has no i8042, so the
flags must be **inert** there. They are — 0.070918 vs 0.072407, a 1.5 ms difference inside a
2.7 ms spread. Had that arm moved, the flags would be doing something other than what J.3
claims and the Firecracker attribution would be unsupported. `test-bench-boot.sh` asserts it
every run and **fails by name** if the two ever diverge.

This is the fault-injection rule applied to a benchmark: a four-arm matrix where one arm is
*expected not to move* is the only version of this measurement that can tell "the flags
disabled the probe" from "the flags changed the boot."

### J.5 The answer, once both engines are on equal footing

| | Firecracker | QEMU `-M microvm` | |
|---|---|---|---|
| kernel → userspace (`K`) | **0.054905** | 0.070918 | FC **1.29× faster** |
| wall clock (`W`) | **0.1041** | 0.1554 | FC **1.49× faster** |
| VMM + firmware (`W − K`) | **0.049** | 0.085 | FC ~36 ms leaner |

**The direction is the opposite of the naive reading, and the magnitude is a third of it.**
Firecracker is faster on both measures — modestly in the guest, more clearly in its own
startup, where QEMU also pays for qboot. What Firecracker is *not* is 8× slower, and nothing
in slices 1–4 could have told you that, because there was only ever one engine in the room.

### J.6 What this changes, and what it does not

- **The density argument stands, and its number moves.** "0.55 s to userspace" is real and
  reproducible, but ~0.51 s of it is a probe that four kernel-cmdline characters remove.
  The honest figure for a *tuned* Firecracker microVM on this kernel is **0.055 s**, and the
  comparison to QEMU should be made there, not at the defaults.
- **A default is not a property.** Slices 1–4 measured Firecracker's *default device model*
  and the plan wrote it down as Firecracker's *speed*. One engine cannot tell those apart —
  which is the entire argument for slice 5 existing.
- **It is decision-E evidence, unexpectedly.** The i8042 is present *because of the `stop`
  seam*: it is FC's Ctrl-Alt-Del path. So the one place the two engines' device models
  genuinely diverge is downstream of the one row in
  [§18.4](#184-what-slice-5-must-answer)'s table marked *"same intent, different channel"*.
  The seams are not independent of the performance story.
- **Unchanged:** [E](#appendix-e--slice-1-one-microvm-by-hand-2026-08-01),
  [G](#appendix-g--slice-3-the-fabric-2026-08-02) and
  [H](#appendix-h--slice-4-the-tool-and-what-it-hides-2026-08-02) are dated records of what
  was measured then and are **not** rewritten. J is what those numbers mean now.

### J.7 Not run — the fabric half is still owed

This is **(a)** only. Neither engine touched a network: no tap, no `br-mc0`, no DHCP, no
name resolution, and therefore **no evidence yet for the network-attachment row** of
[§18.4](#184-what-slice-5-must-answer)'s seam table. `retap` remains uncalled and the
slice-3 exercise remains un-re-run, exactly as
[I.7](#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass) and
[I.9](#i9-the-one-shot-became-a-test-and-the-tests-root-path-ran--pass) said. Slice 5a **(b)**
is the author-run half that pays that debt.

> ✅ **Paid, same day — [Appendix K](#appendix-k--slice-5a-b-two-engines-on-one-fabric-and-decision-e-answered-from-what-the-lifecycles-actually-needed-2026-08-05).** Both engines on `br-mc0`, distinct DHCP leases from
> one dnsmasq, and each engine's guest resolving the other's **by name**. `retap` is still
> uncalled ([K.5](#k5-what-slice-5a-leaves-closed-and-what-it-does-not)).

### J.8 Two defects in the harness, both found by its own honesty

**The parser lied about the boot.** The first version read the timestamp with
`sed "s/…$MARKER…/\1/p"` — and the marker is `Run /sbin/init as init process`, whose slashes
terminate the substitution. All 20 boots failed to parse, and all 20 were reported as
**"never reached userspace within 20s"**, which was false: every guest had booted and printed
the line. A parse failure wearing a boot failure's error message is precisely the liar this
repo fixes first, so `boot_once` now distinguishes the two **by name** and
`test-bench-boot.sh` guards the parser with a log that contains the real marker.

**It wrote its evidence into the repo.** The same run dropped 20 `*-FAILED.log` files into
the working checkout. Scratch now stays in `mktemp -d`, and is **kept rather than deleted**
when a run fails — a benchmark that discards the boot that did not work is one you cannot
debug — with the path printed.

## Appendix K — slice 5a (b), two engines on one fabric, and decision E answered from what the lifecycles actually needed, 2026-08-05

The **author-run half**. Firecracker and QEMU `-M microvm` boot the same `vmlinux` and the
same `.ext4` bytes on two `fabric.sh`-made taps on `br-mc0`, take DHCP leases from one
dnsmasq, and **resolve each other by name across the engine boundary**. Then teardown, with
the [§7.2](#72-teardown-is-a-test-not-a-cleanup) comparison.
[`tests/test-two-engines-one-fabric.sh`](examples/micro-cloud/tests/test-two-engines-one-fabric.sh),
`sudo bash tests/run-all.sh`, **3 passed · 0 skipped · 0 failed**.

### K.1 The run

```text
  - before: calico=local 192.168.1.106 dev enx00051b8eb138 veths=2 ip_forward=1
  - fabric: br-mc0 + two taps from ONE verb, for two different VMMs
  - both guests reached userspace: api1 under Firecracker, api2 under QEMU -M microvm
  - with both engines up: taps addressless, uid-1000 owned, Calico's binding unmoved
  - DHCP: api1=10.71.0.101 (Firecracker) api2=10.71.0.102 (QEMU) — one dnsmasq, two engines
  - name resolution: api1->api2 (Firecracker→QEMU) and api2->api1 (QEMU→Firecracker), by name
  - teardown: ours all gone; calico binding, pod veth count and ip_forward unchanged
PASS
```

**Both VMMs run as uid 1000**, dropped with `runuser` even though the test itself must be
root for `CAP_NET_ADMIN`. That is not tidiness: a root VMM can open *any* tap, so the
uid-1000 tap ownership [G.4](#g4-four-defects-three-of-them-inside-the-safety-checks)
exists to protect would have gone untested and the run would have passed just as happily with
it broken. Dropping privilege is what makes the `owner` assertion mean anything.

### K.2 Decision E, answered — §18.4's table, filled in from what the two lifecycles needed

| seam | Firecracker | QEMU `-M microvm` | verdict |
|---|---|---|---|
| **network attachment** | `host_dev_name: "mc-api1"` | `-netdev tap,ifname=mc-api2,script=no` | **COMMON, and proven.** A pre-made tap *by name*; neither engine creates or destroys it ([H.5](#h5-the-83-tripwire-held--and-51-needs-a-correction)); neither needs privilege. **One fabric verb served both.** |
| **create** | a `config.json` file | argv | common *contract* (kernel · rootfs · tap · vcpu/mem), different artifact |
| **create — `root=`** | **appends `root=/dev/vda rw` itself** and refuses to be told otherwise | appends nothing; must be supplied | **the one genuinely semantic difference.** One spec cannot serve both verbatim ([E.4](#e4-two-findings-the-plan-did-not-anticipate)) |
| **start** | spawn, watch a serial stream | spawn, watch a serial stream | common |
| **stop** | Ctrl-Alt-Del over the emulated **i8042**, else SIGKILL by pid | ACPI via monitor, else SIGKILL by pid | same intent, different channel — **and the channel now has a measured price**, [K.3](#k3-the-seams-are-not-independent-of-the-performance-story) |
| **console** | one client per stream | one client per stream | common, and the same footgun |
| **`exec`** | does not exist | does not exist | the intersection's edge |

**§8.3 shape (b) is right.** The intersection is `create`/`start`/`stop`/`status`/`destroy`,
and every difference above is in the **channel or the artifact** rather than in the meaning —
with exactly one exception, `root=`, which is a difference about *who owns a field* and not
about what "create" means. The slice-4 tripwire stays armed and was not tripped: no verb was
added to either tool for the other engine's benefit.

### K.3 The seams are not independent of the performance story

[Appendix J](#appendix-j--slice-5a-a-the-second-engine-the-number-nobody-had-and-the-number-everybody-had-was-wrong-2026-08-05)
found that 0.512 s of Firecracker's 0.567 s boot is the kernel probing an i8042 that never
answers. **The i8042 is there because of the `stop` seam** — it is Firecracker's
`SendCtrlAltDel` path. So the single row of the table marked *"same intent, different
channel"* is also the row that costs 90% of the boot time. A design conversation about
unifying `stop` is therefore also a conversation about boot latency, which neither slice 4
nor any amount of reading the two APIs would have revealed.

This run re-derived J's finding **from a different direction**, with network devices attached,
measured by the guests themselves rather than by the harness:

```text
SLICE3-BEGIN name=api2 peer=api1 uptime=0.04s      ← QEMU -M microvm
SLICE3-BEGIN name=api1 peer=api2 uptime=0.55s      ← Firecracker, 0.51 s behind
```

J measured no-network boots. Two independent derivations, one from the host's clock and one
from the guests', agreeing to the centisecond.

### K.4 Three defects, all in the test, all found by running it

The lab was right every time; the harness was wrong three times. Worth recording because
**each one would have produced a passing or plausible-looking result** in a slightly different
world:

| # | defect | why it mattered |
|---|---|---|
| 1 | `$HOME` under `sudo` is `/root`, so the workdir default pointed at artifacts that were never there | it **SKIPped honestly** — and that is the only reason it was found. A pass-shaped verdict here would have "verified" two engines without booting either |
| 2 | fixed in the two tests, **missed in `bench-boot.sh`** | two of three call sites is not a fix; the blast-radius rule (`CLAUDE.md`) exists for exactly this |
| 3 | the DHCP assertion **sampled** the console instead of waiting | it failed with `api1 took no DHCP lease`, which was **false** — api1 was still inside `udhcpc`. A stopwatch race against a 0.5 s device probe, which will always fail on whichever engine is behind |

Defect 3 is the interesting one: **it is J's finding turning up as a bug in the test written to
confirm it.** The engines do not arrive together and never will, so any instant-sampled
assertion about two VMMs is a race by construction. `wait_for` a state with a timeout that
reports honestly; never `grep` at an arbitrary instant.

Defect 2 also cost the *"unprivileged half"* its meaning for one run: `test-bench-boot.sh` was
invoking the benchmark as root. It now drops to the checkout's owner, or skips and says why —
measuring the unprivileged claim under privilege would have been the wrong number reported
under the right name.

### K.5 What slice 5a leaves closed, and what it does not

**Closed:** both halves of 5a; §18.4's seam table; the network-attachment row's evidence;
`retap`'s sibling verbs exercised under two engines; [J.7](#j7-not-run--the-fabric-half-is-still-owed)'s
debt paid; and the slice-3 exercise re-run — with a second engine attached, as
[I.7](#i7-the-recovered-fabric-re-verified-against-the-moved-binding--pass) said it would be.

> ✅ **Closed 2026-08-07** — `retap` was run and passed; see [Appendix P](#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07).
> The paragraph below is left as written because it is the record of what was true then.

**Still open (as of this appendix):** `retap` itself is *still* never called (it needs a deliberately root-owned tap
to recover from); [G.9](#g9-not-run--recorded-as-unknown-not-as-pass)'s two break-pass
scenarios are unrun — ⚠️ **"still want a host without a live cluster" was already wrong when
this was written**, and the two do not share a blocker; see
[M.7](#m7-a-correction-this-appendix-inherited-the-g9-blocker-was-lifted-three-days-before-it-was-restated)
— and **slice 5b** — the fidelity case, a
cloud image on `-M q35` with cloud-init — has not started.

## Appendix L — slice 5b's first finding, before a line of it was built: the two tools could never agree, 2026-08-05

Slice 5b adds a **third named instance** (`edge`) and, for the first time, a **static spec
file** that has to name its own MAC. Deriving what that spec needs — rather than writing it
and finding out — turned up a defect in two committed tools that three slices had walked past.

### L.1 The comment said one thing; the code did another

`fabric.sh tap <name>` carried this, verbatim:

```bash
# Deterministic MAC + address, derived from the name so reruns are stable.
n=0; [[ -r "$STATE/dhcp-hosts" ]] && n="$(wc -l < "$STATE/dhcp-hosts")"
IDX=$(( n + 1 ))
MAC="$(printf '06:00:ac:47:00:%02x' "$IDX")"
```

**Nothing in that block reads `$NAME`.** The MAC came from the *line count* — from the order
taps happen to be created. `api1` was `06:00:ac:47:00:01` only because it was always made
first. Bring up a subset, or add an instance ahead of it, and every name shifts.

### L.2 The half that actually bites

`lab-fc.sh` — slice 4's tool, the one that is *supposed to consume these taps* — has hashed
the instance name since the day it was written:

| name | `fabric.sh` reserved | `lab-fc.sh` would set |
|---|---|---|
| `api1` | `06:00:ac:47:00:01` → 10.71.0.101 | `06:00:ac:47:f1:f7` |
| `api2` | `06:00:ac:47:00:02` → 10.71.0.102 | `06:00:ac:47:e9:b6` |

**The two committed tools could never agree**, and the failure is silent by construction: the
fabric reserves a lease *against a MAC*, the VMM *sets* the MAC, and when they differ nothing
errors. The guest takes a dynamic lease from the pool while dnsmasq goes on answering `api1`
with `10.71.0.101` — an address nothing holds. A record that outlives its subject, invisible
from either tool alone, and only observable by booting a guest and asking a **third party**
what its name resolves to.

**Why three slices missed it.** Slices 1, 2, 3 and 5a all hand-wrote the microVM's
`config.json` with the positional MAC. `lab-fc.sh` had **never been pointed at a `fabric.sh`
tap** — Appendix H booted it with no network at all. Every run was green, and the seam
between the two tools had simply never been crossed.

### L.3 The fix, and which half of it is the contract

- **MAC ← hash(name)**, the same formula `lab-fc.sh` already used, so the two agree by
  construction and order stops mattering.
- **Address stays first-come.** A hash into a /24 collides, and a collision here is two
  guests fighting over one lease. It is recorded in `dhcp-hosts` and served by DHCP, so
  nothing needs to predict it — **the NAME is the contract, never the address.** Anything
  that hard-codes `10.71.0.10x` is asserting something this fabric does not promise.
- **Both tools gained a read-only `mac <name>` verb** — no tap, no root. Consumers *ask*
  instead of guessing, and the cross-tool invariant becomes checkable in CI. An invariant
  only verifiable on a host that can create taps is an invariant that drifts.
- `tap` now **refuses a name that already holds a reservation** and points at `retap`, rather
  than appending a second, contradictory entry.

### L.4 The test, and why it is not a string comparison

[`tests/test-fabric-mac-derivation.sh`](examples/micro-cloud/tests/test-fabric-mac-derivation.sh)
drives **both real tools' `mac` verb** over eight names. It does not re-implement the formula
and it does not grep the sources: a test that transcribes the algorithm passes when both
copies are wrong the same way, and a test that greps for `md5sum` fails when someone improves
it. Ask each tool what it would *do*; compare the answers.

Four assertions, each observed failing:

| injected defect | which assertion bit |
|---|---|
| `fabric.sh` back to positional (**the original defect, re-injected**) | agreement |
| `lab-fc.sh` drifts by one hex offset | agreement |
| one tool returns a constant | agreement |
| **both tools return the same constant** | **collision** — agreement and order-independence both passed happily |

That last row is why the test has four assertions instead of one. Two tools that agree can
still both be wrong, and only the collision check and the explicit control (`api1` and `api2`
must derive *different* MACs) can see it.

### L.5 The blast radius, mapped before the edit and not after

`git grep` for the addresses and the MAC prefix first, then classify — five files, of which
**one was a live landmine**: [`test-two-engines-one-fabric.sh`](examples/micro-cloud/tests/test-two-engines-one-fabric.sh)
hand-wrote `06:00:ac:47:00:01` and `:02`, the fabric's *old positional* values. They stopped
being right the instant the derivation changed, and the test would have gone on passing its
DHCP assertion on dynamic leases while its name-resolution assertion failed for a reason
nobody would have connected to this change. It now **asks the fabric** — the consumer pattern
the new verb exists for.

The addresses did not move (`api1` first still gets `.101`), so the dated appendices remain
accurate records. Only the MACs changed.

## Appendix M — slice 5b, the fidelity case joins the fabric, 2026-08-06

A stock Debian 12 cloud image on QEMU `-M q35` — real firmware, cloud-init, systemd, a full
network stack — booted on a `fabric.sh` tap **beside a Firecracker microVM**, took the lease
the fabric had **reserved** for it, and reached that microVM **by name**. `sudo bash
tests/run-all.sh` → **5 passed · 0 skipped · 0 failed**.

### M.1 The run

```text
  - cached MAC checked against its subject: edge.toml == fabric.sh mac edge == 06:00:ac:47:09:03
  - fabric reserved: api1=10.71.0.101  edge=10.71.0.102  (both from ONE verb)
  - api1: created and started through lab-fc.sh, not a hand-written config
  - edge: created from edge.toml and started; one serial reader attached and confirmed alive
  - taps: addressless and uid-1000 owned, with a q35 cloud VM and a microVM attached
  - edge holds its RESERVED lease 10.71.0.102 — the MAC in edge.toml reached the guest
  - edge resolved api1 -> 10.71.0.101 and reached it BY NAME, across the fidelity gap
  - teardown: ours all gone; calico binding, pod veth count and ip_forward unchanged
PASS
```

### M.2 What it establishes that 5a could not

5a compared two engines chosen to be **alike**: same ELF kernel, same raw ext4, no firmware,
no init system. It could not distinguish *"the fabric works"* from *"the fabric works for
stripped guests"*. Here the guest shares **nothing** with the microVMs but the bridge —
different image format, different firmware, different init, 4× the memory, a boot three
orders of magnitude slower — and the attachment is still
`-netdev tap,ifname=…,script=no`: a pre-made tap, by name, from the same fabric verb, with
neither VMM privileged. **§18.4's network-attachment row holds at the far end of the
fidelity axis**, which is the strongest form of the claim available on one host.

**The reserved lease is the load-bearing assertion**, and it is the one that is easy to fake:
a guest that *misses* its reservation still gets a `10.71.0.x` from the same pool, so a
subnet regex would have passed while the point failed. `edge` holds **`10.71.0.102`, the
address `fabric.sh` recorded for it** — which means the MAC written in a static spec file
reached the guest and matched the reservation. That is
[Appendix L](#appendix-l--slice-5bs-first-finding-before-a-line-of-it-was-built-the-two-tools-could-never-agree-2026-08-05)'s
fix demonstrated end to end rather than in a unit test, and `api1` was booted **through
`lab-fc.sh`** — the first time any slice has pointed that tool at a fabric tap.

### M.3 Seven defects between the harness landing and the harness passing — none in the lab

The fabric, the taps, dnsmasq, Calico coexistence and both VMMs were right the whole way.
Every failure was in the **test harness** or in a **phase tool**, and each is recorded
because the shapes recur:

| # | defect | shape |
|---|---|---|
| 1 | the harness never told `lab-fc.sh` where the pinned firecracker lived | the tool refused correctly; the caller was wrong |
| 2 | the EXIT trap reaped the fabric and the edge VM but **not `api1`** | a partial trap leaks; the *next* run then died two failures downstream |
| 3 | the trap killed `lab-fc.sh start`, not the VM — **firecracker outlived it** | killing the wrapper is not killing the VM; use the lifecycle verb |
| 4 | the console file could not be created by the unprivileged reader | and the boot timeout would then have blamed **the guest** |
| 5 | **`lab-vm.sh inspect` exited 1 with no output for every running VM** | a running QEMU locks its disk; `qemu-img` fails; a bare assignment from a pipeline under `set -e` dies silently |
| 6 | **a `: ` in a `runcmd` cancelled every `runcmd`** | a bare YAML scalar is a *plain* scalar; `cc_runcmd` got a mapping and refused, on a VM that booted perfectly |
| 7 | `chpasswd: {list: \|}` deprecated since cloud-init 22.3 | the whole document reads as schema-invalid |

**#5 and #6 are real tool bugs that no green suite could see.** `inspect` is the verb anyone
would reach for on a running VM, and it failed with *no message at all*. A colon-space is
ordinary shell (`echo "x: $y"`, `awk -F': '`), and its consequence was a machine that booted
and silently ignored every command it had been given. Both are now guarded by tests that
**parse or execute rather than grep** — a `grep '- sh -c'` passes happily on the broken
user-data, because the bytes look perfect and only the *parse* is wrong.

### M.4 The harness had to be made honest before it could be made to work

Three of the seven produced *true sentences about the wrong subject*, which cost more than
the failures themselves:

- *"edge never reached cloud-init's runcmd within 240s"* — false; the **reader** had died.
- *"api1 took no DHCP lease"* — false; api1 was still inside `udhcpc`, 0.5 s behind because
  of [J.3](#j3-the-headline-that-was-false)'s i8042 probe. The engines never arrive together,
  so any instant-sampled assertion about two VMMs is a race by construction.
- *"lab-vm.sh inspect did not report a serial socket path"* — true, useless, and unfixable
  without another root run, because the line that produced it discarded stderr **and** piped
  a command whose status was the gate.

The messages now **measure which silence they are in**: zero bytes captured means the reader
or the VM produced nothing; N bytes with no marker means it booted and cloud-init did not
reach the `runcmd`. Opposite fixes; the old message only ever described the second.

### M.5 One false alarm, and the cheap guard that ends it

A run that reproduced the *fixed* cloud-init failure turned out to predate the fix by
**14 minutes** — the guest's own console still printed `chpasswd.list: DEPRECATED`, a string
the fix had removed. The evidence was in the artifact, not in anyone's memory of what was
merged. Checking `git log --oneline -1` before a four-minute boot costs one line and settles
it; the working tree is a cache like any other.

### M.6 What slice 5 leaves closed, and what it does not

**Closed:** both halves of 5a and 5b; §18.4's seam table with the network-attachment row
proven at both ends of the fidelity axis; decision E as §8.3 shape **(b)**
([K.2](#k2-decision-e-answered--184s-table-filled-in-from-what-the-two-lifecycles-needed));
Appendix L's MAC agreement demonstrated on a booted guest.

> ✅ **Closed 2026-08-07** — see [Appendix P](#appendix-p--retaps-first-privileged-run-the-test-failed-and-that-is-the-finding-2026-08-07).
> Left as written: an appendix records what was true when it was written.

**Still open (as of this appendix):** `retap` is *still* never called — it needs a deliberately root-owned tap to
recover from; [G.9](#g9-not-run--recorded-as-unknown-not-as-pass)'s two break-pass scenarios
are unrun — ⚠️ **but not for the reason this line gave.** It said they "want a host without a
live cluster", which [G.9's own addendum](#g9-not-run--recorded-as-unknown-not-as-pass) had
already retired on 2026-08-03: a nested QEMU guest with a disposable microk8s **is** such a
host. And the two scenarios do not share a blocker at all — see
[M.7](#m7-a-correction-this-appendix-inherited-the-g9-blocker-was-lifted-three-days-before-it-was-restated);
and **slice 5c (vsock)** is scoped but not started,
with its own assumption already retired (the lab's kernel has `CONFIG_VSOCKETS=y`) and its
real work identified as a **guest agent**, not plumbing.

### M.7 A correction this appendix inherited: the G.9 blocker was lifted three days before it was restated

*Added 2026-08-06, prompted by the question "could this not be done via a throwaway microk8s
nested inside QEMU?" — which is what [G.9](#g9-not-run--recorded-as-unknown-not-as-pass)
already says, in an addendum dated **2026-08-03**.*

The answer is **yes**, and it has been yes for three days. G.9's bullet *"deferred to a host
without a live cluster"* is followed immediately by a paragraph retiring exactly that
constraint: *"the host without a live cluster need not be another machine — a nested QEMU VM
from phase 2 can BE it."* Every downstream restatement dropped the paragraph and kept the
bullet: [§14](#14-build-order--vertical-slices) row 3,
[K.5](#k5-what-slice-5a-leaves-closed-and-what-it-does-not), M.6 above, and
[`DEFERRED.md`](examples/micro-cloud/DEFERRED.md) all said the scenarios *"want a host without
a live cluster"* flatly, and this appendix — written 2026-08-06 — copied it forward again.

**This is the plan's own bug class #1, committed against a document instead of a host.** A
summary is a cached copy of a fact, and none of the four re-checked their subject. It is also
the sharper variant: the cache was not *stale*, it was **wrong on the day it was written**,
because nothing links a summary back to what it summarises. No tool catches this —
`link_check.py` verifies the link to G.9 resolves, not that the sentence around it is still
true.

**And the restatement hid a second error: the two scenarios never shared a blocker.**

| scenario | what it actually needs | can it run on this host today? |
|---|---|---|
| give a tap an address on purpose and watch it become a candidate | a live Calico that may be broken + `CAP_NET_ADMIN` | **no** — this one is the nested-VM job |
| DHCP pool exhaustion (`.100–.200` = 101 leases) | a **shrinkable range** | **yes** — it needs no cluster at all |

`DHCP_LO`/`DHCP_HI` were bare assignments in [`fabric.sh`](examples/micro-cloud/fabric.sh),
not `${VAR:-default}`, so shrinking the pool meant editing the file — that is the *"or a
config change"* §14's row 3 mentions and every later summary dropped. Exhausting a small pool
on `br-mc0` touches only our own dnsmasq and our own guests; it reaches nothing Calico owns.
**The cheaper of the two deferred scenarios had been runnable here all along, behind a
two-line change.** *(Made, and the scenario run, the same day — [M.8](#m8-the-cheaper-half-of-g9-built--and-the-defect-the-knob-uncovered-2026-08-06).)*

**What the nested run can and cannot claim.** It proves the *mechanism* — does an addressed
tap enter Calico's candidate list and win? — which is precisely what
[G.3](#g3-f7s-ordering-rule-does-not-explain-f6--the-correction) says is unexplained. It does
**not** predict what *this* host's Calico would do, because candidate ordering depends on
which interface names exist (`lxdbr0` at index 9 vs `incusbr0` at index 17 —
[F.8](#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose)), and a guest has
neither. So the nested experiment must enumerate **its own** candidate set rather than reuse
the host's, and it must record the Calico version it observed: the `^br-.*` exclusion and the
index ordering are v3.28.1 facts, and microk8s bundles whatever its channel ships. A result
transferred from a different Calico version would be the same cached-fact mistake one layer
down.

Three further practicalities, none blocking: autodetection re-runs on a **60-second poll**
([I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)), so
the experiment waits rather than only restarting `calico-node`; snapd + Kubernetes + Calico
wants roughly 4 GiB and ~10 GiB of disk; and neither scenario needs a microVM, so **nested KVM
does not have to be enabled** — the guest's own dummy interfaces and DHCP clients suffice.
The harness shape already exists: a cloud image driven by cloud-init on a `fabric.sh` tap is
what [`edge.toml`](examples/micro-cloud/edge.toml) and slice 5b just built and proved.

### M.8 The cheaper half of G.9, built — and the defect the knob uncovered, 2026-08-06

> ✅ **STATUS: GREEN at root, 2026-08-06.** Two runs. The first failed its ninth assertion
> and *the fabric was right* ([M.8.5](#m85-the-first-root-run-the-teardown-assertion-caught-its-own-author));
> both defects were in the harness. The second, after the fixes, passed every assertion:
>
> ```text
>   - layer 1 ABSORBED: the 5th reservation is refused by name, before the tap exists
>   - layer 2: the single dynamic address 10.71.0.100 went to the first unreserved client
>   - layer 2 HALTED (honest): the second unreserved client got no lease at all
>   - layer 2 ABSORBED: with the dynamic pool empty, r1 still received its RESERVED 10.71.0.101
>   - safety: every leased address stayed inside its namespace
>   - clients reaped before teardown — nothing of this test's left in the mc-* namespace
>   - teardown: calico binding and pod veth count unchanged
> PASS: the DHCP pool exhausts honestly at both layers …
> ```
>
> The sixth line is the one the first run bought: an assertion that did not exist until
> `fabric.sh down` refused to call teardown clean while the harness's own veths were on the
> bridge.

[M.7](#m7-a-correction-this-appendix-inherited-the-g9-blocker-was-lifted-three-days-before-it-was-restated)
established that DHCP exhaustion never needed a cluster-free host, only a shrinkable range.
Making the range shrinkable took two lines. What it *uncovered* took more, and is the part
worth keeping.

#### M.8.1 The knob, and a latent defect sitting behind it

`DHCP_LO`/`DHCP_HI` became `MC_DHCP_LO`/`MC_DHCP_HI`. That alone would have been a silent
trap, because the reservation address was computed one line at a time from a **constant**:

```sh
IP="10.71.0.$((100 + IDX))"          # correct only while the pool starts at .100
```

Shrink or move the pool and reservations march straight **out of the range** — dnsmasq is
never told to serve them, so it never answers for them — and `tap` creates the tap anyway.
Nothing errors. The instance boots, fails to get the address its name resolves to, and the
fault surfaces somewhere else entirely. That is bug class #1 with a fuse on it: harmless
while one constant happened to match another, armed the moment anybody used the new knob.

The base now derives from `DHCP_LO`, and exhaustion is **refused before the tap exists**,
naming the pool and the count. A gate after the act is a post-mortem.

The knob also gained validation — malformed address, wrong subnet, inverted ends, a pool
containing the gateway — and that validation had its own instructive failure: written above
`die()`, every refusal printed **`die: command not found` and carried on**, sailing the bad
range past four gates. A validator that cannot fail is worse than none. It was found by
running it, not by reading it, which is the only way that class is ever found.

#### M.8.2 What the test asks, and why the obvious version proves nothing

Running out of addresses is arithmetic, not a bug. The question the ladder asks is *how* it
runs out, and this fabric can run out at **two independent layers**: reservation time (our
code) and lease time (dnsmasq). They fail differently and both are graded.

The load-bearing assertion is the **inverse of slice 5b's**. 5b established that holding
*an* address in the right subnet proves nothing — the property is holding the address the
fabric **reserved**. So: with the dynamic pool completely empty, does a reserved instance
still get *its* address?

| client | expected | rung |
|---|---|---|
| unreserved MAC, pool exhausted | **nothing at all** | HALTED (honest) |
| reserved MAC, same instant | **exactly its reserved address** | ABSORBED |

The first is the **negative control for the second**, taken from the same exhausted state.
Without it, "the reserved client got an address" is indistinguishable from "the pool was
never actually full" — the all-PASS matrix that checks nothing. The test also confirms the
override reached **dnsmasq's own cmdline**, because a run against the default 101-address
pool would exhaust nothing while looking equally busy.

#### M.8.3 The clients are namespaces, and that is the safety property

No VMs. Each fake guest is a veth pair: the host end is enslaved to `br-mc0` and stays
**addressless**, the far end is moved into its own netns, given a MAC, and runs a real
`busybox udhcpc`. The leased IPv4 therefore lands **inside a namespace**, where Calico's
first-found autodetection — a 60-second poll ([I.4](#i4-the-finding-that-outlives-the-migration--autodetection-is-a-60-second-poll)),
not merely a restart-time scan — cannot see it. F.7.1 rule 2 is satisfied *by construction*
rather than by naming discipline, and the test asserts it afterwards rather than assuming
it. A real client also matters: a hand-rolled DISCOVER would test the harness's idea of
DHCP, while `udhcpc` is what a busybox guest actually runs.

#### M.8.4 What it does not close

The **other** G.9 scenario — give an interface an address on purpose and watch it become a
candidate — is untouched, and is now queued as its own lab unit,
[`nested-calico-sandbox/`](examples/micro-cloud/DEFERRED.md#queued--nested-calico-sandbox-a-disposable-cluster-to-break-on-purpose):
a disposable cluster is a safe host for the **whole** slice-3 break pass, including `retap`,
which is still never called. Break coverage for slice 3 is now **4 of 5**.

#### M.8.5 The first root run: the teardown assertion caught its own author

The run produced eight `note` lines and one `FAIL`, and every line about the **fabric** was
what M.8.2 predicted:

```text
  - layer 1 ABSORBED: the 5th reservation is refused by name, before the tap exists
  - layer 2: the single dynamic address 10.71.0.100 went to the first unreserved client
  - layer 2 HALTED (honest): the second unreserved client got no lease at all
  - layer 2 ABSORBED: with the dynamic pool empty, r1 still received its RESERVED 10.71.0.101
  - safety: every leased address stayed inside its namespace
FAIL: fabric.sh down reported failure
```

**`down` was correct and the test was wrong**, which is the most useful outcome available.
`down` asserts that no `mc-*` interface survives teardown; the fake clients are named
`mc-cli1..3`; and the trap that reaped them ran *after* the explicit `down` in the test
body. So `down` reported three interfaces this test had leaked onto the bridge.

That naming was deliberate — putting the clients inside the `mc-*` namespace `down` polices
was chosen *so* a leak would be caught. It was, on the first real exercise, against its
author. [§7.2](#72-teardown-is-a-test-not-a-cleanup)'s *"teardown is a test, not a cleanup"*
has now caught a live-cluster incident ([F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel))
and a harness bug; a `down` that merely returned 0 would have hidden both.

**Then the leftovers pointed at a second, worse defect.** After the failure the interfaces
were *still there* — so the EXIT trap had reaped nothing. The cause:

```sh
got1="$(dhcp_ask 1 …)"      # command substitution == subshell
```

`dhcp_ask` recorded each client with `CLIENTS+=("$id")`, and a command substitution runs in
a **subshell** — so every append went to a copy that died with it. The parent's array was
empty for the whole run, the trap iterated over nothing, and three veths plus three network
namespaces survived on a live host. The bookkeeping had been perfect and invisible.

Both fixes are structural rather than patches:

- `dhcp_ask` sets a global instead of printing, so no subshell stands between it and its
  own records;
- `reap_clients` **derives** the list from the kernel (`ip -o link show`, `ip netns list`)
  after walking its own — an in-memory list of what we created is a cached fact, and a run
  that dies early leaves no bookkeeping at all. This second pass would have caught the
  subshell bug on its own, and it cleans up after a crash;
- it is called from the **body before `down`**, not only from the trap.

And a third, smaller: the `FAIL` said *"see /tmp/tmp.XXXX/log"* and the trap then **deleted
that directory on the way out** — sending the reader to diagnose a run whose evidence the
harness had destroyed. The scratch dir is now kept on any non-zero exit, not only on a
verdict-less one.

**None of the three was findable without running it.** Static gates were green — shellcheck
clean, `bash -n` clean, the unprivileged path SKIPping correctly — and the sandbox denies
both `sudo` and `unshare -r`'s `uid_map` write, so no rehearsal was possible either. This is
the plain case for handing the privileged run to the operator rather than reasoning about
what it would have done.

**The re-run passed every assertion**, including one that did not exist before this failure:
`clients reaped before teardown — nothing of this test's left in the mc-* namespace`. The
first run did not merely find bugs; it bought an assertion. That is the difference between a
failure that is debugged and a failure that is *learned from* — and it is why §7.2's
teardown-is-a-test is worth more than a cleanup that returns 0.

---

## Appendix N — slice 5c, vsock: the first channel that is not the fabric, 2026-08-07

Every seam row before this one is network-attached, and the fabric is the common seam that
made §8.3 shape **(b)** defensible. vsock has no bridge, no lease, no name, no DNS. The
question ([DEFERRED.md](examples/micro-cloud/DEFERRED.md)) was whether the seam story
survives a channel where the **guest** contract is byte-identical and the **host** API
differs in kind. It does — and the differences turned out to be sharper, and to have one
consequence nothing reports.

Harness: [`tests/test-vsock-both-engines.sh`](examples/micro-cloud/tests/test-vsock-both-engines.sh).
**Unprivileged, and with no fabric up** — the test asserts `br-mc0`'s *absence* before it
measures anything, because a result obtained beside a live fabric would say nothing about
independence from it.

### N.1 The gap was userspace, which is the opposite of what "is vsock available?" suggests

Everything that sounds like it would block this was already fine, re-derived on 2026-08-07
rather than read from the 2026-08-05 scoping note:

| | state |
|---|---|
| `/dev/vhost-vsock` | `root:kvm 0660`, uid 1000 is in `kvm` → usable unprivileged, like `/dev/kvm` |
| host modules | `vhost_vsock`, `vsock`, `vmw_vsock_virtio_transport_common` loaded |
| QEMU | `vhost-vsock-device` on the **virtio-bus** — so it works on `-M microvm`, not only q35 |
| the lab's kernel | `__initcall__kmod_vsock__` + `__initcall__kmod_vmw_vsock_virtio_transport__` — an initcall symbol exists only for **built-in** code, and Firecracker boots with no initramfs, so a modular driver would be one that never loads |
| **the guest rootfs** | ⛔ `strings api1.ext4 \| grep -ci vsock` = **0**. busybox+musl, and busybox `nc` has no `AF_VSOCK` |

So the work was a **static agent** ([`vsock-agent.c`](examples/micro-cloud/vsock-agent.c),
musl, 43080 bytes) and a way to get it into an image.

### N.2 Getting a binary into an ext4 with no loop mount and no sudo

`mount -o loop` and `mknod` are unavailable here (blocked even `--privileged`), and putting
"add one file" behind root would gate this slice like every other.
[`make-vsock-rootfs.sh`](examples/micro-cloud/make-vsock-rootfs.sh) uses **`debugfs -w`**,
which writes into an ext4 without mounting it — the same family of trick as `mke2fs -d` in
`export-rootfs`, and the reason that path was chosen (§6).

Three things it does that are not decoration:

- **It copies first and `e2fsck`s the copy.** Every break-pass image ends with a guest
  killed mid-run, which leaves a dirty bitmap that debugfs refuses to open. Repairing the
  *original* would silently rewrite the artifact other tests boot.
- **It reads the agent back out and compares bytes.** `debugfs` printing `Allocated inode`
  is the mechanism; *the image contains the binary I built* is the outcome, and a wrong
  path, a truncated write or a failed `chmod` all leave the first one true.
- **It compiles the agent twice and requires the results to be identical.** The agent has a
  `MC_VSOCK_NO_UAPI` fallback that restates `struct sockaddr_vm` for hosts without
  `linux-libc-dev`. A hand-written ABI that had drifted would still compile, still run, and
  bind the wrong address *inside the guest*. So when the real header is present, both are
  built and `cmp`'d. (Measured: byte-identical.)

### N.3 The launcher, and a comment that turned out to be a measurement

The agent must **not** be a busybox `respawn` entry. `init` runs every `sysinit` action to
completion before starting any `respawn` one, and `mc-probe.sh` is a sysinit action that
blocks for up to ~60 s — its *slowest* path, because slice 5c gives the guest no NIC at all.

That was written first as a comment. Then it was run:

| inittab | console |
|---|---|
| `::sysinit:… mc-vsock-agent &` (shipped) | `MC-VSOCK-AGENT LISTENING` at line **260**, `SLICE3-BEGIN` at **261** |
| `::respawn:/sbin/mc-vsock-agent` (control) | `SLICE3-BEGIN` at 260, `SLICE3-END … uptime=40.59s` at 270, `LISTENING` at **271** |

At t=12 s the control guest answered `nothing in the guest is listening on port 1234`. **The
channel that exists to be independent of the fabric would have spent its first 41 seconds
waiting on the network stack.** The test now asserts the console ordering, so the claim is
checked rather than explained.

### N.4 The seam, measured in both directions

| | Firecracker | QEMU `-M microvm` |
|---|---|---|
| **guest** | `AF_VSOCK`, CID + port | `AF_VSOCK`, CID + port |
| guest binary | the same 43080 static bytes, no engine `#ifdef` anywhere | ← identical |
| guest reply | `MC-VSOCK-AGENT name=vs-fc cid=42 peer=2:1073741824 …` | `MC-VSOCK-AGENT name=vs-qemu cid=43 peer=2:741291667 …` |
| **host** | a **unix socket** + a text handshake: `CONNECT <port>\n` → `OK <n>\n` | a **real `AF_VSOCK`** socket: `connect((cid, port))` |
| host names the guest by | **which socket file it opened** | **a CID** |

The record *shape* is identical — asserted as a shape, not as equal strings, since uptime
and the ephemeral peer port cannot match and demanding it would be asserting a coincidence.
Both guests see the host as **cid 2** (`VMADDR_CID_HOST`), the one number that is the same
on both sides of the seam.

So the hypothesis holds, and vsock **is** a sharper row than `stop`: there the intent
matched and the channel differed; here the guest-side contract is byte-identical while the
host-side API differs in kind. Two host implementations, one guest implementation — which
is what shape (b) predicts, arrived at from a channel that has nothing to do with the fabric.

| seam | Firecracker | QEMU | shape it argues for |
|---|---|---|---|
| **vsock** | unix socket + `CONNECT` handshake; `uds_path` | raw `AF_VSOCK`; `guest-cid=` | **identical guest contract, host APIs different in kind** |

### N.5 The consequence nothing reports: `guest_cid` is not one thing

DEFERRED asked the sharpest version — give two guests the same CID and find out whether the
second is refused or silently answers for the first (the
[seam-answers-for-the-wrong-instance](#appendix-d--where-the-kubernetes-actually-is-2026-08-01)
class, which has bitten this repo through a vbmc port collision). The answer **depends on
the engine**:

| experiment | result | rung |
|---|---|---|
| two QEMU guests, same `guest-cid=43` | the second **never starts**: `vhost-vsock: unable to set guest cid: Address already in use`, refused at device creation | **ABSORBED** |
| a Firecracker guest with `guest_cid: 43` **beside** the live QEMU guest on 43 | **both run.** Each host API still reaches the guest it addressed | — |
| a third guest, also 43, under Firecracker | also runs; three guests believe they are CID 43 at once | — |

QEMU's `guest-cid` is an allocation in the **host kernel's** vhost-vsock namespace, and the
kernel protects it. Firecracker is a *userspace* vsock device: `guest_cid` is a number it
hands the guest, with no presence in that namespace at all — "which guest?" is answered by
which unix socket you opened. **The same field name means a host-global resource in one
engine and an advisory label in the other, and nothing anywhere says so.**

A seam abstraction that treated `guest_cid` as one field would therefore be wrong in a way
that produces no error: it would inherit QEMU's collision safety on paper while Firecracker
silently provides none. Recorded here rather than discovered later.

The only reason the cross-engine case is checkable at all is that the agent reports its own
`mc_name`. Without it, "cid=43 answered" is indistinguishable between three machines —
which is precisely how a wrong-instance answer hides.

### N.6 Three smaller findings — one of them in the harness, found by breaking it

- **An assertion that could never fire.** The CID-collision check backgrounded the second
  QEMU and called `wait`. A guest that is *refused* exits immediately, so the happy path
  looked right — but a guest that successfully takes the CID keeps running, `wait` blocks
  forever, and the assertion written for exactly that case is unreachable. Injecting a free
  CID (44) proved it: the run **timed out at 300 s with no verdict at all** instead of
  failing. It is now foreground under `timeout 20`, and rc=124 *is* the regression. "An
  assertion never observed failing is not known to work" — this one had been green twice.

- **Firecracker's `uds_path` is capped by `SUN_LEN` (~108 bytes).** A scratch dir under the
  agent's own `TMPDIR` was too long and Firecracker refused with `path must be shorter than
  SUN_LEN` — immediate and honest, but it reads as a vsock problem when it is a path-length
  problem. The test uses a deliberately short `/tmp/mcvs.XXXX`, and says why.
- **A refusal has to be checked for its REASON.** The first draft of the CID-collision test
  pointed the second QEMU at the *live* guest's disk image. QEMU refused it — `Failed to get
  "write" lock` — so the process did exit non-zero and the collision test "passed" without
  ever reaching the vsock device. The assertion that demands the refusal name the CID caught
  it. Exit status alone would have shipped a green test that proved nothing.

### N.7 What is closed, and what is not

**Closed:** §18.4 gains a vsock row from what the two host APIs actually needed; the guest
rootfs has vsock-capable userspace for the first time; the console is demoted from *sole
witness* to *one witness*; and slice 5c's break pass has its most interesting scenario
(shared CID) answered with a ladder rung per engine.

**Not closed, and deliberately out of scope** (decision C says start with SSH): replacing
SSH, and MMDS. **5c's break list is now covered** — see [N.8](#n8-the-break-pass-micro-clouds-first-chaos-matrix-and-a-critical-that-is-not-ours).

### N.8 The break pass: micro-cloud's first chaos matrix, and a critical that is not ours

[`tests/test-vsock-chaos.sh`](examples/micro-cloud/tests/test-vsock-chaos.sh) — **six rows**
(five at first writing; the stalled-client row landed 2026-08-08), unprivileged, graded on
`CLAUDE.md`'s ladder. It is the first chaos harness this lab has
had at all.

| row | fault | rung | evidence |
|---|---|---|---|
| **control** | none | ABSORBED | the unbroken channel answers. Without it, "the harness reported failures" is indistinguishable from a system that never worked |
| guest network | `set_link down` under a live agent | **ABSORBED** | the guest held `10.0.2.15/24`, the link was cut, **vsock kept answering** |
| host channel (FC) | `rm` the `uds_path` under a live guest | **STRANDED** | guest still RUNNING and healthy; host gets a clean `ENOENT`; the API **refuses** to rebuild it |
| the VMM | killed with the channel in use | **HALTED** | both engines fail in **0 s** with a named errno — neither hangs |
| CID namespace | a guest asks for CID 0/1/2 | **ABSORBED** | refused at device creation: `guest-cid property must be greater than 2` |

**The matrix is a regression guard, not a pass/fail on criticals.** One row *is* critical
and it is **not our defect** — it is how Firecracker's vsock behaves. Failing forever on an
upstream property trains the reader to ignore the file, so every row declares the rung it
was measured at and the test fails when a rung **moves**, in either direction.

**The critical, graded after attempting the recovery the system offers** (which is what
makes "critical" mean *nothing can be done* rather than *the first thing I looked at was
still wrong*): with the socket unlinked, `PUT /vsock` on Firecracker's live API answers

> `{"fault_message":"The requested operation is not supported after starting the microVM."}`

So **one `rm` permanently severs a healthy, running guest.** And the other half of the row
is why it belongs in this appendix rather than a bug tracker: **QEMU cannot suffer this
fault at all.** Its host end is a kernel object with no name in the filesystem — there is
nothing to delete. [N.4](#n4-the-seam-measured-in-both-directions)'s asymmetry does not
stop at the API's shape; it extends to *what can go wrong*, and a seam that unified the two
would be unifying two different failure domains.

**The fabric row, honestly scoped.** DEFERRED asked for "tear down `br-mc0` with the agent
connected". `set_link down` tests that *property* more severely and without root — it
removes the link from the guest's view entirely, a superset of losing the bridge beneath a
tap — so the property is measured. What is **not** exercised is the fabric's own teardown
*code*, and the matrix says so rather than letting the stronger fault imply the weaker one.

**Named as not covered**, because a layer with no scenario is a layer nobody has watched
fall over: CID **exhaustion** (the space is 2³² and cannot be exhausted the way a DHCP pool
can — there is no analogous failure to grade, which is itself the answer); the fabric's
teardown path; and a channel that is **slow rather than stalled** — vsock has no shaper the
way a NIC does. *(The **stalled** end of that spectrum was covered 2026-08-08. The gap's
original wording — "the host reads but never replies" — pointed the wrong way: the GUEST
agent listens and the host is the client, so an injector built to that sentence would have
looked injected and measured nothing.)*

**Three harness defects, each found by breaking something on purpose.**

The first is the one worth reading. The network row graded **ABSORBED even when its
injector was replaced by a no-op** — because vsock answers whether or not the network went
away, so the verdict never depended on the fault. `{"return":{}}` from QMP says only that
*QEMU accepted the command*; the outcome is *the guest losing carrier*, and those are
different claims. The fix is a **link timeline in the image** (`mc_link=1`, an MC-LINK line
every 2 s from boot), and the row now requires `carrier=1` **before** and `carrier=0`
**after**. mc-probe.sh's own WATCH mode could not serve: it runs behind a 40-iteration peer
loop, so its first line lands ~80 s in — and depending on it would couple the matrix to
mc-probe.sh's internals, which is a mechanism dependency where an outcome was wanted.

The second is [this repo's own documented bug shape, recurring](#appendix-m--slice-5b-the-fidelity-case-joins-the-fabric-2026-08-06):
`boot_qemu` was called in a **command substitution**, so `PIDS+=` updated a subshell's copy
and the EXIT trap reaped nothing — exactly the `dhcp_ask` defect in the DHCP-exhaustion
test. It was found because a leaked guest kept holding a CID, which then blocked the **next**
run's control guest. Two fixes: the PID is published in a variable rather than echoed, and
the CIDs are **derived from the shell's PID** instead of written down — a harness that
hard-codes a CID is vulnerable to the very collision [N.5](#n5-the-consequence-nothing-reports-guest_cid-is-not-one-thing)
documents.

**And two more caught by assertions that demand a failure name its reason:**
the reserved-CID row first ran QEMU without `-enable-kvm`, so it died on *"CPU model 'host'
requires KVM"* **before** ever validating `guest-cid` — the row graded **LIED** and refused
to call an uninjected fault absorbed. And the row now carries a control: a *legal* CID must
**not** produce the refusal, or it would pass on a QEMU that rejects every `guest-cid` for
an unrelated reason.

**§6 asserts the rungs are OCCUPIED**, because zero criticals proves none of this: a
harness that breaks nothing is all-ABSORBED and one that breaks everything is
all-STRANDED, and both survive a criticals-only check. The run reports **3 absorbed, 2
not**.

---

## Appendix O — the nested-Calico experiment, run: two derived rules become measurements, 2026-08-07

`fabric.sh`'s whole safety design rests on two rules that had never been tested by
*experiment*, because testing them on this host means breaking a live cluster
([DEFERRED.md](examples/micro-cloud/DEFERRED.md)). A disposable microk8s in a phase-2 VM
removes that objection. **The lab unit `examples/nested-calico-sandbox/` is still to be
built** — what follows is the experiment run by hand, recorded so the build starts from a
measurement instead of a plan.

### O.1 The assumption most likely to sink it, retired first

Nothing here needed nested KVM (constraint 5 held). What it needed was microk8s to install
and Calico to come up in a `lab-vm.sh` guest, and that was measured before anything was
designed around it:

| | |
|---|---|
| image | the cached `debian-bookworm-x86_64.qcow2`, `qemu-img resize`d to 16 G (3 G virtual is not enough; cloud-init's `growpart` handles the rest) |
| VM | `--memory 4G --cpus 2 --network-mode user` — slirp, **no root** |
| microk8s | **v1.35.6**, installed by snap from cloud-init |
| CNI | **`docker.io/calico/node:v3.29.3`**, `IP_AUTODETECTION_METHOD=first-found` |
| guest interfaces | `lo enp0s3 vxlan.calico cali*` — genuinely its **own** set (constraint 1), with none of the host's `lxdbr0`/`incusbr0`/`docker0` |

**Two of the spike's own markers were false, and both in the safe direction.** `SPIKE-NET
FAIL` came from `ping` — slirp drops ICMP for an unprivileged user, so the *mechanism*
check said no network while the *outcome* check (`apt-get`, which is TCP) said yes; the
outcome was right. And `SPIKE-K8S-NOTREADY` plus an empty `SPIKE-CALICO-VER=` were both
`/snap/bin` not being on `sudo`'s `secure_path`: the cluster was running the whole time.
A spike that had only printed the happy-path marker would have been read as "microk8s does
not work here" and the lab abandoned on a PATH bug.

### O.2 The experiment, and the control that makes it mean something

Two dummy interfaces, both addressed and up, differing **only in name**:

| interface | index | address | matches `^br-.*` |
|---|---|---|---|
| `enp0s3` | 2 | 10.0.2.15/24 | no (the incumbent) |
| `br-decoy` | 8 | 10.99.1.1/24 | **yes** |
| `mc-decoy` | 9 | 10.99.2.1/24 | no |

Then **waited for the poll** rather than restarting `calico-node` (constraint 3 — a restart
measures the startup path only, which is the half already understood):

| t | binding |
|---|---|
| before | `local 10.0.2.15 dev enp0s3` |
| ~100 s | `local 10.0.2.15 dev enp0s3` — *still*, so one poll interval is not enough |
| ~3 min | **`local 10.99.2.1 dev mc-decoy`** — and the node annotation moved with it |

**Rule 2 is now measured.** An addressed interface became a first-found candidate and
Calico *migrated to it on its own*, with nothing restarted. That is F.6's mechanism
reproduced **on purpose**, in a guest we may destroy, instead of observed once as an outage.

But "it took the highest index" would explain that result just as well, and `br-decoy` was
also addressed. So `mc-decoy` was deleted and the binding read again:

> **fell back to `local 10.0.2.15 dev enp0s3`** — index 2 — while `br-decoy` (index 8) was
> still up and still addressed `10.99.1.1/24`.

**Rule 1 is now measured.** If ordering alone decided this, `br-decoy` would have won: it
outranks `enp0s3` on every axis the earlier round appeared to use. It was skipped, twice,
for its **name**. The `^br-.*` exclusion had until now been read out of a binary
([F.7.1](#f7-the-selection-rule-derived--and-7-already-satisfied-it)); it has now been
watched to bite, by naming a bridge the other way and watching the other one get picked.

### O.3 What this does and does not say

**Bound to its subject** (constraint 2): this is **Calico v3.29.3**. The host runs
**v3.28.1**. It is a statement about the selection algorithm at a named version, **not** a
prediction about this host — and the write-up must keep saying so, or it becomes one.

On the ordering that [G.3](#g3-f7s-ordering-rule-does-not-explain-f6--the-correction)
retracted an explanation for, there is now data rather than a story: among **non-excluded**
candidates the **later/higher index won** (`mc-decoy` 9 over `enp0s3` 2). That is consistent
with what this host is doing *right now* — and the host is a third data point nobody
recorded:

> ⚠️ **This plan says Calico's tunnel is on `enx00051b8eb138`, the physical uplink, "since
> 2026-08-04". Measured 2026-08-07: it is `local 10.216.67.1 dev lxdbr0`.** Index **47**,
> chosen over an addressed physical uplink at index **2**. So the binding has now moved
> **three** times (`incusbr0` → the uplink → `lxdbr0`), and
> [F.8](#f8-lxdbr0-is-a-candidate-and-it-outranks-the-one-calico-chose)'s prediction — that
> `lxdbr0` is a candidate which outranks the one Calico chose — came true **on its own,
> with no lab involved**. Every doc naming the uplink was a cached fact, which is exactly
> why [I.6](#i6-the-methodological-point-for-the-third-time-in-this-plan) says to re-derive
> it at pre-flight and never write it down.

### O.4 What is still owed

The measurements above are the *hard* part and they are done. The **lab unit** is not:
`examples/nested-calico-sandbox/` still needs its `.toml`, `README.md`,
`MANUAL_TESTING.md`, a `tests/` harness that asserts the two rungs above with the
delete-`mc-decoy` control included, a 00-INDEX row and a `learning-paths.toml` route. The
**CNI-layer chaos scenario** depends on that harness and has not been started. Recorded as
**not done**, not as pending-and-basically-fine.

---

## Appendix P — `retap`'s first privileged run: the test failed, and that is the finding, 2026-08-07

[`tests/test-retap-recovers-a-root-owned-tap.sh`](examples/micro-cloud/tests/test-retap-recovers-a-root-owned-tap.sh)
was written on 2026-08-06 and recorded as **UNKNOWN, not PASS**, because it needs root and
had never executed an assertion. It was run. It **failed** — at §3, its own fixture — and
the failure is worth more than the pass would have been.

### P.1 The first privileged run failed on its own fixture, and that is the result

```
  - baseline: 'sqs' can attach to the fabric's own tap — TUNSETIFF-OK mc-rt1 uid=1000  ✓
  - (the broken tap is operstate=down, which at least hints at trouble)
FAIL: REGRESSION: 'sqs' could attach to a ROOT-OWNED tap (TUNSETIFF-OK mc-rt1 uid=1000) —
      the defect retap exists to repair cannot be staged on this kernel, so §4 would pass
      without proving anything
```

§3 staged the break with a bare `ip tuntap add dev mc-rt1 mode tap`, on the theory that a
`sudo` from a root shell produces a tap "owned by nobody". **uid 1000 attached to it
without difficulty.** The kernel says why — `drivers/net/tun.c`, `tun_not_capable()`:

```c
return ((uid_valid(tun->owner) && !uid_eq(cred->euid, tun->owner)) ||
        (gid_valid(tun->group) && !in_egroup_p(tun->group))) &&
       !ns_capable(net->user_ns, CAP_NET_ADMIN);
```

With **no** owner and **no** group, both halves of the first clause are false, so the
expression is false and **any** user may attach. An **owner-less** tap is therefore *more*
permissive than a normal one, not less.

> **"Root-owned" and "owner-less" are indistinguishable in `ip link show` and behave in
> opposite directions.** Only one of them is G.4. The real defect is
> [§2675](#g4-four-defects-three-of-them-inside-the-safety-checks)'s: `SUDO_USER=root`
> made `fabric.sh tap` run `ip tuntap add … user root`, so the owner is uid **0** — a
> *valid* uid that is not the caller's — which is precisely the state `fabric.sh:246`
> refuses to create.

**The guard is what caught it**, and it is the one the test was built around: §3 exists to
assert that the broken state was actually staged, so that §4's repair means something. Had
it not been there, `retap` would have "recovered" a tap that uid 1000 could open before and
after, and the run would have printed PASS. *An assertion never observed failing is not
known to work* — this one was observed, on its first opportunity, and it fired.

Two corrections, both in the harness rather than in `fabric.sh`:

- §3 now stages `ip tuntap add … user root`, faithful to how G.4's tap was actually made.
- §3 **reads `/sys/class/net/<tap>/owner` back and requires `0` before asking the ioctl.**
  The fixture is checked, then the outcome is measured. That ordering is the whole lesson:
  the test had been asserting an outcome against a fixture it never verified.

Also corrected: two documents described the defect as "a tap created with no `user`", which
this run shows is a different state with the opposite behaviour.

### P.2 What this run left UNKNOWN (closed in P.4)

At the time: **`retap`'s own verdict.** Nothing here said the verb worked — only that the
harness now staged the state it claimed to. §4–§6 had never executed.

Two things the failed run *did* establish, incidentally: the baseline attach works
(`TUNSETIFF-OK … uid=1000` against a `fabric.sh`-made tap, so the fabric's own ownership
handling is sound), and the EXIT trap tore the fabric and the tap down cleanly on the
failure path — `br-mc0` and `mc-rt1` were both absent afterwards.

### P.3 The corrected run: `retap` works, and §5 failed on a fabric that was right

Second privileged run, same day, with §3 staging `user root`:

```
  - baseline: 'sqs' can attach to the fabric's own tap — TUNSETIFF-OK mc-rt1 uid=1000  ✓
  - broken: the tap exists, is enslaved, is up, owner uid is 0, and 'sqs' still cannot
            attach — TUNSETIFF-FAILED errno=1 (Operation not permitted)  ✓
  - repaired: 'sqs' can attach again — TUNSETIFF-OK mc-rt1 uid=1000  ✓
  - the reservation is byte-identical and still single: 06:00:ac:47:5e:b6,10.71.0.101,rt1  ✓
  - the repaired tap is addressless and on br-mc0  ✓
```

**`retap` does what it was written to do**, and it is now measured rather than read: the
defect is staged for real (EPERM from the ioctl an unprivileged Firecracker would issue),
the repair restores the one property that matters, and the DHCP reservation comes out
**byte-identical and still single** — which is the entire reason it is a separate verb from
`tap`. Three of the four assertions in [G.4](#g4-four-defects-three-of-them-inside-the-safety-checks)'s
repair story have now executed.

Then §5 failed — **and `fabric.sh` was right.** `tap` has *two* guards, and they fire in
different states:

```bash
ip link show "$TAP" … && die "$TAP already exists"                  # cheap, checked FIRST
grep -q ",$NAME\$" dhcp-hosts && die "… already has a reservation … use 'retap' to rebuild"
```

§5 asserted the **second** message while standing in the **first** one's state: after §4's
repair the tap exists, so the interface guard legitimately wins and the operator sees
`mc-rt1 already exists`. The reservation-aware message that points at `retap` is only
reachable when the reservation survives and the interface does not.

The fix is in the harness, and it is the same lesson as P.1 one level up: **the test was
asserting a message where it should have asserted an outcome.** §5 now stages *both* states
— tap-present, and reservation-without-interface (which is where an operator actually lands
when something eats a tap) — asserts each guard in the state that reaches it, and after
each one checks the property that actually matters: `grep -c ",$NAME$" dhcp-hosts` is still
**1**. Which of the two sentences the operator reads is the mechanism; not appending a
second reservation is the outcome.

**Still UNKNOWN at this point:** §5's two refusals and §6. Closed by the next run.

### P.4 The third run: green, every assertion executed

```
  - baseline: 'sqs' can attach to the fabric's own tap — TUNSETIFF-OK mc-rt1 uid=1000  ✓
  - broken: … owner uid is 0, and 'sqs' still cannot attach
            — TUNSETIFF-FAILED errno=1 (Operation not permitted)  ✓
  - repaired: 'sqs' can attach again — TUNSETIFF-OK mc-rt1 uid=1000  ✓
  - the reservation is byte-identical and still single: 06:00:ac:47:5e:b6,10.71.0.101,rt1  ✓
  - the repaired tap is addressless and on br-mc0  ✓
  - tap refuses an existing tap by name, AND refuses a live reservation by pointing at
    retap — neither appending a second entry  ✓
  - retap refuses an unreserved name, and tap refuses a reserved one — each pointing at
    the other  ✓
  - calico binding and pod veth count unchanged across break and repair  ✓
PASS
```

**`retap` is closed.** The verb added for [G.4](#g4-four-defects-three-of-them-inside-the-safety-checks)
on 2026-08-02, uncalled by anything for five days, is measured: the defect staged for real,
the repair proven by the ioctl an unprivileged Firecracker actually issues, the reservation
byte-identical, both verbs refusing the other's case in the state that reaches each guard,
and the live cluster's binding and pod-veth count unmoved across the whole run.

### P.5 The thing worth keeping from this

**Three privileged runs, two harness defects, zero defects in `fabric.sh`.** The tool was
right every time; the test was wrong twice, and caught itself both times:

| run | verdict | what it caught |
|---|---|---|
| 1 | FAIL | its **own fixture** — a bare `ip tuntap add` leaves the owner unset, and an owner-less tap is attachable by **anyone**, so the "break" was never a break |
| 2 | FAIL | itself asserting a **message** where `fabric.sh` was right: `tap`'s two guards fire in different states, and §5 stood in the wrong one |
| 3 | **PASS** | — |

A looser test would have printed PASS on run 1 and reported that a verb works when nothing
had exercised it. Both failures came from assertions written to make the *next* assertion
mean something — §3 exists so §4's repair is not vacuous — which is the whole argument for
writing the negative control first and running it rather than reasoning about it.

The second defect is the more instructive: asserting a refusal's **wording** couples a test
to which of several correct guards happens to fire. The outcome — `grep -c ",$NAME$"
dhcp-hosts` is still **1** — is true whichever message the operator sees, and is what the
guard exists to protect.

---

## Appendix Q — the sandbox packaged, G.9 closed on the real artifact, 2026-08-07

[Appendix O](#appendix-o--the-nested-calico-experiment-run-two-derived-rules-become-measurements-2026-08-07)
ran the experiment by hand and said plainly that the **lab unit was not built**. It is now:
[`examples/nested-calico-sandbox/`](examples/nested-calico-sandbox/) — spec, driver, guest
experiment, stamped findings, four tests, an 00-INDEX row and a `learning-paths` route.

### Q.1 What packaging actually bought

Not tidiness. **Three independent reproductions, and each one corrected something.**

| | |
|---|---|
| the spec's own guard | `sandbox.sh`'s resize check reported `0M -> 0M` **and passed** — it was reading the qcow2 **file's** size out of a nested JSON block instead of the disk's `virtual-size`, and writing metadata makes the file marginally bigger. A guard that could not detect the failure it existed for |
| the migration time | recorded as **180 s** from the hand-run; the first packaged reproduction converged in **15 s**, the second in **10 s**. Same image, same Calico, an order of magnitude apart |
| an `rm -rf /tmp/.` | the live test registered `dirname` of a `mktemp` **file** for recursive deletion. `coreutils` refused it — the only reason it was harmless |

The middle one is the finding. `findings.env` exists to stop a record outliving its subject,
and its **first version contained exactly that defect**: a single number that stopped being
true on the first re-run. It is now a **range**, and the tests *report* convergence time
rather than asserting a bound — because three runs of identical inputs disagreed by 18×.

### Q.2 G.9, closed on the real artifact

[G.9](#g9-not-run--recorded-as-unknown-not-as-pass) deferred one scenario on 2026-08-02:
*give a tap an address on purpose and watch it become a candidate* — refused then because
re-running F.6 meant an outage on a live cluster.
[`tests/test-fabric-tap-becomes-candidate.sh`](examples/nested-calico-sandbox/tests/test-fabric-tap-becomes-candidate.sh)
ran it, and **on the real `fabric.sh`** rather than a stand-in:

```
  - the real fabric.sh is up inside the sandbox — first time it has run on any host but this one  ✓
  - the fabric's tap is addressless, as its own rule requires  ✓
  - before: guest tunnel on 'enp0s3', fabric tap present and addressless  ✓
  - gave mc-g9 10.77.0.1/24 — deliberately violating the fabric's own addressless rule
  - G.9 MEASURED: Calico's tunnel moved onto the fabric's own tap mc-g9 once it had an address  ✓
  - host binding unchanged: local 192.168.1.106 dev enx00051b8eb138  ✓
```

**F.6's outage, caused on purpose, on the actual subject.** [O.3](#o3-what-this-does-and-does-not-say)
recorded the dummy-interface result as *partly* answering G.9 precisely because a dummy in a
guest is not a tap on `br-mc0`; that gap is now closed rather than argued away.

### Q.3 The finding only a second host could produce

`fabric.sh` died instantly inside the sandbox:

> `FAIL: dnsmasq not installed`

**It has undeclared dependencies** — `dnsmasq` and `nft` — and five days of exercising it
never revealed them, because the one machine it had ever run on happened to have both. The
sandbox spec installs `dnsmasq-base` (the binary without the service that would bind :53 and
fight the fabric's own instance) and `nftables`.

That is the argument for a second host, stated better than any reasoning could: a
portability claim nobody had tested was false, and the only way to find out was to run it
somewhere else.

### Q.4 The chaos matrix's uncovered row, closed

[N.8](#n8-the-break-pass-micro-clouds-first-chaos-matrix-and-a-critical-that-is-not-ours)
named *the fabric's own teardown code beneath a live agent* as **not covered**, on the
grounds that `set_link down` tests the property more severely but **a stronger fault does not
prove the weaker one ran**. The matrix now has that row: a guest on a real `fabric.sh` tap,
with vsock alongside, and `fabric.sh down` invoked underneath it. Root-gated, and a skip is
reported as **UNCOVERED** rather than folded into the pass.

Wiring it up cost one more instance of the day's recurring shape: the control row's
*"did the guest have an address?"* check **grepped the console once** instead of waiting, and
went red under the load of a second VM — the same eventual-state race that turned main's CI
red twice this morning, in a test written hours after that fix. It now waits.

---

## Appendix R — the CNI's break pass: the last layer gets an injection point, 2026-08-07

`CLAUDE.md`'s ladder asks for an injection point at **every layer that can fail on its
own**. micro-cloud's one chaos matrix (vsock) covered several layers and the CNI was none of
them — not an oversight, a blocker: breaking a CNI meant breaking the one this machine uses.
*(This sentence read "six rows" until 2026-08-08. The matrix had **five** graded rows when it
was written — the sixth was the conditional `fabric.sh` row that reports UNCOVERED. The count
was never load-bearing, and it had since become accidentally true, which is the worst state
for a wrong number to be in: the count is dropped rather than corrected.)*
[`nested-calico-sandbox/`](examples/nested-calico-sandbox/) removed that objection, so
this is the row that was waiting on a lab rather than on an idea.

[`cni-chaos.sh`](examples/nested-calico-sandbox/cni-chaos.sh) +
[`tests/test-cni-chaos.sh`](examples/nested-calico-sandbox/tests/test-cni-chaos.sh).

### R.1 The matrix

| layer | fault | rung | evidence |
|---|---|---|---|
| *(control)* | none | — | `pods=OK` before anything is broken |
| the CNI **process** | delete `calico-node`'s pod | **ABSORBED** | dataplane never dipped; new pod uid asserted |
| felix's **programming** | flush the netfilter rules | **ABSORBED** | rules gone, restored inside 5 s, `pods=OK` throughout |
| one pod's **veth** | delete it under a running pod | **HALTED** | `pods=FAIL`; **no self-heal in 244 s**; recovered only by recreating the pod |
| the **overlay device** | delete `vxlan.calico` | **DEGRADED** | `tunnel=absent` confirmed, rebuilt in 2 s |
| the **chosen address** | let Calico take a decoy, then delete it | **DEGRADED** | node IP re-detected in 0 s — **and the workload did not come back** |
| the **allocator**, for pods that already hold an address | disable the pools, offer a `/29`, fill it | **ABSORBED** | `pod-a → pod-b` never dipped while the allocator was dry |
| the **allocator**, for a pod admitted at that instant | *(same injection)* | **HALTED** | refused by name; freeing one address let exactly one waiter through in **6 s** |

**0 critical**, and the host's own cluster never moved.

### R.2 The two results worth more than the rungs

**Calico never self-heals a deleted pod veth.** It sat with the dataplane down for the full
244-second deadline and recovered only when the harness deleted and rescheduled the pod.
That is a clean HALTED — broken, honest about it, and a verb the system offers fixes it —
but nothing automatic, which is not what "the CNI manages pod networking" suggests.

**Moving the node's advertised IP heals the control plane and abandons the workload.** The
decoy took the node IP in 15 s; removing it, Calico re-detected in **0 s** while
`pods=no-podb-ip, rules=142` persisted. The CNI recovered *itself* and left the pods broken.
**On a multi-node cluster that is [F.6](#f6-additive-was-not-safe--the-tap-captured-a-live-clusters-tunnel)** — and it is the first time this repo has watched F.6's
*consequence* rather than its mechanism. The row is graded on its own subject (the node IP)
with the collateral reported explicitly, because a row graded on one observable must not
quietly imply the others were fine.

### R.3 A second exclusion pattern, found by naming a decoy badly

Two runs SKIPPED the last row: *"calico never took the decoy"* at 150 s, then at 240 s. The
cause was not the timeout. It was the **name**: `^cni.*` is in Calico's first-found
exclusion list alongside the `^br-.*` this lab was built to measure, so `cni-decoy` was
excluded by the very mechanism under study.

Proven the way rule 1 was, with the control free: `mc-probe` — identical in every other
respect — was taken in **20 seconds**. Recorded as `NCS_RULE1B_CNI_EXCLUSION`.

**`br-mc0` is therefore safe for two reasons, only one of which anyone knew**, and the list
plainly does not stop at two.

### R.4 Four rounds of harness defects before one honest rung

The CNI behaved impeccably throughout. Every defect was in the harness, and the first run
looked perfect:

```
calico-node-killed   pods=OK  RECOVERED=yes  SECS=2
netfilter-flushed    pods=OK  RECOVERED=yes  SECS=1
pod-veth-deleted     pods=OK  RECOVERED=yes  SECS=1
vxlan-deleted        pods=OK  RECOVERED=yes  SECS=1
```

Four rows recovering in about a second — which is exactly what
[`test-cni-chaos.sh`](examples/nested-calico-sandbox/tests/test-cni-chaos.sh)'s own
occupancy check says a matrix looks like **when the faults are not landing**. Three
injectors were silently no-ops:

| injector | why it did nothing |
|---|---|
| netfilter | Calico's 200 rules are in **legacy xtables**; `nft` sees zero, and `-F` spares the custom `cali-*` chains. The [two-backends trap](#b2-the-second-firewall--and-the-bug-p2-committed-while-hunting-it), in the guest this time |
| pod veth | deleted the *first* `cali*` veth — usually CoreDNS's, not pod-a's. Now resolved from the pod's own host route |
| vxlan | checked 5 s later, which cannot tell "deleted and rebuilt fast" from "never deleted". Now asserted immediately |

Plus a **manufactured negative** (a 150 s deadline against convergence this lab had already
measured at up to 200 s), a **namespace race** (`create namespace` returning is not the
namespace being usable — pods died on a serviceaccount mount), and **non-independent rows**
(the workload evaporated by row 5, which then graded STRANDED for somebody else's damage).

Every injector now asserts its fault landed and reports `INJECTOR-FAILED` if not. That rule
existed before any of this; it was applied to the one row whose failure had been noticed and
not to its three siblings — which is how a defect class survives its own discovery.

### R.5 Named as not covered

Cross-node consequences — one node has no peers. **That is now the only entry**, and it is
no longer blocked either: **Appendix S** built the second node (R.9 is the datastore row).

*(**IPAM exhaustion** was listed here on 2026-08-07 as "the most obvious next injector". It
is R.6. **The datastore beneath Calico** was listed here until 2026-08-08 and is now R.9's
row 7 — the fix was changing the OBSERVABLE, not writing a cleverer injector.)*

### R.6 The allocator, run dry — 2026-08-08

The analogue of micro-cloud's DHCP-pool row, one layer up, and the same thesis: **the point
is not that it runs out, it is *how*.** Running out of addresses is arithmetic. What the
ladder asks is what the CNI does at that moment — and, exactly as in the DHCP row, the answer
differs for two subjects the one fault hits at the same instant. They get two rows, because
averaging them into one rung would hide both.

The cluster's pool is a `/16`, so the pools in use are **disabled** and a deliberately tiny
`/29` offered in their place, then filled with real pods making real CNI `ADD` calls. Seven
of its eight addresses were taken; five pods were refused, with this against them:

> `plugin type="calico" failed (add): failed to request IPv4 addresses: Assigned 0 out of 1`
> `requested IPv4 addresses; No IPs available in pools: [10.99.9.0/29]`

Then one filler was deleted — freeing **exactly one** address — and exactly one waiter
started, in six seconds. That is the arithmetic control: it distinguishes "refused because
there was nothing left" from "refused because the allocator broke".

**Three findings beyond the rungs:**

- **`disabled: true` really does stop allocation from an already-affine block.** The row
  rests on this and it had never been measured here. Had it been false, the fillers would
  have come up on `10.1.x.x`, nothing would ever have been refused, and the row would have
  graded ABSORBED having injected nothing.
- **The refusal is exemplary** — it names the operation, the count *and* the pool that ran
  dry. That is the difference between HALTED and a pod sitting in Pending with nothing an
  operator can act on.
- **Reclamation has two speeds.** Six of the seven addresses are back the instant the last
  pod leaves the API; exactly one lingers, and that tail has outrun every deadline picked for
  it (sample-once, 180 s, 600 s — free on the next manual look each time).

### R.7 Two harness defects, both of which would have failed a healthy cluster

Both were in the assertions written to judge Calico, and both fail in the expensive
direction: nothing is broken and the suite insists otherwise.

**A guessed error string.** The check for "did the refusal name itself" grepped for
`assign an IP`, `no IP addresses available`, and `IPAM`. All three were invented at the desk;
all three miss the message quoted above (`Assigned`, not `assign an IP`; `No IPs`, not
`no IP addresses`; no `IPAM` anywhere). An exemplary refusal would have been graded dishonest
by an assertion that was itself asserting a made-up mechanism — [`CLAUDE.md`](CLAUDE.md)'s
bug class #2, committed inside the check written to detect bug class #1. It now matches on
the pool CIDR **the harness itself chose**, which is not a guess about anyone's wording.

**A deadline mistaken for a measurement — three times, in one check.** The leak check sampled
the allocator's records 10 s after the last pod left and reported an address still held. It
had not leaked; the check was early. Raised to 180 s: same answer, and an independent poll
found the address free ~80 s after the script gave up. Raised to 600 s: same answer again,
free on the next look. Three false leak reports against a healthy cluster — the same shape as
the 150 s decoy deadline in R.3, **"I stopped watching" rendered as "it never happened"**,
which is UNKNOWN printed as a verdict.

A leak detector that cries leak on a healthy cluster is not being cautious. It fails CI for a
defect that is not there, and what a reader learns from it is to stop believing it.

**The fix was not a bigger number.** A fourth deadline is the third mistake with more
patience. *"Did it leak"* means *"is it never reclaimed"*, and **no test establishes never** —
so the question changed. What is answerable is the **prompt** path, and it has a real failure
mode: if not one address returns when its pod is deleted, every pod that ever ran permanently
consumes one, and the pool's free count becomes a record that stopped describing its subject.
That is asserted. The slow tail is recorded and reported, never failed on.

Then every branch of the grader was made to **bite**: `CNI_CHAOS_RECORD=<file>` grades a
supplied record instead of injecting, so a hand-written record with one defect in it exercises
each branch in seconds with no cluster at all. Seven were run by hand — dead prompt-release, a
refused pod claiming Running, a pod that never recovers, an unnamed refusal, a dead incumbent
dataplane, pools left disabled, and an injector that did not land — and all seven fired with
their own specific message, against a healthy record that passes. The same switch is how a
failed 25-minute run's kept record gets re-read without spending another 25 minutes; it
announces itself loudly and skips the host-binding check, because a supplied record is a
cached fact and grading one is not a run.

### R.8 The controls that were run by hand are now the controls that run — 2026-08-08

Those seven lived in a scratch directory and were deleted with it. What remained in the repo
was a grader whose branches nobody would exercise again: **a test with no runner is a test
nobody runs**, and the branches in question are the ones that only matter on the day the CNI
misbehaves. [`tests/test-cni-chaos-grader.sh`](examples/nested-calico-sandbox/tests/test-cni-chaos-grader.sh)
makes them permanent — same shape as
[`tools/tests/test-link-check-anchors.sh`](tools/tests/test-link-check-anchors.sh), which
builds a fixture with four deliberate breaks.

It grades a clean record (which must pass, or every control below it fires for the fixture's
reasons), then injects **seventeen** defects one at a time and requires each to be refused
*by its own message* — matching the specific text, because a syntax error in the grader would
fail all seventeen and read as seventeen working controls. It adds three *healthy-but-unusual*
records that must still be accepted, and it **names the branches a record cannot reach** (§5's
occupancy guards, §6's host-binding comparison) instead of implying full coverage. Two
seconds, no cluster, no root — so it runs in CI, where the twenty-minute matrix only SKIPs.

**And one defect came out of it, in the section written to prevent exactly that defect.** The
fixture is a record that can outlive its subject, so §1 checks every key it speaks against
`cni-chaos.sh`. Written first as a grep of **the file**, it passed when the emitted
`allocations_left=` was renamed — because the old name survived in a *comment* three lines
above, describing a past measurement. The check was green while the property it stands for was
false. Prose is not an emission; it now greps the `say` lines, and it fails if that seam itself
moves. Five negative controls were run on the meta-test — a neutered grader assertion, a
mutation whose `sed` matched nothing, a renamed emission, a moved emission seam, and a
grader failing for the wrong reason — and the third of those is the one that found this.

### R.9 The datastore beneath Calico — the last named gap, closed by changing the OBSERVABLE — 2026-08-08

`k8s-dqlite` sat in R.5 from the day the matrix was written, for a real reason: it is a layer
*below* the CNI, and stopping it breaks the API this harness observes through. Every row
would grade STRANDED for harness reasons and the matrix would be reporting on itself.

**The blocker was specific, not fundamental — and the fix was not a cleverer injector.** A
CNI does not need the API to *forward a packet*: once a pod is running, its connectivity is
felix's netfilter rules, Calico's per-pod host route and the pod's veth, all of which are
kernel state. So this row alone is graded on the pod's address **pinged from the node**,
captured while the API was still up, and nothing consults the API after the fault.

**Measured: ABSORBED.** With the unit stopped and `/readyz` refusing, the pod was still
reachable; restarting brought the API back in 21 s. **A datastore outage costs every API
call and not every workload** — a property operators assume and rarely verify.

Two refusals keep it honest: the injector asserts it landed **on the API** (`/readyz`
refusing) rather than on the unit's own status — a stopped unit whose API still answers means
something else is serving it — and it **SKIPs by name** on a cluster with no separate
`k8s-dqlite` unit rather than stopping nothing and collecting a free ABSORBED.

⚠️ The observable crosses **one veth, not two**. That is a weaker subject than `pod-a →
pod-b` and is recorded as such in the script, the grader and `findings.env` rather than
presented as the same measurement.

The matrix is now **8 rows over seven layers: 4 absorbed, 4 not, 0 critical.**

---

## Appendix S — the second node: a private two-VM wire, and what it makes askable — 2026-08-08

**Every "needs a second node" deferral in this plan was really a "needs root" deferral.**
`network_mode = tap|bridge` are the only ways two of this repo's VMs could share a network,
and both are root-gated and both change the **host's** networking — disqualifying for a lab
whose entire premise is that breaking a CNI costs nothing. So F.6's mechanism could be
reproduced but never *witnessed*: the `vxlan-deleted` row is graded on whether Calico rebuilds
the device precisely because, with no peers, the tunnel carries no traffic and the dataplane
observable cannot move. **That rung was an UNKNOWN wearing a DEGRADED.**

### S.1 `peer_link` — phase-2 gains an unprivileged inter-VM wire

QEMU's `socket` netdev joins exactly two VMs into one L2 segment over a TCP connection on
`127.0.0.1`. No bridge, no tap, no host interface created or touched, **no root**.

```toml
peer_link = "listen:12801"   # node1, started FIRST
peer_mac  = "52:54:00:ca:11:01"
```

Two refusals in `lab-vm.sh` that are measurements rather than style:

- **`peer_mac` is mandatory.** QEMU numbers default MACs per NIC index *within a process*, so
  two VMs given none arrive on the same segment holding the **same address**. Nothing errors:
  ARP resolves to whichever end answered last, and it presents as intermittent loss on a link
  every tool reports UP.
- **An address cannot be spelled into the field at all.** `listen=` with a bare port binds
  every interface in QEMU, so the key takes `role:port` and nothing else — and
  `listen:0.0.0.0:9999` is *refused* rather than silently rewritten to loopback, because an
  operator who writes an exposed bind and reads back no error will trust the field next time.

### S.2 What it measured

Two `calico-node` pods, two distinct VXLAN tunnel addresses, two distinct IPAM blocks, and
**3 packets transmitted, 3 received, 0% loss** between pods on two different kernels —
traffic that can only arrive through the tunnel. Host binding identical throughout.

### S.3 Three defects, all one shape

A record that outlives the address it describes — and **none of them failed at the step that
caused it**:

| what | how it presented |
|---|---|
| every slirp guest is `10.0.2.15`, so the leader advertised an endpoint that **is the worker** | `microk8s join` printed *"Successfully joined the cluster"* while kubelet looped on `Unable to register node … EOF` |
| the kubelet serving cert is a **separate certificate** from the API server's; `--node-ip` does not reissue it | nothing failed at join or readiness — it failed at the first `kubectl exec`, the chaos harness's *only* dataplane observable |
| the reissue's success marker was a **mechanism** claim | it printed because a command exited 0; `server.crt` gained the address and `kubelet.crt` did not |

…plus one in the harness's own gate: it counted `=True` where the field separator is `;`, so
**it could never pass on any cluster**. It timed out against a healthy two-node cluster, and
the natural reading was *"the join is slow, raise the timeout"* — a broken assertion wearing
a performance problem's clothes.

### S.4 What is now askable, and is NOT yet written

The capability is proven; the **cross-node chaos rows are not written**, and nothing here
claims otherwise. The two worth having: deleting the tunnel under a live peer, and **F.6 with
a witness** — moving a node's chosen address while another node is routing to it. TODO §0.5
tracks them as the front of the queue.
