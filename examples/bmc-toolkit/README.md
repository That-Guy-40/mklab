# BMC Toolkit — one out-of-band verb surface over IPMI · real SOL · Redfish virtual media

A **reusable out-of-band (OOB) management toolkit** for libvirt VMs: a single,
protocol-agnostic front door — `bmc.sh <node> <verb>` — over **three interchangeable
backends**. Consumers (a control plane like `METAL_AS_A_SERVICE`, a resilient-region
driver, or you at a shell) power a node, pick its boot device, stream its console, or
hand it an install ISO **without caring which protocol reaches the metal**.

This lab is built to be **lifted out and reused** — its verb surface, capability model,
and backend registry are the stable API; everything else is internal. It generalizes the
sibling [`virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/README.md) (IPMI power/bootdev)
into the full OOB surface: **real Serial-over-LAN** and **Redfish virtual media**.

```
   consumer  ──►  bmc.sh <node> power|bootdev|sol|insert-media|sensors|…|inspect
                     │  looks up the node's backend in fleet-bmc.toml
        ┌────────────┼───────────────────────────────┐
        ▼            ▼                                ▼
     vbmcd        ipmi_sim                         redfish (sushy-tools)
   IPMI power    IPMI + REAL SOL                Redfish power/boot + VIRTUAL MEDIA
   + bootdev     (RMCP+/lanplus)                (InsertMedia → boot an ISO, no PXE)
        └──────────── all drive the same libvirt domain ─────────────┘
```

## The three backends (and what each *faithfully* implements)

| Verb | `vbmcd` (IPMI) | `ipmi_sim` (IPMI+) | `redfish` (sushy) |
|---|---|---|---|
| power on/off/cycle/status | ✅ real | ⛔ 0xCC in 1.0.13 → **coexist** | ✅ real |
| boot device (pxe/disk/**cdrom**) | ✅ | ⛔ (coexist) | ✅ |
| **SOL / serial** | ⚠️ substitute (libvirt console) | ✅ **REAL SOL** (RMCP+) | ⚠️ node's libvirt serial |
| **virtual media** | ⛔ n/a | ⛔ n/a | ✅ **InsertMedia** (centerpiece) |
| sensors / fru / sel | ⛔ power+bootdev only | ◐ partial (passthrough) | ◐ partial |

Every backend **declares** its capabilities; `bmc.sh <node> inspect [--json]` prints the
table, and an unsupported verb is **refused loudly with an actionable hint** — never a
silent no-op or a faked success. That honesty *is* the reusable contract: a consumer
queries `inspect --json` and routes on capabilities (e.g. only offer virtual-media deploy
to a node whose backend reports `insert-media: yes`).

> **The `ipmi_sim` "coexist" shape.** OpenIPMI `ipmi_sim` gives us genuine IPMI SOL that
> VirtualBMC can't (VirtualBMC has no `activate_payload`), but its **chassis power control
> returns `0xCC`** in the packaged build — so an `ipmi_sim` node does what it *uniquely*
> can (real SOL) and its **power/bootdev are delegated to a coexisting `vbmcd`**. Two BMCs,
> one node, one `bmc.sh` verb surface. See [POC-A](POC-A-real-sol.md).

## Quick start

```bash
cd examples/bmc-toolkit

./bmc.sh list                     # the fleet + each node's backend + endpoint
./bmc.sh node3 inspect            # what does node3's (redfish) backend faithfully do?
./bmc.sh node3 inspect --json     # machine-readable — what a consumer routes on

# Everything below is HEADLESS + ROOTLESS (qemu:///session, high ports). Run the smokes:
bash tests/run-all.sh             # dispatch + real-SOL + Redfish-vmedia (+ vbmcd, skipped)
```

Driving it by hand (the two marquee capabilities):

```bash
# REAL Serial-over-LAN (ipmi_sim) — see RUNBOOK for wiring a node's serial to serial_tcp
./bmc.sh node2 bmc-up
BMC_SOL_CAPTURE=8 ./bmc.sh node2 sol           # ipmitool -I lanplus … sol activate (real RMCP+)
./bmc.sh node2 bmc-down

# Redfish VIRTUAL MEDIA (sushy-tools) — attach an ISO and boot it, no PXE/DHCP/TFTP
./bmc.sh node3 bmc-up                            # bootstraps the sushy venv on first run
./bmc.sh node3 insert-media /path/to/install.iso
./bmc.sh node3 bootdev cdrom
./bmc.sh node3 power on
./bmc.sh node3 eject-media && ./bmc.sh node3 bmc-down
```

## Files

| File | Role |
|---|---|
| [`bmc.sh`](bmc.sh) | the front door: registry resolution + capability gate + dispatch |
| [`fleet-bmc.toml`](fleet-bmc.toml) | the per-node backend registry (the reusable block's API) |
| [`backends/`](backends/) | `common.sh` (contract) + `vbmcd.sh` / `ipmi_sim.sh` / `redfish.sh` |
| [`nodes/`](nodes/) | `make-session-node.sh` (rootless demo node) + `ipmisim.emu` / `lan.conf.template` |
| [`lib/registry.py`](lib/registry.py) | tiny `fleet-bmc.toml` reader (stdlib `tomllib`) |
| [`make-proof-iso.sh`](make-proof-iso.sh) | build a tiny bootable serial-marker ISO for the tests |
| [`tests/`](tests/) | one-verdict smokes (`run-all.sh`) |
| [`RUNBOOK.md`](RUNBOOK.md) | the by-hand protocol tour + the real-VM-over-SOL combo + gotchas |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | real captured transcripts from each verified path |
| [`POC-A-real-sol.md`](POC-A-real-sol.md) · [`POC-B-redfish-vmedia.md`](POC-B-redfish-vmedia.md) | spike write-ups |
| [`PLAN.md`](PLAN.md) | roadmap pointer ([`BMC_TOOLKIT_LAB_PLAN.md`](../../BMC_TOOLKIT_LAB_PLAN.md)) + outcomes |

## Prereqs
- Host: `ipmi_sim` + `ipmitool` (`openipmi` pkg), `qemu-system-x86_64`, `virsh`, `curl`,
  `genisoimage` + `isolinux`, `python3` (3.11+, for `tomllib`). The `redfish` backend
  bootstraps its own `sushy-tools` venv on first `bmc-up`.
- User in the `kvm` + `libvirt` groups (rootless `qemu:///session`). The `vbmcd` backend
  is **rootful** (`qemu:///system` socket is `root:libvirt`) → its live use is author-run.

## Security posture (AUDIT F1/F7)
- **All endpoints loopback + throwaway creds** (`fleet-bmc.toml`). IPMI/Redfish are weak-
  or-unauthenticated by default — **never** point a backend at a real/networked host.
- **Destructive ops are author-run** (`!`): an installer ISO wipes disks; `vbmcd` power on
  a real domain is rootful. The toolkit itself only *attaches* media (non-destructive).
- **Kill by PID** (pidfiles), never `pkill -f` — `ipmi_sim`/`sushy`/`qemu` share cmdline
  substrings (the serial-socket footgun).

## Sources
- **OpenStack VirtualBMC** — vendored in the sibling [`virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/upstream-tutorial/README.md).
- **OpenIPMI `ipmi_sim` / lanserv**, **sushy-tools** (`sushy-emulator`), and the **DMTF
  Redfish** spec → cite, don't mirror (official docs / upstream code). Pinned:
  `sushy-tools==2.2.0`; `ipmi_sim` 1.0.13 (Debian `openipmi`).
