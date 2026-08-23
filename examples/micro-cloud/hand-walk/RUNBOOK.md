# Hand-walk: boot a Firecracker microVM by hand, in a box

The inverse of [`micro-cloud.sh up`](../micro-cloud.sh). Nothing here is automated: you
`curl` a REST API over a unix socket, watch a kernel boot, and see the VMM as a process.
The automated counterpart, [`phase7-firecracker/lab-fc.sh`](../../../phase7-firecracker/lab-fc.sh),
issues these same calls — this file is the part you can type.

Source of truth for every step: [`../UPSTREAM.md`](../UPSTREAM.md), which cites Firecracker's
own docs (fetched and 200 on 2026-08-23). There is no `upstream-tutorial/` archive here on
purpose — this lab tracks a multi-page doc site and upstream code, which is the repo's
**cite-don't-mirror** tier.

> **Verified, not asserted.** Everything below was run on **2026-08-23** in the box this
> directory builds. The guest reached an Alpine login prompt with `uptime=0.04s`, inside a
> **rootless** podman container. The repo's rule is that a hand-walk is built *and booted*
> before it is claimed; that is what this note records.

## The box

```bash
phase4-podman/lab-podman.sh up --config examples/micro-cloud/hand-walk/hand-walk.toml
podman exec -it lab-micro-cloud-hand-walk-handwalk sh
```

Through the phase tool, not a one-off `podman run` — the repo's rule, and nothing here needs
an exception: `/dev/kvm` arrives via the spec's `devices` key.

**What the image deliberately does NOT contain**, because both are load-bearing decisions:

| not baked in | why |
|---|---|
| the `firecracker` binary | the toolchain-fetch gate forbids fetch+exec of a prebuilt toolchain, and a `RUN curl … && chmod +x` would be exactly that one layer down. It is **bind-mounted** from the pinned v1.16.1 copy, so the box runs the binary the rest of the lab measured rather than whatever is newest on rebuild day |
| `vmlinux` and `rootfs.ext4` | they are lab **output** ([`RUNBOOK-micro-cloud.md` step 0](../RUNBOOK-micro-cloud.md#step-0--the-spine-and-the-two-things-made-from-it-root-once) builds them). An image carrying them starts going stale against the thing that produces them |

## 1. Look before you boot

```sh
ls -l /dev/kvm            # crw-rw----+  … 10, 232   ← P1's finding: a container CAN have this
firecracker --version     # Firecracker v1.16.1      ← the pinned one, mounted in
file -b /work/vmlinux     # ELF 64-bit LSB executable, x86-64 … statically linked
```

**That third line is a real trap, not a formality.** Firecracker's loader is **ELF-only** and
answers a `vmlinuz` with `Elf(InvalidElfMagicNumber)`. A distro kernel is a bzImage; the file
you need is an *uncompressed* `vmlinux`. Asking `file` is how you find that out in one second
instead of after a confusing refusal.

## 2. The rootfs must be writable

```sh
cp /work/rootfs.ext4 /tmp/rw.ext4
```

The mount is `:ro` on purpose — so this step is impossible to skip by accident. A guest whose
root filesystem cannot be written does not fail at boot; it fails later, oddly, inside
userspace. Copying also means the walk is repeatable: every run starts from the same bytes.

## 3. Start the VMM — it does nothing yet

```sh
firecracker --api-sock /tmp/fc.sock > /tmp/fc.log 2>&1 &
```

A started Firecracker is an **API server with no machine**. That separation is the whole
design: the machine is *described* over the API and only then started. `ps` shows one
process; nothing is running inside it.

## 4. Describe the machine — two PUTs

```sh
curl -s -X PUT --unix-socket /tmp/fc.sock http://localhost/boot-source \
  -H 'Content-Type: application/json' \
  -d '{"kernel_image_path":"/work/vmlinux",
       "boot_args":"console=ttyS0 reboot=k panic=1 pci=off i8042.nopnp"}'

curl -s -X PUT --unix-socket /tmp/fc.sock http://localhost/drives/rootfs \
  -H 'Content-Type: application/json' \
  -d '{"drive_id":"rootfs","path_on_host":"/tmp/rw.ext4",
       "is_root_device":true,"is_read_only":false}'
```

Each answers **204 No Content**. Read the boot args:

- `console=ttyS0` — there is no VGA; the serial console *is* the screen.
- `pci=off` — a microVM has no PCI bus, and probing for one wastes boot time.
- **`i8042.nopnp`** — this repo measured that a PS/2 controller probe is roughly **90% of a
  Firecracker boot**: 0.55 s becomes 0.055 s. It is the single most surprising number in the
  lab, and it is one kernel argument.

## 5. Start it, and watch a kernel boot

```sh
curl -s -X PUT --unix-socket /tmp/fc.sock http://localhost/actions \
  -H 'Content-Type: application/json' -d '{"action_type":"InstanceStart"}'
tail -f /tmp/fc.log
```

Observed on 2026-08-23, in this box:

```
[    0.061387] Run /sbin/init as init process
MICROVM-UP uptime=0.04s

Welcome to Alpine Linux 3.21
Kernel 6.1.155+ on an x86_64 (/dev/ttyS0)

(none) login:
```

**`uptime=0.04s` is the checkpoint.** Not "it printed something" — a guest that reached
userspace and said so.

## What this box CANNOT do, and why that is honest

**Networking.** A tap device needs `CAP_NET_ADMIN`, which this container does not have and
should not be given: the host it runs on carries a live Calico cluster whose tunnel endpoint
a stray tap has captured before. So the guest above has **no NIC** — which is exactly why the
walk uses a serial console for its evidence rather than `ssh`.

This is the same partition [`phase1-chroot/hand-walk/`](../../../phase1-chroot/hand-walk/)
documents for `binfmt`: the parts that need a privilege the box will not take are marked as
**author-run**, not silently claimed. The networked version of this walk is
[`RUNBOOK-first-microvm.md`](../RUNBOOK-first-microvm.md), run on the host with the fabric up.

## Tear down

```bash
phase4-podman/lab-podman.sh down --lab micro-cloud-hand-walk
```
