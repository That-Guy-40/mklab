# Tiny-Linux experiments — boot the smallest Linux that boots

Specs for booting *minimal* Linux systems in RAM under QEMU — no installer, no
disk, no package manager. Two lineages live here, sharing the "tiny + fast +
in-RAM" theme but built very differently:

1. **From-source micro-linux** — compile a kernel + a tiny userspace (static
   BusyBox, or u-root for riscv64) from upstream source with
   [`../../micro-linux/mlbuild.sh`](../../micro-linux/mlbuild.sh), then boot to a
   console login (`root` / `micro`) via
   [`../../phase2-qemu-vm/lab-vm.sh`](../../phase2-qemu-vm/lab-vm.sh)'s
   `kernel+initrd` backend. The `micro-linux-*.toml` files.
2. **Alpine microVM** — an upstream Alpine minirootfs turned into an in-RAM
   initramfs and booted on QEMU's real `microvm` machine, auto-built by
   `lab-vm.sh` (no separate build step). The `microvm-alpine*.toml` files.

> This dir was split out of the flat `examples/` root as one cohesive group (see
> [`../INDEX.md`](../INDEX.md)). It is **not** the build tooling — that's the
> top-level [`../../micro-linux/`](../../micro-linux/) subsystem (`mlbuild.sh`,
> the kernel `.config`s, the toolchain Containerfile, tests).

## From-source micro-linux (`micro-linux-*.toml`)

Build once per arch (`mlbuild.sh all --arch <arch>`), then `create` + `start`:

| File | What you get |
|---|---|
| `micro-linux-x86_64.toml` | x86_64 kernel + static BusyBox → getty/login over serial (`q35`). |
| `micro-linux-x86_64-microvm.toml` | Same artifacts on QEMU's real `microvm` machine (qboot, virtio-mmio). |
| `micro-linux-x86_64-tiny.toml` | The `kernel-tiny` config + default initramfs on microvm. |
| `micro-linux-x86_64-baked.toml` | The `kernel-baked` build (initramfs baked in, no `-initrd`). |
| `micro-linux-aarch64.toml` | 🐌 arm64 twin, cross-compiled; boots on QEMU `virt` (TCG on x86). |
| `micro-linux-aarch64-microvm.toml` | 🐌 arm64 microvm-style: firmware-free `virt` + virtio-mmio. |
| `micro-linux-riscv64.toml` | riscv64 + a u-root (pure-Go) cpio — the "faithful track". |
| `micro-linux-ppc64le.toml` | 🐌 ppc64le on QEMU `pseries` (SLOF, HVC console); needs `WITH_EXTRA_ARCHES=1`. |
| `micro-linux-s390x.toml` | 🐌 s390x on `s390-ccw-virtio` (IBM Z emulation, SCLP console); needs `WITH_EXTRA_ARCHES=1`. |

```bash
micro-linux/mlbuild.sh all --arch x86_64                                          # build (rootless, once)
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro-linux-x86_64.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64                                # log in: root / micro
```

> The `kernel`/`initrd` paths in each TOML point at `micro-linux/out/<arch>/…`
> under *this* checkout — **edit them** if your tree lives elsewhere (each file
> says so in its header).

## Alpine microVM (`microvm-alpine*.toml`)

No build step — `lab-vm.sh` fetches the Alpine minirootfs and assembles the
initramfs on first `create`.

| File | What you get |
|---|---|
| `microvm-alpine.toml` | True microVM: Alpine minirootfs as an in-RAM initramfs — `network`/`ssh`/`persist` flags. |
| `microvm-alpine-custom-init.toml` | Same, but PID 1 is a hand-rolled static C `/sbin/init` (auto-compiled by `lab-vm.sh`). |
| [`alpine-custom-init.TXT`](alpine-custom-init.TXT) | Side-by-side walkthrough: busybox-init vs. a custom C PID 1. |

## Sub-directories

| Dir | What it is |
|---|---|
| [`micro_linux_dhcp_lease/`](micro_linux_dhcp_lease/) | The networking demo: the from-source distro pulls a **DHCP lease** over a virtio NIC (one `micro-linux-<arch>-dhcp.toml` per arch). See its [README](micro_linux_dhcp_lease/README.md). |
| [`reference/`](reference/) | Standalone build scripts that predate `lab-vm.sh`'s auto-build — read them to see the microVM initramfs built without the framework. |

## ⚠️ Security

These are **throwaway** VMs: root logs in with the well-known password `micro`
(from-source) or `root` (Alpine) and nothing authenticates the NIC. Networking
is **off by default**; the dhcp demo opts back in via the `mllab.net` cmdline
token, which is fine on QEMU user-mode networking (NAT, no inbound route) but
**don't bridge these to an untrusted network**. To change the from-source
password, rebuild with `MLBUILD_LAB_PASSWORD=…`.
