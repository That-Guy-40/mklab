# MANUAL_TESTING-pxeboot — provision an OS from the ROM, by hand

This walks the **PLAN-PXEBOOT P1** network-install **by hand**, one lab piece at a
time, so you can reproduce what [`showcase-pxeboot.sh`](showcase-pxeboot.sh) does in
one shot — and *feel* each stage. The **why** behind every command (and the DHCP wall
+ the coreboot stale-cache trap) is in [`POC-PXEBOOT.md`](POC-PXEBOOT.md); this file is
the hands-on drill plus **real captured transcripts** (Ubuntu 24.04 + QEMU 8.2.2 / KVM,
run **2026-07-01**, ANSI stripped, trimmed).

The chain you'll drive:

```
coreboot ROM ─► Linux (kernel DHCP: ip=dhcp) ─► u-root ─► pxeboot -file <URL>
   ─► fetch boot-<os>.ipxe (HTTP :8181) ─► fetch kernel+initrd ─► kexec
   ─► the installer runs its automated kickstart (RHEL) / preseed (Debian)
```

Three OSes, two installer families, **one OS-agnostic ROM**: **AlmaLinux 9** and
**Rocky 9** (RHEL / Anaconda / kickstart) and **Kali** (Debian / d-i / preseed).

---

## 0. Prerequisite — the pxeboot ROM (built once, offline)

The 16 MB `coreboot.rom` is author-run (~20 min); everything below reuses it. If you
don't have it yet:

```
$ ./fetch-go.sh                                    # no-sudo Go 1.25 (u-root main needs it)
$ CBCONFIG=coreboot-qemu-q35-pxeboot.config \
    UROOT_GOBIN=$HOME/linuxboot-lab/go1.25/bin ./build-coreboot.sh
```

Confirm it's the **pxeboot** ROM (u-root main + `ip=dhcp`), not the disk-finale one:

```
$ grep -E 'UROOT_MAIN|ip=dhcp' ~/linuxboot-lab/coreboot/.config
CONFIG_LINUX_COMMAND_LINE="console=ttyS0 ip=dhcp"
CONFIG_LINUXBOOT_UROOT_MAIN=y
```

> If you just flipped the config and rebuilt but the booted kernel later says
> `Unknown kernel command line parameters "ip=dhcp"`, you hit the **stale-cache trap**
> (order-only u-root clone + cached CI kernel) — see POC-PXEBOOT.md, clear the caches
> and rebuild. **Ground-truth the running kernel, never the `.config` on disk.**

---

## 1. Bring up the netboot server (`:8181`) — by hand

u-root `pxeboot` fetches the installer kernel/initrd (and the big stage2 / packages)
over HTTP. `serve-netboot.sh` just wraps the repo's rootless podman netboot server
(nginx, `~/netboot` → `:8181`):

```
$ ./serve-netboot.sh up
==> bringing up :8181 netboot server (reuses podman-netboot-server.toml)
==> :8181 serving ~/netboot
```

Prove it by hand with `curl` (the guest reaches the host at `10.0.2.2` over slirp;
from the host it's `127.0.0.1`):

```
$ curl -fsI http://127.0.0.1:8181/vmlinuz >/dev/null && echo OK
OK
```

---

## 2. Stage an OS installer + its iPXE script — by hand

`fetch-netboot-os.sh` reuses the `rocky-pxe-lab` / `kali-pxe-lab` fetchers and renders
`boot-<os>.ipxe`. AlmaLinux is pre-staged at `~/netboot/`; Rocky/Kali on demand:

```
$ ./fetch-netboot-os.sh rocky        # vmlinuz + initrd + the ~1.2 GB stage2 install.img
$ ./fetch-netboot-os.sh kali         # linux + initrd.gz (d-i pulls packages from the mirror)
```

What lands (Rocky shown) — note the iPXE script `pxeboot` will parse:

```
$ ls ~/netboot/rocky
.treeinfo  images/  initrd.img  rocky9-zerotouch.ks  vmlinuz
$ cat ~/netboot/boot-rocky.ipxe
#!ipxe
kernel http://10.0.2.2:8181/rocky/vmlinuz inst.stage2=http://10.0.2.2:8181/rocky/ \
  inst.ks=http://10.0.2.2:8181/rocky/rocky9-zerotouch.ks inst.text console=ttyS0 ip=dhcp
initrd http://10.0.2.2:8181/rocky/initrd.img
boot
```

`inst.stage2=…/rocky/` points Anaconda at the **local** `install.img` (via `.treeinfo`),
so the ~1.2 GB stage2 doesn't stream from the internet mid-install.

---

## 3. Boot the ROM and type `pxeboot` yourself

This is the heart of it. Give the installer a scratch disk to land on, then launch the
ROM **interactively** (serial on your terminal — no automation):

```
$ qemu-img create -f qcow2 ~/linuxboot-lab/pxe-target-alma.qcow2 12G

$ qemu-system-x86_64 -M q35 -accel kvm -cpu host -m 4096 \
    -bios ~/linuxboot-lab/coreboot/build/coreboot.rom \
    -netdev user,id=n0,tftp=$HOME/netboot,bootfile=boot-alma.ipxe \
    -device e1000,netdev=n0 -device virtio-rng-pci \
    -drive file=~/linuxboot-lab/pxe-target-alma.qcow2,format=qcow2,if=virtio \
    -nographic
```

- **`-cpu host`** — RHEL 9 glibc needs an x86-64-v2 microarch (else a boot panic); it
  also exposes RDRAND, which seeds the kernel CRNG so u-root's netboot has entropy.
- **`-device virtio-rng-pci`** — belt-and-suspenders entropy (needed on the TCG path).
- **`-nographic`** — serial goes to *your* terminal, so you can type. (Exit QEMU with
  `Ctrl-a x`.)

coreboot boots, the payload Linux does DHCP (`ip=dhcp`), u-root comes up as PID 1 and
drops you at a shell. **At the `$` prompt, type** (the URL is the iPXE script, served
by the server from step 1):

```
$ pxeboot -v -ipv6=false -file http://10.0.2.2:8181/boot-alma.ipxe
```

Why `-file` and not bare `pxeboot`: u-root's *own* DHCP client emits **zero packets**
over QEMU slirp (fully diagnosed in POC-PXEBOOT.md). `-file` is a "manual target" that
**skips u-root's DHCP** and fetches over the interface the **kernel** already brought
up with `ip=dhcp`. pxeboot parses the iPXE script, pulls kernel+initrd, and `kexec`s.

> **Automation note (what `drive-boot.py` does for you).** The lab's
> [`run-coreboot-pxe.sh`](run-coreboot-pxe.sh) launches the same QEMU with a unix
> **serial socket** instead of `-nographic`, and [`drive-boot.py`](drive-boot.py) types
> that exact command for you — one byte at a time with ~80 ms gaps, because a serial
> console has **no flow control** and drops characters fed too fast. By hand at a real
> terminal you don't notice; automating it, you must slow-type. One client per socket.

---

## 4. Watch the handoff — real transcripts

Each OS shows the identical firmware→u-root→pxeboot prefix, then `kexec`s into a
**different** kernel and a **different** installer. The `[    0.000000]` clock resetting
is the kexec — a fresh kernel starting its own clock.

### AlmaLinux 9.8 (Anaconda / kickstart) — ran to completion

```
IP-Config: Got DHCP answer from 10.0.2.2, my address is 10.0.2.15   ← the KERNEL's DHCP (ip=dhcp)
Welcome to u-root!                                                  ← u-root main, PID 1
2026/… Skipping DHCP for manual target..                            ← pxeboot -file: no u-root DHCP
2026/… Boot URI: http://10.0.2.2:8181/boot-alma.ipxe
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 …          ← KEXEC (clock reset)
Welcome to AlmaLinux 9.8 (Olive Jaguar)!
anaconda 34.25.7.14-1.el9.alma.1 for AlmaLinux 9.8 started.
Starting automated install.                                        ← the kickstart, unattended
Installing rootfiles.noarch (309/309)                              ← all 309 packages
Installing boot loader                                             ← install complete
```

### Rocky Linux 9.8 (Anaconda / kickstart) — a different RHEL member, same ROM

```
IP-Config: Got DHCP answer from 10.0.2.2, my address is 10.0.2.15
Welcome to u-root!
2026/… Skipping DHCP for manual target..  /  Boot URI: …/boot-rocky.ipxe
[    0.000000] Linux version 5.14.0-687.10.1.el9_8.0.1.x86_64 (mockbuild@…rockylinux.org) …   ← KEXEC
[    2.479171] Loaded X.509 cert 'Rocky … Rocky Linux kernel signing key: 9d828512…'          ← Rocky's own keys
Welcome to Rocky Linux 9.8 (Blue Onyx)!
anaconda 34.25.7.14-1.el9.rocky.0.6 for Rocky Linux 9.8 started.
Starting automated install.  /  Setting up the installation environment
```

### Kali (Debian d-i / preseed) — the *other* family entirely

```
Welcome to u-root!
$ pxeboot -v -ipv6=false -file http://10.0.2.2:8181/boot-kali.ipxe   ← the command, as typed
2026/… Skipping DHCP for manual target..  /  Boot URI: …/boot-kali.ipxe
2026/… Got ipxe config file …: kernel …/kali/linux … preseed/url=…/kali/kali-preseed.cfg …
[    0.000000] Linux version 7.0.12+kali-amd64 (devel@kali.org) (… gcc-15 …) Kali 7.0.12-2kali1   ← KEXEC
Loading additional components  … 100%                              ← debian-installer
Installing the base system  … 100%                                ← the preseed, unattended
```

> **One wart to know:** u-root's iPXE parser passes the script's `|| goto retry` through
> into the kexec cmdline, so d-i logs `Unknown kernel command line parameters "--- || goto
> retry …"`. It's harmless — d-i ignores unknown params (they go to userspace) and the
> base-system install proceeds — but it's why the Kali cmdline looks noisy.

Ground-truth (don't trust the screen scrape) — the two distinct target kernels prove the
kexec across families:

```
$ grep -h 'Linux version 5.14' ~/linuxboot-lab/pxe-rocky-boot.log | head -1   # RHEL family
$ grep -h 'Linux version 7'    ~/linuxboot-lab/pxe-kali-boot.log  | head -1   # Debian/Kali
```

---

## 5. Or: the whole thing in one shot

[`showcase-pxeboot.sh`](showcase-pxeboot.sh) does §1–§4 for every OS and prints a proof
grid — the "watch it all work" driver:

```
$ ./showcase-pxeboot.sh alma rocky kali
▶ Stage 0 — the coreboot ROM …          ✓ …/coreboot.rom (16M) — pxeboot config (u-root main + ip=dhcp)
▶ Stage 1 — the :8181 netboot server …  ==> :8181 serving ~/netboot
▶ Stage 2 — stage the installers …      ✓ alma  ✓ rocky  ✓ kali
▶ Stage 3/<os> — coreboot ROM → u-root → pxeboot -file → kexec → <os> installer   (×3)
▶ Stage 4 — proof grid:
  stage \ os                     alma    rocky   kali
  kernel DHCP (ip=dhcp)            ✓       ✓       ✓
  u-root (PID 1)                   ✓       ✓       ✓
  pxeboot -file (skip DHCP)        ✓       ✓       ✓
  fetched boot-<os>.ipxe           ✓       ✓       ✓
  kexec into installer             ✓       ✓       ✓
  installer running                ✓       ✓       ✓
  automated install started        ✓       ✓       ✓
```

Tear down the server when done: `./serve-netboot.sh down`.

---

## Summary

| Piece (by hand) | Command | Result |
|---|---|---|
| netboot server | `./serve-netboot.sh up` | ✅ `:8181` serving `~/netboot` |
| stage installers | `./fetch-netboot-os.sh rocky\|kali` | ✅ kernel+initrd(+stage2) + `boot-<os>.ipxe` |
| boot ROM + type `pxeboot -file` | `qemu … -bios coreboot.rom -nographic` | ✅ u-root shell → typed command |
| **AlmaLinux 9.8** | (Anaconda/kickstart) | ✅ kexec `5.14`, **309/309 pkgs + boot loader** |
| **Rocky 9.8** | (Anaconda/kickstart) | ✅ kexec `5.14` (Rocky keys), automated install started |
| **Kali** | (d-i/preseed) | ✅ kexec `7.0.12+kali`, **base system installed** |
| one-shot | `./showcase-pxeboot.sh alma rocky kali` | ✅ full proof grid |

Firmware booted Linux, which fetched three different OSes over the network and `kexec`'d
each into an unattended install. That's LinuxBoot's real job — reproduced from a real ROM.
