# PoC "MATRYOSHKA" — boot Linux to boot Linux, proven with u-root + kexec

> **What this is:** the feasibility spike behind the [LinuxBoot lab plan](PLAN.md),
> written up as a reproducible proof-of-concept. Codename **Matryoshka** — like the
> Russian nesting dolls, we boot one Linux kernel whose entire userland's job is to
> **`kexec` a *second* kernel into its place**. Turtles all the way down.
>
> **What it proves:** the core LinuxBoot mechanic — *a Linux kernel + a custom Go
> `init` (u-root) acting as the bootloader, then handing off to the real OS kernel
> via `kexec`* — works end-to-end under QEMU/KVM on this host. This validates **Tier
> C** and the foundation of **Tier B** in [PLAN.md](PLAN.md). It does **not** yet
> cover the OVMF/UEFI front-end (Tier B) or the coreboot ROM (Tier A).
>
> Every command below was run on **2026-06-29**; every output block is real,
> trimmed only for length and stripped of terminal ANSI escapes.

---

## 0. The idea, in one breath

LinuxBoot replaces firmware boot logic with **a Linux kernel whose initramfs `init`
*is* the bootloader**. That userland is canonically **[u-root](https://github.com/u-root/u-root)**
(a Go "busybox" that ships `kexec`, `boot`, `localboot`). It probes the machine,
picks a target, and **`kexec`s** the real OS kernel. This PoC reproduces exactly
that handoff in miniature: **kernel #1 → u-root `init` → `kexec` → kernel #2**.

```
QEMU -kernel vmlinuz -initrd stage1.cpio
   └─ kernel #1 boots, PID 1 = u-root /init            ← "the bootloader"
        └─ /init runs our kexec script
             └─ kexec loads kernel #2 (+ its initramfs) and jumps
                  └─ kernel #2 boots fresh (new command line)   ← the handoff
```

---

## 1. Environment & prerequisites

Host: **Ubuntu 24.04.4 LTS**, x86_64, QEMU/KVM. Two packages (the only `sudo` you
need for this PoC):

```bash
sudo apt install -y golang-go kexec-tools
```

**Checkpoint 1 — toolchain present and new enough** (u-root needs Go ≥ 1.21):

```
$ go version
go version go1.22.2 linux/amd64
$ command -v kexec qemu-system-x86_64; ls -l /dev/kvm
/usr/sbin/kexec
/usr/bin/qemu-system-x86_64
crw-rw----+ 1 root kvm 10, 232 ... /dev/kvm
```

A **work directory** off the repo (the artifacts are large):

```bash
mkdir -p /media/sqs/COLD_STORAGE/linuxboot-spike
cd /media/sqs/COLD_STORAGE/linuxboot-spike
```

We also need **one world-readable bzImage** to boot (and to kexec into). The host's
own `/boot/vmlinuz-*` is mode `0600` (root-only), so reuse a kernel we can read —
here an AlmaLinux 9 installer kernel already fetched by another lab:

```
$ file /home/sqs/netboot/vmlinuz
/home/sqs/netboot/vmlinuz: Linux kernel x86 boot executable bzImage,
  version 5.14.0-687.5.3.el9_8.x86_64 ... #1 SMP PREEMPT_DYNAMIC
```

> Any modern distro `vmlinuz` works — it needs virtio + `CONFIG_KEXEC` (RHEL/Alma
> kernels have both). The kernel doesn't know it's an "installer" kernel; the
> initramfs decides userspace, and ours is u-root.

---

## 2. Build the u-root userland — and the gotcha that cost the most time

The intuitive first move fails in an instructive way:

```
$ go install github.com/u-root/u-root@latest        # builds the tool OK...
$ ~/go/bin/u-root -build=bb -o initramfs.cpio core boot
... WARN You are not using one of the recommended Go versions
        (have = go1.25.11, recommended = [go1.20 go1.21 go1.22])
... ERROR mkuimage error: failed to resolve package paths:
        package core is not in std (.../toolchain@v0.0.1-go1.25.11/src/core)
```

**Two traps, one symptom:**

1. **Go toolchain auto-download.** u-root's modules request a newer Go, so Go's
   `GOTOOLCHAIN=auto` *silently downloads go1.25.11* and builds under it — exactly
   the version u-root warns against. Pin it: **`GOTOOLCHAIN=local`** (use the apt
   Go 1.22.2).
2. **Command keywords only resolve in-tree.** The `core`/`boot` shorthands are
   u-root's own command globs; run standalone in an empty dir they resolve as Go
   std packages and fail (`no Go commands match`). Fix: **build from the u-root
   source tree**, where `core` → `./cmds/core/*`.

The recipe that works:

```bash
git clone --depth 1 -b v0.14.0 https://github.com/u-root/u-root
cd u-root
GOTOOLCHAIN=local go build -o u-root .                       # build the tool under Go 1.22
GOTOOLCHAIN=local ./u-root -build=bb -o ../initramfs.cpio core boot
cd ..
```

**Checkpoint 2 — initramfs built, and it *is* a LinuxBoot userland** (`/init` +
`kexec` present):

```
$ ls -lh initramfs.cpio
-rw-r--r-- 1 sqs sqs 16M ... initramfs.cpio
$ cpio -itv < initramfs.cpio | grep -E '(^|/)(init$|bbin/kexec)'
lrwxrwxrwx ... init -> bbin/init
lrwxrwxrwx ... bbin/kexec -> bb
```

---

## 3. Stage A — does u-root boot as PID 1?

Before the handoff, prove the simpler half: a kernel booting **u-root** as init.

```bash
qemu-system-x86_64 -name uroot-spike -machine q35 -accel kvm -m 1024 \
  -kernel /home/sqs/netboot/vmlinuz \
  -initrd /media/sqs/COLD_STORAGE/linuxboot-spike/initramfs.cpio \
  -append "console=ttyS0" \
  -display none -serial file:console.log -monitor none -no-reboot \
  -pidfile qemu.pid &
sleep 25
```

**Checkpoint 3 — the u-root banner on the serial console** (`console.log`):

```
[    0.388722] Run /init as init process
2026/06/29 06:30:56 Welcome to u-root!
                              _
   _   _      _ __ ___   ___ | |_
  | | | |____| '__/ _ \ / _ \| __|
  | |_| |____| | | (_) | (_) | |_
   \__,_|    |_|  \___/ \___/ \__|

M-? toggle key help • C-d erase/stop • C-c clear/cancel • M-. hide/show prompt
```

`Run /init as init process` → **`Welcome to u-root!`** → the elvish shell prompt.
A Linux kernel is now running a Go userland as PID 1. Stop it:

```bash
kill "$(cat qemu.pid)"        # always by PID/pidfile, never by pattern
```

---

## 4. Stage B — the kexec handoff (the actual PoC)

For u-root to `kexec` a second kernel, that kernel **and** a second initramfs must
exist *inside* the running u-root. We embed them into a **stage-1** image with
u-root's `-files`, and auto-run a kexec script via `-uinitcmd` (u-root runs
`/bin/uinit` before the shell).

First, the kexec script. u-root's `kexec <kernel>` defaults to **load *and* exec**
(verified in `cmds/core/kexec/kexec_linux.go`: `if !load && !exec { load=exec=true }`),
so one call does the handoff. We try `kexec_file_load` first, falling back to the
older `kexec_load` syscall (`-L`, no signature check) if needed:

```sh
# dokexec.sh
#!/bin/sh
echo "=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ==="
kexec -i /boot/initramfs2.cpio -c "console=ttyS0 LINUXBOOT_STAGE2=reached" /boot/bzImage || {
  echo "=== LINUXBOOT_STAGE1: file_load failed; trying kexec_load syscall (-L) ==="
  kexec -L -i /boot/initramfs2.cpio -c "console=ttyS0 LINUXBOOT_STAGE2=reached" /boot/bzImage
}
echo "=== LINUXBOOT_STAGE1: kexec did NOT take over (failure) ==="
```

Build the stage-1 image — u-root **+** the kernel (`/boot/bzImage`) **+** a stage-2
initramfs (`/boot/initramfs2.cpio`, just a copy of the Stage-A image) **+** the
script, with `/bin/uinit` wired to run it under u-root's POSIX shell `gosh`:

```bash
cd u-root
GOTOOLCHAIN=local ./u-root -build=bb \
  -uinitcmd="gosh /bin/dokexec.sh" \
  -files "/home/sqs/netboot/vmlinuz:boot/bzImage" \
  -files "/media/sqs/COLD_STORAGE/linuxboot-spike/initramfs.cpio:boot/initramfs2.cpio" \
  -files "/media/sqs/COLD_STORAGE/linuxboot-spike/dokexec.sh:bin/dokexec.sh" \
  -o ../initramfs-stage1.cpio core boot
cd ..
```

**Checkpoint 4 — stage-1 image is the expected ~46 MiB** (16M u-root + 15M kernel +
16M stage-2):

```
$ ls -lh initramfs-stage1.cpio
-rw-r--r-- 1 sqs sqs 46M ... initramfs-stage1.cpio
```

Boot it (give it 2 GiB — the 46 MiB initramfs unpacks in RAM, then kexec loads a
second kernel + initramfs):

```bash
qemu-system-x86_64 -name uroot-kexec-spike -machine q35 -accel kvm -m 2048 \
  -kernel /home/sqs/netboot/vmlinuz \
  -initrd /media/sqs/COLD_STORAGE/linuxboot-spike/initramfs-stage1.cpio \
  -append "console=ttyS0 LINUXBOOT_STAGE1=boot" \
  -display none -serial file:kexec.log -monitor none -no-reboot \
  -pidfile qemu-kexec.pid &
sleep 40
```

---

## 5. The proof

**Checkpoint 5 — two distinct kernels booted, with two distinct command lines, and
two u-root banners.** From `kexec.log`, in order (ANSI stripped):

```
[    0.000000] Command line: console=ttyS0 LINUXBOOT_STAGE1=boot     ← kernel #1
[    0.008961] Kernel command line: console=ttyS0 LINUXBOOT_STAGE1=boot
[    0.424557] Run /init as init process
2026/06/29 06:35:04 Welcome to u-root!                               ← u-root = the bootloader
=== LINUXBOOT_STAGE1: u-root init is now the bootloader; kexec-ing stage 2 ===
[    0.000000] Command line: console=ttyS0 LINUXBOOT_STAGE2=reached  ← kernel #2 (KEXEC!)
[    0.005241] Kernel command line: console=ttyS0 LINUXBOOT_STAGE2=reached
[    0.379823] Run /init as init process
2026/06/29 06:35:05 Welcome to u-root!                               ← second kernel up
```

The tell is the **`[    0.000000]` timestamp resetting** before
`LINUXBOOT_STAGE2=reached`: that's a *fresh kernel* starting its own clock — not a
userspace trick. Different command line, second `Run /init`, second banner. The
machine booted Linux, and that Linux booted Linux.

Quick programmatic confirmations:

```
$ grep -c 'Kernel command line' kexec.log      # two kernels
2
$ grep -c 'Welcome to u-root'   kexec.log       # two u-root inits
2
$ grep -o 'LINUXBOOT_STAGE[12]=[a-z]*' kexec.log | sort -u
LINUXBOOT_STAGE1=boot
LINUXBOOT_STAGE2=reached
```

Default `kexec_file_load` succeeded — there is no `file_load failed` line, so the
`-L` fallback was never needed (no Secure Boot in plain QEMU ⇒ no signature
enforcement). Stop the VM:

```bash
kill "$(cat qemu-kexec.pid)"
```

---

## 6. What this establishes (and what it doesn't)

| Claim | Status |
|---|---|
| u-root builds on Ubuntu 24.04 (with the Go-pin recipe) | ✅ proven |
| A Linux kernel boots **u-root as PID 1** under QEMU/KVM | ✅ proven (Stage A) |
| u-root's `init` **`kexec`s a second kernel** — the LinuxBoot handoff | ✅ proven (Stage B) |
| **Tier C** (`-kernel/-initrd` + u-root + kexec) | ✅ this PoC |
| **Tier B** (OVMF/UEFI front-end → u-root → kexec) | ✅ DONE since — [`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md) (`PLAN.md` §Status) |
| **Tier A** (coreboot `qemu-q35` ROM with a LinuxBoot payload) | ✅ DONE since — `build-coreboot.sh` + `run-coreboot-linuxboot.sh` (`PLAN.md` §Status) |
| kexec into a **real installed OS** (u-root `localboot`) | ⏳ the lab's "finale" |

> **Note (this is the early Tier-C PoC doc):** Tiers B and A were spiked
> and landed after this was written — see [`PLAN.md`](PLAN.md) §Status and
> [`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md). The ⏳ rows above are
> kept as the historical snapshot; the ✅ annotations are the current state.

Two truths worth carrying into the build:
- **"Cloud/distro kernel" ≠ "kexec-signed."** Plain QEMU has no Secure Boot, so
  `kexec_file_load` of an unsigned kernel just works; on a locked-down/Secure-Boot
  host you'd need a signed kernel or the `-L` syscall path.
- **The Go toolchain will sandbag you.** Always `GOTOOLCHAIN=local` + build u-root
  from its tree, or you'll silently get go1.25 and cryptic "package not in std".

---

## 7. Reproduce / clean up

Full reproduction is §1 → §5 (≈5 minutes after the apt install). Artifacts live in
`/media/sqs/COLD_STORAGE/linuxboot-spike/` (u-root clone + `initramfs.cpio` +
`initramfs-stage1.cpio` + the two `*.log`s, ~80 MB). To reclaim space:

```bash
rm -rf /media/sqs/COLD_STORAGE/linuxboot-spike
```

Next steps are tracked in [PLAN.md](PLAN.md): spike **Tier B** (OVMF → u-root →
kexec, fully verifiable here), then author **Tier A** (coreboot ROM; the ~hour
`crossgcc` build is author-run per the repo's toolchain convention).
