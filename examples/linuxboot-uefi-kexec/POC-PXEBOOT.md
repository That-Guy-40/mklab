# POC-PXEBOOT — network boot/provision from the coreboot ROM, and the u-root DHCP wall

> **Status: VERIFIED FROM THE REAL COREBOOT ROM.** The full chain — the actual
> `coreboot.rom` (16 MB, `qemu -bios`) → Linux → u-root **main** → `pxeboot -file`
> → `kexec` → an OS installer running an **automated, unattended install over the
> network** — was verified end-to-end on this host (Ubuntu 24.04 + QEMU 8.2.2 / KVM).
> AlmaLinux 9.8 Anaconda ran its kickstart to **309/309 packages + boot loader**
> straight off the ROM (transcript at the bottom). The first pass of this doc proved
> the *mechanism* in the fast `qemu -kernel` loop; it is now proven in the real
> firmware. Still open (P1 follow-up): the same run for **Rocky 9 + Kali** from the
> same ROM, and a hands-off `uinit` wrapper. In the spirit of
> [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) and
> [`POC-UEFI-MATRYOSHKA.md`](POC-UEFI-MATRYOSHKA.md).

This is the network sibling of the disk finale ([`RUNBOOK.md`](RUNBOOK.md) §6): instead
of u-root's `boot` reading a local disk's GRUB, u-root's **`pxeboot`** fetches an OS over
the network and `kexec`s it — the actual reason LinuxBoot exists at scale
([`PLAN-PXEBOOT.md`](PLAN-PXEBOOT.md) P1).

## TL;DR — the recipe that works

```
coreboot ROM ─► Linux (kernel does DHCP: ip=dhcp) ─► u-root ─►
   pxeboot -file http://10.0.2.2:8181/boot-<os>.ipxe ─► (fetch kernel+initrd) ─►
   kexec ─► the installer ─► automated kickstart/preseed install
```

Four non-obvious keys, each forced by a concrete failure:

| Key | Without it | Why |
|---|---|---|
| **u-root `main`** (Go ≥1.25) | v0.14.0 has no usable path | main's `pxeboot -file` skips DHCP; v0.14.0's does too but see below — both share the DHCP bug, so we need `-file` regardless, and `-file` is cleanest on main |
| **kernel `ip=dhcp`** (`CONFIG_IP_PNP_DHCP`) | no IP at all | u-root's own DHCP client emits **zero packets** over QEMU slirp (see below); the *kernel's* in-stack DHCP works fine |
| **`pxeboot -file <URI>`** | `pxeboot` hangs at "Attempting to get DHCPv4 lease" | `-file` = a "manual target" that **skips DHCP** and fetches over the already-configured interface |
| **`-cpu host`** (+ `-device virtio-rng-pci`) | glibc `x86-64-v2` panic / `could not get random number` | RHEL9 userspace needs a v2 microarch; u-root netboot needs early entropy. `-cpu host` also exposes **RDRAND**, which seeds the kernel CRNG in time — so on the real ROM (no `CONFIG_HW_RANDOM_VIRTIO` in the payload kernel) the entropy stall **did not recur** even though the kernel couldn't use the virtio-rng device. Keep `virtio-rng-pci` as insurance / for the TCG path where RDRAND is absent. |

## The wall: u-root's DHCP emits no packets over QEMU slirp

The obvious plan was "type `pxeboot`, watch it DHCP and boot." It never got past:

```
2026/… Attempting to get DHCPv4 lease on eth0
2026/… Netboot failed: context deadline exceeded
```

`eth0` came up (kernel IPv6 SLAAC happened), the interface was `UP`, but no lease. A
QEMU `-object filter-dump` pcap of the guest NIC told the real story: **zero IPv4 frames
left the guest** — only the boot-time IPv6. u-root's DHCP `WriteTo` returns *success*,
yet nothing reaches the wire.

### Ruling out every suspect (pcap-verified)

The temptation is to blame slirp, the NIC, or the pinned old u-root. All wrong:

- **Not the u-root version.** Built u-root **main** (commit `4cba096`, Go 1.25.7) — DHCP
  fails **identically**, 0 frames. *A newer u-root does not fix it.*
- **Not the kernel config.** Rebuilt the payload kernel with u-root's **own CI kernel
  config** (`.circleci/images/kernel-amd64/config_linux.txt` — `NET_SCHED`, `NETFILTER`,
  the lot). Still 0 frames. (Our minimal config already matched u-root's on every network
  symbol.)
- **Not KVM/machine/NIC/CIDR.** KVM ≡ TCG, `q35` ≡ `pc` (i440fx), `e1000` ≡ `virtio-net`,
  default net ≡ u-root's `net=192.168.0.0/24`, explicit MAC ≡ default — all 0 frames.
- **The static-IP control passed.** With a hand-set `ip addr add 10.0.2.15/24` +
  route, `wget http://10.0.2.2:8181/…` fetches fine. The whole TCP/IP stack + slirp +
  HTTP work — only DHCP (u-root's AF_PACKET client) is broken.

### The tell: the kernel's own DHCP works

On the **identical kernel**, booting with `ip=dhcp` (kernel in-stack DHCP, not u-root):

```
Sending DHCP requests ., OK
IP-Config: Got DHCP answer from 10.0.2.2, my address is 10.0.2.15
```

and the pcap shows the full `DHCP Discover → Reply`. So **slirp DHCP + Linux works** — the
bug is *specifically* u-root's userspace **AF_PACKET `SOCK_DGRAM`** broadcast send
(`insomniacslk/dhcp`'s `nclient4` via `mdlayher/packet`), which doesn't egress on this
host. A different DHCP *server* wouldn't help; the send never happens.

## The fix, discovered by reading u-root's source

`pxeboot`'s `-file` flag is documented as *"full URI to use instead of DHCP."* In
`cmds/boot/pxeboot/pxeboot_linux.go`, when `-file` is set `main()` takes a different
branch:

```go
} else {
    log.Printf("Skipping DHCP for manual target..")
    l, err = newManualLease()          // builds a lease from -file/-server, NO DHCP
    images, err = netboot.BootImages(ctx, ulog.Log, curl.DefaultSchemes, l)
}
```

`newManualLease()` never touches the network config — it relies on the interface being
**already up**. So: let the **kernel** DHCP (`ip=dhcp`), then `pxeboot -file <the iPXE
script URL>` fetches over that interface, parses the iPXE script (its `dhcp`/`goto`/`sleep`
lines are harmlessly *"Ignoring unsupported ipxe cmd"*), pulls kernel+initrd, and `kexec`s.

Two more speed bumps, both from u-root's own test harness (`qemu.VirtioRandom()`):

- `Netboot failed: could not get random number: context deadline exceeded` → the kernel's
  RNG had no entropy. Add QEMU **`-device virtio-rng-pci`** (+ `CONFIG_HW_RANDOM_VIRTIO`).
- The installer kexec'd, then `Fatal glibc error: CPU does not support x86-64-v2` →
  kernel panic. AlmaLinux/RHEL 9 userspace needs a v2 microarch. Add **`-cpu host`**.

## Verified transcript (the REAL ROM — `qemu -bios coreboot.rom`)

`./run-coreboot-pxe.sh alma` — a genuine coreboot ROM boots, the driver types
`pxeboot -v -ipv6=false -file http://10.0.2.2:8181/boot-alma.ipxe`, QEMU with
`-M q35 -cpu host -device e1000 -device virtio-rng-pci`:

```
IP-Config: Got DHCP answer from 10.0.2.2, my address is 10.0.2.15   ← the KERNEL's DHCP (ip=dhcp)
Welcome to u-root!                                                  ← u-root main, PID 1
2026/… Skipping DHCP for manual target..                            ← pxeboot -file: no u-root DHCP
2026/… Boot URI: http://10.0.2.2:8181/boot-alma.ipxe               ← fetch the iPXE script over the lease
[    0.000000] Linux version 5.14.0-687.5.3.el9_8.x86_64 …          ← KEXEC — clock resets (fresh kernel)
Welcome to AlmaLinux 9.8 (Olive Jaguar)!
anaconda 34.25.7.14-1.el9.alma.1 for AlmaLinux 9.8 started.
Starting automated install.                                        ← the kickstart runs, unattended
Installing rootfiles.noarch (309/309)                              ← all 309 packages
Installing boot loader                                             ← install complete
Configuring installed system
```

A real firmware ROM booted Linux, which fetched an OS over the network and `kexec`'d
into an **unattended install that ran to completion**. That's LinuxBoot's real job,
reproduced in genuine firmware. (The first proof of the *mechanism* was in the fast
`qemu -kernel` loop — same four keys, same result, ~20 s per iteration instead of a
ROM rebuild; that loop remains the way to iterate.)

## The coreboot rebuild trap (what it took to get the ROM to match the config)

Flipping the coreboot config to `CONFIG_LINUXBOOT_UROOT_MAIN=y` + `ip=dhcp` and
re-running `build-coreboot.sh` produced a ROM that **looked** rebuilt but wasn't —
the booted kernel printed `Unknown kernel command line parameters "ip=dhcp", will be
passed to user space` (no in-kernel DHCP → `network is unreachable`). Two stale
caches, both silent:

- **u-root stayed v0.14.0.** coreboot's payload Makefile clones u-root with an
  **order-only prerequisite** — `$(uroot_build): | build/ ; git clone … ; git checkout
  $(VERSION)`. Order-only means "run only if the *directory* is absent"; it does **not**
  re-fire when `UROOT_VERSION` flips `v0.14.0`→`main`. The old checkout persisted.
- **The kernel stayed the wrong build.** `build/kernel-6_3` held a **CI-config** kernel
  from an earlier spike (`NETFILTER=y`, ~3975-line `.config`) and `build/Image` was an
  even older copy — neither carried `CONFIG_IP_PNP`. coreboot happily re-wrapped that
  stale payload into CBFS.

Fix = a **clean payload rebuild**: remove `build/kernel-6_3`, `build/Image`,
`build/initramfs*`, and the `build/go/src/github.com/u-root/u-root` checkout (keep the
137 MB `linux-6.3.tar.xz` and the crossgcc toolchain), then rebuild. The result: a
fresh kernel from the **committed minimal defconfig** (IP_PNP present, no NETFILTER)
and u-root **main** — the ROM that produced the transcript below. **Ground-truth the
running kernel** (the `ip=dhcp` accept/reject line, `/proc/cmdline`), never the config
on disk.

## What remains (P1 follow-up)

- **Rocky 9 + Kali from the same ROM.** `./serve-netboot.sh up` +
  `./fetch-netboot-os.sh both`, then `./run-coreboot-pxe.sh rocky` / `kali`. (The ROM
  is OS-agnostic — only the staged installer + `boot-<os>.ipxe` change.)
- A hands-off `uinit` wrapper (a uinit symlink can't carry the `-file` flag), then P2
  (HTTPS via the lab CA) and P3 (System Transparency). See [`PLAN-PXEBOOT.md`](PLAN-PXEBOOT.md).

### To rebuild the ROM from scratch

`./fetch-go.sh` then
`CBCONFIG=coreboot-qemu-q35-pxeboot.config UROOT_GOBIN=$HOME/linuxboot-lab/go1.25/bin ./build-coreboot.sh`
(u-root main; `ip=dhcp`, NIC, `IP_PNP_DHCP`, virtio-rng are baked into the config +
`build-coreboot.sh` §3a). On a **fresh** coreboot clone this is one clean shot; on a
tree from an earlier build, clear the stale caches above first.

## Files this spike leaves behind

| File | Role |
|---|---|
| [`fetch-go.sh`](fetch-go.sh) | no-sudo Go 1.25 (u-root main needs it) |
| [`coreboot-qemu-q35-pxeboot.config`](coreboot-qemu-q35-pxeboot.config) | the network-boot ROM config (u-root main + `ip=dhcp`) |
| [`build-coreboot.sh`](build-coreboot.sh) | `CBCONFIG=`/`UROOT_GOBIN=` build the pxeboot ROM; §3a adds NIC + `IP_PNP_DHCP` + `virtio-rng` |
| [`serve-netboot.sh`](serve-netboot.sh) | bring up the `:8181` netboot server (reuses the podman netboot TOML) |
| [`fetch-netboot-os.sh`](fetch-netboot-os.sh) | stage Rocky + Kali installers + render `boot-<os>.ipxe` (reuses the pxe-labs) |
| [`run-coreboot-pxe.sh`](run-coreboot-pxe.sh) | boot the ROM + drive `pxeboot -file` (`-cpu host`, `virtio-rng`) |
| [`drive-boot.py`](drive-boot.py) | the serial driver (now handles v0.14.0 *and* main prompts) |
