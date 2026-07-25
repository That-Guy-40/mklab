# metal-as-a-service — manual testing

Real transcripts, warts and all. Increment 1 is **headless** (mock BMC, throwaway
state dir), so §1 reproduces anywhere with `bash` + `python3`. §2 is the
**author-run** rootful fleet bring-up (needs sudo/libvirt/podman) — the command and
its expected signature, handed over.

## 1. Headless — the full state machine (verified 2026-07-25)

### 1a. The smoke suite

```console
$ bash examples/metal-as-a-service/tests/run-all.sh

=== test-state-machine.sh ===
  - enroll -> enrolled ✓
  - double-enroll refused ✓
  - deploy refused from enrolled ✓
  - manage -> manageable, called BMC power status ✓
  - history records the verifying saga ✓
  - inspect -> facts recorded, still manageable ✓
  - provide -> available (through cleaning) ✓
  - deploy refused unknown driver ✓
  - deploy -> active (driver+image recorded) ✓
  - rescue <-> unrescue ✓
  - release -> available, slots cleared ✓
  - maintenance -> back to available (prior state restored) ✓
  - verify failure -> error ✓
  - retry: error -> manageable once the BMC answers ✓
PASS: full Ironic state machine: happy path + illegal-transition refusals + error/retry (headless)

=== test-cleaning-guard.sh ===
  - provide halted in 'cleaning' (did not auto-advance) ✓
  - wipe command handed to operator (blkdiscard/dd) ✓
  - disk canary intact — no destructive verb ran ✓
  - provide --wiped -> available ✓
  - out-of-allow-list disk refused ✓
PASS: cleaning is guarded: no auto-wipe, command handed over, data survives, allow-list enforced

=== test-registry.sh ===
  - atomic state write, no temp litter ✓
  - history log shape + ordering ✓
  - generated registry parses via bmc-toolkit registry.py ✓
  - list --json valid ✓
PASS: registry: atomic writes, history shape, generated bmc registry parses, list --json valid

=== summary: 3 passed, 0 skipped, 0 failed ===
```

### 1b. Drive one node end-to-end + the history saga

```console
$ cd examples/metal-as-a-service
$ export MAAS_STATE="$(mktemp -d)/maas"  MAAS_BMC="$PWD/tests/mock-bmc.sh"

$ ./create-fleet.sh enroll
enrolled node1 (domain=node1 bmc=127.0.0.1:6230 firmware=bios)
enrolled node2 (domain=node2 bmc=127.0.0.1:6231 firmware=bios)
enrolled node3 (domain=node3 bmc=127.0.0.1:6232 firmware=bios)
==> fleet enrolled; generated BMC registry: 3 nodes
NODE       STATE        DRIVER     DOMAIN
node1      enrolled     -          node1
node2      enrolled     -          node2
node3      enrolled     -          node3

$ ./maas-lab.sh manage node1 && ./maas-lab.sh inspect node1 \
    && ./maas-lab.sh provide node1 \
    && ./maas-lab.sh deploy node1 --driver ramdisk --image busybox-netboot
manageable node1 (BMC creds verified)
  - no --facts given; wrote a pending placeholder (real inspection probe = build step 2)
  - cleaning 'node1': no backing disk registered — wipe is a no-op (ramdisk-style node)
available node1 (cleaned; schedulable)
  - driver=ramdisk image=busybox-netboot — STATE-ONLY in increment 1
  - real boot + health-gated activation (§4b) lands in build step 3
active node1 (driver=ramdisk image=busybox-netboot)

$ ./maas-lab.sh show node1
node        node1
state       active
domain      node1
bmc         127.0.0.1:6230 (admin/password)
firmware    bios
driver      ramdisk
image       busybox-netboot (previous: -)
facts       {"status":"pending","note":"real RAM probe lands in build step 2"}
history:
  2026-07-25T…Z  <new>       -> enrolled    (enroll)
  2026-07-25T…Z  enrolled    -> verifying   (manage)
  2026-07-25T…Z  verifying   -> manageable  (manage)
  2026-07-25T…Z  manageable  -> manageable  (inspect)
  2026-07-25T…Z  manageable  -> cleaning    (provide)
  2026-07-25T…Z  cleaning    -> available   (provide)
  2026-07-25T…Z  available   -> deploying   (deploy)
  2026-07-25T…Z  deploying   -> active      (deploy)
```

The **transient states are recorded** (`verifying`, `cleaning`, `deploying`) — the
saga is observable, which is exactly what `tools/control-pane` will render as live
progress once increment 2 wires the console milestones.

### 1c. The generated bmc-toolkit registry

`enroll` regenerates `$MAAS_STATE/fleet-bmc.toml` — a real bmc-toolkit registry the
control plane calls `bmc.sh` against:

```toml
[[node]]
name      = "node1"
backend   = "vbmcd"
domain    = "node1"
uri       = "qemu:///system"
ipmi_host = "127.0.0.1"
ipmi_port = 6230
ipmi_user = "admin"
ipmi_pass = "password"
# … node2 (6231), node3 (6232) …
```

`test-registry.sh` asserts bmc-toolkit's own `registry.py` parses it and resolves
`NODE_IPMI_PORT=6231` for node2 — so the seam is wired to the real tool, not a lookalike.

## 2. Author-run — the real fleet (rootful; NOT run here)

`create-fleet.sh up` wraps `virtualbmc-ipmi-lab/` and needs `sudo` +
`qemu:///system` + rootful `podman`, which this agent environment can't provide.
Hand-run and paste back:

```bash
cd examples/metal-as-a-service
export MAAS_STATE="$HOME/.local/state/lab-create/metal-as-a-service"

# stand up 3 libvirt domains + one vbmcd container with BMCs on 6230–6232, then enroll:
./create-fleet.sh up

# real IPMI round-trip through the control plane (bmc.sh → ipmitool → libvirt):
./maas-lab.sh manage node1        # expect: "manageable node1 (BMC creds verified)"
./maas-lab.sh power  node1 status # expect: "Chassis Power is off"  (or on)
./maas-lab.sh bootdev node1 pxe   # expect: "Set Boot Device to pxe"
./maas-lab.sh list

# tear down (prints the sudo rm for the disk images — F7, run those yourself):
./create-fleet.sh down
```

**Expected signature:** `manage` reaches `manageable` only if the BMC answers
`chassis power status`; a domain whose `vbmcd` isn't up sends the node to `error`
(and `maas-lab.sh show node1` shows the `verifying -> error` transition) — the same
unhappy path the headless `MOCK_BMC_FAIL=power` test proves in §1a.

> Ordering gotcha carried from the vbmc lab: for the PXE-install driver (increment
> 3), bring the `vbmc-pxe` network up **before** defining domains, or you hit the
> orphaned-tap empty-leases trap (see `virtualbmc-ipmi-lab/MANUAL_TESTING.md`).
