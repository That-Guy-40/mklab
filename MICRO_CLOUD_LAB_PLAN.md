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

**Two holes v2 did not name, and both are the mechanism-vs-outcome trap:**

1. **`panic=1` being *present* is not evidence that a panic *exits*.** Without it a guest
   panic **hangs the VM forever** — the single most confusing Firecracker failure mode.
   Slice 1 must **watch the hang** so this assertion guards a behaviour somebody observed.
2. **A config is not a pure function of the spec — it is a function of the spec *and the
   files it points at*.** A generator test passes happily with a nonexistent kernel, or a
   `bzImage` where an ELF is required, validating a document about an imaginary machine. So
   the generator tests must also assert the referenced paths **exist and are the right
   kind** (`file` says ELF, not `bzImage`).

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
started, with contents you can read on disk. It also grounds the security lesson: MMDS V2's
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
| `lxdbr0` | **10.216.67.0/24** | LXD — **and the k8s VXLAN underlay** | leave, load-bearing |
| `vxlan.calico` | 10.1.24.128/32 (+ blackhole /26) | **live Calico CNI** | leave, load-bearing |

**`10.71.0.0/24` is genuinely free** — verified, not guessed. Three consequences it did
*not* survive:

1. **`net.ipv4.ip_forward` is already `1`.** v2's *"down: reverse"* would revert a global
   that a **running Kubernetes depends on**. The rule is now: **record what you changed and
   revert only that.** This is the same shape as MAAS's `error_reason` defect — a path that
   changes state without recording that it did.
2. **Calico owns firewall rules** we cannot even read unprivileged (P1: nft ownership
   **UNKNOWN**, needs root — P2). Our table must be **additive and separately named**, and
   teardown must delete only `mklab-mc`.
3. **§9.2 puts `db` on LXD** — the same LXD hosting the Kubernetes. Not fatal, but LXD is
   not an idle phase tool on this host.

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
| `db` | LXD/Incus | stateful "pet" with its own init | the system-container case ⚠️ §7.1: LXD also hosts the k8s here |
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
| **A live Kubernetes + Calico shares this host** | 5 `calico-node` procs; `vxlan.calico` up over `lxdbr0`; `ip_forward` already `1`; nft ownership unreadable unprivileged | §7.1/§7.2: additive nft table, revert only what we set, teardown asserts absence of *our* objects only. **New top risk in v3** |
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
| **1** | **One microVM, by hand** | ext4 from a chroot (Alpine **and** Debian); a `vmlinux`; boot with `--no-api --config-file`; boot again over the REST API with `curl` | login prompt in <1s; both rootfs sizes + boot times side by side | drop `panic=1` → **watch it hang forever**; flip `is_root_device`; bend `ip=`; try `extract-vmlinux` (decision B, answered) |
| **2** | **The microVM gets an identity** | one tap, no bridge; MMDS `PUT` from the host | read `instance-id` from `169.254.169.254` *inside* the guest; V2 token by hand | V1 vs V2 and why V1 + SSRF leaks credentials; ask MMDS for a key never `PUT` |
| **3** | **Two microVMs that reach each other** | `fabric.sh up/down/status` — additive nft, recorded `ip_forward`, dnsmasq as DHCP **and** DNS | `api1` pings `api2` **by name**; `down` asserts absence of *our* objects only | delete the bridge under a running VM; exhaust the DHCP pool; leave a stale tap; **confirm Calico still works** |
| **4** | **The tool, and what it hides** | `lab-fc.sh` + `preflight`; **derive** §5.2's schema from slices 1–3 | one command, same boot; `--dry-run` diffed against slice 1's hand-written `config.json` | the preflight tripwire; **name what the tool silently started doing for you** — that list is the deliverable. Watch for the §8.3 verb tripwire |
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

## Appendix A — P1 assumption preflight, 2026-07-29

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
| **FAIL** | §7,§13 | the forwarding path has no other owner | **5 live `calico-node`; `vxlan.calico` over `lxdbr0`** |
| UNKNOWN | §7,§13 | who owns the nftables ruleset | `nft list tables` needs root — P2 |
| PASS | §9.2 | engines reachable | `qemu-system-x86_64`, `podman`, `docker`, `incus`, `lxc` |
| PASS | §8.1 | the phase1–5 wizards still pass | **28 passed** |
| **XFAIL** | §8.1 | the web UI has wizards | **expected gap — zero refs in `phase6b-web/`** |
| **XFAIL** | §13 | the `firecracker` binary is installed | **expected — author-run fetch** |
| **XFAIL** | §6 | a chroot exists to export | **NEGATIVE CONTROL — none; slice 1 must debootstrap first** |

**P2 (author-run, sudo + fetch) resolves the three UNKNOWNs** and flips the chroot and
firecracker rows.
