# Manual testing — kdump-kexec-lab

Every step below was **run end-to-end in a real KVM VM** on this host (Debian 12
bookworm, generic kernel `6.1.0-49-amd64`, QEMU 8.2, 6 G / 4 vCPU) and the output
captured. The load-bearing proof is **§C** (a real `vmcore` lands after a panic)
and **§E** (`crash` resolves the faulting address to the buggy source line).
Nothing here is "documented but unrun."

| Step | Proof | Status |
|---|---|---|
| A. Provision + crashkernel reserved | `Reserving 128MB … for crashkernel` | ✅ |
| B. kdump armed | `kexec_crash_loaded = 1`, service active | ✅ |
| C. SysRq panic → vmcore | 42 MB `dump.*` in `/var/crash/<ts>/` | ✅ |
| D. `crash` analysis (sysrq) | `bt` stack + `sym` → `sysrq.c:151` | ✅ |
| E. module build → `insmod` panic → `crash mod -s` | `sym` → `test-module.c: 8` | ✅ |

---

## A. Provision + reserve the crashkernel

`provision-kdump.sh` installs the generic kernel + headers + `kdump-tools crash
makedumpfile` + matching `-dbg`, applies the article's config, removes the cloud
kernel, and `update-grub`. After `sudo reboot`:

```
$ uname -r
6.1.0-49-amd64                      # generic flavor (divergence ①), debug symbols available
$ sudo dmesg | grep -i crash
[    0.010490] Reserving 128MB of memory at 1840MB for crashkernel (System RAM: 6137MB)
```

**PASS** — booted the generic kernel; 128 MB reserved at boot (the article's
verification step, on a 6 GB VM).

---

## B. kdump environment verified

```
$ sudo sysctl -a | grep kernel | grep -e panic_on_oops -e sysrq
kernel.panic_on_oops = 1
kernel.sysrq = 1
$ cat /sys/kernel/kexec_crash_loaded
1
$ systemctl is-active kdump-tools.service
active                              # "active (exited) … loaded kdump kernel"
```

**PASS** — all four green; the capture kernel is loaded and armed.

---

## C. The panic → vmcore  (the centerpiece)

```
$ echo "c" | sudo tee /proc/sysrq-trigger          # SSH drops immediately (expected)
```

Serial console through the panic → kexec → capture → reboot:

```
[  232.914076] Kernel panic - not syncing: sysrq triggered crash
… capture kernel boots from the reserved region …
kdump-tools[…]: running makedumpfile -F -c -d 31 /proc/vmcore | compress > /var/crash/202606090544/dump-incomplete.
kdump-tools[…]: makedumpfile Completed.
kdump-tools[…]: kdump-tools: saved vmcore in /var/crash/202606090544.
```

After the auto-reboot:

```
$ sudo ls -lh /var/crash/202606090544/
-rw------- 1 root root  44K  dmesg.202606090544     # kernel log at panic
-rw-r--r-- 1 root root  42M  dump.202606090544      # the captured vmcore
```

**PASS** — a real 42 MB `vmcore` + `dmesg` captured.

> **Gotcha found & fixed during verification:** with `--no-install-recommends` and
> no explicit `makedumpfile`, the first panic logged `makedumpfile: not found` and
> saved a **0-byte** `dump`. `provision-kdump.sh` now installs `makedumpfile`
> explicitly — re-running produced the 42 MB dump above.

---

## D. Analyze the SysRq crash with `crash`

```
$ cd /var/crash/202606090544/
$ sudo crash dump.202606090544 /usr/lib/debug/boot/vmlinux-6.1.0-49-amd64
…
       PANIC: "Kernel panic - not syncing: sysrq triggered crash"
     COMMAND: "tee"
crash> bt
 #2 [..] panic at ffffffffa91f6d14
 #3 [..] sysrq_handle_crash at ffffffffa8e8a1b6
 #4 [..] __handle_sysrq.cold at ffffffffa9224fe1
 #5 [..] write_sysrq_trigger at ffffffffa8e8ab04
 #6 [..] proc_reg_write at ffffffffa8c01543
 #7 [..] vfs_write at ffffffffa8b63cd4
 #9 [..] do_syscall_64 at ffffffffa9238b95
crash> sym sysrq_handle_crash
ffffffffa8e8a1a0 (t) sysrq_handle_crash …/drivers/tty/sysrq.c: 151
```

**PASS** — `bt` matches the article's stack (`…→ sysrq_handle_crash →
write_sysrq_trigger → vfs_write → do_syscall_64`); `sym` maps to `sysrq.c`
(line 151 vs the article's 144 — kernel-version drift, divergence ④).

---

## E. Crash your own module → trace to the buggy line

```
$ make
test-module.c:7:18: warning: initialization of ‘int *’ from ‘int’ makes pointer from integer without a cast [-Wint-conversion]
  LD [M]  /home/lab/test-module.ko          # the DELIBERATE warning; builds anyway
$ sync && sudo insmod test-module.ko        # SSH drops — panic
```

Console:

```
BUG: kernel NULL pointer dereference, address: 0000000000000001
… do_init_module … __do_sys_finit_module …
kdump-tools[…]: saved vmcore in /var/crash/202606090550.
```

Analyze with the module's object file loaded:

```
$ sudo cp ~/test-module.o /var/crash/202606090550/
$ cd /var/crash/202606090550/
$ sudo crash dump.202606090550 /usr/lib/debug/boot/vmlinux-6.1.0-49-amd64
       PANIC: "Oops: 0000 [#1] PREEMPT SMP NOPTI" (check log for details)
     COMMAND: "insmod"
crash> bt
    [exception RIP: init_module+5]          # faulting address = ffffffffc087f00f
crash> mod -s test_module ./test-module.o   # load module symbols (name uses '_')
     MODULE            NAME           …  OBJECT FILE
ffffffffc0881040  test_module        …  ./test-module.o
crash> sym ffffffffc087f00f
ffffffffc087f00f (t) test_module_init+5 [test_module] /home/lab/test-module.c: 8
$ sed -n 8p test-module.c
        printk("%d\n", *p);
```

**PASS** — the exact article payoff: the faulting instruction resolves to
**`test-module.c: 8`**, the `*p` dereference of the bad pointer. Before `mod -s`,
the same address was only `init_module+5 [test_module]` with no source line.

---

## F. Environment notes

- **Host:** KVM available, ~108 GB free RAM. The full loop (2 panics, 3 reboots,
  ~860 MB of packages incl. 5.7 GB of unpacked debug symbols) ran in one VM.
- **Disk:** the Debian cloud image root is ~3 GB; the debug symbols don't fit. The
  overlay qcow2 was grown to 30 GB (`qemu-img resize`) and cloud-init expanded the
  filesystem on boot. This is documented as RUNBOOK §0 / README step 2.
- **`crashkernel=128M`** (the article's value) was sufficient on this 6.1 kernel —
  no OOM during capture. Bump to `256M` only if a capture ever fails.
- Nothing here touched the host kernel; every panic was contained to the VM.
