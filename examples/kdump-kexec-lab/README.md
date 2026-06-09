# kdump-kexec-lab — explore a kernel panic with kexec & kdump

A faithful, by-hand reproduction of Petros Koutoupis's
**[*Oops! Debugging Kernel Panics*](upstream-tutorial/)** (Linux Journal) in a
throwaway Debian VM. You configure **kdump**, **deliberately panic the kernel**,
and watch a second kernel — pre-loaded into a reserved slice of RAM by **kexec** —
boot from the wreckage, dump the dead kernel's memory to `/var/crash`, and reboot.
Then you open that `vmcore` in the **`crash`** utility and trace the panic to the
exact source line.

**The whole point is the panic + the post-mortem**, end to end. Every step was run
and verified in a real KVM VM (see [`MANUAL_TESTING.md`](MANUAL_TESTING.md)).

## kexec & kdump in two sentences

`kexec` boots a new kernel directly from a running one, skipping firmware/BIOS.
`kdump` uses that to keep a small *capture kernel* resident in a memory region
reserved at boot (`crashkernel=`); when the main kernel panics, the capture kernel
takes over, copies the dead kernel's RAM out to disk as a `vmcore`, and reboots —
giving you a frozen snapshot to autopsy with `crash`.

> **Why a VM, not a chroot/container.** kdump reserves memory **at boot** and
> `kexec`s into a *separate* kernel on panic, and you trigger a **real** panic.
> Containers share the host kernel and can't do any of that. Panicking a VM is
> safe and free — it just reboots; your host never notices.

## Quick start

```bash
# 1. create the VM
phase2-qemu-vm/lab-vm.sh create --config examples/kdump-kexec-lab/kdump-kexec-lab.toml

# 2. grow the disk — kdump's debug symbols are ~5.7 GB; the cloud image root is ~3 GB
VMDIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/vms/kdump-kexec-lab"
qemu-img resize "$VMDIR/disk.qcow2" 30G        # cloud-init grows the fs on boot
phase2-qemu-vm/lab-vm.sh start kdump-kexec-lab

# 3. provision kdump (install + configure), then reboot to reserve the crashkernel
scp -P <port> examples/kdump-kexec-lab/provision-kdump.sh lab@127.0.0.1:   # pw: lab
phase2-qemu-vm/lab-vm.sh ssh kdump-kexec-lab -- 'sudo bash provision-kdump.sh && sudo reboot'

# 4. ...then walk RUNBOOK.md §3 onward: verify -> 'echo c > /proc/sysrq-trigger' -> crash
```

Follow [`RUNBOOK.md`](RUNBOOK.md) for the full faithful walk (the article's exact
order, with the *why* at each step and verified output).

## What's here

| File | What it is |
|---|---|
| [`README.md`](README.md) | This file — the concept + quick start. |
| [`RUNBOOK.md`](RUNBOOK.md) | The full by-hand walk in the article's order: install → configure → verify → **panic** → `crash`/`bt`/`sym` → module crash. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Verified pass/fail with **real captured output** (42 MB vmcore; `sym` → `test-module.c:8`). |
| [`kdump-kexec-lab.toml`](kdump-kexec-lab.toml) | The Phase-2 VM spec (Debian, 6 G / 4 vCPU). |
| [`provision-kdump.sh`](provision-kdump.sh) | Non-interactive install+configure (the automated equivalent of RUNBOOK §1–§2). |
| [`test-module.c`](test-module.c) | The article's crashing module — null-deref bug verbatim on **line 8**. |
| [`Makefile`](Makefile) | The article's out-of-tree module Makefile. |
| [`upstream-tutorial/`](upstream-tutorial/) | Byte-exact archive of the post + provenance. |

## Two crashes, one workflow

1. **SysRq crash** — `echo c > /proc/sysrq-trigger` forces an immediate panic.
   `crash`/`bt`/`sym` trace it into `drivers/tty/sysrq.c`.
2. **Your own buggy module** — `test-module.c` dereferences `int *p = 1;`,
   panicking on `insmod`. With `crash`'s `mod -s` (load the module's object file),
   `sym` resolves the faulting address to **`test-module.c: 8`** — debugging *your*
   code from a crash dump.

## Faithfulness notes

The method is the article's exactly; four divergences are forced by 2019-Debian →
2026-bookworm and are flagged inline in the RUNBOOK:

- **Generic `-amd64` kernel, not the cloud image's `-cloud-amd64`.** The article
  uses the generic `-amd64` flavor, and only it has matching debug symbols in
  Debian's archive (the stale cloud point-release has none). `provision-kdump.sh`
  installs the generic kernel + headers + `-dbg` and removes the cloud kernel.
- **`MODULE_LICENSE("GPL")` appended to `test-module.c`.** Modern `modpost` makes a
  missing license a hard *build error*; the article's 4.9 kernel only tainted. The
  line is appended at the **end**, so the deliberate bug stays on **line 8** and
  `crash`'s `:8` still matches. The `-Wint-conversion` warning is preserved (it's
  the bug; bookworm's gcc-12 warns rather than errors).
- **Debug vmlinux at `/usr/lib/debug/boot/vmlinux-<ver>`** (was `/usr/lib/debug/`).
- **Source line numbers differ by kernel version** (`sysrq.c:151` here vs `:144`).
- Also: **disk grow** (debug symbols are large) and **`makedumpfile`** named
  explicitly (a Recommends that actually writes the vmcore) — see RUNBOOK §1.

## Safety

Nothing offensive here — just a kernel killing itself in a sandbox. The panics are
deliberate and contained to the VM; the box reboots clean each time. Credentials
are the lab defaults (`lab` / `lab`); don't expose the VM to untrusted networks.

## Provenance

Operationalises **Petros Koutoupis**, *Oops! Debugging Kernel Panics*, Linux
Journal (<https://www.linuxjournal.com/content/oops-debugging-kernel-panics-0>,
2019-08-07; retrieved 2026-06-09). Byte-exact archive + sha256 + attribution in
[`upstream-tutorial/`](upstream-tutorial/). All rights remain with the author.
