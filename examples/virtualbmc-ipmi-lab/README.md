# VirtualBMC — give a libvirt VM an IPMI BMC, and PXE-provision it over IPMI

Real servers carry a **BMC** (Baseboard Management Controller — iDRAC, iLO, IPMI):
a tiny always-on computer that powers the box on/off, picks its boot device, and
streams its serial console — all **over the network**, independent of the OS.
It's how a data centre (and OpenStack **Ironic**) drives bare metal it can't
physically touch.

OpenStack **[VirtualBMC](https://opendev.org/openstack/virtualbmc)** fakes one for
a **libvirt virtual machine**: a daemon (`vbmcd`) listens for **IPMI-over-LAN** and
translates each command into a libvirt API call. So you can power a VM on with
`ipmitool` exactly as you would a physical server — then take the training wheels
off and **netboot-install an OS into it, driven entirely by IPMI**: the real
Ironic workflow, in miniature, on one laptop.

> **This is the repo's first libvirt-based lab.** Phase 2's `lab-vm.sh` is pure
> raw QEMU (zero libvirt); VirtualBMC's *only* driver is libvirt, so this lab
> talks to `qemu:///system` directly.

```
  host: ipmitool ──IPMI/UDP 6230──> vbmcd (container, --network host)
                                       │ libvirt API over the bind-mounted socket
                                       ▼
                              libvirt domain  "alpine-node"
                                       ▲
        (PXE finale) firmware iPXE ────┘ DHCP/TFTP from libvirt's own dnsmasq,
                                         kernel/initrd over HTTP → OS installs
```

## The teaching arc

| Step | What you prove | State |
|---|---|---|
| **1. Power round-trip** | A real IPMI `chassis power on` moves a libvirt domain (`ipmitool` ⟷ `vbmc` ⟷ `virsh` all agree). | ✅ verified |
| **2. Boot device + serial console** | IPMI `chassis bootdev pxe\|disk` rewrites the domain's `<os><boot>`; watch it boot on the serial console. | ✅ verified |
| **3a. PXE bridge (busybox)** | IPMI `bootdev pxe` + power → firmware netboots → a serial shell, with **no OS on disk**. | ✅ verified |
| **3b. PXE finale (AlmaLinux)** | The same path runs the **real Anaconda installer**, kickstart-installs to disk, powers off; flip `bootdev disk` and boot the OS you just provisioned. | ✅ verified |

The honest **scope** (and the surprises behind it):

- **No IPMI Serial-over-LAN.** VirtualBMC implements power + boot device only —
  there is no `activate_payload` in its code, so `ipmitool sol activate` is not a
  thing here. The console is **libvirt's own** `virsh console` (the honest
  substitute), which this lab wires up and showcases.
- **`vbmcd` runs in a rootful container.** `qemu:///system`'s socket is
  `root:libvirt` — a rootless container's user namespace can't open it. See the
  [RUNBOOK](RUNBOOK.md) for the container-vs-host-install trade-off (the upstream
  how-tos install it straight onto the host; we contrast both).
- **Throwaway lab creds only.** The BMC is `admin`/`password` on `127.0.0.1:6230`;
  the node's OS is `root`/`alpine`. Loopback/lab only — **never** a real or
  networked host.

## Quick start (the convenience layer)

`vbmc-lab.sh` and its helpers wrap the real tools so you can run the whole arc in a
handful of commands. (To learn the **actual** `vbmcd`/`vbmc`/`ipmitool` underneath
— including installing them on the host per the upstream how-tos — follow the
[RUNBOOK](RUNBOOK.md), which is the point of this lab.)

```bash
cd examples/virtualbmc-ipmi-lab

# one-time host prereqs (see RUNBOOK §0): qemu-kvm libvirt virtinst ipmitool podman

# Steps 1–2: a node + its BMC, then drive power & boot device over IPMI
./create-node.sh                 # define libvirt domain "alpine-node" (off)
./vbmc-lab.sh build              # build the vbmcd container image (rootful)
./vbmc-lab.sh up                 # run vbmcd (host net + mounted libvirt socket)
./vbmc-lab.sh add                # vbmc add alpine-node --port 6230 + vbmc start
./vbmc-lab.sh power status       # → Chassis Power is off   (== virsh: shut off)
./vbmc-lab.sh power on           # → Up/On
./vbmc-lab.sh bootdev pxe        # IPMI sets <boot dev='network'/>
./vbmc-lab.sh console            # libvirt serial console (login: root / alpine)

# Step 3: PXE-provision over IPMI (the finale)
PAYLOAD=almalinux ./setup-pxe-net.sh             # PXE network FIRST (order matters)
DISK_SIZE=10G NET=vbmc-pxe MEMORY_MB=4096 ./create-node.sh
./vbmc-lab.sh up && ./vbmc-lab.sh add
./vbmc-lab.sh netboot            # bootdev=pxe + power + console: watch Anaconda install
# …it powers off when done…
./vbmc-lab.sh bootdev disk && ./vbmc-lab.sh power on && ./vbmc-lab.sh console
```

> Use `PAYLOAD=busybox` (the default) for setup-pxe-net.sh first if you want to
> isolate and prove **just** the netboot path before the full installer.

## Files

| File | Role |
|---|---|
| [`README.md`](README.md) | this page — concept, arc, scope, quick start |
| [`RUNBOOK.md`](RUNBOOK.md) | **the by-hand walk**: install + drive the *real* `vbmcd`/`vbmc`/`ipmitool` (host **and** container), serial console, the PXE finale, gotchas |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | real captured serial/IPMI transcripts from each verified step |
| [`Containerfile.vbmcd`](Containerfile.vbmcd) | the `vbmcd` daemon as a disposable Ubuntu 24.04 container |
| [`create-node.sh`](create-node.sh) | define the managed libvirt domain (Alpine cloud image + NoCloud seed for a serial login) |
| [`vbmc-lab.sh`](vbmc-lab.sh) | the driver: `build`/`up`/`add`/`power`/`bootdev`/`console`/`netboot`/`destroy` |
| [`setup-pxe-net.sh`](setup-pxe-net.sh) | the PXE side: a libvirt dnsmasq network (DHCP/TFTP/bootp) + boot.ipxe + HTTP payloads (`PAYLOAD=busybox\|almalinux`) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | byte-exact archives of the two source how-tos (siberoloji + server-world) |

## Teardown

```bash
./vbmc-lab.sh destroy        # vbmcd container + domain + image
./vbmc-lab.sh pxe-down       # the vbmc-pxe network + the HTTP payload container
```

## Sources

Built from two write-ups, vendored byte-exact under
[`upstream-tutorial/`](upstream-tutorial/README.md):

- **Siberoloji**, *How to Use VirtualBMC on KVM with AlmaLinux* —
  <https://www.siberoloji.com/virtualbmc-kvm-almalinux/>
- **Server World**, *Ubuntu 24.04 : KVM : Use VirtualBMC* —
  <https://www.server-world.info/en/note?os=Ubuntu_24.04&p=kvm&f=14>

The PXE finale reuses the repo's existing AlmaLinux netboot assets
(`~/netboot`, served on `:8181`).
