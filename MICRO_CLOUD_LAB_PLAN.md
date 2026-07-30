# Micro-Cloud Lab — Design Plan v2

> **Status**: draft v2 (2026-07-29) — **decision document, nothing built yet.**
> Scope: assemble the phases this repo already has into one single-host
> **micro cloud**, and add **Firecracker microVMs** as a fourth compute type
> alongside chroots, QEMU VMs, and containers.
>
> Sibling design docs: [`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
> [`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md),
> [`KALI_LLM_LAB_PLAN.md`](KALI_LLM_LAB_PLAN.md),
> [`METAL_AS_A_SERVICE_LAB_PLAN.md`](METAL_AS_A_SERVICE_LAB_PLAN.md).

## What changed from v1, and why it matters

v1 was written 2026-07-27 and rescued verbatim from a branch that was never merged.
Two things moved underneath it. Both change the plan's **structure**, not just its facts.

**1. Four of v1's honest constraints were false.** They were measured on a different
host state, and they were load-bearing: they drove decision 10 (partition
verification), the `--dry-run`-everything design, and §12's refusal to build a
hand-walk. Re-measured on this host, 2026-07-29:

| v1 said | actually |
|---|---|
| no `/dev/kvm` | present — and **openable RW**, checked by `os.open(O_RDWR)`, not inferred from group membership |
| no `vmx`/`svm` CPU flags | `svm` (AMD-V) in `/proc/cpuinfo` |
| no QEMU | `qemu-system-x86_64`, `qemu-img`, `virsh` all installed |
| egress blocks the release endpoint | GitHub releases API returns 200; latest tag **`v1.16.1`**, published 2026-07-02 |

Also present: the M1 toolchain (`mkfs.ext4`, `debugfs`, `truncate`) and the fabric
toolchain (`ip`, `nft`, `dnsmasq`); the user is in both `kvm` and `libvirt`. Only
`firecracker`/`jailer` are absent — one pinned download, and it lands on the *author's*
side of the toolchain fetch gate.

**The consequence outweighs the correction.** "Nothing that boots can be verified here"
was a real constraint that shaped every design choice. It is gone. This lab can *run*
on this box, which is the precondition for the second change.

**2. The goal is understanding, not delivery.** Stated by the user, 2026-07-29:
*"The idea is NOT to churn it out as fast as possible to meet the goals of the moment…
I want to use this build to understand these technologies as well as how to use them,
more deeply than I do. I want to be actively in both building and exercising this micro
cloud."*

That is a **structural constraint**, and v1's build order violates it — see §0.1 and
§14. It is the single biggest difference between v1 and v2.

**3. [`METAL_AS_A_SERVICE_LAB_PLAN.md`](METAL_AS_A_SERVICE_LAB_PLAN.md) went from plan to
a built v1** ([`examples/metal-as-a-service/`](examples/metal-as-a-service/)). v1's
rescue note said this gave §"orchestration" a concrete implementation to compose with.
**That was the wrong slot.** §2.1 re-files it.

---

## 0. TL;DR

A cloud is not a mystery box — it's **seven subsystems** (images, compute, network,
metadata, identity, orchestration, storage) wired together. This repo already implements
six of them, scattered across six phases and ~65 examples. Nobody has ever *stood them
up at the same time and called the result what it is*.

This plan does three things:

1. **Names the mapping** — every mklab building block against the cloud subsystem it
   actually is (§2), and, new in v2, **which parts of the bare-metal control plane
   transfer to a cloud one and which actively do not** (§2.1). This is the pedagogical
   payload: you don't learn "a cloud" by reading OpenStack, you learn it by recognising
   that `lab-chroot.sh export-tarball` *is* Glance.
2. **Adds the missing compute type** — `phase7-firecracker/lab-fc.sh`, a Firecracker
   driver with the same verb surface, TOML schema, and state model as every other phase
   (§5). Firecracker is what makes instances cheap enough (~125 ms boot, <5 MiB
   overhead) that "spawn twelve of them" is a lab step rather than an afternoon.
3. **Adds the one bridge that's missing** — `lab-chroot.sh export-rootfs`, turning any
   Phase-1 tree into the raw **ext4 block image** Firecracker boots (§6), exactly as
   `export-initrd` turned it into a netboot initrd.

The deliverable lab is `examples/micro-cloud/`: one `micro-cloud.toml`, one bring-up
script, five heterogeneous instances on one L2 fabric, a metadata service, a CA, and a
control plane that lists them all in one pane.

### 0.1 How this lab is built differs from the others

The other labs in this repo were built to *work*, and their teaching came out of the
write-up afterwards. This one is built to be *understood while it is being built*, which
means three rules that override the usual component-ladder instinct:

1. **Vertical slices, not components.** Every increment boots something and is
   exercisable the day it lands. v1's M0→M7 built the image bridge, then the kernel, then
   the driver — **nothing booted until M3 and nothing was exercisable until M5**. That is
   two milestones of writing code you cannot yet interrogate. §14 replaces it.
2. **Hand-walk before automate, then diff what the tool hides.** v1 had this instinct in
   one place (§5.5: boot a microVM by hand over the REST API before `lab-fc.sh` exists).
   In v2 it is the rule for *every* subsystem, and it has a third step: after the tool
   works, **diff it against the hand-walk and name what it silently started doing for
   you**. The understanding lands in that diff, and it is only available in that order.
3. **Every increment ships a break-it pass.** Not a final milestone.
   [`examples/metal-as-a-service/`](examples/metal-as-a-service/)'s most valuable
   artifact is not its working control plane, it is its
   [**16-defect ledger**](examples/metal-as-a-service/DEFERRED.md) — and every entry came
   from pointing something real at a suite that was green. Planning for that from
   increment 1 costs less than retrofitting it, and it is the difference between having
   assembled a thing and understanding it.

**The corollary is a scope rule.** v1's §13 already named scope creep as "very real —
the mapping table is seductive." A learning goal makes that *worse*, not better, because
every subsystem is now interesting on purpose. So §15's five-instance transcript is
**demoted from the goal to a late milestone**: while it is the goal, the answer to
"should I stop and break this?" is always no.

---

## 1. What we're building

```text
                          ┌─────────────────────────────────────────┐
   control plane          │  phase6-tui / phase6b-web               │
   (one pane of glass)    │  inventory · topology up/down · logs    │
                          └───────────────┬─────────────────────────┘
                                          │ reads manifests + engine queries
   ┌──────────────────────────────────────┼──────────────────────────────────┐
   │                   micro-cloud.toml   │   (one file, every phase)        │
   └──────────────────────────────────────┼──────────────────────────────────┘
                                          │
  IMAGE SERVICE  ──────────────────────┐  │  ┌──────────────────────────────┐
  phase1-chroot (debootstrap/dnf)      │  │  │  COMPUTE (4 flavors)         │
    ├─ export-tarball  → OCI images ───┼──┼─▶│  fc      Firecracker µVM  NEW│
    ├─ export-initrd   → netboot RAM ──┼──┼─▶│  vm      QEMU full VM        │
    └─ export-rootfs   → ext4       NEW┼──┼─▶│  ctr     podman / docker     │
  micro-linux/mlbuild.sh → vmlinux ────┘  │  │  sys     LXD/Incus container │
                                          │  └───────────────┬──────────────┘
  IDENTITY            examples/lab-ca/    │                  │
    lab CA → per-instance TLS certs ──────┤                  │ tap devices
                                          │                  ▼
  METADATA                                │   ┌──────────────────────────────┐
    cloud-init NoCloud seed (QEMU)        │   │  NETWORK FABRIC              │
    Firecracker MMDS @ 169.254.169.254 ───┼──▶│  br-mc0  10.71.0.1/24        │
                                          │   │  nft masquerade → uplink     │
  BARE METAL — already built, see §2.1    │   │  dnsmasq: DHCP+DNS+TFTP      │
    examples/metal-as-a-service/    ──────┘   └──────────────────────────────┘
```

**The demo that proves it works** (§15): `micro-cloud.sh up` brings the fabric and five
instances of four different types online; every instance resolves and pings every other
by name; each reads its own identity from the metadata service; the TUI lists all five in
one tree; `micro-cloud.sh down` leaves no bridge, tap, process, or state directory
behind. **This is the demo, not the goal** — see §0.1.

---

## 2. The mapping — this repo is already most of a cloud

The point of the whole lab, in one table. Left column: what a cloud calls it. Right
column: what mklab already ships.

| Cloud subsystem | OpenStack / AWS | What already exists here | Gap |
|---|---|---|---|
| **Image service** | Glance / AMI | [`phase1-chroot/lab-chroot.sh`](phase1-chroot/lab-chroot.sh) `create` + `export-tarball` / `export-initrd` (both verified present); [`micro-linux/mlbuild.sh`](micro-linux/mlbuild.sh) builds kernels from source | **`export-rootfs`** (ext4) — §6 |
| **Compute — VM** | Nova (libvirt) / EC2 | [`phase2-qemu-vm/lab-vm.sh`](phase2-qemu-vm/lab-vm.sh) — 6 arches, cloud-init, snapshots | — |
| **Compute — microVM** | Nova / Lambda, Fargate | *(QEMU's `microvm` machine is the closest — see [`examples/tiny-linux-experiments/micro-linux-x86_64-microvm.toml`](examples/tiny-linux-experiments/micro-linux-x86_64-microvm.toml))* | **`phase7-firecracker`** — §5 |
| **Compute — container** | Nova-LXD / ECS | [`phase3-docker`](phase3-docker/lab-docker.sh), [`phase4-podman`](phase4-podman/lab-podman.sh), [`phase5-lxd`](phase5-lxd/lab-lxd.sh) | — |
| **Compute — namespace** | *(below the cloud line)* | [`examples/exploring-containers/`](examples/exploring-containers/) | — |
| **Network** | Neutron / VPC | bridge/tap already in `lab-vm.sh` (`network_mode`, `bridge`, `tap`); dnsmasq in [`examples/podman-pxe-dhcp.toml`](examples/podman-pxe-dhcp.toml); routing/DNS in [`examples/tiny-internet-project/`](examples/tiny-internet-project/README.md) | **one fabric script** — §7 |
| **Metadata** | config-drive / IMDS | cloud-init NoCloud seeds (Phase 2); a real HTTP metadata service in [`examples/metal-as-a-service/lib/metadata.py`](examples/metal-as-a-service/lib/metadata.py) | **MMDS** — §5.7 |
| **Identity / PKI** | Keystone, ACM | [`examples/lab-ca/`](examples/lab-ca/README.md) — CA + server-cert issuance | wire it in |
| **Orchestration / API** | Heat, `nova boot` | [`phase6-tui/`](phase6-tui/README.md) + [`phase6b-web/`](phase6b-web/README.md) inventory + topology bring-up (an ABC in `backends/base.py` with **5** resource backends); `[lab]`-grouped TOML | **the four-seam problem** — §8 |
| **Config management** | user-data, cloud-init | [`examples/ansible/`](examples/ansible/) | wire it in |
| **Block storage / snapshots** | Cinder, EBS snapshots | qcow2 snapshots (`lab-vm.sh snapshot`); ZFS boot environments in [`examples/zfsbootmenu-boot-environments/`](examples/zfsbootmenu-boot-environments/README.md) | FC snapshot/restore — §5.8 |
| **Bare metal** | **Ironic** | [`examples/metal-as-a-service/`](examples/metal-as-a-service/) — **built, v1 complete** | **not a gap — see §2.1** |

Two gaps are *real* (a compute driver and an image format); most of the rest is
integration work, and one — §8 — turns out to be a genuine unsolved design question.

### 2.1 Where Metal-as-a-Service actually fits — and what does NOT transfer

v1 filed MAAS under "orchestration", implying the micro cloud inherits a control plane
and needs only a sixth Phase-6 backend. **That is the wrong slot, and getting it wrong
would cost a rewrite later.**

MAAS is the **Ironic rung, built faithfully** — and Ironic's abstraction is *a machine
you do not own*. Its entire seam discipline exists to enforce exactly that: the control
plane reaches a node **only** through the BMC and its console, policed by a refusing
`virsh` stub on `PATH`, because a machine in a rack has no hypervisor to ask.

A cloud's compute API is the **inverse**. `nova boot` *conjures* the instance. There is
no BMC because there is no pre-existing machine, and Firecracker's REST socket is not an
out-of-band channel — it **is** the instance's existence.

So the transfer splits cleanly, and knowing which side a thing falls on is most of the
design work ahead:

**Transfers — this is the real substrate:**

| what | why it transfers |
|---|---|
| **`apply`, the reconcile loop** | declare end-state → diff → issue the *minimum* transitions → converge → **no-op on pass two**. That is the core loop of both Terraform and Kubernetes, and MAAS's carries the hard-won rule that **it must not trust its own registry** — its registry-layer chaos fault proved the record can diverge from the machine |
| **The driver interface + catalog pattern** | 5 drivers behind one contract; and the rule that *the catalog names the lab that owns each artifact and the exact command that builds it, and builds nothing itself*. That is precisely how micro-cloud must treat `vmlinux` and `.ext4` instead of forking six labs into a seventh |
| **The metadata service** | [`lib/metadata.py`](examples/metal-as-a-service/lib/metadata.py) is already a working NoCloud source **and** a POST sink with DER validation. MMDS is a different *delivery* against a near-identical contract |
| **The chaos ladder** | ABSORBED / DEGRADED / HALTED / STRANDED / LIED. For a learning goal this is the highest-value import in the repo: it is the difference between having built a thing and understanding how it fails |
| **Registry-as-cache discipline** | derive the fact, don't cache it; if you must cache it, bind it to its subject's identity and refuse a mismatch **by name** |
| **The preflight ordering rule** | refuse before the irreversible step. `lab-fc.sh` copies a 400 MB rootfs and creates a tap; both are irreversible-ish, and both come *after* answers that are free to check |

**Does NOT transfer — this is where the actual thinking is:**

| what | why not |
|---|---|
| **Lifecycle ownership** | MAAS never creates a machine. Micro-cloud must, and `destroy` really destroys. That is a materially different state machine: there is a `building`/`spawning` state with no BMC analogue |
| **The seam** | MAAS has **one** seam (`bmc.sh <node> <verb>`) with swappable backends, and its drivers own *deploy* only — lifecycle is the seam's job. Micro-cloud has **four engines whose lifecycle *is* their control surface**, and they share almost nothing. §8 |
| **Networking as a subsystem** | MAAS has essentially none — it consumes a pre-existing PXE net. §7's fabric is new ground, and carries the densest "understand it deeply" payload in the plan |
| **The console as the only witness** | MAAS reads a serial log because it is all a rack machine offers. A microVM you own can be asked directly (vsock, MMDS, exec). Keeping the console habit here would be cargo-culting a constraint that no longer applies |

**The uncomfortable conclusion, stated plainly:** the strongest, most-tested thing in
this repo is the tier v1 filed as a *stretch arm* (§9.4). v1's centre of gravity is in
the wrong place. v2 does not move bare metal into scope — it stops pretending the micro
cloud inherits a control plane from it.

---

## 3. Why Firecracker — and what it is *not*

Firecracker is AWS's Rust VMM (it runs Lambda and Fargate). It is a KVM front-end that
deliberately implements almost no device model: virtio-net, virtio-block, virtio-vsock, a
serial port, and a keyboard controller that exists only so the guest can trigger a reset.
No PCI bus, no BIOS/UEFI, no option ROMs, no SCSI, no USB, no VGA. That's the entire
point — less emulated surface means a smaller attack surface, ~5 MiB of VMM memory
overhead, and a boot measured in milliseconds.

**Where it sits among the four compute types this lab will run:**

| | isolation boundary | boot | image format | best at |
|---|---|---|---|---|
| chroot (Phase 1) | filesystem root only | none | directory tree | building images |
| container (Phase 3/4/5) | namespaces + cgroups (shared kernel) | ms | OCI layers / tarball | services, density |
| QEMU VM (Phase 2) | hardware virt, **full** device model | seconds | qcow2 (+UEFI) | fidelity: firmware, PXE, kdump, weird arches |
| **Firecracker (Phase 7)** | hardware virt, **minimal** device model | **~125 ms** | raw **ext4** + `vmlinux` | density with a real kernel boundary; fleets |

**What Firecracker is not, stated plainly** — so the lab doesn't oversell it:

- **Not a QEMU replacement.** No UEFI, no PXE/netboot, no TPM, no secure boot, no
  non-native arches. Every existing Phase-2 lab that teaches firmware or network boot
  *must stay on QEMU*. Firecracker deletes exactly the machinery those labs are about —
  and the whole of [`examples/metal-as-a-service/`](examples/metal-as-a-service/) is
  built on machinery Firecracker does not have.
- **Not "QEMU microvm with a new name."** The repo already has QEMU's `microvm` machine
  type and it is genuinely close (virtio-mmio, qboot, no PCI). The differences that
  justify a whole new phase are the **API-driven lifecycle** (§5.5), **MMDS** (§5.7),
  **snapshot/restore-in-milliseconds** (§5.8), the **jailer** (§5.6), and **rate
  limiters** — i.e. the parts that make it a *cloud* compute driver rather than a fast
  emulator. A side-by-side of the two is itself a lab step.
- **Not runnable without KVM.** There is no TCG fallback. `/dev/kvm` or nothing — and on
  this host, `/dev/kvm` (§10).

---

## 4. Decisions

### Locked in

| # | Question | Answer |
|---|---|---|
| 1 | Scope of "micro cloud" | **Single host, no clustering.** One box, one L2 fabric, heterogeneous instances. Multi-host is explicitly out (it would become a networking lab, not a cloud lab). |
| 2 | New phase directory | **`phase7-firecracker/lab-fc.sh`** — a new compute *rung* on the ladder. Runner-up: `phase2b-firecracker/` (sibling-of-Phase-2, mirroring the `phase6b` convention) — rejected because `6b` means "same thing, different UI", while Firecracker is a different thing. Phase 6/6b stay the capstone and simply gain a sixth backend. |
| 3 | Instance identity | **Every instance is a `[[…]]` block in one `micro-cloud.toml`** with `lab = "micro-cloud"`, so all five existing `list --lab` surfaces and the Phase-6 topology view work unchanged. No new inventory format. |
| 4 | Firecracker launch mode | **Both.** `--no-api --config-file config.json` is the default (deterministic, reproducible, and a *pure function of the spec* → host-testable). The REST API over `--api-sock` is the **teaching** path: `PUT /boot-source`, `/drives`, `/network-interfaces`, `/actions` is a cloud compute API you can read in ten minutes. **v2: the API path comes FIRST** (§14, slice 1) — by hand, before any tool exists. |
| 5 | Rootfs format | **Raw ext4**, built by `mkfs.ext4 -d` from a Phase-1 chroot (§6). No loop mount, no root, no qcow2. |
| 6 | Kernel | **Pinned upstream FC CI `vmlinux`** as the fast path; **`micro-linux/mlbuild.sh` → `vmlinux`** as the own-the-whole-stack path (§6.3). |
| 7 | Network fabric | **One Linux bridge + one tap per instance**, `10.71.0.0/24`, host is `.1` and the NAT gateway. Not the per-microVM `/30` that FC's own getting-started uses — instances must reach *each other*, which is the whole point of a cloud. |
| 8 | Guest addressing | **Static via the kernel `ip=` boot arg** for Firecracker (no DHCP client needed in a 20 MB rootfs), **DHCP from dnsmasq** for the QEMU/LXD members that already expect it. Both served by the same fabric. |
| 9 | Isolation tier | **Plain `firecracker` first, `jailer` second** — as an explicit, documented upgrade step, because the jailer *is* a chroot + cgroup + netns + seccomp wrapper and therefore closes the loop back to Phase 1 (§5.6). |
| 10 | ~~Verification honesty: partitioned~~ | **SUPERSEDED (v2).** v1 partitioned because nothing could boot here. It can. §10 is rewritten: nearly everything is verifiable on this host, and the honesty burden moves from *"which claims are untested"* to *"which claims were tested by observation rather than by reading a config"*. |
| A | Which release to pin? | **`v1.16.1`** (published 2026-07-02, read off the releases API 2026-07-29). Pin tag + `sha256` in a `versions.lock`-style file mirroring [`micro-linux/versions.lock`](micro-linux/versions.lock). |
| 11 | **NEW — build shape** | **Vertical slices with a break-it pass each** (§0.1, §14), replacing v1's component ladder. |
| 12 | **NEW — hand-walk** | **Yes, build one.** v1 §12 refused, reasoning that a container cannot host a KVM microVM. That was downstream of the no-KVM premise. `podman run --device /dev/kvm` can, and a first boot with no networking needs nothing more. See §12. |

### To confirm before building

| # | Question | Recommendation |
|---|---|---|
| B | Does `scripts/extract-vmlinux` on a Debian `bzImage` produce an FC-bootable ELF? | Still **unverified** — but v1 could only ever reason about it. Slice 1 can now *try it and watch*, so this stops being a decision and becomes an experiment with an answer. |
| C | vsock guest agent, or SSH? | Start with SSH over the fabric (familiar). Add a vsock "no-network agent" as a later step — it's the neatest demonstration that a control plane doesn't need the data network, and the cleanest counter-example to MAAS's console-only habit (§2.1). |
| D | Include the bare-metal tier in v1? | **No**, and for a better reason than v1 gave: not "it doubles the surface" but "it is a *different abstraction*" (§2.1). It stays a sibling lab, cross-linked, not absorbed. |
| **E** | **NEW — what is the control-plane seam?** | **Do not decide up front.** §8 lays out three candidate shapes; the decision comes after slice 5, when two engines exist and the question is concrete. Deciding now is how you get an abstraction that fits one engine. |
| **F** | **NEW — guest distro** | Alpine (~40 MB) as the default because a small rootfs makes "spawn twelve" real; Debian for parity with the rest of the repo. Slice 1 builds **both** and the size/boot-time difference is itself the observation. |

---

## 5. New component A — `phase7-firecracker/lab-fc.sh`

The contract every phase tool in this repo honours: one self-contained bash script,
TOML-or-flags input, a per-resource state dir with a `manifest.toml`, `--json` on the
read verbs, `--lab` filtering, and `tests/` whose every file prints exactly one
`PASS`/`FAIL`/`SKIP` line.

> **v2 sequencing note.** Nothing in §5 gets written until **slice 4** (§14). Slices 1–3
> boot microVMs *by hand*. The tool exists to remove typing, and you cannot see what it
> removed unless you did the typing first.

### 5.1 CLI surface

```bash
lab-fc.sh preflight --config examples/micro-cloud/micro-cloud.toml   # v2 — see §5.9
lab-fc.sh create   --config examples/micro-cloud/micro-cloud.toml
lab-fc.sh create   --name api1 --rootfs /var/lib/mklab/images/debian.ext4 \
                   --kernel /var/lib/mklab/images/vmlinux --memory 256M --vcpus 1
lab-fc.sh start    api1              # spawn firecracker, wait for the boot banner
lab-fc.sh console  api1              # attach to the serial console
lab-fc.sh ssh      api1              # ssh via the fabric address
lab-fc.sh list     [--lab micro-cloud] [--json]
lab-fc.sh inspect  api1 [--json]     # manifest + live pid/tap/ip/uptime
lab-fc.sh stop     api1 [--force]    # graceful: SendCtrlAltDel action; --force: SIGKILL by PID
lab-fc.sh destroy  api1 [--force]    # stop + delete tap + delete state dir
lab-fc.sh snapshot api1 --tag warm   # pause → snapshot → resume
lab-fc.sh restore  api2 --from api1:warm   # boot a CLONE from a snapshot
lab-fc.sh mmds     api1 --set '{"instance-id":"api1"}' | --get
```

`stop`/`destroy` **resolve to a PID and `kill` it** — never `pkill -f`. The per-VM socket
paths (`api.sock`, `console.sock`) appear in the `firecracker` argv, so a pattern kill
would match the very process it names, plus any sibling tooling. This is the exact
footgun CLAUDE.md documents — and the one that once killed a QEMU VM *and the agent's own
shell* with exit 144; the fix is `fc.pid`.

### 5.2 `[[microvm]]` TOML schema

Array-of-tables with an `engine` key, so it coexists in a unified lab file exactly like
`[[service]]`/`[[instance]]` do today:

```toml
[[microvm]]
name        = "api1"
engine      = "firecracker"        # engine filter → other phase tools ignore this block
lab         = "micro-cloud"        # inherited from [lab].name when omitted
kernel      = "images/vmlinux"     # uncompressed ELF (x86_64) — see §6.3
rootfs      = "images/debian.ext4" # raw ext4 block image — see §6
rootfs_mode = "rw"                 # "ro" + an overlay is the density trick
vcpus       = 1
memory      = "256M"
boot_args   = "console=ttyS0 reboot=k panic=1 pci=off"   # ip= appended by the fabric
network     = { bridge = "br-mc0", ip = "10.71.0.11/24", gateway = "10.71.0.1", mac = "52:54:00:mc:00:11" }
mmds        = { "instance-id" = "api1", "local-hostname" = "api1" }
vsock_cid   = 11                   # optional: guest agent without a network
balloon     = { size_mib = 0, deflate_on_oom = true }    # optional memory reclaim
jailer      = false                # true → run under `jailer` (§5.6)
[[microvm.rate_limiter]]           # optional: per-tenant quotas
target      = "network"
bandwidth   = { size = "10M", refill_time = 1000 }
```

Fields that mirror Phase 2's manifest (`name`, `lab`, `memory`, `kernel`) keep their
Phase-2 spelling so the Phase-6 backends and any future cross-phase tooling can read
either without special-casing.

### 5.3 State directory

`$LAB_STATE_DIR/fc/<name>/`, mirroring `$LAB_STATE_DIR/vms/<name>/`:

```text
manifest.toml   the resolved spec (what Phase 6 reads)
config.json     the generated Firecracker machine config (§5.4)
api.sock        Firecracker's REST socket (API mode)
console.sock    serial console (unix socket; `console` attaches, one client at a time)
fc.pid          the VMM pid — the ONLY thing stop/destroy signals
fc.log          Firecracker's own log fifo, drained to a file (tailable by the TUI)
rootfs.ext4     per-instance copy or CoW overlay of the image
tap             the tap device name, so teardown is deterministic
snapshots/<tag>/{snapshot.bin,memory.bin,config.json}
```

### 5.4 The generated `config.json` — the host-testable core

`--no-api --config-file` means the entire boot is a **pure function of the spec**. That
function is the unit under test, and it needs no KVM:

```json
{
  "boot-source": {
    "kernel_image_path": "/var/lib/mklab/images/vmlinux",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=10.71.0.11::10.71.0.1:255.255.255.0:api1:eth0:off"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "…/rootfs.ext4",
      "is_root_device": true, "is_read_only": false }
  ],
  "network-interfaces": [
    { "iface_id": "eth0", "host_dev_name": "mc-api1",
      "guest_mac": "52:54:00:mc:00:11" }
  ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256, "smt": false },
  "mmds-config": { "version": "V2", "network_interfaces": ["eth0"] },
  "vsock": { "guest_cid": 11, "uds_path": "…/vsock.sock" }
}
```

`tests/test-fc-config-json.sh` asserts, with `python3 -m json.tool` + a schema walk:
`is_root_device` true on exactly one drive; `boot_args` carries `reboot=k panic=1`
(without which a guest panic **hangs the VM forever** instead of exiting — the single
most confusing Firecracker failure mode); the `ip=` octets match the spec;
`host_dev_name` matches the tap the fabric will create; `ro` rootfs never paired with a
writable overlay-less boot. Every assertion gets its own `fail "REGRESSION: …"` message.

**v2 caveat, and it is the §0.1 rule biting immediately:** every assertion above tests
the *generator*, not the *machine*. A `config.json` with `panic=1` present is not
evidence that a panic exits — that is the mechanism-not-outcome trap. Slice 1 must
**observe the hang** with `panic=1` removed, so that this test is guarding a behaviour
somebody watched rather than a string somebody expected.

### 5.5 API mode is the lesson, config mode is the default

The centrepiece of slice 1 is booting one microVM *by hand*, with `curl`, over a Unix
socket — because that is precisely what a cloud's compute API does when you click "launch
instance":

```bash
firecracker --api-sock /tmp/fc.sock &
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/boot-source' \
     -H 'Content-Type: application/json' \
     -d '{"kernel_image_path":"vmlinux","boot_args":"console=ttyS0 reboot=k panic=1 pci=off"}'
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/drives/rootfs' \
     -d '{"drive_id":"rootfs","path_on_host":"rootfs.ext4","is_root_device":true,"is_read_only":false}'
curl --unix-socket /tmp/fc.sock -X PUT 'http://localhost/actions' \
     -d '{"action_type":"InstanceStart"}'
# …guest login prompt appears on the terminal in well under a second.
```

Then the same boot via `lab-fc.sh start` — and the point lands: the tool is a config
generator and a process babysitter, nothing more. That demystification is the reason to
build the phase by hand rather than wrap `ignite` or `weave`.

### 5.6 The jailer tier — Phase 1 closes the loop

`jailer` is the production launcher: it creates a chroot, moves the VMM into it, drops to
an unprivileged uid/gid, joins a netns and a cgroup, then execs `firecracker` with seccomp
filters applied.

```bash
jailer --id api1 --exec-file /usr/bin/firecracker \
       --uid 30000 --gid 30000 --chroot-base-dir /srv/jail --netns /var/run/netns/mc-api1 \
       -- --config-file config.json
```

Every noun in that command line is something an earlier phase already taught: chroot
(Phase 1), namespaces and cgroups
([`examples/exploring-containers/`](examples/exploring-containers/)), and now they're
wrapped *around a hypervisor*. The lab step is "boot the same microVM twice, plain and
jailed, then diff `/proc/<pid>/root`, `/proc/<pid>/ns/net`, and `/proc/<pid>/status`'s
`Seccomp` line." Note the sharp edge: under the jailer every path in `config.json` is
**relative to the new chroot**, so the kernel and rootfs must be hard-linked or
bind-mounted in first — the classic first-attempt failure.

### 5.7 MMDS — a real 169.254.169.254

Firecracker's Microvm Metadata Service is a genuine link-local metadata endpoint served
by the VMM itself. The guest does `curl 169.254.169.254/latest/meta-data/` and gets back
whatever the host `PUT` into MMDS — which is *exactly* the EC2/GCE IMDS contract,
including V2's token handshake:

```bash
TOKEN=$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-metadata-token-ttl-seconds: 60')
curl -s -H "X-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
```

This is the highest-value teaching artifact in the whole plan: the same magic IP you've
hit on every EC2 box, running on your laptop, served by a process you started, with
contents you can read on disk. It also grounds the security lesson — MMDS V2's token
exists because V1 plus an SSRF bug is how cloud credentials get stolen.

The QEMU members of the fabric keep their cloud-init NoCloud seed; the runbook puts the
two side by side (config-drive vs. IMDS) as the two ways every cloud does metadata. A
third sits in this repo already —
[`metal-as-a-service/lib/metadata.py`](examples/metal-as-a-service/lib/metadata.py)
serves NoCloud over HTTP on `:8282` to a *machine it does not own* — so the comparison is
actually three-way, and the third is the one a cloud can't use.

### 5.8 Snapshot / restore — the "micro" in micro cloud

Pause a running microVM, write its memory and device state to disk, then restore it —
repeatedly, into *many* new instances. Restore skips boot entirely:

```bash
lab-fc.sh snapshot api1 --tag warm         # pause → PUT /snapshot/create → resume
for n in 1 2 3 4 5; do lab-fc.sh restore "w$n" --from api1:warm; done
```

Five identical warm instances, each resumed from the same memory image, in about the time
one of them would have taken to boot. That is literally how Lambda serves a cold start.

**And it must be taught with its caveats**, which are real cloud-engineering lessons, not
footnotes: every clone resumes with the *same* entropy pool, the same in-memory secrets,
the same MAC and the same view of its network, and the same clock. Restoring a snapshot
across a different VMM version or CPU model is unsupported. The lab step is to
*demonstrate* the duplicate-randomness hazard (`head -c8 /dev/urandom | xxd` matching
across clones) and then fix it by re-seeding on resume — which is why real fleets treat
snapshot restore as requiring an explicit re-personalisation step.

Note where this lands on the chaos ladder (§2.1): a fleet of clones that all believe they
are the same instance is **LIED**, not HALTED. Nothing errors. That is why it outranks a
crash.

### 5.9 `preflight` — new in v2

Ported from the lesson
[`create-fleet.sh`](examples/metal-as-a-service/create-fleet.sh) learned the hard way:
`lab-fc.sh create` copies a multi-hundred-megabyte rootfs and `lab-fc.sh start` creates a
tap device. Both are effects. Every gate that can refuse the run — `/dev/kvm` openable,
the `firecracker` binary present and the pinned version, kernel is an ELF not a bzImage,
rootfs exists and has an `/sbin/init`, the tap name is free, no IP collision in the spec
— is answerable **before** any of it. And `preflight` must be *the same function* `create`
calls first, not a second implementation that predicts what `create` will do.

---

## 6. New component B — `lab-chroot.sh export-rootfs` (the image service)

Firecracker boots a **raw ext4 filesystem image** as `/dev/vda`. Phase 1 already knows
how to produce a root filesystem; it just can't emit that container yet. This verb is the
exact analogue of `export-initrd` (which emits `cpio.gz` for netboot) and `export-tarball`
(which emits an OCI-importable tarball) — **both confirmed present in
[`lab-chroot.sh`](phase1-chroot/lab-chroot.sh) as of 2026-07-29**.

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
5. chown to $SUDO_UID:$SUDO_GID          (same rootless-handoff as export-tarball)
6. verify: debugfs -R "ls -l /sbin" "$out"  → assert init is present
```

Step 4 is the whole trick. **`mke2fs -d <dir>` builds a populated filesystem image
without ever mounting it** — no loop device, no `CAP_SYS_ADMIN`, no privileged container.
That matters twice over: it keeps the verb usable rootlessly wherever the tree is
readable, and it makes the output **verifiable with no mount privileges**, because
`debugfs -R` can list and extract files straight out of the image.

> **Verified on the mklab host while writing v1** (2026-07-27): building a 32 MiB ext4
> from a directory with `truncate` + `mkfs.ext4 -d`, then reading `/etc/hostname` back
> out with `debugfs -R 'ls -l /etc'`, succeeds with no loop mount and no elevated
> capability. `mkfs.ext4`, `debugfs` and `truncate` re-confirmed present 2026-07-29.

The same image is what a QEMU `kernel+initrd` VM can take as a `disk=`, so
`export-rootfs` is useful even to people who never install Firecracker.

**One gap slice 1 must handle:** there are currently **no chroots** under this host's
default state dir, so the first `export-rootfs` needs a tree built first
(`lab-chroot.sh create`) — a sudo-gated step, and the honest first thing the slice-1
runbook has to say.

### 6.3 The kernel

Firecracker takes an **uncompressed ELF `vmlinux`** on x86_64 — not the `bzImage` QEMU
boots — and a PE-format `Image` on aarch64. Three sources, in the order the lab should
present them:

| # | Source | Verdict |
|---|---|---|
| a | Upstream Firecracker CI kernel artifacts, pinned + `sha256`'d | **Fast path.** Known-good, zero build time. Egress confirmed working (§10). |
| b | [`micro-linux/mlbuild.sh`](micro-linux/mlbuild.sh) with a new `vmlinux` artifact target + an FC-minimal `.config` | **The good path.** `mlbuild.sh` already builds pinned, PGP-verified kernels from source per arch, and its `kernel_image()` **already returns bare `vmlinux` for ppc64le** (QEMU's pseries takes the ELF directly) — verified 2026-07-29 at `mlbuild.sh:238`. So x86_64-for-FC is a small, well-precedented addition. Config needs virtio-mmio/blk/net + 8250 serial + KVM guest, and can drop essentially all of PCI — a genuinely instructive kconfig exercise. |
| c | `scripts/extract-vmlinux` on a distro `bzImage` | **Unverified** (decision B) — but now *testable*. Try it in slice 1 and record what happens. |

---

## 7. New component C — the network fabric

One script, `examples/micro-cloud/fabric.sh`, with `up` / `down` / `status`:

```text
up:
  ip link add br-mc0 type bridge          # the "VPC"
  ip addr add 10.71.0.1/24 dev br-mc0     # host = gateway
  ip link set br-mc0 up
  nft add table ip mklab-mc               # NAT out of the box
  nft … oifname <uplink> ip saddr 10.71.0.0/24 masquerade
  sysctl -w net.ipv4.ip_forward=1
  dnsmasq --interface=br-mc0 --dhcp-range=10.71.0.100,10.71.0.200 \
          --domain=mc.lab --conf-file=… --pid-file=…       # DHCP + DNS for the QEMU/LXD members
per instance:
  ip tuntap add mc-<name> mode tap        # one tap per microVM
  ip link set mc-<name> master br-mc0 up
down:
  reverse, then assert `ip link show br-mc0` fails and no tap named mc-* remains
```

Address plan: `.1` host/gateway/DNS, `.11–.49` static (Firecracker, via `ip=`),
`.100–.200` DHCP pool (QEMU cloud images, LXD containers). Containers from Phase 3/4 join
through their own engine networks and reach the fabric via the host — the runbook is
explicit that this asymmetry exists and *why* (rootless podman has no business enslaving
a host bridge).

`down` is written as a **teardown test**, not a best-effort cleanup: it asserts absence
afterwards and fails loudly otherwise, because a leaked bridge with a stale `10.71.0.1`
is the kind of thing that quietly breaks the *next* lab.

**One live collision to check before picking `10.71.0.0/24`:** this host already runs a
`vbmc-pxe` libvirt network for
[`metal-as-a-service`](examples/metal-as-a-service/) plus libvirt's `default`. Per
CLAUDE.md's blast-radius rule, enumerate every existing bridge and subnet **before** the
first `ip addr add`, and classify each — the netboot port lesson (`8080` was intentional
on this host) applies to subnets too.

---

## 8. New component D — the control plane, and the four-seam problem

> **This is the plan's one genuinely unsolved design question.** v1 framed it as
> mechanical: "Phase 6's backend layer is an ABC with five implementations; adding a
> sixth is mechanical." The *surfacing* half is indeed mechanical. The **control** half
> is not, and §2.1 is why.

### 8.1 The mechanical half — surfacing

Confirmed present: [`phase6-tui/lab_tui/backends/`](phase6-tui/) has `base.py` plus
`chroot.py`, `docker.py`, `lxd.py`, `podman.py`, `vm.py` (+ `control_pane.py`). A sixth is
a known shape:

- `phase6-tui/lab_tui/backends/fc.py` — `FCBackend(BackendRunner)`, `name = "fc"`,
  `state_paths() → $LAB_STATE_DIR/fc`, `list_resources()` reading each `manifest.toml` +
  `fc.pid` liveness (the same `_pid_alive` pattern `vm.py` uses), `inspect()` preferring
  `lab-fc.sh inspect --json`, `console_command` → `lab-fc.sh console <name>` when running.
- `BackendName` literal and `ALL_BACKENDS` gain `"fc"`.
- `phase6-tui/lab_tui/topology.py` — a `"fc"` `PhaseSlot`. Ordering matters and is a
  *dependency*, not a preference: **Phase 1 (build the tree) → export-rootfs (make the
  image) → fabric up → fc/vm/containers → fabric down last.**
- Phase 6b picks it up for free — `base.py` is deliberately framework-agnostic and the web
  routes consume the same backends.

### 8.2 The unsolved half — one seam, or four?

MAAS has **one** seam: `bmc.sh <node> <verb>`, with swappable backends behind it, and its
drivers own *deploy* only — lifecycle (power, boot device) belongs to the seam. That works
because every machine in a rack answers the same five IPMI verbs.

Micro-cloud has **four engines whose lifecycle *is* their control surface**, and they do
not agree on what the verbs mean:

| engine | control surface | "stop" means | has no concept of |
|---|---|---|---|
| Firecracker | REST over a unix socket | `SendCtrlAltDel` action, or SIGKILL the VMM | `exec` |
| QEMU (Phase 2) | libvirt/`virsh`, or a raw process + monitor | ACPI shutdown, or destroy | — |
| podman (Phase 4) | CLI (rootless) | SIGTERM the entrypoint | "power" |
| LXD/Incus (Phase 5) | CLI / REST | `incus stop` | a kernel of its own |

Three candidate shapes, none obviously right:

| | shape | attraction | the objection |
|---|---|---|---|
| **(a)** | One `instance.sh <name> <verb>` seam, per-engine backends — mirrors `bmc.sh` exactly | one vocabulary; `apply` works unchanged | the verbs **do not mean the same thing**. A podman container has no power state; a microVM has no `exec`. A seam that forces them into one vocabulary lies about three of the four |
| **(b)** | Per-engine drivers with a common *contract* but engine-specific verbs; the control plane speaks only the **intersection** | honest about difference | the intersection may be so small (`create`/`destroy`/`status`) that the control plane can't do anything interesting |
| **(c)** | Don't unify. `micro-cloud.sh` orchestrates the existing phase tools as-is; "one pane of glass" is read-only | zero new abstraction, and it is v1's implicit answer | no `apply`, so the best thing MAAS built doesn't transfer |

**Decision E: do not choose yet.** Choose after slice 5, when two engines are actually
running on one fabric and the question is concrete. Picking now produces an abstraction
shaped by whichever engine was imagined most vividly — and the repo has a name for that
failure: a record that outlived the thing it described, except the record is an interface.

---

## 9. The lab — `examples/micro-cloud/`

### 9.1 Layout

```text
examples/micro-cloud/
├── README.md                 what a micro cloud is; the §2 mapping table
├── micro-cloud.toml          ONE spec: chroot + microvms + vm + containers
├── fabric.sh                 bridge/tap/NAT/dnsmasq  (§7)
├── micro-cloud.sh            up | down | status — orders the phase tools
├── images/                   .gitignore'd build output (vmlinux, *.ext4)
├── hand-walk/                NEW in v2 — Containerfile + RUNBOOK (§12)
├── RUNBOOK-build-images.md   chroot → export-rootfs → vmlinux (§6)
├── RUNBOOK-first-microvm.md  boot one FC by hand over the REST API (§5.5)
├── RUNBOOK-micro-cloud.md    the full bring-up, instance by instance
├── RUNBOOK-fleet.md          snapshot → restore ×5 + the clone hazards (§5.8)
├── LEDGER.md                 NEW in v2 — the running defect/surprise ledger (§0.1)
├── UPSTREAM.md               cite-don't-mirror provenance (§12)
├── MANUAL_TESTING.md         what was observed vs what was only generated (§10)
└── tests/                    lib.sh + run-all.sh + host-safe checks (§10)
```

### 9.2 The instances

Five instances, four compute types, one fabric — chosen so each one *has a reason to
exist*:

| Instance | Type | Role | Why this type |
|---|---|---|---|
| `edge` | QEMU VM (Phase 2) | TLS reverse proxy, cert from [`lab-ca`](examples/lab-ca/README.md) | needs a full network stack + cloud-init; the fidelity case |
| `api1`, `api2` | **Firecracker** | two identical app microVMs behind `edge` | the density case; MMDS gives each its own identity from one image |
| `db` | LXD/Incus (Phase 5) | stateful "pet" with its own init | the system-container case |
| `metrics` | podman (Phase 4) | rootless scrape/collect sidecar | the OCI case, rootless |

### 9.3 The unified spec

```toml
[lab]
name        = "micro-cloud"
description = "A single-host micro cloud: image service, four compute types on one L2 fabric, metadata, PKI, one control plane."
tags        = ["cloud", "firecracker", "cross-phase", "capstone"]

[[chroot]]                       # Phase 1 — the image service
name = "micro-cloud-base"
backend = "debootstrap"; distro = "debian"; suite = "bookworm"; arch = "x86_64"
target  = "/var/chroots/micro-cloud-base"

[[microvm]]                      # Phase 7 — NEW
name = "api1"; engine = "firecracker"
kernel = "images/vmlinux"; rootfs = "images/debian.ext4"
vcpus = 1; memory = "256M"
network = { bridge = "br-mc0", ip = "10.71.0.11/24", gateway = "10.71.0.1" }
mmds    = { "instance-id" = "api1", "local-hostname" = "api1" }

[[vm]]                           # Phase 2
name = "edge"; backend = "disk-image"; distro = "debian"; suite = "bookworm"
arch = "x86_64"; memory = "1024M"; network_mode = "bridge"; bridge = "br-mc0"

[[instance]]                     # Phase 5
name = "db"; engine = "lxd"; type = "container"

[[service]]                      # Phase 4
name = "metrics"; engine = "podman"; image = "docker.io/library/alpine:latest"
```

Same file, five tools, one `--lab micro-cloud` view. That is the demo.

### 9.4 Sibling, not stretch arm — the bare-metal tier

v1 listed this as a deferred sixth instance. **v2 reclassifies it**: bare metal is not a
harder version of the same thing, it is a *different abstraction* (§2.1), and it is
already built — [`examples/metal-as-a-service/`](examples/metal-as-a-service/), v1
complete, with a 16-defect ledger. It stays a **cross-linked sibling**: the micro-cloud
README's mapping table points at it for the Ironic row, and MAAS's README gains a
"the cloud-side counterpart" pointer. Absorbing it would mean flattening the one
distinction this plan most wants the reader to see.

---

## 10. Verification plan — what runs where

**v1's partition is void.** It assumed nothing that boots could be verified here.
Re-measured 2026-07-29: `/dev/kvm` present and **openable RW** (checked with
`os.open(O_RDWR)`, not inferred from `id -nG`), `svm` in `/proc/cpuinfo`, QEMU installed,
user in `kvm` and `libvirt`, releases API reachable. Firecracker can run on this host.

So the honesty burden **moves**, it does not disappear. The old question was *"which
claims are untested?"* The new and harder one is:

> **Which claims were tested by observation, and which only by reading a config?**

That is the mechanism-vs-outcome trap, and it is the single failure mode most likely to
make this lab feel understood while it is not. Every test below is labelled accordingly.

Per CLAUDE.md, every test prints exactly one verdict line (`PASS`/`FAIL`/`SKIP`, exit
0/1/77) via `tests/lib.sh`, arms an `EXIT` trap that prints `FAIL: test exited early
(rc=N)` for any rc outside `{0,77}`, and wraps every `die`-ing call in a subshell.

**Generator tests — assert the artifact, need no KVM, gate CI:**

| Test | Asserts | ⚠️ does NOT prove |
|---|---|---|
| `test-fc-config-json.sh` | spec → `config.json`: exactly one root drive, `reboot=k panic=1` present, `ip=` octets match, `host_dev_name` matches the planned tap, MMDS block iff `mmds` set | that a panic actually exits — see the boot test |
| `test-fc-argv.sh` | `firecracker`/`jailer` argv per spec (sourced-function unit test, modelled on [`test-microvm-argv.sh`](phase2-qemu-vm/tests/test-microvm-argv.sh)) | that the VMM accepts it |
| `test-export-rootfs.sh` | `mkfs.ext4 -d` output is valid ext4 whose `/sbin/init` is present, read back with `debugfs -R` — no mount, no KVM | that the kernel can *boot* it |
| `test-fabric-plan.sh` | `fabric.sh --dry-run` emits the exact `ip`/`nft`/`dnsmasq` plan; no IP collisions; every `up` line has a matching `down` line | that the bridge forwards a packet |
| `test-spec-validation.sh` | `micro-cloud.toml` parses (`tomllib`); addresses unique; every `[[microvm]]` names a kernel + rootfs | — |
| `test-fc-preflight.sh` | every §5.9 gate refuses **before** the rootfs copy and the tap — with a tripwire negative control, the shape [`test-fleet-preflight.sh`](examples/metal-as-a-service/tests/test-fleet-preflight.sh) established | — |
| `test-shellcheck.sh` | `lab-fc.sh`, `fabric.sh`, `micro-cloud.sh` clean | — |
| `test-no-pattern-kill.sh` | greps the new scripts for `pkill -f`/`killall` and fails on a hit — the CLAUDE.md footgun, guarded mechanically | — |

**Behaviour tests — need KVM, and now RUN here:**

| Test | Observes |
|---|---|
| `test-fc-boots.sh` | a microVM reaches a login prompt; records wall-clock boot time |
| `test-fc-panic-exits.sh` | **the negative control for `panic=1`**: with it, a guest panic exits the VMM; without it, the VM hangs. Watched, not read |
| `test-mmds-from-guest.sh` | `169.254.169.254` answers *inside* the guest, V2 token handshake included |
| `test-fabric-forwards.sh` | two microVMs on `br-mc0` reach each other; teardown asserts absence |
| `test-clone-entropy.sh` | the §5.8 hazard: restored clones produce identical `/dev/urandom` reads — then don't, after re-seeding |

**Still author-run / sudo-gated:** `lab-chroot.sh create` (debootstrap needs root), the
fabric's `ip`/`nft`/`sysctl` (needs `CAP_NET_ADMIN`), and the pinned `firecracker`
download (the agent's Bash runner gates fetch-then-execute of prebuilt binaries; the
author fetches, the agent verifies the `sha256`).

`lab-fc.sh` still gets a `--dry-run` that prints its command plan instead of executing —
not because KVM is missing, but because a plan you can diff against the hand-walk is the
§0.1 rule made mechanical. Same dependency-injection trick that made
[`be.sh`](examples/zfsbootmenu-boot-environments/be.sh) logic-testable with no ZFS.

---

## 11. Catalog routing

Both gates must stay green (`tools/link_check.py`, `tools/paths.py --check`):

- **[`examples/00-INDEX.md`](examples/00-INDEX.md)** — a new
  `## ☁️ Micro cloud — every phase, one fabric` section, plus a row under the Phase-1
  section for the `export-rootfs` example spec, and a
  `## 🔥 Firecracker microVMs — Phase 7` section for the standalone FC specs.
- **[`examples/learning-paths.toml`](examples/learning-paths.toml)** — a new
  `[[path]] id = "micro-cloud"` (🔴 deep, ⏱ half-day+). **v2: the path steps are the
  slices of §14, in order**, which is the point — the build order and the learning order
  are the same sequence, so the path is not a retrospective narration of a finished lab.
  Each step needs an **observable** checkpoint (a `curl` output, a boot banner, an
  `ip link` listing) mirroring `MANUAL_TESTING.md`. The image-build and config-generation
  steps can carry `verify_cmd` + `verify_marker` with `verify_host = true`; boot steps
  stay lab-context. Also add the lab to `close-to-the-metal`.
- Then `tools/paths.py render && tools/paths.py --check` and `tools/link_check.py`. New
  phase dirs also want a `README.md` + `SHOWCASE.md` + `MANUAL_TESTING.md` to match
  phases 1–5, and a row in the status table in [`README.md`](README.md).

**Discoverability is a deliverable, not a chore.** A reader arriving at
`examples/micro-cloud/README.md` should be able to answer "what is a cloud made of" from
the §2 table alone, and then "which of these can I go type right now" from the path
steps. The `LEDGER.md` is part of that surface: it is the file that says *this was harder
than it looks, here is where*.

---

## 12. Provenance — and the hand-walk v1 ruled out

Firecracker is **official multi-page documentation plus upstream code**, not one blog
post — so per CLAUDE.md this is the **cite-don't-mirror** tier, like
[`examples/zfsbootmenu-boot-environments/UPSTREAM.md`](examples/zfsbootmenu-boot-environments/UPSTREAM.md).
`UPSTREAM.md` records exact URLs (getting-started, network setup, jailer, MMDS,
snapshotting, the API spec) with a **retrieved date**, the **pinned release tag +
`sha256`** for every downloaded binary and kernel artifact, and a one-line note per source
on what this lab adapted. No doc-site archiving.

**v1 refused a `hand-walk/`; v2 builds one.** v1's reasoning — *"a container cannot host a
KVM microVM here"* — was downstream of the no-KVM premise, and that premise is void.
`podman run --device /dev/kvm` gives a container everything Firecracker needs for a first
boot; networking needs `CAP_NET_ADMIN` and comes later, exactly the partition
[`phase1-chroot/hand-walk/`](phase1-chroot/hand-walk/) already documents for `binfmt`.

That matters more here than in any other lab, because the hand-walk *is* the vehicle for
§0.1's rule: a disposable container reproducing the environment, with a `RUNBOOK.md` that
walks the upstream steps and says **why** at each one. Its first checkpoint is
`--device /dev/kvm` working inside the container — proving the vehicle before relying on
it.

---

## 13. Risks and honest constraints

| Risk | Reality | Mitigation |
|---|---|---|
| ~~No KVM in this environment~~ | **Void.** `/dev/kvm` present and openable RW; `svm` in cpuinfo | — |
| ~~Egress blocks the release/docs endpoints~~ | **Void.** Releases API 200, `v1.16.1` | Still pin tag + `sha256` in a lockfile; the *fetch* is author-run (agent fetch-then-exec of prebuilt binaries is gated) |
| **Scope creep into "build a mini-OpenStack"** | Very real, and a learning goal makes it **worse** — every subsystem is now interesting on purpose | §0.1's slice rule; §15's transcript demoted from goal to milestone; one fabric, no scheduler, no multi-tenancy, no HA, no clustering |
| **Understanding the config instead of the machine** | The likeliest way this lab feels done while not being understood: every `config.json` assertion passes and nobody watched a panic hang | §10 splits generator tests from behaviour tests and labels what each does *not* prove; each slice carries a break-it pass |
| **Root is required for the fabric** | bridge/tap/nft/sysctl all need `CAP_NET_ADMIN` | Fabric is a separate script with its own confirmation and a teardown *test*; the image half stays rootless |
| **Subnet/bridge collision on this host** | `vbmc-pxe` + libvirt `default` already exist here | Enumerate and classify every existing bridge/subnet before the first `ip addr add` (CLAUDE.md blast-radius rule) |
| **Firecracker's minimal device model surprises people** | No UEFI/PXE/TPM; a kernel panic hangs forever without `panic=1` | Make the limits a *lesson* (§3); **observe** the hang, don't just assert the flag (§10) |
| **Duplicate state across snapshot clones** | Same entropy, MAC, secrets, clock | Demonstrate the hazard, then fix it — it's curriculum, and it's a **LIED** on the ladder (§5.8) |
| **The seam gets decided by accident** | §8's three shapes are easy to drift between; (a) is seductive because MAAS already proved it once, for a case that isn't this one | Decision E: choose after slice 5, from two running engines, not from imagination |
| **Phase 7 bit-rots against phases 1–6** | Six phase tools already share conventions by hand | `lab-fc.sh` reuses the manifest/`--json`/`--lab` shapes verbatim; the Phase-6 backend is the forcing function that proves it did |

---

## 14. Build order — vertical slices

Replaces v1's M0→M7 component ladder (§0.1 rule 1). **Every slice boots something and is
exercisable the day it lands.** Every slice has three parts: *build*, *exercise*, and
**break** — and the break pass writes into `LEDGER.md`.

| # | Slice | Build | Exercise | Break it |
|---|---|---|---|---|
| **1** | **One microVM, by hand** | pinned `v1.16.1`; a chroot; `export-rootfs` → ext4 (Alpine **and** Debian); a `vmlinux`; boot with `--no-api --config-file`; boot again over the REST API with `curl` | guest login prompt in <1s; both rootfs sizes and boot times recorded side by side | drop `panic=1` → **watch it hang forever**; flip `is_root_device`; bend the `ip=` octets; try `extract-vmlinux` on a Debian bzImage (decision B, answered by experiment) |
| **2** | **The microVM gets an identity** | one tap, no bridge yet; MMDS `PUT` from the host | read `instance-id` from `169.254.169.254` *inside* the guest; do the V2 token handshake by hand | V1 vs V2: show why V1 + an SSRF bug leaks credentials; ask MMDS for a key that was never `PUT` |
| **3** | **Two microVMs that can reach each other** | `fabric.sh up/down/status` — bridge, taps, nft masquerade, dnsmasq as DHCP **and** DNS authority | `api1` pings `api2` **by name**; `down` asserts absence | delete the bridge under a running VM; exhaust the DHCP pool; leave a stale tap and re-run `up`. Grade each on the chaos ladder |
| **4** | **The tool, and what it hides** | `phase7-firecracker/lab-fc.sh` + `preflight` (§5.9) + generator tests | same boot, one command; `--dry-run` output diffed against slice 1's hand-written `config.json` | the tripwire test: `preflight` must refuse **before** the rootfs copy and the tap. **Name what the tool silently started doing for you** — that list is the slice's real deliverable |
| **5** | **A second engine on one fabric** | add the QEMU `edge` (Phase 2 already does bridge mode) | two engines, one L2, one `--lab` view | kill one engine's daemon and see what the other reports. **Now answer decision E** (§8) with evidence |
| **6** | **The control plane** | whichever of §8's three shapes slice 5 argued for; the Phase-6 `fc.py` backend + topology slot | all instances in one tree; if the seam supports it, an `apply` that is a no-op on pass two | make the registry disagree with reality and see whether the loop notices — MAAS's registry-layer fault, ported |
| **7** | **The fleet** | snapshot/restore; the jailer tier | five warm clones from one memory image, faster than one boot | the clone-entropy hazard, then re-seeding; diff `/proc/<pid>/root`, `ns/net`, `Seccomp` plain vs jailed |
| **8** | **The demo** | `micro-cloud.sh up`, all five instances, the §15 transcript; catalog routing + learning path | the transcript reproduces | teardown leaves **nothing**: no bridge, no tap, no pid, no state dir |

**Natural stopping points, and they are real:** slice 2 is already a complete lesson (a
real IMDS on your own box). Slice 4 gives a usable Firecracker phase with no micro cloud
at all. Slice 6 is where it becomes a *cloud* rather than several things on a bridge.
Slices 7–8 are the flourish.

**The slices are also the learning-path steps** (§11) — build order and reading order are
one sequence, so the path is not a retrospective narration.

---

## 15. Exit criteria

**Demoted from goal to milestone** (§0.1). Slice 8's target, on a KVM-capable host — which
now includes this one:

```text
$ examples/micro-cloud/micro-cloud.sh up
  ✓ fabric br-mc0 up, 10.71.0.1/24, NAT via <uplink>, dnsmasq pid …
  ✓ images: debian.ext4 (412M), vmlinux (ELF, 5.2M)
  ✓ api1  (firecracker)  10.71.0.11  boot 0.13s
  ✓ api2  (firecracker)  10.71.0.12  boot 0.12s
  ✓ edge  (qemu vm)      10.71.0.101
  ✓ db    (lxd)          10.71.0.102
  ✓ metrics (podman)     rootless, host-side
$ phase6-tui/…                       # all five in one tree, one lab
$ ssh api1 'curl -s -H "X-metadata-token: $T" 169.254.169.254/latest/meta-data/instance-id'
api1
$ ssh api1 'ping -c1 db.mc.lab'      # 0% loss — heterogeneous instances, one L2
$ curl -k https://edge/               # TLS, cert issued by the lab CA
$ examples/micro-cloud/micro-cloud.sh down
  ✓ no br-mc0, no mc-* taps, no fc pids, no state dirs left
```

Plus: `examples/micro-cloud/tests/run-all.sh` and `phase7-firecracker/tests/run-all.sh`
print `N passed, 0 failed`, and `tools/link_check.py` + `tools/paths.py --check` are green.

**And the criterion v1 did not have** — the one that matches the actual goal:

> `LEDGER.md` is **not empty**, and every entry names something that was observed rather
> than predicted.

A micro cloud that came up first try taught nobody anything. Sixteen defects came out of
[`metal-as-a-service`](examples/metal-as-a-service/DEFERRED.md) while its suite was green
at every step; the ones here are already waiting in the four subsystems this repo has
never built.

---

## 16. Open questions for the user

Resolved since v1: the **phase number** (`phase7-firecracker`, decision 2), **which
release** (`v1.16.1`, decision A), the **hand-walk** (yes, decision 12), the **guest
distro** (both, Alpine default — decision F), and the **verification partition** (void,
§10).

Still open:

1. **Where to stop.** Slice 2, 4, 6, or 8 (§14)? All four are honest stopping points, and
   the plan is written so that stopping early leaves something finished rather than
   half-built.
2. **Decision E — the seam** (§8). Recommendation: leave it open until slice 5. Confirm
   you're content to start building without it settled, because that is unusual for this
   repo's plans.
3. **Does the fleet arm (slice 7) matter to you?** It's the most cloud-revealing part —
   snapshot/restore is *literally* how Lambda serves a cold start — and the most work.
4. **Subnet choice.** `10.71.0.0/24` was v1's pick, made without checking this host.
   `vbmc-pxe` and libvirt's `default` already exist here; want me to enumerate and
   classify every bridge/subnet before this is locked (§7, §13)?
5. **Which slice-1 kernel path first** — the pinned FC CI artifact (fast, known-good) or
   `mlbuild.sh --arch x86_64` with an FC-minimal kconfig (slower, and the kconfig exercise
   is itself a lesson)? Recommendation: **(a) to get a boot, then (b) to own it**, so a
   failure in the hand-built kernel is diagnosable against a known-good one.
