# MANUAL_TESTING — verified transcripts

All captured on the dev host (AlmaLinux kernel for the proof ISO, `ipmi_sim` 1.0.13,
`sushy-tools` 2.2.0), **headless & rootless**. Reproduce with `bash tests/run-all.sh`.

## Success signature (the whole suite)

```
=== test-dispatch.sh ===        PASS: bmc.sh dispatch + capability model behave …
=== test-ipmi_sim-sol.sh ===    PASS: real IPMI SOL over RMCP+ streamed the node serial … (8 marker lines)
=== test-redfish-vmedia.sh ===  PASS: Redfish InsertMedia attached the ISO and the node BOOTED it … — no PXE/DHCP/TFTP
=== test-vbmcd.sh ===           SKIP: no vbmc BMC on 127.0.0.1:6230 … (rootful; author-run)
==== summary: 3 passed, 1 skipped, 0 failed ====
```

## 1. Dispatch + capability model (`test-dispatch.sh`)

```
  - list shows vbmcd + ipmi_sim + redfish
  - redfish inspect --json advertises insert-media=yes (the vmedia capability)
  - vbmcd refuses insert-media loudly + hints at a redfish-backed node
  - ipmi_sim refuses power + hints coexist (real SOL here, power on vbmcd)
  - vbmcd sol flags itself a substitute (no IPMI SOL) and prints the console command
PASS: bmc.sh dispatch + capability model behave (list, inspect, loud refusal, substitute caveat)
```

The refusals, verbatim:

```
$ ./bmc.sh node1 insert-media foo.iso
bmc: backend 'vbmcd' does not implement 'insert-media' (virtual media is Redfish-only — use a redfish-backed node)

$ ./bmc.sh node2 power on
bmc: backend 'ipmi_sim' does not implement 'power' (ipmi_sim chassis-control is 0xCC in this build; drive power via a coexisting vbmcd backend (see README: coexist))
```

## 2. Real IPMI Serial-over-LAN (`test-ipmi_sim-sol.sh`)

```
  - start the node's serial source (TCP-LISTEN:9101 -> repeating marker)
  - bmc.sh node2 bmc-up (ipmi_sim; SOL bridges tcp:127.0.0.1:9101)
  - ipmi_sim up: RMCP+ 127.0.0.1:9001  SOL<-tcp:127.0.0.1:9101
  - sanity: RMCP+ session works (raw lanplus chassis status via ipmitool)
  - REAL SOL: bmc.sh node2 sol (capture mode), expect the marker to stream
PASS: real IPMI SOL over RMCP+ streamed the node serial via 'ipmitool -I lanplus sol activate' (8 marker lines)
```

Raw `sol activate` output (the session goes operational, then serial streams):

```
tcgetattr: Inappropriate ioctl for device
[SOL Session operational.  Use ~? for help]
[BMC_TOOLKIT_SOL_TEST_…] node serial tick
[BMC_TOOLKIT_SOL_TEST_…] node serial tick
… (8 lines) …
```

## 3. Redfish virtual media boot (`test-redfish-vmedia.sh`)

```
  - build a bootable proof ISO (marker in kernel cmdline)
  - define the blank session node (BIOS, serial->file, sushy adds the cdrom)
  - bmc.sh node3 bmc-up (bootstraps sushy venv on first run — may take a minute)
  - sushy-emulator up: http://127.0.0.1:8000 (libvirt qemu:///session)
  - InsertMedia + boot=cdrom + power on, all via the Redfish backend
inserted: http://127.0.0.1:8899/proof.iso
boot override -> Cd (once)
On
  - wait for the node to boot the virtual media (marker on serial)
  - eject-media cleans up
PASS: Redfish InsertMedia attached the ISO and the node BOOTED it over virtual media — no PXE/DHCP/TFTP
```

Control-plane + boot proofs in one run — the domain XML gains the virtual CD, and the
node's serial shows the kernel that came off it:

```
$ virsh -c qemu:///session dumpxml bmc-vmedia-node | grep -A2 "device='cdrom'"
      <disk type='file' device='cdrom'>
        <driver name='qemu' type='raw'/>
        <source file='…/state/node3/pool/proof-iso-<uuid>.img'/>

# node serial:
  [    0.000000] Command line: BOOT_IMAGE=/vmlinuz console=ttyS0,115200 BMC_TOOLKIT_VMEDIA_TEST_<pid>
```

## 4. vbmcd power (`test-vbmcd.sh`) — author-run, **verified live 2026-07-25**

SKIPs unless a rootful vbmc BMC is already up (it's `qemu:///system`, `root:libvirt`).
To run it live: `cd ../virtualbmc-ipmi-lab && ./vbmc-lab.sh build && ./vbmc-lab.sh up &&
./vbmc-lab.sh add`, then `bash tests/test-vbmcd.sh`.

Verified end-to-end on KVM — the BMC came up (`alpine-node` on `127.0.0.1:6230`) and the
test flipped **SKIP → PASS**:

```
### bmc-toolkit test-vbmcd (with the BMC live) ###
  - vbmc BMC is live on 127.0.0.1:6230 — exercising the vbmcd backend via bmc.sh
  - power status: Chassis Power is off
PASS: vbmcd backend round-trips IPMI power via bmc.sh (chassis power status)
```

Then a full power round-trip driven **through `bmc.sh`** (real IPMI-over-LAN → vbmcd →
`virsh start`/`destroy` a `qemu:///system` domain):

```
$ ./bmc.sh node1 bootdev pxe     → Set Boot Device to pxe
$ ./bmc.sh node1 power on        → Chassis Power Control: Up/On
$ ./bmc.sh node1 power status    → Chassis Power is on
$ ./bmc.sh node1 power off       → Chassis Power Control: Down/Off
$ ./bmc.sh node1 power status    → Chassis Power is off
```

## Teardown / clean state

Each test tears down its own daemons (by recorded PID) and session domains/pools
(`virsh destroy/undefine`, `pool-destroy/undefine`). Verify clean:

```bash
virsh -c qemu:///session list --all      # no bmc-* domains
virsh -c qemu:///session pool-list --all # no 'default' pool left behind
pgrep -af 'sushy-emulator|ipmi_sim'      # nothing (kill by PID if a run was interrupted)
```
