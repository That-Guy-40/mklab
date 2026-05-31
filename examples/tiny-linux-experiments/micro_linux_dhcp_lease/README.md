# micro-linux gets a DHCP lease

A tiny demo: the from-source micro-linux distro — a kernel + a single static
BusyBox you compiled yourself — brings up a virtio NIC and pulls a **DHCP lease**
from QEMU's built-in user-mode network, all in RAM, booted on the real
`microvm` machine. It's the networking follow-on to the micro-linux build and a
nice end-to-end proof that virtio-net rides the **mmio** bus on microvm.

## Run it

```bash
# 1. Build the kernel + initramfs (rootless; once)
micro-linux/mlbuild.sh all --arch x86_64

# 2. Boot the DHCP demo (x86_64, uses KVM if available)
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro_linux_dhcp_lease/micro-linux-x86_64-dhcp.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-x86_64-dhcp
phase2-qemu-vm/lab-vm.sh console micro-linux-x86_64-dhcp     # attach the serial
```

The arm64 twin is `micro-linux-aarch64-dhcp.toml` (build `--arch aarch64`; runs
under slow TCG on an x86 host). For the riscv64 / u-root track, see
"[riscv64: run dhclient yourself](#riscv64-u-root-run-dhclient-yourself)" below —
it works differently.

On the console you'll see the network warning, then udhcpc binding eth0:

```
*** NETWORK ENABLED (mllab.net): this throwaway VM has a LIVE NIC ...
udhcpc: eth0 bound to 10.0.2.15 (gw 10.0.2.2, dns 10.0.2.3)

(none) login: root
Password:
~ # ifconfig eth0
eth0  ...  inet addr:10.0.2.15  Bcast:10.0.2.255  Mask:255.255.255.0
~ # ip route
default via 10.0.2.2 dev eth0
~ # cat /etc/resolv.conf
nameserver 10.0.2.3
```

(`10.0.2.15` / `10.0.2.2` / `10.0.2.3` are QEMU user-mode networking's fixed
slirp lease / gateway / DNS.) Quit with `poweroff`, or `Ctrl-]` to detach the
console without stopping the VM.

## How it works

Three small pieces, no daemon and no config files baked into the image beyond a
script:

1. **The NIC.** Phase 2's `kernel+initrd` backend always attaches a
   `virtio-net` device with user-mode networking + an SSH hostfwd. On `microvm`
   it rides the **virtio-mmio** bus (`virtio-net-device`), which is exactly why
   the micro-linux kernel is built with `CONFIG_VIRTIO_MMIO`.
2. **udhcpc.** BusyBox's DHCP client is already in our static BusyBox
   (`CONFIG_UDHCPC=y`). On each lease event it execs the handler baked at
   `/usr/share/udhcpc/default.script` (vendored as
   [`micro-linux/udhcpc.script`](../../../micro-linux/udhcpc.script)), which applies
   the address/route/DNS with `ifconfig`/`route`.
3. **Opt-in bring-up.** `/init` only touches the network when the kernel cmdline
   carries the `mllab.net` token (set via `append = "... mllab.net=1"`). It brings
   up `eth0`, runs `udhcpc` in the background, and prints the warning below. With
   the token absent — i.e. every *other* micro-linux spec — `/init` is byte-for-byte
   the network-down behavior it had before, so the default posture is unchanged.

## riscv64 (u-root): run dhclient yourself

The riscv64 "faithful track" runs the u-root (pure-Go) userspace instead of
BusyBox. It boots to an **interactive shell** (no getty/login) and ships its own
DHCP client, `dhclient` — so there's no udhcpc, no lease script, and no
`mllab.net` token. Networking stays off until you ask, which fits u-root's
interactive nature: just run the client at the shell.

```bash
micro-linux/mlbuild.sh all --arch riscv64
phase2-qemu-vm/lab-vm.sh create --config examples/tiny-linux-experiments/micro_linux_dhcp_lease/micro-linux-riscv64-dhcp.toml
phase2-qemu-vm/lab-vm.sh start  micro-linux-riscv64-dhcp     # TCG — slow
phase2-qemu-vm/lab-vm.sh console micro-linux-riscv64-dhcp
```

```
> dhclient -v -ipv6=false eth0           # -ipv6=false skips the v6 SOLICIT slirp ignores
... received message: DHCPv4(... msg_type=ACK, your_ip=10.0.2.15, server_ip=10.0.2.2)
Configured eth0 with IPv4 DHCP Lease IP 10.0.2.15/24
> ip addr show eth0                      # → inet 10.0.2.15/24
> ip route                               # → default via 10.0.2.2
```

(riscv `virt` puts virtio-net on **PCI**, handled by the kernel's
`CONFIG_VIRTIO_PCI`; `dhclient`/`ip` are in u-root's default `cmds/core/*` set.)

## ⚠️ Security (AUDIT F1)

Every other micro-linux spec sets `network = false` deliberately: root logs in
with the **well-known** password `micro`, and nothing authenticates the NIC. This
demo opts back in, which is fine for a throwaway lab on QEMU user-mode networking
(loopback/NAT; no inbound route without an explicit `hostfwd`) — but **do not
bridge this VM to an untrusted network**. If you later add tap/bridge networking
or a real listener, change the password (`MLBUILD_LAB_PASSWORD=...`) first.
