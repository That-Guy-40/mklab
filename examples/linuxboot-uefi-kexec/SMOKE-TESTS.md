# SMOKE-TESTS — what kind of shell is the u-root LinuxBoot rescue environment?

> **Evidence, not folklore.** Every LinuxBoot tier in this lab drops to (or passes
> through) a **u-root shell** — the interactive environment a human lands in when no
> boot policy fires. This is that shell driven through a battery of probes over the
> serial console ([`smoke-uroot.sh`](smoke-uroot.sh) + [`smoke-uroot.py`](smoke-uroot.py)),
> so we can state exactly how it behaves. Verified on the Tier-C fast loop
> (`qemu -kernel payload-bzImage -initrd uroot-main.cpio`), u-root **main**, gosh shell,
> Linux 6.3.0, KVM.
>
> **Run it:** `./smoke-uroot.sh main` (or `v0.14.0`). It boots the shell, types the
> probes, and prints the sliced transcript + headline findings.

## Headline: typing `exit` does **NOT** panic the kernel

The natural fear for a firmware shell: "if I type `exit`, I kill PID 1 and the kernel
panics." **In u-root, it doesn't** — and the reason is a real design choice worth
understanding.

u-root's `init` (`cmds/core/init`) is PID 1. It runs, in order, `/inito` → a `uinit`
(if any) → then a **shell as a *child* process**. When you `exit` the shell, control
returns to `init`, which then logs *"Waiting for orphaned children"* and calls
`libinit.WaitOrphans()` — it **blocks there, still alive as PID 1**. No
`Kernel panic - not syncing: Attempted to kill init!`. (You won't even see the
"Waiting…" line: init *lowers the console loglevel* right before starting the interactive
shell, precisely so boot spam doesn't clutter your prompt — so the message is logged but
suppressed on the console.) The machine is left with a live init and no shell — you
reboot to get it back.

**Contrast with the BusyBox/floppinux family in this repo** (`examples/tiny-linux-experiments/`):
there the shell *is* PID 1 (`init=/bin/sh`), so `exit` really does kill init → instant
panic. u-root's supervise-a-child-shell model is the more robust rescue design. Verified
on **both** u-root main and v0.14.0: no panic on `exit`.

## Full probe results (u-root main, `gosh`)

| Probe | Result | Notes |
|---|---|---|
| shell identity | **`gosh`** | u-root's Go shell (`$0` = `gosh`); v0.14.0 adds a line-editor with a `M-? toggle key help` hint |
| pipe `\|` | ✅ works | `echo pipe_ok \| cat` → `pipe_ok` |
| redirection `>` | ✅ works | `echo … > /tmp/r; cat /tmp/r` |
| glob `*` | ✅ works | `ls -d /b*` → `bbin bin buildbin` |
| variables | ✅ works | `FOO=bar123; echo val=$FOO` → `val=bar123` |
| command substitution `$(…)` | ✅ works | but u-root's `date` has no `+%s` → prints literal `%s` (a `date` gap, not a shell gap) |
| background `&` | ✅ works | `sleep 20 &` returns to the prompt immediately |
| `jobs` / `fg` / `bg` | ❌ **absent** | not builtins — looked up as external commands → `"jobs": executable file not found in $PATH; error: exit status 127` |
| Ctrl-Z (SIGTSTP suspend) | ❌ not handled | no job-control suspend; the byte isn't consumed as a suspend |
| Ctrl-C (SIGINT) | ✅ works | interrupts the running command and returns to a fresh prompt |
| unknown command | ✅ clean error | `"…": executable file not found in $PATH` + `error: exit status 127` |
| `exit` at PID 1 | ✅ **no panic** | init `WaitOrphans()`, stays alive (see headline) |

**Job-control verdict:** gosh does **asynchronous spawn (`&`)** but is **not a
job-control shell** — no `jobs`/`fg`/`bg`, no Ctrl-Z suspend. **Signal delivery works**
(Ctrl-C/SIGINT interrupts foreground commands). Core interactive features (pipes,
redirection, globbing, variables, `$()`) all work.

## The command set — a real rescue toolkit (118 commands in `/bbin`)

u-root ships a busybox-style multi-call binary (`bb`) exposing 118 commands, including
the ones that make it a genuine recovery environment:

```
backoff base64 basename bb blkid brctl cat chmod chroot cmp comm cp cpio date dd df
dhclient dirname dmesg du echo false find free fusermount gosh gpgv gpt grep gzip head
hexdump hostname hwclock id init insmod io ip kexec kill lddfiles ln lockmsrs losetup ls
lsdrivers lsfd lsmod man md5sum mkdir mkfifo mknod mktemp more mount mount9p msr mv netcat
netstat nohup ntpdate pci pidof ping poweroff printenv ps pwd pxeboot readlink realpath rm
rmmod rsdp scp seq service shasum shutdown sleep sluinit sort sshd strace strings stty
switch_root sync tail tar tee time timeout touch tr true truncate ts tsort tty ufs umount
uname uniq unmount unshare update-rc.d uptime watchdog watchdogd wc wget which xargs yes
```

Highlights for firmware/rescue work: **`kexec`** + **`pxeboot`** (the boot policies this
lab exercises), **`ip`/`dhclient`/`wget`/`scp`/`sshd`/`netcat`/`ping`** (network bring-up
and transfer), **`mount`/`losetup`/`blkid`/`gpt`/`switch_root`** (storage), and
**`insmod`/`lsmod`/`rmmod`/`dmesg`/`strace`/`pci`/`io`/`msr`** (hardware poking). No text
editor and no `bash`/POSIX-scripting niceties (arithmetic `(( ))`, `case`, arrays) — gosh
is deliberately small.

## Scope

These probes target the **u-root rescue/boot environment** — the shell every tier passes
through. The *kexec'd* OS (the AlmaLinux/Rocky/Kali installer the boot policy hands off
to) is the payload, covered by [`POC-PXEBOOT.md`](POC-PXEBOOT.md) /
[`POC-PXEBOOT-P2.md`](POC-PXEBOOT-P2.md) / [`POC-PXEBOOT-P3.md`](POC-PXEBOOT-P3.md); it's a
full distro installer, not this lab's rescue shell, so it's out of scope here.

## Files

| File | Role |
|---|---|
| [`smoke-uroot.sh`](smoke-uroot.sh) | boot u-root on the fast `-kernel` loop, drive the probes, slice the transcript (`main` / `v0.14.0`) |
| [`smoke-uroot.py`](smoke-uroot.py) | the serial probe driver — types each probe fenced by a marker; `exit` last (it ends the shell) |
