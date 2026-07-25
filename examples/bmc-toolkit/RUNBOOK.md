# RUNBOOK — the out-of-band protocol tour, by hand

`bmc.sh` is the convenience layer. This walk drives the **real** tools underneath —
`ipmi_sim`, `ipmitool -I lanplus`, `sushy-emulator`, `curl` — so you learn what each
protocol actually does, and exactly where the toy diverges from a physical BMC. Every
command here is **headless & rootless** except the `vbmcd` section (rootful, marked).

## 0. Prereqs

```bash
# host tools (Debian/Ubuntu):
sudo apt install openipmi ipmitool qemu-system-x86 libvirt-daemon-system \
                 genisoimage isolinux syslinux-common python3 curl
# you in the rootless-virt groups:
id | grep -o 'kvm\|libvirt'      # both should appear; re-login after usermod -aG
```

## 1. The verb surface + the capability model (the reusable crux)

```bash
./bmc.sh list                    # each node -> backend -> endpoint
./bmc.sh node3 inspect           # a human table of what THIS backend faithfully implements
./bmc.sh node3 inspect --json    # the same, machine-readable — what a consumer routes on
```

The honesty rule: an unsupported verb is **refused loudly**, never a silent no-op.

```bash
./bmc.sh node1 insert-media x.iso    # vbmcd: "does not implement 'insert-media' (… use a redfish node)"
./bmc.sh node2 power on              # ipmi_sim: "… 0xCC … drive power via a coexisting vbmcd"
./bmc.sh node1 sol                   # vbmcd: flags itself a SUBSTITUTE (libvirt console, not IPMI SOL)
```

This is what makes the block reusable: a control plane asks `inspect --json` and programs
against capabilities, not guesses.

## 2. Real IPMI Serial-over-LAN with `ipmi_sim` (the money shot)

VirtualBMC has **no** IPMI SOL (no `activate_payload`). OpenIPMI `ipmi_sim` does — a real
RMCP+/lanplus BMC that bridges the SOL payload to a serial device. The toolkit wires it:

```bash
# node2's serial lives on tcp:127.0.0.1:9101 (see fleet-bmc.toml serial_tcp). Give it
# something to say — a real QEMU node (see §3) or, to see the bridge in isolation:
python3 tests/serial-source.py 9101 HELLO-SOL &      # a stand-in 'node serial'

./bmc.sh node2 bmc-up                                 # starts ipmi_sim; SOL <- tcp:9101
ipmitool -I lanplus -H 127.0.0.1 -p 9001 -U ipmiusr -P test -C 3 chassis status   # RMCP+ works
BMC_SOL_CAPTURE=8 ./bmc.sh node2 sol                  # REAL 'sol activate' — the marker streams
./bmc.sh node2 bmc-down; kill %1
```

**The load-bearing gotcha:** `ipmitool … sol activate </dev/null` reads stdin **EOF** and
tears the session down *before* any serial arrives. `bmc.sh sol` (and `BMC_SOL_CAPTURE`)
hold stdin open. Other `ipmi_sim` gotchas (all learned the hard way — see
[POC-A](POC-A-real-sol.md)): `-d` core-dumps (use `-n`); needs a writable `-s` state dir;
`-C 3` skips the slow cipher-suite probe; SOL is enabled by default. The SOL device may be
a PTY or **`tcp:host:port`** — the latter is the QEMU/libvirt path (`<serial type='tcp'>`).

**Power is delegated (coexist).** `ipmi_sim` chassis-control returns `0xCC` in 1.0.13, so
power/bootdev for an `ipmi_sim` node run on a coexisting `vbmcd` (§5). The `startcmd`
directive *is* the intended power hook (a `virsh start` shim), but the Chassis Control
command itself is rejected in this build — see POC-A's open follow-up.

## 3. A real VM's console over real SOL (combining §2 and §4's node)

The satisfying end-to-end: a real QEMU node whose serial is on `tcp:9101`, its boot
streamed over genuine SOL.

```bash
./make-proof-iso.sh --marker HELLO_FROM_A_REAL_VM --out /tmp/p.iso
nodes/make-session-node.sh --name bmc-sol-node --serial tcp:127.0.0.1:9101 \
    --cdrom /tmp/p.iso --out /tmp/sol-node.xml
virsh -c qemu:///session define /tmp/sol-node.xml

./bmc.sh node2 bmc-up                                  # ipmi_sim retries tcp:9101 until the VM binds it
BMC_SOL_CAPTURE=20 ./bmc.sh node2 sol &                # start capturing FIRST (kernel prints the marker once)
sleep 1; virsh -c qemu:///session start bmc-sol-node   # now boot — SOL streams the kernel banner
wait
virsh -c qemu:///session destroy bmc-sol-node; virsh -c qemu:///session undefine bmc-sol-node
./bmc.sh node2 bmc-down
```

> Start the SOL capture **before** booting: the kernel echoes its command-line marker once,
> very early. (The automated smoke uses the deterministic `serial-source.py` to avoid this
> race; this by-hand version shows the real thing.)

## 4. Redfish virtual media with `sushy-tools` (the centerpiece)

Redfish can do what IPMI cannot: **hand the machine an image**. `InsertMedia` attaches an
ISO as a virtual CD, a boot override points at it, and the node boots it — **no PXE/DHCP/
TFTP at all**.

```bash
nodes/make-session-node.sh --name bmc-vmedia-node --serial file:/tmp/n3.log \
    --out /tmp/vmedia-node.xml
virsh -c qemu:///session define /tmp/vmedia-node.xml

./bmc.sh node3 bmc-up                                  # bootstraps the sushy venv; ensures a storage pool
./bmc.sh node3 insert-media /path/to/install.iso       # sushy downloads the ISO, attaches a cdrom
virsh -c qemu:///session dumpxml bmc-vmedia-node | grep cdrom    # proof: the virtual CD is attached
./bmc.sh node3 bootdev cdrom
./bmc.sh node3 power on                                 # boots the installer off the virtual CD
./bmc.sh node3 eject-media; ./bmc.sh node3 bmc-down
virsh -c qemu:///session destroy bmc-vmedia-node; virsh -c qemu:///session undefine bmc-vmedia-node
```

Under the hood it's just curl (see `backends/redfish.sh`):
`POST …/VirtualMedia/Cd/Actions/VirtualMedia.InsertMedia {"Image":"http://…/x.iso"}`.
Gotchas (see [POC-B](POC-B-redfish-vmedia.md)): the `Image` must be an **HTTP URL** (real
BMCs download it — `bmc.sh` serves a local ISO over localhost); sushy needs a libvirt
**storage pool** (`bmc-up` creates one); sushy **adds** the cdrom itself (the node needs no
pre-provisioned slot); and **UEFI** needs a `SUSHY_EMULATOR_BOOT_LOADER_MAP` override to
the host's real OVMF path (v1 uses **BIOS**, which needs no loader).

## 5. VirtualBMC power (the proven IPMI baseline) — ROOTFUL, author-run

`vbmcd` drives a `qemu:///system` domain and its socket is `root:libvirt`, so this section
is **author-run** (sudo). Reuses [`../virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/RUNBOOK.md):

```bash
cd ../virtualbmc-ipmi-lab && ./create-node.sh && ./vbmc-lab.sh up && ./vbmc-lab.sh add
cd ../bmc-toolkit
./bmc.sh node1 power status         # ipmitool -I lanplus … chassis power status
./bmc.sh node1 bootdev pxe
./bmc.sh node1 power on
./bmc.sh node1 sol                  # SUBSTITUTE: prints the `virsh console` command (no IPMI SOL here)
```

## 6. Divergences from a real BMC (name them, don't hide them)

- **`ipmi_sim` power = 0xCC** in 1.0.13 → coexist with `vbmcd`. A real BMC does power+SOL
  in one session; here it's two BMCs behind one verb surface.
- **`vbmcd` "sol"** is libvirt's console, not IPMI SOL (VirtualBMC has no `activate_payload`).
- **`redfish` "sol"** tails the node's libvirt serial; sushy doesn't emulate Redfish
  SerialConsole. `sensors`/`fru`/`sel` are `partial` — real hardware exposes far more.
- **swtpm/attestation, real auth, non-loopback `lanplus`** are all out of scope (F1) — this
  is a lab on an isolated loopback, never a real host.
