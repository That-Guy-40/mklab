# Hand-walk: *explore a kernel panic with kexec & kdump*

Follow Petros Koutoupis's **[*Oops! Debugging Kernel Panics*](upstream-tutorial/)**
(Linux Journal) inside a throwaway Debian VM: configure **kdump** (a crash-dump
mechanism built on **kexec**), **deliberately panic the kernel**, and watch a
*second* kernel boot from the reserved memory, capture the dead kernel's RAM to
`/var/crash`, and reboot — then open that `vmcore` in the **`crash`** utility and
trace the panic back to the exact source line.

- **The post (byte-exact archive):** [`upstream-tutorial/`](upstream-tutorial/) ·
  canonical: <https://www.linuxjournal.com/content/oops-debugging-kernel-panics-0>
- **The environment:** a Debian VM ([`kdump-kexec-lab.toml`](kdump-kexec-lab.toml)).
- **The automation:** [`provision-kdump.sh`](provision-kdump.sh) does §1–§2 in one
  shot (non-interactive); this RUNBOOK shows the same steps **by hand**, in the
  article's order, with the *why* at each — and what's **verified** (`# →` lines
  are real output from this lab; full transcript in
  [`MANUAL_TESTING.md`](MANUAL_TESTING.md)).
- **The crashing module:** [`test-module.c`](test-module.c) + [`Makefile`](Makefile).

> **Why a VM and not a chroot/container.** kdump reserves a `crashkernel=` region
> **at boot time** and `kexec`s into a *separate* kernel when the live one panics —
> and you trigger a **real panic**. That needs a whole machine and control of the
> boot path; a container shares the host kernel and can't do any of it. Panicking
> a *VM* is free and safe — it just reboots.

> **Faithfulness divergences (all forced by 2019-Debian → 2026-bookworm), called
> out inline below:** ① cloud image's `-cloud-amd64` kernel → Debian's generic
> `-amd64` (the article's flavor, and the only one with matching debug symbols);
> ② `MODULE_LICENSE` appended to the module (modern `modpost` rejects its absence);
> ③ debug vmlinux path is `/usr/lib/debug/boot/…`; ④ source line numbers differ by
> kernel version. The **method is identical**.

---

## 0. Bring up the box

```bash
# from the repo root:
phase2-qemu-vm/lab-vm.sh create --config examples/kdump-kexec-lab/kdump-kexec-lab.toml
```

**Grow the disk first.** kdump's kernel **debug symbols are ~5.7 GB**, but the
Debian cloud image's root is only ~3 GB. `lab-vm.sh`'s disk-image backend has no
resize flag, so grow the overlay qcow2 directly — cloud-init expands the
filesystem to fill it on the next boot:

```bash
VMDIR="${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/vms/kdump-kexec-lab"
qemu-img resize "$VMDIR/disk.qcow2" 30G        # → cloud-init growpart fills it on boot
phase2-qemu-vm/lab-vm.sh start kdump-kexec-lab
```

Then install + configure kdump. The fast path is the bundled script; the by-hand
equivalent is §1–§2. Copy the script in (the SSH port is auto-allocated — `create`
prints it, or `lab-vm.sh list` shows it), then run it and reboot:

```bash
PORT=2222    # whatever 'create' / 'lab-vm.sh list' reported
scp -P "$PORT" examples/kdump-kexec-lab/provision-kdump.sh lab@127.0.0.1:    # password: lab
phase2-qemu-vm/lab-vm.sh ssh kdump-kexec-lab -- 'sudo bash provision-kdump.sh && sudo reboot'
```

Log in as `lab` / `lab` (sudo NOPASSWD). Everything below runs **inside the VM**;
hop in with `phase2-qemu-vm/lab-vm.sh ssh kdump-kexec-lab`.

---

## 1. Install the required packages  *(article: "Installing the Required Packages")*

The article first confirms the kernel was built with the features kdump needs —
worth knowing they're all `=y` in any stock Debian kernel:

```bash
grep -E 'CONFIG_(RELOCATABLE|KEXEC|CRASH_DUMP|DEBUG_INFO|MAGIC_SYSRQ|PROC_VMCORE)' \
    /boot/config-$(uname -r)
```

Then the toolchain (article's exact line, adapted — see divergence ① below):

```bash
sudo apt update && sudo apt upgrade
sudo apt install gcc make binutils linux-headers-`uname -r` kdump-tools crash `uname -r`-dbg
#                         ^build the module   ^kdump+kexec ^analyse  ^debug symbols for crash
```

- **Divergence ①.** On the cloud image `uname -r` is `…-cloud-amd64`, whose `-dbg`
  symbols aren't in Debian's debug archive (and the article uses the *generic*
  `-amd64` anyway). `provision-kdump.sh` installs `linux-image-amd64` +
  `linux-headers-amd64`, removes the cloud kernel, and pulls the matching
  `linux-image-<ver>-amd64-dbg` — so headers (for the module build) **and**
  symbols (for `crash`) line up with the running kernel.
- **`makedumpfile`** (a *Recommends* of `kdump-tools`) is what actually writes the
  `vmcore`. The article's plain `apt install` pulls it in; the script names it
  explicitly. Without it the crash kernel logs `makedumpfile: not found` and saves
  a **0-byte** dump.
- The two debconf prompts the article answers by hand (*"run kexec on shutdown?"*
  → no; *"should kdump load at boot?"* → yes) are preseeded so nothing hangs.

---

## 2. Configure kdump  *(article: "Configuring kdump")*

Three edits + a crashkernel reservation, then `update-grub` and **reboot** (the
reservation only happens at boot):

```bash
# (a) panic on Oops, and tell kdump to set it — /etc/default/kdump-tools
USE_KDUMP=1
KDUMP_SYSCTL="kernel.panic_on_oops=1"

# (b) enable SysRq so 'echo c' can request a crash — /etc/sysctl.d/99-sysctl.conf
kernel.sysrq=1

# (c) reserve crash memory on the kernel cmdline — /etc/default/grub.d/kdump-tools.*
#     the article changes the stock 'crashkernel=384M-:128M' to a plain:
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT crashkernel=128M"

sudo update-grub
sudo reboot
```

**Why each.** `panic_on_oops=1` turns a *recoverable* Oops into a full panic so
kdump fires (a plain Oops wouldn't trigger a dump). `kernel.sysrq=1` enables the
magic-SysRq channel that `echo c` uses. `crashkernel=128M` reserves a slice of RAM
**at boot**, walled off from the running kernel, for the *capture* kernel to live
in — that's the kexec trick: the second kernel is already resident, so it can boot
even though the first kernel is wedged. (If a capture ever OOMs, bump to `256M`;
128M is the article's value and it works here.)

---

## 3. Verify your kdump environment  *(article: "Verifying Your kdump Environment")*

```bash
sudo dmesg | grep -i crash
# → [    0.010490] Reserving 128MB of memory at 1840MB for crashkernel (System RAM: 6137MB)
sudo sysctl -a | grep kernel | grep -e panic_on_oops -e sysrq
# → kernel.panic_on_oops = 1
# → kernel.sysrq = 1
cat /sys/kernel/kexec_crash_loaded
# → 1                              ← the capture kernel is loaded and armed
systemctl status kdump-tools.service
# → Active: active (exited) … "loaded kdump kernel"
sudo kdump-config show            # full config: DUMP_MODE, COREDIR=/var/crash, kexec cmd…
```

All five must be green before you pull the trigger. `kexec_crash_loaded = 1` is the
one that says "a kernel is sitting in the reserved region, ready to take over."

---

## 4. The moment of truth  *(article: "The Moment of Truth")* — trigger the panic

```bash
echo "c" | sudo tee /proc/sysrq-trigger
```

Your SSH session dies instantly — **that's expected**. On the VM's serial console
([`lab-vm.sh console`](../../phase2-qemu-vm/README.md)) you'll see the live kernel
panic, then the *capture* kernel boot from the reserved region and run
`makedumpfile`:

```
[  232.914076] Kernel panic - not syncing: sysrq triggered crash
… (kexec into the capture kernel) …
kdump-tools[…]: running makedumpfile -F -c -d 31 /proc/vmcore | compress > /var/crash/<ts>/dump-incomplete.
kdump-tools[…]: makedumpfile Completed.
kdump-tools[…]: kdump-tools: saved vmcore in /var/crash/<ts>.
```

It then reboots into your normal kernel. SSH back in — the crash is on disk:

```bash
cd /var/crash/ && ls          # → 202606090544  kexec_cmd
ls -lh /var/crash/202606090544/
# → dump.202606090544   (42M)   ← the captured kernel RAM (filtered+compressed vmcore)
# → dmesg.202606090544  (44K)   ← the kernel log at the instant of panic
```

A real `vmcore`. Memory at the moment of death, frozen for autopsy.

---

## 5. What now?  *(article: "What Now?")* — open it in `crash`

```bash
cd /var/crash/202606090544/
sudo crash dump.202606090544 /usr/lib/debug/boot/vmlinux-$(uname -r)   # divergence ③: /boot/ in the path
```

`crash` prints a summary and a prompt. The summary already names the culprit:

```
      KERNEL: /usr/lib/debug/boot/vmlinux-6.1.0-49-amd64
    DUMPFILE: dump.202606090544  [PARTIAL DUMP]
       PANIC: "Kernel panic - not syncing: sysrq triggered crash"
     COMMAND: "tee"        ← the process that wrote to /proc/sysrq-trigger
```

```
crash> bt
 #2 [..] panic at ...
 #3 [..] sysrq_handle_crash at ...
 #4 [..] __handle_sysrq.cold at ...
 #5 [..] write_sysrq_trigger at ...
 #7 [..] vfs_write at ...
 #9 [..] do_syscall_64 at ...
crash> sym sysrq_handle_crash
# → ffffffff… (t) sysrq_handle_crash …/drivers/tty/sysrq.c: 151    (article saw :144 on 4.9 — divergence ④)
```

`bt` is the call stack at the panic; `sym` maps a kernel address to
**function + source file + line**. You've gone from "the box died" to "it died in
`sysrq_handle_crash`, in `drivers/tty/sysrq.c`" without a debugger attached to a
live system.

---

## 6. Custom kernel module crash debugging  *(article's second scenario)*

Now make the kernel die in *your* code and trace it back to *your* source line.
[`test-module.c`](test-module.c) is the article's module verbatim — its bug is on
**line 8**: it sets `int *p = 1;` then dereferences `*p`, reading address `0x1`.

```bash
make                       # builds test-module.ko
# → test-module.c:7:18: warning: initialization of 'int *' from 'int' … [-Wint-conversion]
#   ↑ the article's DELIBERATE warning — this is the bug, compiling anyway (divergence ②: a
#     MODULE_LICENSE line is appended so modern modpost doesn't hard-error on the missing license)
sync && sudo insmod test-module.ko        # loads the module → its init runs → panic
```

Same dance: SSH drops, the capture kernel saves a new `vmcore`, the box reboots.
The console shows the article's exact death:

```
BUG: kernel NULL pointer dereference, address: 0000000000000001
… do_init_module … __do_sys_finit_module …
```

Analyse it — but a fresh `crash` can only name the address as `init_module+5
[test_module]`, *no source line*, because the module's symbols aren't in the
kernel image. Feed `crash` the **unstripped object file** with `mod -s`:

```bash
sudo cp ~/test-module.o /var/crash/<ts>/      # the article copies its test.o here
cd /var/crash/<ts>/
sudo crash dump.<ts> /usr/lib/debug/boot/vmlinux-$(uname -r)
crash> bt                                      # note the [exception RIP: init_module+5] address
crash> mod -s test_module ./test-module.o      # load module symbols (name uses '_', not '-')
crash> sym <that-RIP-address>
# → ffffffff… (t) test_module_init+5 [test_module] /home/lab/test-module.c: 8
```

Line 8. The dereference. `crash` walked the dead kernel's RAM, matched the faulting
instruction to your object file, and pointed at the exact line — the article's
payoff, reproduced:

```bash
sed -n 8p test-module.c
# →         printk("%d\n", *p);
```

---

## 7. What else can you do here?  *(article's tour)*

Still at the `crash>` prompt, the dead kernel is a queryable object:

```
crash> kmem -i      # memory usage at panic (pages, free/used, slab, swap)
crash> log          # the full dmesg ring buffer, boot → panic
crash> ps           # process table as it was
crash> help         # every command (bt, sym, mod, kmem, log, struct, vm, …)
```

---

## 8. Tear down & provenance

```bash
phase2-qemu-vm/lab-vm.sh destroy kdump-kexec-lab --force    # VM + disk gone
```

- **Provenance.** The archived post under [`upstream-tutorial/`](upstream-tutorial/)
  is the work of **Petros Koutoupis** / **Linux Journal**; all rights remain with
  them. [`test-module.c`](test-module.c) is the author's module (line-8 bug
  verbatim). This runbook only operationalises the article. Prefer the [canonical
  page](https://www.linuxjournal.com/content/oops-debugging-kernel-panics-0).
- **Verified end-to-end in this lab** (Debian bookworm, generic `6.1.0-49-amd64`,
  KVM): crashkernel reserved → SysRq panic → **42 MB `vmcore` captured** →
  `crash`/`bt`/`sym` → `sysrq.c`; then module build (warning intact) → `insmod`
  NULL-deref panic → `vmcore` → `mod -s` → **`test-module.c: 8`**. Real transcript:
  [`MANUAL_TESTING.md`](MANUAL_TESTING.md).
