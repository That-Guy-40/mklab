# POC-PXEBOOT — network boot/provision from the coreboot ROM, and the u-root DHCP wall

> **Status: spike PROVEN end-to-end.** The full chain — coreboot-style firmware →
> Linux → u-root → `pxeboot` → `kexec` → an OS installer running an **automated,
> unattended install over the network** — was verified on this host (Ubuntu 24.04 +
> QEMU 8.2.2 / KVM). The verified transcript is at the bottom (AlmaLinux 9.8 Anaconda
> installing 309 packages). What is **not** yet done: folding this into the actual
> coreboot ROM (a `build-coreboot.sh` rebuild with u-root main); that's the P1
> follow-up. This document is the feasibility spike + the hard-won recipe, in the
> spirit of [`POC-MATRYOSHKA.md`](POC-MATRYOSHKA.md) and
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
| **`-device virtio-rng-pci`** + **`-cpu host`** | `could not get random number` / glibc `x86-64-v2` panic | u-root netboot needs entropy; RHEL9 userspace needs a v2 CPU |

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

## Verified transcript (fast `-kernel` loop, the mechanism the ROM will carry)

Command driven: `pxeboot -v -ipv6=false -file http://10.0.2.2:8181/boot-alma.ipxe`,
kernel booted with `ip=dhcp`, QEMU with `-cpu host -device e1000 -device virtio-rng-pci`:

```
IP-Config: Got DHCP answer from 10.0.2.2, my address is 10.0.2.15   ← kernel DHCP (real lease)
Welcome to u-root!
2026/… Skipping DHCP for manual target..                            ← pxeboot -file: no u-root DHCP
[kexec into the installer kernel 5.14.0-…el9_8.x86_64]
anaconda 34.25.7.14-1.el9.alma.1 for AlmaLinux 9.8 started.
Not asking for VNC because text mode was explicitly asked for in kickstart
Starting automated install.                                         ← the kickstart runs, unattended
Starting package installation process
Installing glibc.x86_64 (27/309) … Installing dracut-network.x86_64 (262/309)
```

Firmware-Linux booted Linux, which fetched an OS over the network and `kexec`'d into an
**unattended install**. That's LinuxBoot's real job, reproduced.

## What remains (P1 build-out, deferred to a fresh session)

- **Rebuild the ROM** with the network config:
  `./fetch-go.sh` then
  `CBCONFIG=coreboot-qemu-q35-pxeboot.config UROOT_GOBIN=$HOME/linuxboot-lab/go1.25/bin ./build-coreboot.sh`
  (u-root main; `ip=dhcp`, NIC, `virtio-rng`, `IP_PNP_DHCP` are baked in).
- `./serve-netboot.sh up` and `./fetch-netboot-os.sh both` (Rocky 9 + Kali), then
  `./run-coreboot-pxe.sh rocky` / `kali` — verify the same chain **from the real ROM**.
- A hands-off `uinit` wrapper (a uinit symlink can't carry the `-file` flag), then P2
  (HTTPS via the lab CA) and P3 (System Transparency). See [`PLAN-PXEBOOT.md`](PLAN-PXEBOOT.md).

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
