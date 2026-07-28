# Micro-Cloud Lab — Design Plan v1

> **Status**: draft v1 (2026-07-27) — **decision document, nothing built yet.**
> Scope: assemble the phases this repo already has into one single-host
> **micro cloud**, and add **Firecracker microVMs** as a fourth compute type
> alongside chroots, QEMU VMs, and containers.
>
> Sibling design docs: [`NETBOOT_LAB_PLAN.md`](NETBOOT_LAB_PLAN.md),
> [`MICRO_LINUX_LAB_PLAN.md`](MICRO_LINUX_LAB_PLAN.md),
> [`KALI_LLM_LAB_PLAN.md`](KALI_LLM_LAB_PLAN.md).
>
> **Rescued 2026-07-27, unchanged.** This doc was written on a branch that was never
> merged and was about to be deleted; it is restored here verbatim, with only this
> note added. Its analysis stands, but one thing moved underneath it on the same day:
> **[`METAL_AS_A_SERVICE_LAB_PLAN.md`](METAL_AS_A_SERVICE_LAB_PLAN.md) went from plan
> to a built v1** ([`examples/metal-as-a-service/`](examples/metal-as-a-service/)) —
> an Ironic-faithful control plane with a pluggable deploy interface, declarative
> `apply` reconciliation, and an actions panel over
> [`tools/control-pane`](tools/control-pane). So §"orchestration" and the bare-metal
> provisioning row below now have a concrete implementation to compose with rather
> than to invent. Read the mapping table with that substitution in mind.

---

## 0. TL;DR

A cloud is not a mystery box — it's **seven subsystems** (images, compute,
network, metadata, identity, orchestration, storage) wired together. This repo
already implements six of them, scattered across six phases and ~65 examples.
Nobody has ever *stood them up at the same time and called the result what it
is*.

This plan does three things:

1. **Names the mapping** — every mklab building block against the cloud
   subsystem it actually is (§2). This is the pedagogical payload: you don't
   learn "a cloud" by reading OpenStack, you learn it by recognising that
   `lab-chroot.sh export-tarball` *is* Glance and `virtualbmc-ipmi-lab` *is*
   Ironic.
2. **Adds the missing compute type** — `phase7-firecracker/lab-fc.sh`, a
   Firecracker driver with the same verb surface, TOML schema, and state model
   as every other phase (§5). Firecracker is what makes instances cheap enough
   (~125 ms boot, <5 MiB overhead) that "spawn twelve of them" is a lab step
   rather than an afternoon.
3. **Adds the one bridge that's missing** — `lab-chroot.sh export-rootfs`,
   turning any Phase-1 tree into the raw **ext4 block image** Firecracker
   boots (§6), exactly as `export-initrd` turned it into a netboot initrd.

The deliverable lab is `examples/micro-cloud/`: one `micro-cloud.toml`, one
bring-up script, five heterogeneous instances on one L2 fabric, a metadata
service, a CA, and a control plane that lists them all in one pane.

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
  BARE METAL (stretch)                    │   │  dnsmasq: DHCP+DNS+TFTP      │
    virtualbmc-ipmi-lab (IPMI/BMC)  ──────┤   └──────────────────────────────┘
    debian-pxe-lab (netboot install) ─────┘
```

**The demo that proves it works** (§15): `micro-cloud.sh up` brings the fabric
and five instances of four different types online; every instance resolves and
pings every other by name; each reads its own identity from the metadata
service; the TUI lists all five in one tree; `micro-cloud.sh down` leaves no
bridge, tap, process, or state directory behind.

---

## 2. The mapping — this repo is already most of a cloud

The point of the whole lab, in one table. Left column: what a cloud calls it.
Right column: what mklab already ships.

| Cloud subsystem | OpenStack / AWS | What already exists here | Gap |
|---|---|---|---|
| **Image service** | Glance / AMI | [`phase1-chroot/lab-chroot.sh`](phase1-chroot/lab-chroot.sh) `create` + `export-tarball` / `export-initrd`; [`micro-linux/mlbuild.sh`](micro-linux/mlbuild.sh) builds kernels from source | **`export-rootfs`** (ext4) — §6 |
| **Compute — VM** | Nova (libvirt) / EC2 | [`phase2-qemu-vm/lab-vm.sh`](phase2-qemu-vm/lab-vm.sh) — 6 arches, cloud-init, snapshots | — |
| **Compute — microVM** | Nova / Lambda, Fargate | *(QEMU's `microvm` machine is the closest — see [`examples/tiny-linux-experiments/micro-linux-x86_64-microvm.toml`](examples/tiny-linux-experiments/micro-linux-x86_64-microvm.toml))* | **`phase7-firecracker`** — §5 |
| **Compute — container** | Nova-LXD / ECS | [`phase3-docker`](phase3-docker/lab-docker.sh), [`phase4-podman`](phase4-podman/lab-podman.sh), [`phase5-lxd`](phase5-lxd/lab-lxd.sh) | — |
| **Compute — namespace** | *(below the cloud line)* | [`examples/exploring-containers/`](examples/exploring-containers/) | — |
| **Network** | Neutron / VPC | bridge/tap already in `lab-vm.sh` (`network_mode`, `bridge`, `tap`); dnsmasq in [`examples/podman-pxe-dhcp.toml`](examples/podman-pxe-dhcp.toml); routing/DNS in [`examples/tiny-internet-project/`](examples/tiny-internet-project/README.md) | **one fabric script** — §7 |
| **Metadata** | config-drive / IMDS | cloud-init NoCloud seeds (Phase 2) | **MMDS** — §5.7 |
| **Identity / PKI** | Keystone, ACM | [`examples/lab-ca/`](examples/lab-ca/README.md) — CA + server-cert issuance | wire it in |
| **Orchestration / API** | Heat, `nova boot` | [`phase6-tui/`](phase6-tui/README.md) + [`phase6b-web/`](phase6b-web/README.md) inventory + topology bring-up; `[lab]`-grouped TOML | **fc backend** — §8 |
| **Config management** | user-data, cloud-init | [`examples/ansible/`](examples/ansible/) | wire it in |
| **Block storage / snapshots** | Cinder, EBS snapshots | qcow2 snapshots (`lab-vm.sh snapshot`); ZFS boot environments in [`examples/zfsbootmenu-boot-environments/`](examples/zfsbootmenu-boot-environments/README.md) | FC snapshot/restore — §5.8 |
| **Bare metal** | Ironic | [`examples/virtualbmc-ipmi-lab/`](examples/virtualbmc-ipmi-lab/) (IPMI/BMC), [`examples/debian-pxe-lab/`](examples/debian-pxe-lab/), [`netboot/`](netboot/SHOWCASE.md) | stretch goal — §9 |

Two gaps are *real* (a compute driver and an image format); everything else is
integration work. **That ratio is the reason this lab is worth building.**

---

## 3. Why Firecracker — and what it is *not*

Firecracker is AWS's Rust VMM (it runs Lambda and Fargate). It is a KVM
front-end that deliberately implements almost no device model: virtio-net,
virtio-block, virtio-vsock, a serial port, and a keyboard controller that exists
only so the guest can trigger a reset. No PCI bus, no BIOS/UEFI, no option ROMs,
no SCSI, no USB, no VGA. That's the entire point — less emulated surface means a
smaller attack surface, ~5 MiB of VMM memory overhead, and a boot measured in
milliseconds.

**Where it sits among the four compute types this lab will run:**

| | isolation boundary | boot | image format | best at |
|---|---|---|---|---|
| chroot (Phase 1) | filesystem root only | none | directory tree | building images |
| container (Phase 3/4/5) | namespaces + cgroups (shared kernel) | ms | OCI layers / tarball | services, density |
| QEMU VM (Phase 2) | hardware virt, **full** device model | seconds | qcow2 (+UEFI) | fidelity: firmware, PXE, kdump, weird arches |
| **Firecracker (Phase 7)** | hardware virt, **minimal** device model | **~125 ms** | raw **ext4** + `vmlinux` | density with a real kernel boundary; fleets |

**What Firecracker is not, stated plainly** — so the lab doesn't oversell it:

- **Not a QEMU replacement.** No UEFI, no PXE/netboot, no TPM, no secure boot,
  no non-native arches. Every existing Phase-2 lab that teaches firmware or
  network boot *must stay on QEMU*. Firecracker deletes exactly the machinery
  those labs are about.
- **Not "QEMU microvm with a new name."** The repo already has QEMU's `microvm`
  machine type and it is genuinely close (virtio-mmio, qboot, no PCI). The
  differences that justify a whole new phase are the **API-driven lifecycle**
  (§5.5), **MMDS** (§5.7), **snapshot/restore-in-milliseconds** (§5.8), the
  **jailer** (§5.6), and **rate limiters** — i.e. the parts that make it a
  *cloud* compute driver rather than a fast emulator. A side-by-side of the two
  is itself a lab step.
- **Not runnable without KVM.** There is no TCG fallback. `/dev/kvm` or nothing
  (§10, §13).

---

## 4. Decisions

### Locked in

| # | Question | Answer |
|---|---|---|
| 1 | Scope of "micro cloud" | **Single host, no clustering.** One box, one L2 fabric, heterogeneous instances. Multi-host is explicitly out (it would become a networking lab, not a cloud lab). |
| 2 | New phase directory | **`phase7-firecracker/lab-fc.sh`** — a new compute *rung* on the ladder. Runner-up: `phase2b-firecracker/` (sibling-of-Phase-2, mirroring the `phase6b` convention) — rejected because `6b` means "same thing, different UI", while Firecracker is a different thing. Phase 6/6b stay the capstone and simply gain a sixth backend. |
| 3 | Instance identity | **Every instance is a `[[…]]` block in one `micro-cloud.toml`** with `lab = "micro-cloud"`, so all five existing `list --lab` surfaces and the Phase-6 topology view work unchanged. No new inventory format. |
| 4 | Firecracker launch mode | **Both.** `--no-api --config-file config.json` is the default (deterministic, reproducible, and a *pure function of the spec* → host-testable). The REST API over `--api-sock` is the **teaching** path in the runbook: `PUT /boot-source`, `/drives`, `/network-interfaces`, `/actions` is a cloud compute API you can read in ten minutes. |
| 5 | Rootfs format | **Raw ext4**, built by `mkfs.ext4 -d` from a Phase-1 chroot (§6). No loop mount, no root, no qcow2. |
| 6 | Kernel | **Pinned upstream FC CI `vmlinux`** as the fast path; **`micro-linux/mlbuild.sh` → `vmlinux`** as the own-the-whole-stack path (§6.3). |
| 7 | Network fabric | **One Linux bridge + one tap per instance**, `10.71.0.0/24`, host is `.1` and the NAT gateway. Not the per-microVM `/30` that FC's own getting-started uses — instances must reach *each other*, which is the whole point of a cloud. |
| 8 | Guest addressing | **Static via the kernel `ip=` boot arg** for Firecracker (no DHCP client needed in a 20 MB rootfs), **DHCP from dnsmasq** for the QEMU/LXD members that already expect it. Both served by the same fabric. |
| 9 | Isolation tier | **Plain `firecracker` first, `jailer` second** — as an explicit, documented upgrade step, because the jailer *is* a chroot + cgroup + netns + seccomp wrapper and therefore closes the loop back to Phase 1 (§5.6). |
| 10 | Verification honesty | **Partitioned** per CLAUDE.md: config/argv/image generation verified on the mklab host; every boot marked **author-run under KVM** (§10). |

### To confirm before building

| # | Question | Recommendation |
|---|---|---|
| A | Which release to pin? | Pin an explicit `v1.x.y` tag in a `versions.env`-style file with a `sha256`, mirroring [`micro-linux/versions.lock`](micro-linux/versions.lock). The exact current tag must be read off the release page at build time — **this environment's egress blocks it** (§13). |
| B | Does `scripts/extract-vmlinux` on a Debian `bzImage` produce an FC-bootable ELF? | Plausible but **unverified** — treat as an experiment, not a documented path, until someone boots it. Ship (a) and (b) from §6.3 first. |
| C | vsock guest agent, or SSH? | Start with SSH over the fabric (familiar). Add a vsock "no-network agent" as a later step — it's the neatest demonstration that a control plane doesn't need the data network. |
| D | Include the Ironic/bare-metal tier in v1? | **No** — document it as the stretch arm (§9.4). The IPMI + PXE labs already exist and stand alone; folding them in now doubles the surface. |

---

## 5. New component A — `phase7-firecracker/lab-fc.sh`

The contract every phase tool in this repo honours: one self-contained bash
script, TOML-or-flags input, a per-resource state dir with a `manifest.toml`,
`--json` on the read verbs, `--lab` filtering, and `tests/` whose every file
prints exactly one `PASS`/`FAIL`/`SKIP` line.

### 5.1 CLI surface

```bash
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

`stop`/`destroy` **resolve to a PID and `kill` it** — never `pkill -f`. The
per-VM socket paths (`api.sock`, `console.sock`) appear in the `firecracker`
argv, so a pattern kill would match the very process it names, plus any sibling
tooling. This is the exact footgun CLAUDE.md documents; the fix is `fc.pid`.

### 5.2 `[[microvm]]` TOML schema

Array-of-tables with an `engine` key, so it coexists in a unified lab file
exactly like `[[service]]`/`[[instance]]` do today:

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

Fields that mirror Phase 2's manifest (`name`, `lab`, `memory`, `kernel`) keep
their Phase-2 spelling so the Phase-6 backends and any future cross-phase
tooling can read either without special-casing.

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

`--no-api --config-file` means the entire boot is a **pure function of the
spec**. That function is the unit under test, and it needs no KVM:

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

`tests/test-fc-config-json.sh` asserts, with `python3 -m json.tool` + a schema
walk: `is_root_device` true on exactly one drive; `boot_args` carries
`reboot=k panic=1` (without which a guest panic **hangs the VM forever** instead
of exiting — the single most confusing Firecracker failure mode); the `ip=`
octets match the spec; `host_dev_name` matches the tap the fabric will create;
`ro` rootfs never paired with a writable overlay-less boot. Every assertion gets
its own `fail "REGRESSION: …"` message.

### 5.5 API mode is the lesson, config mode is the default

The runbook's centrepiece is booting one microVM *by hand*, with `curl`, over a
Unix socket — because that is precisely what a cloud's compute API does when you
click "launch instance":

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

Then the same boot via `lab-fc.sh start` — and the point lands: the tool is a
config generator and a process babysitter, nothing more. That demystification is
the reason to build the phase by hand rather than wrap `ignite` or `weave`.

### 5.6 The jailer tier — Phase 1 closes the loop

`jailer` is the production launcher: it creates a chroot, moves the VMM into it,
drops to an unprivileged uid/gid, joins a netns and a cgroup, then execs
`firecracker` with seccomp filters applied.

```bash
jailer --id api1 --exec-file /usr/bin/firecracker \
       --uid 30000 --gid 30000 --chroot-base-dir /srv/jail --netns /var/run/netns/mc-api1 \
       -- --config-file config.json
```

Every noun in that command line is something an earlier phase already taught:
chroot (Phase 1), namespaces and cgroups
([`examples/exploring-containers/`](examples/exploring-containers/)), and now
they're wrapped *around a hypervisor*. The lab step is "boot the same microVM
twice, plain and jailed, then diff `/proc/<pid>/root`, `/proc/<pid>/ns/net`, and
`/proc/<pid>/status`'s `Seccomp` line." Note the sharp edge: under the jailer
every path in `config.json` is **relative to the new chroot**, so the kernel and
rootfs must be hard-linked or bind-mounted in first — the classic first-attempt
failure.

### 5.7 MMDS — a real 169.254.169.254

Firecracker's Microvm Metadata Service is a genuine link-local metadata endpoint
served by the VMM itself. The guest does `curl 169.254.169.254/latest/meta-data/`
and gets back whatever the host `PUT` into MMDS — which is *exactly* the EC2/GCE
IMDS contract, including V2's token handshake:

```bash
TOKEN=$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-metadata-token-ttl-seconds: 60')
curl -s -H "X-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id
```

This is the highest-value teaching artifact in the whole plan: the same magic IP
you've hit on every EC2 box, running on your laptop, served by a process you
started, with contents you can read on disk. It also grounds the security
lesson — MMDS V2's token exists because V1 plus an SSRF bug is how cloud
credentials get stolen.

The QEMU members of the fabric keep their cloud-init NoCloud seed; the runbook
puts the two side by side (config-drive vs. IMDS) as the two ways every cloud
does metadata.

### 5.8 Snapshot / restore — the "micro" in micro cloud

Pause a running microVM, write its memory and device state to disk, then restore
it — repeatedly, into *many* new instances. Restore skips boot entirely:

```bash
lab-fc.sh snapshot api1 --tag warm         # pause → PUT /snapshot/create → resume
for n in 1 2 3 4 5; do lab-fc.sh restore "w$n" --from api1:warm; done
```

Five identical warm instances, each resumed from the same memory image, in about
the time one of them would have taken to boot. That is literally how Lambda
serves a cold start.

**And it must be taught with its caveats**, which are real cloud-engineering
lessons, not footnotes: every clone resumes with the *same* entropy pool, the
same in-memory secrets, the same MAC and the same view of its network, and the
same clock. Restoring a snapshot across a different VMM version or CPU model is
unsupported. The lab step is to *demonstrate* the duplicate-randomness hazard
(`head -c8 /dev/urandom | xxd` matching across clones) and then fix it by
re-seeding on resume — which is why real fleets treat snapshot restore as
requiring an explicit re-personalisation step.

---

## 6. New component B — `lab-chroot.sh export-rootfs` (the image service)

Firecracker boots a **raw ext4 filesystem image** as `/dev/vda`. Phase 1 already
knows how to produce a root filesystem; it just can't emit that container yet.
This verb is the exact analogue of `export-initrd` (which emits `cpio.gz` for
netboot) and `export-tarball` (which emits an OCI-importable tarball).

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

Step 4 is the whole trick. **`mke2fs -d <dir>` builds a populated filesystem
image without ever mounting it** — no loop device, no `CAP_SYS_ADMIN`, no
privileged container. That matters twice over: it keeps the verb usable
rootlessly wherever the tree is readable, and it makes the output
**verifiable on a host with no KVM and no mount privileges**, because `debugfs
-R` can list and extract files straight out of the image.

> **Verified on the mklab host while writing this plan** (2026-07-27): building a
> 32 MiB ext4 from a directory with `truncate` + `mkfs.ext4 -d`, then reading
> `/etc/hostname` back out with `debugfs -R 'ls -l /etc'`, succeeds with no loop
> mount and no elevated capability. So §10's host-side image test is known-good
> before a line of it is written.

The same image is what a QEMU `kernel+initrd` VM can take as a `disk=`, so
`export-rootfs` is useful even to people who never install Firecracker.

### 6.3 The kernel

Firecracker takes an **uncompressed ELF `vmlinux`** on x86_64 — not the
`bzImage` QEMU boots — and a PE-format `Image` on aarch64. Three sources, in the
order the lab should present them:

| # | Source | Verdict |
|---|---|---|
| a | Upstream Firecracker CI kernel artifacts, pinned + `sha256`'d | **Fast path.** Known-good, zero build time. Requires egress (§13). |
| b | [`micro-linux/mlbuild.sh`](micro-linux/mlbuild.sh) with a new `vmlinux` artifact target + an FC-minimal `.config` | **The good path.** `mlbuild.sh` already builds pinned, PGP-verified kernels from source per arch; its `kernel_image()` case statement already returns `vmlinux` for ppc64le (QEMU's pseries takes the ELF directly), so x86_64-for-FC is a small, well-precedented addition. Config needs virtio-mmio/blk/net + 8250 serial + KVM guest, and can drop essentially all of PCI — which is a genuinely instructive kconfig exercise. |
| c | `scripts/extract-vmlinux` on a distro `bzImage` | **Unverified** (decision B). Do not document as a path until someone boots it. |

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
`.100–.200` DHCP pool (QEMU cloud images, LXD containers). Containers from
Phase 3/4 join through their own engine networks and reach the fabric via the
host — the runbook is explicit that this asymmetry exists and *why* (rootless
podman has no business enslaving a host bridge).

`down` is written as a **teardown test**, not a best-effort cleanup: it asserts
absence afterwards and fails loudly otherwise, because a leaked bridge with a
stale `10.71.0.1` is the kind of thing that quietly breaks the *next* lab.

---

## 8. New component D — control plane integration

Phase 6's backend layer is an ABC with five implementations; adding a sixth is
mechanical and is the payoff for `lab-fc.sh` honouring the phase contract:

- `phase6-tui/lab_tui/backends/fc.py` — `FCBackend(BackendRunner)`, `name = "fc"`,
  `state_paths() → $LAB_STATE_DIR/fc`, `list_resources()` reading each
  `manifest.toml` + `fc.pid` liveness (the same `_pid_alive` pattern
  `vm.py` uses), `inspect()` preferring `lab-fc.sh inspect --json`,
  `console_command` → `lab-fc.sh console <name>` when running.
- `BackendName` literal and `ALL_BACKENDS` gain `"fc"`.
- `phase6-tui/lab_tui/topology.py` — a `"fc"` `PhaseSlot`. Ordering matters and
  is a *dependency*, not a preference: **Phase 1 (build the tree) → export-rootfs
  (make the image) → fabric up → fc/vm/containers → fabric down last.**
- Phase 6b picks it up for free — `base.py` is deliberately framework-agnostic
  and the web routes consume the same backends.

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
├── RUNBOOK-build-images.md   chroot → export-rootfs → vmlinux (§6)
├── RUNBOOK-first-microvm.md  boot one FC by hand over the REST API (§5.5)
├── RUNBOOK-micro-cloud.md    the full bring-up, instance by instance
├── RUNBOOK-fleet.md          snapshot → restore ×5 + the clone hazards (§5.8)
├── UPSTREAM.md               cite-don't-mirror provenance (§12)
├── MANUAL_TESTING.md         verified-here vs author-run matrix (§10)
└── tests/                    lib.sh + run-all.sh + host-safe checks (§10)
```

### 9.2 The instances

Five instances, four compute types, one fabric — chosen so each one *has a
reason to exist*:

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

### 9.4 Stretch arm — the Ironic tier

Deliberately *not* in v1 (decision D): a sixth instance provisioned like bare
metal — [`virtualbmc-ipmi-lab`](examples/virtualbmc-ipmi-lab/) gives a QEMU VM an
IPMI BMC, so `ipmitool … chassis bootdev pxe` + `power on` drives a
[`debian-pxe-lab`](examples/debian-pxe-lab/) network install onto it. Both halves
already work standalone; joining them is a follow-up plan, not a section of this
one.

---

## 10. Verification plan — what runs where

Per CLAUDE.md, every test prints exactly one verdict line (`PASS`/`FAIL`/`SKIP`,
exit 0/1/77) via `tests/lib.sh`, arms an `EXIT` trap that prints
`FAIL: test exited early (rc=N)` for any rc outside `{0,77}`, and wraps every
`die`-ing call in a subshell so a `die` can't blow past an `if` and kill the run
before its assertions.

**Host-safe — runs on the mklab controller, gates CI:**

| Test | Asserts |
|---|---|
| `test-fc-config-json.sh` | spec → `config.json` is correct: exactly one root drive, `reboot=k panic=1` present, `ip=` octets match, `host_dev_name` matches the planned tap, MMDS block present iff `mmds` set |
| `test-fc-argv.sh` | `firecracker` / `jailer` argv construction per spec (sourced-function unit test, modelled on [`phase2-qemu-vm/tests/test-microvm-argv.sh`](phase2-qemu-vm/tests/test-microvm-argv.sh)) |
| `test-export-rootfs.sh` | `mkfs.ext4 -d` output is a valid ext4 whose `/sbin/init` is present, read back with `debugfs -R` — **no mount, no KVM** (§6.2, pre-verified) |
| `test-fabric-plan.sh` | `fabric.sh --dry-run` emits the exact `ip`/`nft`/`dnsmasq` command plan; no IP collisions; every `up` line has a matching `down` line |
| `test-spec-validation.sh` | `micro-cloud.toml` parses (`tomllib`); addresses unique; every `[[microvm]]` names a kernel + rootfs |
| `test-shellcheck.sh` | `lab-fc.sh`, `fabric.sh`, `micro-cloud.sh` clean |
| `test-no-pattern-kill.sh` | greps the new scripts for `pkill -f`/`killall` and fails on a hit — the CLAUDE.md footgun, guarded mechanically |

Note the shape: `lab-fc.sh` gets a `--dry-run` that prints its command plan
instead of executing it, the same dependency-injection trick that made
[`be.sh`](examples/zfsbootmenu-boot-environments/be.sh) logic-testable on a host
with no ZFS. **Design for the sandbox you have.**

**Author-run, under KVM — marked as such, never claimed as verified:**
every actual boot; MMDS from inside a guest; snapshot/restore and the clone
hazard; jailer isolation diffs; the full five-instance bring-up; teardown
leaving no bridge/tap/pid behind.

This host has **no `/dev/kvm`, no vmx/svm CPU flags, and no QEMU** — Firecracker
cannot run here at all, and there is no TCG fallback to fall back to. That is
stated plainly in `MANUAL_TESTING.md` rather than papered over.

---

## 11. Catalog routing

Both gates must stay green (`tools/link_check.py`, `tools/paths.py --check`):

- **[`examples/00-INDEX.md`](examples/00-INDEX.md)** — a new
  `## ☁️ Micro cloud — every phase, one fabric` section, plus a row under the
  Phase-1 section for the `export-rootfs` example spec, and a
  `## 🔥 Firecracker microVMs — Phase 7` section for the standalone FC specs.
- **[`examples/learning-paths.toml`](examples/learning-paths.toml)** — a new
  `[[path]] id = "micro-cloud"` (🔴 deep, ⏱ half-day+) whose steps are:
  chroot → `export-rootfs` → one hand-driven FC boot over the REST API → the
  fabric → the five-instance bring-up → snapshot fleet → the control plane.
  Each step needs an **observable** checkpoint (a `curl` output, a boot banner,
  an `ip link` listing) mirroring `MANUAL_TESTING.md`. The image-build and
  config-generation steps can carry `verify_cmd` + `verify_marker` with
  `verify_host = true`; the boot steps stay lab-context.
  Also add the lab to the `close-to-the-metal` collection.
- Then `tools/paths.py render && tools/paths.py --check` and
  `tools/link_check.py`. New phase dirs also want a `README.md` +
  `SHOWCASE.md` + `MANUAL_TESTING.md` to match phases 1–5, and a row in the
  status table in [`README.md`](README.md).

---

## 12. Provenance

Firecracker is **official multi-page documentation plus upstream code**, not one
blog post — so per CLAUDE.md this is the **cite-don't-mirror** tier, like
[`examples/zfsbootmenu-boot-environments/UPSTREAM.md`](examples/zfsbootmenu-boot-environments/UPSTREAM.md).
`UPSTREAM.md` records exact URLs (getting-started, network setup, jailer, MMDS,
snapshotting, the API spec) with a **retrieved date**, the **pinned release tag
+ `sha256`** for every downloaded binary and kernel artifact, and a one-line note
per source on what this lab adapted. No doc-site archiving.

A `hand-walk/` sandbox is **not** proposed: the whole point of the hand-walk
pattern is reproducing an author's environment inside a container, and a
container cannot host a KVM microVM here. The by-hand REST-API runbook (§5.5)
serves the same pedagogical role in the only place it can run.

---

## 13. Risks and honest constraints

| Risk | Reality | Mitigation |
|---|---|---|
| **No KVM in this environment** | Firecracker cannot execute here — at all | Partition verification (§10); design every script with a `--dry-run` plan mode so the *logic* is CI-gated |
| **Egress blocks the release/docs endpoints** | The GitHub release download for the FC binary and the FC CI kernel artifacts are not reachable from this container (the ZFSBootMenu lab hit the same wall) | Pin versions + hashes in a lockfile; the fetch is an author-run step; `lab-fc.sh` must fail with a *useful* message, not a stack trace, when the binary is absent |
| **Root is required for the fabric** | bridge/tap/nft/sysctl all need `CAP_NET_ADMIN` | Fabric is a separate script with its own confirmation and a teardown test; the *image* half stays rootless |
| **Scope creep into "build a mini-OpenStack"** | Very real — the mapping table is seductive | v1 ships one fabric, five instances, no scheduler, no multi-tenancy, no clustering, no HA. Ironic tier explicitly deferred (§9.4) |
| **Firecracker's minimal device model surprises people** | No UEFI/PXE/TPM; a kernel panic hangs forever without `panic=1` | Make the limits a *lesson* (§3), and assert `reboot=k panic=1` in the config test |
| **Duplicate state across snapshot clones** | Same entropy, MAC, secrets, clock | Demonstrate the hazard, then fix it — it's a feature of the curriculum (§5.8) |
| **Phase 7 bit-rots against phases 1–6** | Six phase tools already share conventions by hand | `lab-fc.sh` must reuse the existing manifest/`--json`/`--lab` shapes verbatim; the Phase-6 backend is the forcing function that proves it did |

---

## 14. Build order

Each milestone is independently useful and independently verifiable — no
milestone requires the next one to justify itself.

| # | Milestone | Deliverable | Verified how |
|---|---|---|---|
| **M0** | This plan | `MICRO_CLOUD_LAB_PLAN.md` | link/paths gates green |
| **M1** | Image service | `lab-chroot.sh export-rootfs` + test + docs | **host-safe** — ext4 built and read back with `debugfs` |
| **M2** | Kernel | `mlbuild.sh` `vmlinux` target + FC-minimal kconfig | **host-safe** — artifact exists, `file` says ELF |
| **M3** | The driver | `phase7-firecracker/lab-fc.sh` (create/start/stop/list/inspect/destroy/console/ssh) + `--dry-run` + tests | **host-safe** for config/argv; boot is author-run |
| **M4** | Fabric | `fabric.sh up/down/status` + dry-run plan test | plan test host-safe; bring-up author-run |
| **M5** | The lab | `examples/micro-cloud/` — spec, `micro-cloud.sh`, 4 runbooks, MANUAL_TESTING | author-run end-to-end |
| **M6** | Control plane + catalog | `fc.py` backend, topology slot, 00-INDEX rows, learning path, README status row | Phase-6 tests + `paths.py --check` |
| **M7** *(stretch)* | Fleet + jailer | snapshot/restore, clone-hazard demo, jailer tier | author-run |

Natural stopping points: after **M3** you have a usable Firecracker phase even
with no micro cloud; after **M5** you have the lab; **M6** makes it discoverable;
**M7** is the flourish.

---

## 15. Exit criteria

The lab is done when, on a KVM-capable host, this transcript is reproducible:

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

Plus, on **any** host including this one: `examples/micro-cloud/tests/run-all.sh`
and `phase7-firecracker/tests/run-all.sh` print `N passed, 0 failed`, and
`tools/link_check.py` + `tools/paths.py --check` are green.

---

## 16. Open questions for the user

1. **Phase number** — `phase7-firecracker/` (recommended: a new compute rung) or
   `phase2b-firecracker/` (sibling-of-QEMU, mirroring the `6b` convention)?
2. **Scope of v1** — the full §14 ladder (M1–M6), or start with **M1+M3** (the
   image bridge + the Firecracker phase, standalone) and decide about the micro
   cloud once there's something to boot?
3. **Guest distro for the microVM rootfs** — Debian (consistent with the rest of
   the repo, ~400 MB) or Alpine (~40 MB, and `lab-vm.sh` already has an Alpine
   microvm builder to borrow from)? Recommendation: **both**, Alpine as the
   default because a 40 MB rootfs makes "spawn twelve" real.
4. **Does the fleet/snapshot arm (M7) matter to you?** It's the most
   cloud-revealing part and the most work.
5. **Ironic tier** — leave deferred (§9.4), or is bare-metal-style provisioning
   the part you actually wanted?
