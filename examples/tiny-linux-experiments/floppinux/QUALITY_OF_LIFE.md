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
  boot (that's what `QOL=1` does). `QOL=1` gives you the init-handoff login
  *shell*; add **`LOGIN=1`** on top for a real `floppinux login:` prompt with a
  password — see **[Add a login prompt](#add-a-login-prompt-login1)** below. You
  *can* preview the mechanics live: `getty -L 0 - vt100` or run `login` as a
  command — but the boot itself is fixed once running.
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

## Add a login prompt (`LOGIN=1`)

By default the QoL build drops you **straight to a root shell** — convenient, but
not what a "real" distro does. `LOGIN=1` swaps that auto-spawned shell for a
proper `floppinux login:` prompt: you authenticate as **`root`** (password
**`lab`**) before you get a shell.

> **Throwaway credential.** `root`/`lab` is baked into the image so you can boot a
> floppy in QEMU — it is *not* security (anyone holding the image has it). Never
> put a `LOGIN=1` floppy on, or bridge its VM to, an untrusted network.

### Why this one isn't a live tweak (it needs a rebuild)

Unlike §1–§9, you can't switch a *running* system to a login prompt. The prompt
is produced by **`getty`**, and `getty` has to be spawned by `init` from
`/etc/inittab` **at boot**. Making a running `init` re-read a changed inittab
needs `SIGHUP` — and that's the exact PID-1 signal wall we hit with shutdown (see
[Shutting down](#shutting-down--leaving-qemu) below): the kernel won't deliver a
fatal-default signal like `SIGHUP` to PID 1, so `kill -HUP 1` no-ops and `init`
never reloads. So a login prompt is inherently a **boot-time** change. You can
still preview the moving parts live (below).

### The flow: `getty` → `login` → shell

1. **`getty`** opens the console, prints `/etc/issue`, shows `login:`, reads the
   username, then execs **`/bin/login`**.
2. **`login`** finds the user in `/etc/passwd`, prompts `Password:`, hashes what
   you type and compares it to the stored hash, prints `/etc/motd`, then execs
   the login shell (`-/bin/sh`) — which sources `/etc/profile` (so all of §1–§8
   and the `poweroff`/`reboot` functions are live the moment you're in).

Preview the prompt half live (the full build carries both applets) — `getty`
grabs the current console, shows the issue + `login:`, then hands to `login`:
```sh
getty -L 0 - vt100        # type a name to watch the hand-off; Ctrl-C to back out
```
(`login` then checks `/etc/passwd`; the non-login build's `root:x:…` has no
password set, so it'll say `Login incorrect` — `LOGIN=1` is what fills in the
hashed `root` account.)

### What `LOGIN=1` writes

`LOGIN=1` needs **`QOL=1`** (for the init→login-shell handoff) and
**`BUSYBOX_FULL=1`** (the curated set omits `getty`/`login`/crypt); the build
errors early if either is missing.

| File | Non-login QoL | `LOGIN=1` |
|------|---------------|-----------|
| `/etc/inittab` | `::respawn:-/bin/sh` | `::respawn:/sbin/getty -L 0 -` |
| `/etc/passwd`  | `root:x:0:0:…`       | `root:$1$floppinx$…:0:0:…` (hash of `lab`) |
| `/etc/issue`   | *(none)*             | one-line pre-login banner |

The design choices (all source-verified against BusyBox 1.36.1):

- **`getty -L 0 -`** — `-L` = ignore carrier-detect, baud `0` = leave the line
  speed alone, TTY `-` = *reuse the console fd `init` already opened* for me.
  That one entry serves **both** the `tty0` graphical console and the `ttyS0`
  serial console — no separate per-tty lines. No `TERMTYPE` argument, so `TERM`
  stays unset and `/etc/profile`'s `${TERM:-linux}` default holds (passing, say,
  `vt100` would silently downgrade the VGA console).
- **Hash inline in `/etc/passwd`, no `/etc/shadow`.** BusyBox `login` only
  redirects to `/etc/shadow` when the password field is *exactly* `x`/`*`; a real
  hash in field 2 is used directly. The hash is reproducible —
  `busybox cryptpw -m md5 -S floppinx lab` prints exactly the stored string.
- **No `/etc/securetty`.** When that file is *absent*, BusyBox treats every tty
  as "secure", so `root` may log in on the console. (If you ever *add* a
  `securetty`, the console tty must be listed or root login is refused.)

### Make it permanent

```sh
cd examples/tiny-linux-experiments/floppinux/floppinux-2.88mb
LOGIN=1 QOL=1 BUSYBOX_FULL=1 ./build-2.88.sh build
./build-2.88.sh test
```

### Validate (after the `LOGIN=1` boot)

- A `floppinux login:` prompt appears, with the issue banner above it.
- `root` + `lab` logs you in; a wrong password gives `Login incorrect`.
- `tty` → `/dev/console` and `sleep 5 & jobs` shows the job — **job control
  works** (the shell has a controlling terminal; no "job control turned off").
- **`exit` returns you to the `login:` prompt** (init respawns `getty`) — *not* a
  panic and *not* a bare root shell. That's the visible behaviour change from the
  non-login QoL build.

## Shutting down / leaving QEMU

The QoL build defines `poweroff`/`reboot` as **shell functions** that do the
graceful cleanup themselves, then force the power-off/reset:

- **`poweroff`** — `cd /`, `sync`, unmount the floppy (`/home`, then `/mnt`, so
  the FAT is cleanly unmounted — no "not properly unmounted" next boot), then
  `poweroff -f`. QEMU exits (graphical *and* headless). Needs `BUSYBOX_FULL` (the
  `poweroff` applet + the APM kernel).
- **`reboot`** — same cleanup, then `reboot -f`; in `test`/`-no-reboot` QEMU exits.
- **`Ctrl-A` then `X`**, or close the graphical window.

`halt` only halts the CPU (QEMU stays up).

**Apply it live (any build):**
```sh
poweroff() { cd /; sync; umount /home 2>/dev/null; umount /mnt 2>/dev/null; command poweroff -f "$@"; }
```
**Validate:** `poweroff` now unmounts the floppy (`mount | grep -c fd0` → 0) and
powers off — before, bare `poweroff` was a *no-op*. `QOL=1` bakes these functions
into `/etc/profile`; without it, add them to your `/home/profile` (§5).

### Why bare `poweroff`/`reboot` no-op — the init-signal dead end

We traced this; it's a genuine BusyBox/PID-1 interaction worth understanding.
Bare `poweroff`/`reboot` (the BusyBox applets, non-`-f`) do `kill(1, SIGUSR2)` /
`kill(1, SIGTERM)` to ask **BusyBox `init`** to run its `::shutdown:` actions and
power off. That *should* work — and it's **not** the inittab or how init is
started (a trivial `::shutdown:/bin/true` and a direct `rdinit=/sbin/init` boot
both still fail). The real chain:

1. BusyBox 1.36.1 init installs **no signal handler** for the shutdown signals —
   it `sigprocmask`-blocks them and drains them with `sigtimedwait` in its main
   loop. Their disposition stays **`SIG_DFL`** (`/proc/1/status` `SigCgt` = only
   `SIGTSTP`).
2. init is **PID 1**, and the kernel's init-protection **won't deliver a `SIG_DFL`
   signal whose default action is *fatal*** (SIGUSR2/SIGTERM/…) to PID 1 — even to
   `sigtimedwait`. The signal **queues** (`/proc/1/status` `ShdPnd` shows the bit)
   but is never dispatched, so init never enters its shutdown path.
3. `SIGCHLD` is the tell: same blocked set, but its default action is *ignore*
   (not fatal), so the kernel **does** deliver it — which is exactly why
   **respawn works but signal-driven shutdown doesn't.**

So the graceful *init* path is a dead end in this BusyBox+kernel combo short of
patching BusyBox to install handlers. The functions above get the same outcome
(cleanup, then power-off) reliably.

**The `-f` power-off itself** is APM: [`kernel-apm.config-fragment`](kernel-apm.config-fragment)
(merged only for `BUSYBOX_FULL`) sets `CONFIG_SUSPEND=y` (→ `PM_SLEEP` → `PM`),
`CONFIG_APM=y`, `CONFIG_APM_DO_ENABLE=y` (and leaves `CONFIG_APM_CPU_IDLE` **off**).
If `poweroff -f` only halts (`Power off not available`), APM didn't engage — try
the cmdline `apm=power-off`, or `CONFIG_ACPI=y`.
