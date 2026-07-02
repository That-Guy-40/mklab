# `qemu-guestfwd-boot.py` — drive a QEMU VM and serve it files, **no sudo, no host ports**

A sudo-free QEMU driver: it boots a disk/ISO image headless, **serves a
directory to the guest without opening any host port or running any server
process**, tees the serial console to a log, and exits `0` the instant a serial
line matches a marker you name (or times out and kills QEMU by PID). It
complements the serial-console *drivers* in this repo
([`serial-login-identify.py`](../serial-login-identify.py) and the per-lab
`drive-*.py`): those *type into* a VM; this one *launches* a VM, *feeds it
files*, and *waits for a result*.

## The trick: `guestfwd` + a per-connection responder

The standout idea, lifted from System Transparency's stboot test harness, is
QEMU user-net **`guestfwd`**:

```
-nic user,model=e1000,guestfwd=tcp:10.0.2.50:80-cmd:<responder>
```

slirp intercepts the guest's TCP connections to `10.0.2.50:80` and, **per
connection**, runs `<responder>` with the guest's byte stream wired to its
stdin/stdout. So the "web server" the guest talks to is a short-lived
subprocess that speaks one HTTP request/response over stdio and exits:

- **no listening socket on the host**, no bound port to collide with anything;
- **no long-running server**, nothing to start/stop/reap;
- **no root** — it's just a subprocess QEMU spawns.

This tool *is* that responder (`serve-http` subcommand) and also the launcher +
serial gate, in one file. That makes it ideal for the labs here that boot a VM
which must fetch something over the "network" (netboot images, OS packages,
kickstarts) while staying entirely in userspace.

## Provenance

A pure-Python port of the reusable core of **stboot v0.7.0**'s
`integration/qemu-boot-from-net.sh` (`git.glasklar.is/system-transparency/core`,
BSD-2-Clause). The two Go originals it reimplements — `serve-http.go` (the
per-connection HTTP responder) and `look-for.go` (the serial marker gate) — are
vendored byte-exact with attribution + sha256 under
[`vendor/`](vendor/README.md).

## Usage

```
# Boot a disk image, serve ./www to the guest, wait for a login prompt:
tools/qemu-guestfwd-boot/qemu-guestfwd-boot.py run \
    --disk out/disk.img \
    --www  out/www \
    --expect "amnesiac-debian login: " \
    --timeout 240
# exit 0 = marker seen; exit 1 = timeout / QEMU died first; full console in *.serial.log
```

Key options (see `run --help` for all):

| Option | Meaning |
|---|---|
| `--disk FILE` / `--cdrom ISO` | the boot image (raw `-drive` / `-cdrom`) |
| `--www DIR` | directory served to the guest over `guestfwd` (omit → plain user-net, no serving) |
| `--guest-addr IP:PORT` | guest-visible address the dir answers on (default `10.0.2.50:80`) |
| `--expect STR` | exit 0 when a serial line contains `STR` |
| `--timeout N` | seconds to wait before giving up (default 300) |
| `--bios PATH` | firmware for `-bios` (default `/usr/share/ovmf/OVMF.fd`; `''` → SeaBIOS) |
| `--nic-model M` | slirp NIC model (default `e1000`) |
| `--no-rng` | drop the virtio-rng entropy device (added by default) |
| `--mem`, `--log`, `--qemu` | RAM, serial-log path, QEMU binary |
| `-- <extra>` | anything after `--` is appended verbatim to the QEMU cmdline |

The `serve-http` subcommand is normally invoked *by QEMU*, not by hand, but it's
runnable standalone for testing:

```
printf 'GET /file HTTP/1.1\r\nHost: x\r\n\r\n' | \
    tools/qemu-guestfwd-boot/qemu-guestfwd-boot.py serve-http -d ./www
```

## How the port differs from the Go originals (deliberately)

- **Serial matching is substring, not strict line-prefix**, and **ANSI/CSI
  escapes are stripped before matching**. `look-for.go` matches a bare
  line-prefix; real consoles wrap prompts in color escapes, so substring +
  strip is more robust. It also matches on the **running line buffer**, so a
  login **prompt with no trailing newline** is still caught.
- **One file, two roles** (`run` + `serve-http`) instead of two Go binaries, and
  it re-execs itself as the `guestfwd` responder — no build step, stdlib only.
- **Kills QEMU by the recorded PID** (never by pattern) on match/timeout.
- **`e1000` is the default NIC.** Empirically (proven by running the upstream
  harness here) that is the model that carries `u-root`/stboot **DHCP over
  slirp** — DHCP is not "dead over slirp," it just needs a working NIC driver.

## Requirements

`qemu-system-x86_64` and Python 3 (stdlib only). For the default UEFI path,
OVMF at `/usr/share/ovmf/OVMF.fd` (Debian/Ubuntu: `apt install ovmf`). KVM is
used if available, with automatic fallback to TCG.
