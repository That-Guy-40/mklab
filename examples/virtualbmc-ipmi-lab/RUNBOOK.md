# RUNBOOK — drive a VM's "BMC" by hand with VirtualBMC, `ipmitool`, and `virsh`

This is the teaching walk. The [`vbmc-lab.sh`](vbmc-lab.sh) wrapper exists so you
can run the lab fast — but the **point** is to understand the real tools it wraps:
how to **install** `vbmcd` (straight on the host, per the upstream how-tos), how to
register a VM as a virtual BMC with `vbmc`, and how to power it, pick its boot
device, watch its console, and **PXE-install an OS into it** — every step a raw
`ipmitool`/`vbmc`/`virsh` command you type yourself.

Sources, vendored byte-exact under [`upstream-tutorial/`](upstream-tutorial/README.md):
- **server-world** — *Ubuntu 24.04 : KVM : Use VirtualBMC* (the host-install recipe we track).
- **siberoloji** — *VirtualBMC on KVM with AlmaLinux* (the conceptual `vbmc`/`ipmitool` walk; the lab's `admin`/`password` creds come from here).

> **Throwaway lab creds only.** Everything below uses `admin`/`password` (BMC) and
> `root`/`alpine` (node OS) on **loopback**. Never put VirtualBMC, these creds, or
> an IPMI listener on a real or networked host — IPMI v2.0 `lanplus` has a
> well-known protocol weakness (RAKP hash disclosure) and these are demo passwords.

---

## 0. Host prerequisites (one time)

On the Ubuntu 24.04 KVM host:

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                    virtinst qemu-utils ipmitool podman curl cloud-image-utils
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm "$USER"      # log out/in for group membership
# the default NAT network must be active (steps 1–2 attach the node to it)
sudo virsh net-start default 2>/dev/null; sudo virsh net-autostart default
```

`ipmitool` is the IPMI client; `podman` runs the containerised `vbmcd`;
`virtinst`/`qemu-utils`/`cloud-image-utils` build the node. Everything else is a
stock server-world.info Ubuntu KVM host.

---

## 1. Install VirtualBMC — the real thing

`vbmcd` is a Python daemon; `vbmc` is its thin CLI (they talk over a Unix socket
under `~/.vbmc`). There are three ways to stand it up. **Read all three** — the
contrast is half the lesson.

### 1a. On the host, Ubuntu — a venv behind a systemd unit (server-world's way)

Modern distros mark the system Python **PEP 668 "externally managed"**, so a plain
`pip install` is refused. server-world's faithful answer is a dedicated venv that
can still see the system's libvirt C binding:

```bash
sudo apt -y install python3-pip python3-venv ipmitool
# --system-site-packages lets the venv import the OS's python3-libvirt
sudo python3 -m venv --system-site-packages /opt/virtualbmc
sudo /opt/virtualbmc/bin/pip3 install virtualbmc
```

Then run `vbmcd` as a service. Create `/usr/lib/systemd/system/virtualbmc.service`:

```ini
[Unit]
Description=Virtual BMC Service
After=network.target libvirtd.service

[Service]
Type=simple
ExecStart=/opt/virtualbmc/bin/vbmcd --foreground
ExecStop=/bin/kill -HUP $MAINPID
User=root
Group=root

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now virtualbmc.service
/opt/virtualbmc/bin/vbmc list            # empty table = the daemon is up
```

It runs as **root** because `qemu:///system`'s socket is `root:libvirt` — keep
this in mind, it's the same reason the container is rootful (§1c).

### 1b. On the host, AlmaLinux — `dnf` + `pip` (siberoloji's way)

siberoloji's page predates the PEP 668 lockdown, so it shows the older form:

```bash
sudo dnf install python3-pip libvirt libvirt-python ipmitool -y
sudo pip3 install virtualbmc        # AlmaLinux 9 will also warn/refuse here now
vbmc --version
```

On a current AlmaLinux 9 that `sudo pip3 install` hits the same externally-managed
wall, so the venv form from §1a (or `pipx install virtualbmc`) is the modern
faithful adaptation. The *commands* siberoloji then runs (`vbmc add/start/list`,
`ipmitool … power …`) are identical and are exactly what §3–§5 below cover.

### 1c. In a container — what this lab does, and why

This lab runs `vbmcd` in a **disposable Ubuntu 24.04 container**
([`Containerfile.vbmcd`](Containerfile.vbmcd)) so the host stays clean. Two design
points worth understanding:

- **It's rootful (`sudo podman`).** A rootless container maps your UID into a user
  namespace where it is *not* in the `libvirt` group, so it cannot open the
  `root:libvirt` `qemu:///system` socket we bind-mount in. Rootful podman's
  real-root process can. (Same root-ownership fact as §1a.)
- **`--break-system-packages` is OK *here*.** Inside a throwaway container we let
  pip drop `virtualbmc` into the system site-packages so it can import apt's
  prebuilt `python3-libvirt` (a venv/pipx would hide that C binding). On a real
  **host** you would *not* do this — there you'd use the venv (§1a) or pipx. That
  host-vs-container contrast is the whole reason both appear here.

```bash
cd examples/virtualbmc-ipmi-lab
./vbmc-lab.sh build       # sudo podman build -f Containerfile.vbmcd -t vbmcd:lab
./vbmc-lab.sh up          # sudo podman run -d --network host \
                          #   -v /var/run/libvirt:/var/run/libvirt -v ./state/vbmc:/root/.vbmc vbmcd:lab
```

`up` runs `vbmcd --foreground` as PID 1. `--network host` puts the IPMI UDP
listener straight on the host netns (so `ipmitool -H 127.0.0.1 -p 6230` just
works); the bind-mounted socket dir is how the container reaches the host's
libvirtd; `-v …/state/vbmc` persists your `vbmc add` config across restarts.

From here on, every `vbmc …` command is run **inside** the container with
`sudo podman exec vbmcd-lab vbmc …`. If you installed on the host (§1a/§1b)
instead, drop the `podman exec` prefix and run `vbmc …` directly — the arguments
are identical.

---

## 2. Define the node — a libvirt domain to manage

VirtualBMC manages a **libvirt domain by name**, so first we need a real VM.
[`create-node.sh`](create-node.sh) downloads a tiny Alpine cloud image, flattens it
into the libvirt pool, builds a NoCloud seed ISO (so there's a serial login), and
defines a domain `alpine-node` **left powered off**:

```bash
./create-node.sh
virsh -c qemu:///system list --all      # -> alpine-node   shut off
```

> **Why flatten (not a CoW overlay)?** qemu runs as `libvirt-qemu` and opens the
> *whole* backing chain at boot. An overlay whose backing file sits outside the
> pool (our download cache on the external mount) fails with *"Cannot access
> backing file … Permission denied"* — and VirtualBMC masks that as a bare IPMI
> **"Node busy"**. `qemu-img convert` collapses the image to one self-contained
> file in the pool. (We hit this for real — see [MANUAL_TESTING](MANUAL_TESTING.md).)

By hand, the essence of what the script does is:

```bash
qemu-img convert -f qcow2 -O qcow2 alpine-*.qcow2 /var/lib/libvirt/images/alpine-node.qcow2
virt-install --connect qemu:///system --name alpine-node --memory 512 --vcpus 1 \
    --import --disk path=/var/lib/libvirt/images/alpine-node.qcow2,bus=virtio \
    --disk path=…/alpine-node-seed.iso,device=cdrom \
    --osinfo detect=on,require=off --network network=default,model=virtio \
    --graphics none --console pty,target_type=serial --noautoconsole --print-xml \
  | sudo virsh -c qemu:///system define /dev/stdin
```

`--graphics none --console pty,target_type=serial` is what gives us a serial
console (§6) instead of a VGA display.

---

## 3. Register the node as a virtual BMC (`vbmc add` / `start` / `list` / `show`)

This is the heart of VirtualBMC — straight from both upstream pages:

```bash
V="sudo podman exec vbmcd-lab vbmc"          # or just: V=vbmc   (host install)

$V add alpine-node --port 6230 --username admin --password password
$V start alpine-node
$V list
# +-------------+---------+---------+------+
# | Domain name | Status  | Address | Port |
# +-------------+---------+---------+------+
# | alpine-node | running | ::      | 6230 |
# +-------------+---------+---------+------+
$V show alpine-node                          # full property table (libvirt_uri, port, …)
```

- `--port 6230`: IPMI's well-known port is **623**, but that's privileged; the lab
  binds an unprivileged **6230** per node. Add more nodes on 6231, 6232, …
- **Remote hosts:** server-world shows managing a VM on *another* KVM host by
  adding `--libvirt-uri qemu+ssh://root@<host>/system` (with an SSH key in place).
  Same `vbmc add`, different libvirt URI.
- `vbmc start` is what actually opens the IPMI UDP listener; `vbmc stop` /
  `vbmc delete` tear it back down.

The lab's convenience equivalent of this whole section is `./vbmc-lab.sh add`.

---

## 4. Power the node over IPMI — by hand

Now talk to it as if it were a physical server's BMC. The client is **`ipmitool`**
over `lanplus` (IPMI v2.0/RMCP+). Define a shell alias for brevity:

```bash
ipmi() { ipmitool -I lanplus -H 127.0.0.1 -p 6230 -U admin -P password "$@"; }

ipmi chassis power status     # Chassis Power is off
ipmi chassis power on         # Chassis Power Control: Up/On
ipmi chassis power status     # Chassis Power is on
ipmi chassis power off        # Chassis Power Control: Down/Off   (hard off)
ipmi chassis power reset      # hard reset (power-cycle a running node)
ipmi chassis power cycle      # off, then on
ipmi mc info                  # the (fake) BMC's own info — proves IPMI is answering
```

**Cross-check that it's real** — the IPMI command actually moved the libvirt domain:

```bash
ipmi chassis power on
virsh -c qemu:///system domstate alpine-node     # -> running
```

Under the hood: `ipmitool` sends an RMCP+/IPMI 2.0 Chassis Control request to UDP
6230; `vbmcd` receives it and calls libvirt `domainCreate()` / `domainDestroy()` on
`alpine-node` through the mounted socket. **A real IPMI command, over the wire,
moved a VM.** (Captured green in [MANUAL_TESTING](MANUAL_TESTING.md).)

Lab shortcuts: `./vbmc-lab.sh power on|off|status|reset|cycle` and
`./vbmc-lab.sh status` (which prints `vbmc list` + `ipmitool power status` +
`virsh domstate` side by side so you can see all three agree).

---

## 5. Pick the boot device over IPMI (`chassis bootdev`)

A BMC's other core job is choosing what the box boots *next*. VirtualBMC translates
IPMI boot-device requests into edits of the domain's `<os><boot>` element:

| `ipmitool chassis bootdev …` | libvirt `<boot dev=…>` |
|---|---|
| `pxe` | `network` |
| `disk` | `hd` |
| `cdrom` | `optical` |

```bash
ipmi chassis bootdev pxe
virsh -c qemu:///system dumpxml alpine-node | grep '<boot '
#   <boot dev='network'/>
ipmi chassis bootdev disk
virsh -c qemu:///system dumpxml alpine-node | grep '<boot '
#   <boot dev='hd'/>
```

So an IPMI call *re-orders the VM's firmware boot* — exactly how you'd tell a real
server "PXE-boot once for a reimage." Lab shortcut: `./vbmc-lab.sh bootdev pxe`
(it sets the device and prints the resulting `<boot>` line).

---

## 6. Watch the console — `virsh console` (VirtualBMC has **no** SOL)

A real BMC streams the server's serial console over IPMI **Serial-over-LAN**
(`ipmitool … sol activate`). **VirtualBMC does not implement SOL** — there's no
`activate_payload` in its code; it's scoped to power + boot device. The honest
substitute is **libvirt's own serial console**, which the node already exposes
(`--graphics none --console …serial` from §2):

```bash
ipmi chassis power on                              # the domain must be running
virsh -c qemu:///system console alpine-node        # Ctrl-] to detach
# … cloud-init runs on first boot (~30–60s), then:
#   alpine-node login:  root / alpine
```

Two things that bite people (both learned the hard way — see MANUAL_TESTING):

- **Run it in the foreground.** `virsh console` is interactive; backgrounding it
  (`… console &`) gives you no usable terminal. The lab's `./vbmc-lab.sh console`
  and `netboot` run it foreground and `exec` it so `Ctrl-]` drops you straight back
  to your shell.
- **One consumer at a time** on the console pty. A second `virsh console` silently
  steals the bytes.
- **The node must be running** — `virsh console` errors with *"domain is not
  running"* otherwise. Power it on first (`ipmi chassis power on`).

Why no serial login on a bare Alpine cloud image? It puts its login on the **VGA**
console (`tty0`), invisible to a headless VM — serial showed only the kernel boot.
[`create-node.sh`](create-node.sh) fixes this with a **NoCloud seed ISO**
(cloud-init) that sets the root password and adds a `getty` bound to `ttyS0`. (We
went this route because `virt-customize`/libguestfs is unusable on this host —
it dies `passt exited with status 1` on both its backends.)

---

## 7. The finale — PXE-install an OS into the node, over IPMI

Now the payoff: tell the node **over IPMI** to network-boot, power it on, and watch
it **PXE-install an OS** — bare-metal provisioning in miniature, exactly the
OpenStack Ironic workflow.

### Why it sidesteps the L2 nightmare

PXE is a DHCP *broadcast*, so the node and a DHCP/TFTP server must share a broadcast
domain. Instead of bridging the podman container onto a libvirt segment, we let
**libvirt's own dnsmasq be the PXE server**: a dedicated NAT network whose `<dhcp>`
serves the range + a `<bootp>` file, and whose `<tftp>` root hands out `boot.ipxe`.
The heavy kernel/initrd come over **HTTP** from the repo's existing nginx
(`~/netboot` on `:8181`, reached at the network's gateway IP).

```
node (vbmc-pxe NIC) ──DHCP/TFTP──> libvirt dnsmasq @ 192.168.123.1   (boot.ipxe)
                     ──HTTP──────> host nginx @ 192.168.123.1:8181    (kernel/initrd)
```

The node's QEMU virtio NIC already carries an iPXE option ROM; it runs the
`boot.ipxe` *script* we serve. ([`setup-pxe-net.sh`](setup-pxe-net.sh) builds all
of this; `8181` is intentional on this host — SABnzbd owns 8080.)

### 7a. Prove the netboot path first (busybox)

Same spike discipline as the rest of the lab — prove the **netboot path** with the
lightest payload (a tiny kernel + RAM initrd → a serial shell; no stage2, kickstart
or internet), *then* swap in the real installer.

```bash
./setup-pxe-net.sh                     # PAYLOAD=busybox (default)
NET=vbmc-pxe MEMORY_MB=4096 ./create-node.sh
./vbmc-lab.sh up && ./vbmc-lab.sh add
./vbmc-lab.sh netboot                  # bootdev=pxe + power on + attach console
```

Success: the NIC does DHCP, TFTP-fetches `boot.ipxe`, iPXE HTTP-fetches the kernel +
initrd, and Linux boots on `ttyS0` to a **busybox shell** — a node that booted with
**no OS on its disk**, driven entirely by IPMI.

> **Why `MEMORY_MB=4096`** (not the 512 default): a RAM-rooted netboot
> (`root=/dev/ram0`) holds the *uncompressed* rootfs in RAM **plus** the compressed
> initrd during `gunzip`. The 325 MB `initrd.gz` unpacks to ~1 GB; at 512 MB the
> kernel panics `out_of_memory` mid-`unpack_to_rootfs`. Give netboot nodes GBs.

### 7b. The real installer (AlmaLinux 9 Anaconda) — the provisioning lifecycle

> **Order matters: bring up the PXE network *before* the node.** Destroying or
> recreating a libvirt network orphans an attached node's NIC tap (silent: no DHCP,
> dead serial). `setup-pxe-net.sh` is now non-destructive — it leaves a running
> network alone — but the **first-time order is still net-first.**

If you have a half-installed node from a prior run, destroy it first:

```bash
./vbmc-lab.sh power off 2>/dev/null || true
virsh -c qemu:///system destroy  alpine-node 2>/dev/null || true
virsh -c qemu:///system undefine alpine-node --nvram 2>/dev/null || true
```

Then the lifecycle:

```bash
# 1. PXE side first: dnsmasq network + a clean whole-disk kickstart + HTTP
PAYLOAD=almalinux ./setup-pxe-net.sh           # look for "OK: …/kernel reachable"

# 2. node on that network, 10 GB disk, 4 GB RAM
DISK_SIZE=10G NET=vbmc-pxe MEMORY_MB=4096 ./create-node.sh

# 3. arm the BMC
./vbmc-lab.sh up && ./vbmc-lab.sh add          # "File exists" on add is fine (state persisted)

# 4. boot→network, install, power off  (Anaconda runs unattended over the console)
./vbmc-lab.sh netboot                          # clearpart vda → autopart → @^minimal → poweroff

# 5. boot→disk: run the OS you just provisioned
./vbmc-lab.sh power status                      # wait for "Chassis Power is off"
./vbmc-lab.sh bootdev disk
./vbmc-lab.sh power on
./vbmc-lab.sh console                           # AlmaLinux 9 from disk → login: root / alpine
```

That whole arc — **boot→network, power on (install), power off, boot→disk, power on
(run)** — is the bare-metal provisioning lifecycle, and *every step is an IPMI
command*. That's the finale. 🎉

Notes baked into the scripts so you don't re-hit our bumps:
- The stock AlmaLinux *gencloud* kickstart rebuilds their cloud **image** and
  references a pre-existing `vda2` — it fails on a blank disk (*"Partition vda2 does
  not exist"*). `setup-pxe-net.sh` therefore **generates** a clean
  `clearpart --all --drives=vda` + `autopart` kickstart at `~/netboot/vbmc-almalinux.ks`.
- That kickstart ends in **`poweroff`, not `reboot`** — `bootdev` is still `pxe`, so
  a reboot would loop straight back into the installer.

---

## 8. Teardown

```bash
./vbmc-lab.sh down            # stop the vbmcd container (keep the domain)
./vbmc-lab.sh destroy         # full: container + domain + image
./vbmc-lab.sh pxe-down        # the vbmc-pxe network + the HTTP payload container
```

By hand, the BMC-side teardown mirrors `vbmc add`:

```bash
$V stop alpine-node ; $V delete alpine-node      # unregister from VirtualBMC
```

---

## 9. Convenience layer ↔ real commands (cheat sheet)

| `vbmc-lab.sh …` | What it actually runs |
|---|---|
| `build` | `sudo podman build -f Containerfile.vbmcd -t vbmcd:lab .` |
| `up` | `sudo podman run -d --network host -v /var/run/libvirt:… -v state/vbmc:/root/.vbmc vbmcd:lab` (→ `vbmcd --foreground`) |
| `node` | `./create-node.sh` (define the libvirt domain) |
| `add` | `vbmc add alpine-node --port 6230 -U admin -P password` + `vbmc start alpine-node` |
| `power <c>` | `ipmitool -I lanplus -H 127.0.0.1 -p 6230 -U admin -P password chassis power <c>` |
| `bootdev <d>` | `ipmitool … chassis bootdev <d>` + show the resulting `<boot>` XML |
| `status` | `vbmc list` + `ipmitool … power status` + `virsh domstate` |
| `console` | `virsh -c qemu:///system console alpine-node` (guards: domain must be running) |
| `netboot` | `ipmitool … bootdev pxe` + `power on`/`reset` + `exec virsh console` |
| `destroy` / `pxe-down` | teardown (§8) |

---

## Gotchas (the fiddly bits, all hit for real)

- **IPMI "Node busy" on power on** = libvirt couldn't open the disk's backing
  chain. Flatten the image into the pool (§2); never use an out-of-pool CoW backing
  file with `qemu:///system`.
- **`vbmc add` says `File exists`** — harmless; the node is already registered from
  a prior run (state persists under `state/vbmc`). `vbmc start` re-arms the listener.
- **Silent serial + empty `virsh net-dhcp-leases vbmc-pxe`** during netboot = an
  **orphaned tap** (the node's NIC lost L2 because the network was recreated under
  it). Recover with a **cold** cycle (`power off` then `on`/`netboot`), *not* a warm
  `reset` — only a cold start re-bridges the tap.
- **`setup-pxe-net.sh` "network is already active" / mis-detected state** — fixed:
  it now does its libvirt reads with the same privilege as the writes and treats an
  already-active network as success.
- **`console` must be foreground**, one consumer at a time, domain running (§6).
