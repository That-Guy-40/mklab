# FLOPPINUX quality-of-life — add it live, then make it stick

A hands-on walkthrough: boot FLOPPINUX, log in, and add the niceties a normal
shell/distro has — **one at a time, with a validation after each** — then learn
how to make them permanent. Everything here assumes the **full** toolbox
(`BUSYBOX_FULL=1`, the [2.88 MB variant](floppinux-2.88mb/)); a few steps need
`grep`/`less`/`setsid`, which the curated build doesn't carry.

> If you'd rather have all of this baked in already, skip to the end: rebuild
> with **`QOL=1`** and it ships pre-wired. This doc is for *understanding* each
> piece by doing it by hand.

## Two facts to get straight first

1. **The root filesystem is an in-RAM initramfs.** Anything you change under `/`,
   `/etc`, `/bin`, … is in RAM and **vanishes on reboot**. Great for
   experimenting, useless for persistence — by itself.
2. **`/home` is the floppy.** `rc` bind-mounts the floppy's `data/` dir onto
   `/home`, so **files you write under `/home` persist** across reboots (they're
   really on the FAT disk). That's your lever for keeping things.

So each tweak below is **live now**; to keep it you either stash it under
`/home` and re-apply it, or bake it in with `QOL=1`. Validate that fact first:

```sh
mount | grep /home          # → /dev/fd0 on /home type msdos ...  (it's the floppy)
echo persist-test > /home/proof ; ls /home
```
Reboot, and `/home/proof` is still there; anything you put in `/etc` is not.

---

## 1. Put `/sbin` on `PATH` (fixes "applet not found" for `poweroff`, `halt`, …)

By default there's no `/etc/profile`, so `PATH` is bare and `/sbin` tools need a
full path. **Live:**

```sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin
```
**Validate:**
```sh
command -v poweroff        # → /sbin/poweroff   (before: prints nothing)
ip addr 2>/dev/null; echo $?   # ip (in /sbin) is now found
```

## 2. Aliases everyone expects

**Live:**
```sh
alias ls='ls --color=auto' ll='ls -alF' la='ls -A'
alias grep='grep --color=auto' ..='cd ..'
```
**Validate:**
```sh
ll /            # long, classified listing
ls /etc         # filenames now show in colour
```

## 3. A real prompt

The default prompt is a bare `#`. BusyBox `ash` understands the bash-style
escapes (`\u` user, `\h` host, `\w` cwd). **Live:**
```sh
PS1='\u@\h:\w\$ '
```
**Validate:** your prompt becomes e.g. `root@floppinux:/home# `. (Colour works
too if you like: `PS1='\033[1;32m\u@\h\033[0m:\w\$ '` — escape codes can be
finicky in `ash`, so plain is the safe default.)

## 4. Command history that survives reboots

History is on (full build), and because `/home` is the floppy you can **persist
it to the disk**. **Live:**
```sh
export HISTFILE=/home/.ash_history HISTSIZE=500
```
**Validate:** run a few commands, then:
```sh
history | tail            # up-arrow / Ctrl-R also recall them
exit                      # (or: kill -HUP $$) flushes history to the file
cat /home/.ash_history    # ...and it's on the floppy → survives reboot
```

## 5. Make 1–4 apply to *every* shell automatically — `/etc/profile` + `$ENV`

Typing those each login is tedious. `ash` sources **`/etc/profile`** for a login
shell, and **`$ENV`** for every interactive shell. Put your settings in one file
and point both at it. **Live:**
```sh
cat > /etc/profile <<'EOF'
export PATH=/bin:/sbin:/usr/bin:/usr/sbin HOME=/home ENV=/etc/profile
export HISTFILE=/home/.ash_history HISTSIZE=500 PAGER=less EDITOR=vi
alias ls='ls --color=auto' ll='ls -alF' grep='grep --color=auto' ..='cd ..'
PS1='\u@\h:\w\$ '
EOF
. /etc/profile          # apply to the current shell
```
**Validate:**
```sh
sh -c 'alias; echo "PATH=$PATH"'   # a fresh subshell already has the aliases + PATH
```
(That works because the subshell sources `$ENV=/etc/profile` on startup.)
**Keep it:** `/etc` is RAM, so copy it to the floppy and re-source after boot —
```sh
cp /etc/profile /home/profile      # persists on the floppy
# after a reboot:  . /home/profile
```

## 6. Names instead of numbers — `/etc/passwd` + `/etc/group`

`ls -l` shows UID `0` and `whoami` errors because there's no account database.
**Live:**
```sh
echo 'root:x:0:0:root:/home:/bin/sh' > /etc/passwd
echo 'root:x:0:'                     > /etc/group
```
**Validate:**
```sh
whoami           # → root      (before: "whoami: unknown uid 0")
id               # → uid=0(root) gid=0(root)
ls -l /etc/passwd  # owner shows as 'root', not '0'
```

## 7. A hostname

**Live:**
```sh
hostname floppinux
```
**Validate:**
```sh
hostname         # → floppinux
uname -n         # → floppinux  ; and PS1's \h now shows it
```

## 8. A login banner (motd)

**Live:**
```sh
printf '\n Welcome to FLOPPINUX.  `busybox --list` shows every applet.\n\n' > /etc/motd
cat /etc/motd
```
To show it automatically at each login, add `[ -f /etc/motd ] && cat /etc/motd`
to `/etc/profile` (§5).

## 9. Job control (fix "can't access tty; job control turned off")

That warning means the shell has **no controlling terminal**, so `Ctrl-C`,
`Ctrl-Z`, `fg`/`bg` don't work. You can grab one **live** with `setsid -c`:
```sh
setsid -c sh           # new session + controlling tty; sources $ENV from §5
```
**Validate** inside that shell:
```sh
sleep 100 &            # background job
jobs                   # → [1]+ Running   sleep 100
kill %1                # job control by %job now works; Ctrl-C / Ctrl-Z too
```
This is only for the current session. The *permanent* fix is a boot-model
change (next section) — you can't re-parent the already-running PID 1 by hand.

## 10. What you can't do live — needs a rebuild

Some "distro" features aren't runtime tweaks:

- **A `login:` prompt / proper sessions / `exit` not panicking.** PID 1 is the
  `rc` script; to get BusyBox `init` to respawn a login shell you change the
  boot (that's what `QOL=1` does). You *can* preview the mechanics:
  `getty 38400 /dev/tty1` or run `login` as a command — but the boot itself is
  fixed once running.
- **`tmpfs` / `devpts`.** Handy for a separate `/tmp` or pseudo-terminals, but
  this kernel doesn't include them — prove it:
  ```sh
  mount -t tmpfs none /tmp 2>&1      # → ... unknown filesystem type 'tmpfs'
  ```
  Adding them means `CONFIG_TMPFS` / `CONFIG_DEVPTS_FS` + `UNIX98_PTYS` in
  [`kernel.config-fragment`](kernel.config-fragment) and a kernel rebuild. (Note:
  the initramfs root is already RAM-backed and writable, so a separate `/tmp`
  tmpfs is mostly optional.)

---

## Make it permanent

**Option A — keep it on the floppy (no rebuild).** Put your customizations in one
file under `/home` (the floppy) and source it after each boot:
```sh
cp /etc/profile /home/profile        # plus /home/passwd etc. if you like
# every boot:  . /home/profile
```
Persists, but you re-source by hand (the RAM `rc` has no hook into `/home`).

**Option B — bake it in with `QOL=1` (rebuild).** This wires up *all* of the
above at boot, no manual steps:
```sh
cd examples/tiny-linux-experiments/floppinux/floppinux-2.88mb
QOL=1 BUSYBOX_FULL=1 ./build-2.88.sh build
./build-2.88.sh test
```
`QOL=1` bakes in: a **BusyBox-`init` login shell** with a controlling tty (job
control + `exit` respawns instead of panicking + `/etc/profile` auto-sourced),
plus `/etc/profile` (PATH incl `/sbin`, prompt, aliases, persistent history),
`/etc/passwd`+`/etc/group` (names), `/etc/hostname`, and `/etc/motd`. It enables
the few BusyBox features these need (`FEATURE_USE_INITTAB`, `FEATURE_INIT_SCTTY`,
line-editing/history, `ASH_EXPAND_PRMT`, `LS_COLOR`) — no-ops in the full build,
which already has them. See [`README.md`](README.md) and the variant's
[`floppinux-2.88mb/`](floppinux-2.88mb/) docs.

**Validate the baked version** (after the `QOL=1` rebuild boots): no
"job control turned off" message, the prompt is `root@floppinux:/home#`,
`whoami` → `root`, and typing `exit` re-spawns the shell instead of panicking.

## Shutting down / leaving QEMU

In the QoL build, the profile aliases `poweroff`/`reboot` to their **`-f`** forms,
so the bare commands work:

- **`poweroff`** (= `poweroff -f`) — direct, synced APM power-off; QEMU exits,
  graphical *and* headless. Needs `BUSYBOX_FULL` (the `poweroff` applet + APM kernel).
- **`reboot`** (= `reboot -f`) — CPU reset; in `test`/`-no-reboot` QEMU exits.
- **`Ctrl-A` then `X`**, or close the graphical window.

`halt` only halts the CPU (QEMU stays up).

**The alias workaround — apply it live (any build):**
```sh
alias poweroff='poweroff -f' reboot='reboot -f'
```
**Validate:** `poweroff` now powers the machine off (before the alias it was a
*no-op* — the prompt just returned). `poweroff -d 10` works too (it becomes
`poweroff -f -d 10`). To keep it without `QOL=1`, add that `alias` line to your
`/home/profile` (§5) and source it at boot; `QOL=1` bakes the same two aliases
into `/etc/profile`.

**Why the aliases are needed:** the *bare* `poweroff`/`reboot` (BusyBox applets)
do `kill(1, SIGUSR2/SIGTERM)` to ask **BusyBox `init`** for a graceful shutdown,
which doesn't fire in this minimal init — so they no-op. The `-f` forms skip init
and call `reboot(2)` directly (still `sync`ing first), so they actually work.

**How `poweroff` powers off:** [`kernel-apm.config-fragment`](kernel-apm.config-fragment)
(merged only for `BUSYBOX_FULL`) adds APM — `CONFIG_SUSPEND=y` (→ `PM_SLEEP` →
`PM`), `CONFIG_APM=y`, `CONFIG_APM_DO_ENABLE=y` (and leaves `CONFIG_APM_CPU_IDLE`
**off** — idle BIOS calls can hang). It's kept out of the curated kernel (APM
raises the boot RAM floor above 20 MB, and curated has no `poweroff` applet). If
`poweroff -f` only halts (`Power off not available`), APM didn't engage — try the
cmdline `apm=power-off`, or `CONFIG_ACPI=y`.
