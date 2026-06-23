# MANUAL_TESTING — captured transcripts

Real output from driving this lab on the Ubuntu 24.04 host (KVM/libvirt),
step by step. These are the actual pasted-back transcripts, warts and all — the
errors are kept because each one is a documented gotcha in the
[RUNBOOK](RUNBOOK.md). Throwaway lab creds throughout (`admin`/`password`,
`root`/`alpine`).

---

## Step 1 — the IPMI power round-trip

### 1a. First attempt hit the backing-file trap

```
./vbmc-lab.sh power status
Chassis Power is off
$ ./vbmc-lab.sh power on
Set Chassis Power Control to Up/On failed: Node busy
```

`Node busy` is VirtualBMC masking a libvirt error: qemu (as `libvirt-qemu`)
couldn't open the disk's backing file, which lived in the download cache on the
external `COLD_STORAGE` mount (AppArmor only whitelists `/var/lib/libvirt/images`).
Fix: flatten the image into the pool with `qemu-img convert` (now what
`create-node.sh` does). See [memory: libvirt backing-file outside pool].

### 1b. After the fix — GREEN

```
$ ./vbmc-lab.sh power status    # → "Chassis Power is off"
Chassis Power is off
$ ./vbmc-lab.sh power on        # → "Up/On"   (the one that just failed)
Chassis Power Control: Up/On
$ ./vbmc-lab.sh power status    # → "Chassis Power is on"
Chassis Power is on
$ ./vbmc-lab.sh status          # vbmc + ipmitool + virsh all agree
== vbmc list ==
+-------------+---------+---------+------+
| Domain name | Status  | Address | Port |
+-------------+---------+---------+------+
| alpine-node | running | ::      | 6230 |
+-------------+---------+---------+------+

== ipmitool chassis power status ==
Chassis Power is on

== virsh domstate alpine-node ==
running
```

**A real IPMI command, over the wire, moved a libvirt domain.** ✅

---

## Step 2 — boot device over IPMI

```
$ ./vbmc-lab.sh power off
Chassis Power Control: Down/Off
$ ./vbmc-lab.sh bootdev pxe
Set Boot Device to pxe
==> libvirt domain boot order now (set via IPMI -> libvirt XML):
    <boot dev='network'/>
$ ./vbmc-lab.sh bootdev disk
Set Boot Device to disk
==> libvirt domain boot order now (set via IPMI -> libvirt XML):
    <boot dev='hd'/>
```

IPMI `bootdev pxe`/`disk` rewrites the domain's `<os><boot dev=…>`
(`pxe`→`network`, `disk`→`hd`). ✅

The `console` subcommand correctly refuses when the domain is off (the guard
added after this run):

```
$ ./vbmc-lab.sh console
==> libvirt serial console for alpine-node (Ctrl-] to exit)
    (this is libvirt's console, NOT IPMI SOL — VirtualBMC has none)
error: The domain is not running
```

Powering on first, then `console`, brings up the serial login (`root`/`alpine`)
once cloud-init has run from the NoCloud seed. ✅

---

## Step 3a — PXE bridge, busybox payload (proves the netboot path)

After `setup-pxe-net.sh` (busybox), `create-node.sh NET=vbmc-pxe MEMORY_MB=4096`,
`up`/`add`, then `./vbmc-lab.sh netboot`:

```
[    1.323037] Freeing unused kernel image (text/rodata gap) memory: 2040K
[    1.339107] Run /init as init process
ip: SIOCGIFFLAGS: No such device
udhcpc: SIOCGIFINDEX: No such device
/bin/sh: 0: can't access tty; job control turned off
# ls
bin   etc   initrd.img      lib64    mnt   root  srv  usr      vmlinuz.old
boot  home  initrd.img.old  linuxrc  opt   run   sys  var
dev   init  lib             media    proc  sbin  tmp  vmlinuz
#
```

A node that booted to a shell **with no OS on its disk** — DHCP → TFTP `boot.ipxe`
→ iPXE HTTP kernel+initrd → busybox, the whole chain driven by one IPMI
`bootdev pxe` + power. ✅

(An earlier attempt at 512 MB kernel-panicked `out_of_memory` unpacking the RAM
initrd — that's *proof the netboot worked*; only the payload starved. Recreated
with `MEMORY_MB=4096`.)

---

## Step 3b — PXE finale, AlmaLinux 9 Anaconda installer

`PAYLOAD=almalinux ./setup-pxe-net.sh` then `./vbmc-lab.sh netboot` netbooted the
**real AlmaLinux installer** over IPMI. The node got a DHCP lease on the
`vbmc-pxe` network and Anaconda ran over the serial console:

```
$ virsh -c qemu:///system net-dhcp-leases vbmc-pxe
 Expiry Time           MAC address         Protocol   IP address          Hostname   Client ID or DUID
-----------------------------------------------------------------------------------------------------------
 2026-06-22 02:23:02   52:54:00:5e:a5:9a   ipv4       192.168.123.13/24   -          01:52:54:00:5e:a5:9a
```

```
================================================================================
Installation

1) [x] Language settings                 2) [x] Time settings
3) [x] Installation source               4) [x] Software selection
       (https://repo.almalinux.org/...)          (Custom software selected)
5) [!] Installation Destination          6) [x] Kdump
7) [x] Network configuration             8) [ ] User creation
       (Connected: ens2)
```

The first finale run surfaced a kickstart bug — the borrowed *gencloud* kickstart
referenced a pre-existing partition:

```
Partition "vda2" given in part command does not exist.
```

Fix: `setup-pxe-net.sh` now **generates** a clean whole-disk kickstart
(`clearpart --all --drives=vda` + `autopart`, ending in `poweroff`) at
`~/netboot/vbmc-almalinux.ks`. With that, the **full lifecycle was verified
end-to-end** (2026-06-23): PXE network up → node created → `netboot` → Anaconda
installs `@^minimal-environment` from the public mirror → **poweroff** →
`bootdev disk` → `power on` → AlmaLinux 9 boots from disk. ✅

> The clean installed-OS serial login wasn't captured verbatim in this session;
> paste it here on the next run to complete the record (`./vbmc-lab.sh console`
> after the disk boot → `localhost login: root`).

---

## Empty-leases / orphaned-tap gotcha (for reference)

During an early finale attempt the node was on `vbmc-pxe` but got **no** DHCP
lease — the symptom of an orphaned tap (the network had been recreated under the
running node):

```
$ virsh -c qemu:///system domiflist alpine-node
 Interface   Type      Source     Model    MAC
--------------------------------------------------------------
 vnet2       network   vbmc-pxe   virtio   52:54:00:5e:a5:9a

$ virsh -c qemu:///system net-dhcp-leases vbmc-pxe
 Expiry Time   MAC address   Protocol   IP address   Hostname   Client ID or DUID
-----------------------------------------------------------------------------------
  (empty)
```

Fixes: `setup-pxe-net.sh` is non-destructive (leaves a running network alone), and
recovery is a **cold** power cycle (not a warm `reset`) — only a cold start
re-bridges the tap. After that, the lease appears (the `192.168.123.13` capture
above).
