# RUNBOOK — one microVM, by hand

**Slice 1 of [the micro-cloud path](../learning-paths/path-micro-cloud.md).** No tool, no
root, no network. You write a JSON file and hand it to a binary, and about half a second
later a Linux userspace is running. Then you do the *same* boot again by `PUT`ing that
JSON's four sections at a socket, so that when
[`lab-fc.sh`](../../phase7-firecracker/lab-fc.sh) starts generating configs for you in
slice 4 you already know exactly what it is generating.

> **Everything below was re-run on 2026-08-20** against Firecracker v1.16.1 on
> Ubuntu 24.04 / kernel 6.8.0-138. The outputs are transcripts, not illustrations. The
> dated *record* of the original slice-1 session is
> [Appendix E](../../MICRO_CLOUD_LAB_PLAN.md#appendix-e--slice-1-one-microvm-by-hand-2026-08-01);
> this file is the part you can follow.

## What you need

| | |
|---|---|
| `firecracker` v1.16.1 | `export PATH="$HOME/.local/state/lab-create/micro-cloud-s3:$PATH"` — the pinned copy P2 fetched and sha-verified |
| a **`vmlinux`** | an *uncompressed ELF*. See the naming trap below |
| a rootfs `.ext4` | built by [`RUNBOOK-micro-cloud.md` step 0](RUNBOOK-micro-cloud.md#step-0--the-spine-and-the-two-things-made-from-it-root-once), or the Alpine one from slice 1 |
| `/dev/kvm` readable | be in the `kvm` group; `ls -l /dev/kvm` |

**No root.** `mkfs.ext4 -d` populates an image with no mount and no loop device, so even
building the rootfs is unprivileged. Every file in the Alpine image is owned by uid 1000 and
it boots anyway — the kernel runs init as root regardless of who owns the files.

Work in the slice-1 directory, which still holds all of it:

```bash
cd ~/.local/state/lab-create/micro-cloud-s1
```

## Step 1 — the whole machine, as one file

```json
{
  "boot-source": {
    "kernel_image_path": "vmlinux-6.1.155",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "alpine.ext4",
      "is_root_device": true, "is_read_only": false }
  ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 128 }
}
```

That is the entire specification of a virtual machine: a kernel, a disk, a CPU count and a
memory size. There is no firmware, no bootloader, no PCI bus, no BIOS — `pci=off` is not an
optimisation, it is a statement that the machine has no PCI at all. **This is why it boots in
half a second**: almost nothing exists to enumerate.

Two boot args worth knowing rather than copying:

* **`console=ttyS0`** — the guest's console is Firecracker's stdout. That is the only way you
  will see anything; there is no display device to attach to.
* **`panic=1`** — reboot one second after a panic. With `reboot=k` that terminates the VMM,
  so a guest that dies takes its process with it instead of leaving a wedged VM you have to
  notice. (Appendix E measured this: the *first* attempt to prove it showed no difference at
  all, because the argument was never reaching the kernel. Read `/proc/cmdline` **inside the
  guest** if you want to know what it actually got — not the JSON you meant to write.)

## Step 2 — boot it

```bash
firecracker --no-api --config-file config-alpine-ci.json
```

**Checkpoint:**

```
[    0.568463] Run /sbin/init as init process
MICROVM-UP uptime=0.55s

Welcome to Alpine Linux 3.21
(none) login:
```

`MICROVM-UP uptime=0.55s` is printed by an inittab marker inside the guest reading its own
`/proc/uptime`, so it measures the *guest's* boot and excludes host-side Firecracker startup.
That is what makes the number comparable across kernels, engines and runs — and it is why the
lab's benchmark reads it from the guest rather than timing the host command.

Nothing tells it to stop; `Ctrl-C`, or bound it with `timeout 25 firecracker …`. There is no
`shutdown` here because there is no ACPI — that is what `reboot=k` is standing in for.

## Step 3 — the same boot, over the API

`--no-api --config-file` and the REST socket are two front doors to one machine. Start it with
**no** config at all and it waits:

```bash
rm -f api.sock
firecracker --api-sock api.sock &
```

Then `PUT` the four sections of that same JSON — this is literally the file above, taken
apart:

```bash
q() { curl -s -o /dev/null -w '%{http_code}\n' --unix-socket api.sock \
        -X PUT "http://localhost$1" -H 'Content-Type: application/json' -d "$2"; }

q /boot-source    '{"kernel_image_path":"vmlinux-6.1.155","boot_args":"console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw"}'
q /drives/rootfs  '{"drive_id":"rootfs","path_on_host":"alpine.ext4","is_root_device":true,"is_read_only":false}'
q /machine-config '{"vcpu_count":1,"mem_size_mib":128}'
q /actions        '{"action_type":"InstanceStart"}'
```

**Checkpoint — four `204`s, then the identical boot:**

```
PUT /boot-source     -> 204
PUT /drives/rootfs   -> 204
PUT /machine-config  -> 204
PUT /actions (start) -> 204

MICROVM-UP uptime=0.55s
(none) login:
```

**Same 0.55 s.** The API is not a slower or richer path — it is the same configuration
arriving in four messages instead of one file. Everything the rest of this lab does to a
running microVM goes through this socket: `snapshot create`, `PATCH /drives` when a clone
re-points its disk, seeding MMDS, `set_link down` in the chaos matrix. Knowing it is a plain
unix socket taking JSON is most of what you need to debug any of them.

Kill it **by the PID you started**, never by pattern — a pattern matching `api.sock` also
matches the VMM whose cmdline carries that path:

```bash
kill "$FCPID"
```

## Step 4 — the failure that catches everyone

Hand it a kernel that is not an uncompressed ELF:

```bash
firecracker --no-api --config-file config-notelf.json
```

```
Kernel Loader: failed to load ELF kernel image: Kernel Loader: Invalid Elf magic number
Error: RunWithoutApiError(BuildMicroVMFromJson(StartMicroVM(ConfigureSystem(
       KernelLoader(Elf(InvalidElfMagicNumber))))))
```

**`vmlinuz` is the compressed bzImage a bootloader unpacks. `vmlinux` is the uncompressed ELF
Firecracker requires.** There is no bootloader here to do the unpacking, so the file your
distro ships in `/boot` is the wrong shape. `file -b` tells them apart:

```
vmlinux-6.1.155      ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked
/boot/vmlinuz-6.8.0  (a compressed bzImage — and usually mode 600, so you cannot even read it)
```

`extract-vmlinux` (in the kernel source tree, not on `PATH` by default) converts one to the
other, and Appendix E measured the result booting **this host's own 6.8 kernel** inside the
microVM in 0.62 s. **The condition to check before you try it:** `CONFIG_VIRTIO_MMIO`,
`CONFIG_VIRTIO_BLK`, `CONFIG_EXT4_FS` and `CONFIG_SERIAL_8250_CONSOLE` must be `=y`, not `=m`
— Firecracker boots with no initramfs, so a modular driver is a driver that will never load,
and the failure looks like a hang rather than an error.

## Where this goes next

| next | what it adds |
|---|---|
| **slice 2** — identity | MMDS v2 at `169.254.169.254`, answered by the VMM on the guest's own NIC. `tests/test-mmds-answers-inside-the-guest.sh` runs it unprivileged |
| **slice 4** — the tool | [`lab-fc.sh`](../../phase7-firecracker/lab-fc.sh) writes the JSON you just wrote by hand, and `create --dry-run` prints every value it filled in for you |
| **the whole lab** | [`RUNBOOK-micro-cloud.md`](RUNBOOK-micro-cloud.md) |

**The point of doing it by hand once:** when `lab-fc.sh` later refuses to start an instance
whose kernel digest changed, or a clone's `PATCH /drives` fails, you are debugging a JSON
document and a unix socket you have already driven yourself — not a black box.
