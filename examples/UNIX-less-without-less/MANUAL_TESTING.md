# MANUAL_TESTING — UNIX-less-without-less

Verification log: every command below was **actually run** on this repo's
host (2026-07-18), and the output shown is **captured, not typed from
memory**. Environments:

| | Debian container | Alpine container |
|---|---|---|
| image | `images:debian/13` → Debian **13.6** (trixie) | `images:alpine/latest` → Alpine **3.24.1** |
| bash | 5.2.37 (glibc) | 5.3.9 (musl) — *installed by setup* |
| dd | GNU coreutils 9.7 | GNU coreutils 9.11 — *installed by setup*; BusyBox 1.37.0 dd still probed |
| python3 | 3.13.5 | 3.14.5 |
| engine | Incus (via `phase5-lxd/lab-lxd.sh`) | same |

## 1. Bring-up + provision + demo (Debian)

```console
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-less-without-less/less-without-less-debian.toml
$ examples/UNIX-less-without-less/setup-workshop.sh less-without-less-debian/shell
==> [1/5] detecting distro in less-without-less-debian/shell
    distro=debian
...
==> [5/5] verifying the sandbox (as learner): run demo.sh
  whoami  : learner
  bash    : GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
  dd      : dd (coreutils) 9.7
  tput    : /usr/bin/tput
  python3 : Python 3.13.5
  --- running ~/less-without-less/demo.sh ---
```

**Success signature** (final lines, Debian):

```
   [ok]  Ctrl-C exits 130 -- exactly what USAGE.md documents, DESPITE stty raw
   [ok]  ...and bash still ran the EXIT trap: rmcup restored the terminal
   [ok]  dd sees Enter as byte 13 (\r survives: ICRNL really is off for dd)
...
----------------------------------------------------------------
PASS: all 28 checks hold (ddpager's features verified through a real
      pty; the dd trick and the raw-mode illusion both reproduce)
```

## 2. The same on Alpine

```console
$ phase5-lxd/lab-lxd.sh up --config examples/UNIX-less-without-less/less-without-less-alpine.toml
$ examples/UNIX-less-without-less/setup-workshop.sh less-without-less-alpine/shell
...
  whoami  : learner
  bash    : GNU bash, version 5.3.9(1)-release (x86_64-alpine-linux-musl)
  dd      : dd (coreutils) 9.11
  tput    : /usr/bin/tput
  python3 : Python 3.14.5
  --- running ~/less-without-less/demo.sh ---
...
PASS: all 28 checks hold (ddpager's features verified through a real
      pty; the dd trick and the raw-mode illusion both reproduce)
```

## 3. Documented divergence: Alpine before setup (captured verbatim)

```console
$ lab-lxd.sh exec less-without-less-alpine/shell -- sh -c 'command -v bash || echo "NO bash"'
NO bash

$ ... -- sh -c 'command -v tput || echo "NO tput"'
NO tput

$ ... -- sh -c 'dd if=/etc/hostname of=/dev/null bs=512 count=1 2>&1; readlink -f $(command -v dd)'
0+1 records in
0+1 records out
35 bytes (35B) copied, 0.000049 seconds, 697.5KB/s
/bin/busybox
```

Note the BusyBox dd stderr dialect: `35 bytes (35B) copied` vs GNU's
`35 bytes copied, ...`. `detect_binary`'s parser (previous word before
`bytes*`, must be all digits) handles both — verified inside the Alpine
container against the *BusyBox* dd on a 6-byte NUL-laden file:

```console
learner$ busybox dd if=/tmp/nul.bin of=/dev/null bs=512 count=1 2>&1 | <the pager's parse loop>
busybox-dd parsed byte count: 6
```

## 4. Driving the pager by hand (either base)

```console
learner$ cd ~/less-without-less
learner$ seq 1 100 | sed 's/^/line /' > /tmp/hundred.txt
learner$ python3 drive-pager.py --out /tmp/cap.bin -k '1.0:25G' -k '0.8:q' -- \
             bash bin/ddpager /tmp/hundred.txt ; echo rc=$?
rc=0
learner$ grep -ac 'line 25/100' /tmp/cap.bin
1
```

Interactively (a pager is for humans): `bash bin/ddpager /etc/passwd
/etc/hosts`, then `j`/`k`, `25G`, `/root`, `&nologin`, `:n`, `h`, `q`.

## 5. Notes for reproducers (a.k.a. things that bit the author)

- **`TERM` leaks through `lab-lxd.sh exec`.** The first container run failed
  17 of 28 checks: the host terminal's `TERM=xterm-ghostty` reached the
  pager, the container has no ghostty terminfo, every `tput` failed, and the
  pager drew *nothing* (status width `%.0s` truncates to zero). The driver
  now **forces `TERM=xterm`** in the child — a deterministic harness must
  not inherit the operator's terminal.
- **`script(1)` is not a faithful raw-mode harness.** Probing showed `\r`
  arriving as `\n` and Ctrl-C raising SIGINT even with the slave verifiably
  `-icrnl -isig` — that investigation is what surfaced the bash-`read`
  termios behavior the demo now proves with the dd experiment. Hence a real
  pty driver instead.
- **Keep pager filenames short in tests.** The status line truncates to the
  terminal width; a long absolute path pushes `line 1/100` clean off it,
  and your grep "fails" while the pager works fine.
- **The demo needs ~60 s** (a dozen pty sessions with human-speed typing).
  That is the cost of testing the real thing.

## 6. Teardown

```console
$ phase5-lxd/lab-lxd.sh down --lab less-without-less-debian
$ phase5-lxd/lab-lxd.sh down --lab less-without-less-alpine
```
