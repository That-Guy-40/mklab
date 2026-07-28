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

## 3. Headless — inspection, metadata & watch (increment 2, verified 2026-07-25)

### 3a. The inspection chain (probe → metadata service → schedulable facts)

The real probe boots over PXE and POSTs via busybox `wget --post-data`; headless, we
POST exactly what it would and let the rest of the chain run for real.

```console
$ ./metadata-serve.sh                         # the facts sink + NoCloud, on :8282
  maas-metadata listening on http://127.0.0.1:8282 state=…/metal-as-a-service

# the probe POSTs its facts (shown here via urllib; on a node it's busybox wget):
recorded facts for node1

$ ./maas-lab.sh inspect node1 --from-metadata
  - recorded facts the probe POSTed to the metadata service
inspected node1 (cpus=4 mem_mb=8000 mac=52:54:00:aa:bb:01)

$ ./maas-lab.sh show node1 | grep schedulable
schedulable cpus=4 mem_mb=8000 mac=52:54:00:aa:bb:01
```

The probe `/init` itself is unit-tested in `--emit` mode against fixture `/proc`
(`test-inspect-metadata.sh`): `cpus=4, mem_kb=8192000, mac=52:54:00:aa:bb:cc` (it
skips `lo`). `build-probe-initramfs.sh` packs the same `/init` into a bootable
initramfs and `test-probe-build.sh` unpacks it to prove `/init` is the probe and
busybox + its applets are present.

### 3b. Watchable progress (delegates to `tools/control-pane`)

```console
$ ./maas-lab.sh watch node1 --profile probe --console <console>
  - registered 'node1' under the control-pane fleet: …/control-pane/node1/node.toml (profile=probe)
  - watching node1 (profile=probe) via tools/control-pane…
[ 30%] [######--------------] probe: loading probe  | Unpacking initramfs
[ 60%] [############--------] probe: probe up  | MAAS inspection probe: booting
[ 80%] [################----] probe: facts collected  | collected facts cpus=4
[100%] [####################] probe: facts posted (done)  | facts posted (introspection complete)
control-pane: probe reached 'facts posted' (100%) — done
```

`watch` also writes `$LAB_STATE_DIR/control-pane/node1/node.toml` (profile + console
+ MAAS's `milestones.toml`), so the same node appears in the Phase-6 TUI **and**
phase6b-web with a live bar — no MAAS-local TUI code. `control-pane list --json
--fleet <dir>` discovers it. The suite: `tests/run-all.sh` → **6 passed, 0 skipped,
0 failed**.

### 3c. Author-run — the real PXE probe (`inspect --boot`)

`inspect --boot` PXE-boots the probe on a live node; it needs the fleet + the PXE net
+ the metadata service, so it is author-run:

```bash
cd examples/metal-as-a-service
./build-probe-initramfs.sh                       # -> ~/.cache/lab-create/maas/probe-initramfs.cpio.gz
cp ~/.cache/lab-create/maas/probe-initramfs.cpio.gz ~/netboot/initrd.gz   # served on :8181
# ensure the busybox-payload kernel is at ~/netboot/kernel and boot.ipxe cmdline has:
#     maas.node=node1  maas.md=http://<pxe-gw>:8282
./metadata-serve.sh --host 0.0.0.0 --port 8282 & # the facts sink (reachable from the node)
./maas-lab.sh inspect node1 --boot               # bootdev pxe → power on → await facts → power off
./maas-lab.sh show node1 | grep schedulable      # real cpus/mem/mac from the booted node
```

**Expected signature:** the probe console shows `MAAS inspection probe: booting` →
`collected facts cpus=N` → `facts posted (introspection complete)` → the node powers
off, and `inspect --boot` returns with a populated `schedulable` line. A probe that
can't reach the sink prints `FAILED to post facts` and `inspect --boot` times out
(the node would go to `error` on the control plane).

## 4. Headless — health-gated deploy, A/B rollback & the F2 tamper drill (increment 3)

Real installs are author-run (§4b below); the activation logic — verify gate, health
gate, A/B rollback — is exercised headlessly with the **mock driver** (`tests/mock.sh`)
over **real OpenSSL CMS** signatures. `MOCK_HEALTH_<image>=fail` injects a health
failure.

### 4a. A/B rollback (a new image fails its health gate)

```console
$ maas-lab.sh deploy node1 --driver mock --image app-v1        # healthy
  - deploying image 'app-v1' via 'mock' (verify=1, health timeout 3s)…
active node1 (driver=mock image=app-v1, healthy)

$ MOCK_HEALTH_APP_V2=fail maas-lab.sh deploy node1 --driver mock --image app-v2
  - deploying image 'app-v2' via 'mock' (verify=1, health timeout 3s)…
maas: image 'app-v2' failed its health gate (never reached 'active')
maas: rolling back 'node1' to its previous image 'app-v1' (§4b A/B)…
maas: DEGRADED: 'node1' is active on its PREVIOUS image 'app-v1' (new image 'app-v2' was rejected)
active node1 (driver=mock image=app-v1, DEGRADED — rolled back)

$ maas-lab.sh show node1 | grep -E '^(state|image) '
state       active
image       app-v1 (previous: )
```

### 4b. The F2 tamper drill (a tampered image is refused pre-boot)

`app-bad` is correctly signed, then one byte is flipped — so `openssl cms -verify`
fails, and the node **never boots it**, staying on its previous good image (the
required signature, mirroring RAM-INFRA §13):

```console
$ maas-lab.sh deploy node1 --driver mock --image app-bad       # tampered
  - deploying image 'app-bad' via 'mock' (verify=1, health timeout 3s)…
maas: F2 signature verification failed for image 'app-bad'
maas: rolling back 'node1' to its previous image 'app-v1' (§4b A/B)…
active node1 (driver=mock image=app-v1, DEGRADED — rolled back)
```

`test-deploy-rollback.sh` + `test-verify-tamper.sh` assert these paths (plus
both-slots-bad → `error`, no-previous → `error`, and that `--no-verify` bypasses the
gate — proving the gate was the thing that blocked the tampered image). Suite:
`tests/run-all.sh` → **9 passed, 0 skipped, 0 failed**.

### 4c. Author-run — a real `install` deploy

```bash
cd examples/metal-as-a-service
# stage the PXE net + a signed kickstart payload for the image (once):
( cd ../virtualbmc-ipmi-lab && PAYLOAD=almalinux ./setup-pxe-net.sh )
# sign the served kernel/initrd so the F2 gate can verify them:
drivers/verify-lib.sh gen-keys --dir "$MAAS_IMAGES_DIR/trust"
drivers/verify-lib.sh sign ~/netboot/vmlinuz --keydir "$MAAS_IMAGES_DIR/trust"   # etc.
./create-fleet.sh up                             # rootful fleet (increment 1)
./maas-lab.sh deploy node1 --driver install --image almalinux9-ks
```

**Expected signature:** `install` sets `bootdev pxe` → powers on → the kickstart
installs and `poweroff`s → **the driver sees `Chassis Power is off` over IPMI** →
`bootdev disk` → powers on → the health gate polls the node console for `login:` →
node reaches `active`. If the install never produces a login within the timeout, the node rolls
back (or → `error` if there's no previous image) — the same logic §4a proves headless.

---

## 5. The real `install` driver, headless (increment 3a)

Until now the deploy tests all drove `tests/mock.sh`, so `drivers/install.sh` had never
run under test — and hiding in it was a call to **`virsh domstate`** to decide whether
the installer had finished. That is not something a control plane can do to a machine
in a rack, and it was the one call no seam could intercept, which is precisely why the
driver was untested. The installer finishing is now observed the way real metal reports
it: the kickstart ends in `poweroff`, so the node powers **itself** down and
`chassis power status` says so.

```console
$ ./tests/test-install-driver.sh
  - the real drivers/install.sh reaches active: verify -> PXE -> wait -> disk -> login  ✓
  - the driver never touched virsh: every effect went through the BMC seam  ✓
  - sequence: bootdev pxe -> power on -> 3 power polls -> bootdev disk -> power on  ✓
  - installer never finishes -> timeout, no boot-from-disk, node -> error  ✓
  - install completes but no login: -> health gate FAILS -> error (not active)  ✓
  - tampered image: install.sh's own verify refuses it before the BMC is touched at all  ✓
PASS: drivers/install.sh drives real metal through the BMC seam only: no virsh, correct
boot order, the power-off wait and the health gate both load-bearing
```

The test puts a **refusing `virsh` stub** on `PATH`, so the seam leak cannot come back
silently. Both negative controls were run rather than assumed:

```console
# CONTROL A — re-introduce the virsh call
  - LEAKED: virsh -c qemu:///system domstate node1
FAIL: REGRESSION: the install driver called virsh (above). Every out-of-band effect must
go through the MAAS_BMC seam — a driver that talks to the hypervisor cannot run against
real metal, and cannot be tested at all

# CONTROL B — delete the wait for the installer to power off
FAIL: REGRESSION: the driver polled chassis power only 1 time(s) — it is not waiting for
the installer, it is assuming it finished
```

Full suite after the fix:

```console
$ ./tests/run-all.sh
=== summary: 9 passed, 0 skipped, 0 failed ===
```

---

## 6. The `ramdisk` driver — RAM-resident payloads (increment 4)

`deploy --driver ramdisk --image <name>` netboots a kernel + initramfs and runs the
machine entirely in RAM. The payload comes from [`ramdisk-catalog.toml`](ramdisk-catalog.toml),
which routes to the lab that owns it.

```console
$ ./drivers/ramdisk.sh describe
ramdisk: netboot a kernel+initramfs and run entirely in RAM; nothing is written to disk.
images (--image NAME), from .../ramdisk-catalog.toml:
  anycast-dns-ram
  cdn-edge-ram
  package-mirror-ram
  micro-linux-x86_64
  floppinux
  busybox-netboot

$ ./drivers/ramdisk.sh describe micro-linux-x86_64
ramdisk/micro-linux-x86_64: from-source kernel + BusyBox/u-root initramfs, built by micro-linux/mlbuild.sh
  from   micro-linux/   (build: micro-linux/mlbuild.sh all --arch x86_64)
  active = console matches /(login:|~ #)/
```

### 6a. Staging a real payload (host-safe, verified here)

The driver builds nothing. It stages what the owning lab produced, and signs it:

```console
$ ./drivers/ramdisk.sh stage micro-linux-x86_64
verify-lib: signed …/images/micro-linux-x86_64/kernel -> …/kernel.sig
verify-lib: signed …/images/micro-linux-x86_64/initrd -> …/initrd.sig
ramdisk: staged + SIGNED 'micro-linux-x86_64' into …/images/micro-linux-x86_64

$ ./drivers/ramdisk.sh verify micro-linux-x86_64 && echo OK
OK
```

A payload the owning lab has **not** built is refused with that lab's build command —
"file not found" is useless when the fix lives in a different lab:

```console
$ ./drivers/ramdisk.sh stage floppinux
ramdisk: kernel not found: /home/sqs/.cache/lab-create/floppinux/bzImage
ramdisk: initramfs not found: /home/sqs/.cache/lab-create/floppinux/rootfs.cpio.xz
ramdisk: 'floppinux' has not been built. This driver does not build it — examples/tiny-linux-experiments/floppinux/ owns it:
    examples/tiny-linux-experiments/floppinux/build-floppinux.sh build
Then re-run: drivers/ramdisk.sh stage floppinux
```

### 6b. The headless proof

```console
$ ./tests/test-ramdisk-driver.sh
  - the shipped catalog validates: 6 images, each with the fields its health kind needs  ✓
  - an unbuilt payload is refused WITH the lab's own build command  ✓
  - stage copies the lab's artifacts, signs both, and verify passes (real OpenSSL CMS)  ✓
  - a byte flipped in the staged initramfs fails verification  ✓
  - a signed RAM payload reaches active through the same gate install uses  ✓
  - no 'bootdev disk': the node netboots every time, by design  ✓
  - it confirms power-on and stops there (1 poll(s)) — no wait for a poweroff that never comes  ✓
  - per-node iPXE script: staged kernel+initrd, the catalog's cmdline, and imgverify on both  ✓
  - the node records persistence=none: nothing was written, so there is nothing to wipe  ✓
  - payload boots but never prints its marker -> health gate FAILS -> error  ✓
  - REAL: 'micro-linux-x86_64' staged + signed + verified (13M kernel, 1.2M initramfs)
  - 1 of 6 catalog entries are built here and stage for real; not built: anycast-dns-ram …
PASS: the ramdisk driver netboots a signed payload into RAM: no bootdev disk, no wait for
a poweroff that never comes, persistence=none, and the same verify+health gate as install
```

The two assertions that carry the increment are the ones separating a RAM deploy from a
disk install, and both negative controls were **run, not assumed**:

```console
# CONTROL A — make the driver switch to boot-from-disk at the end, like install does
FAIL: REGRESSION: the ramdisk driver set 'bootdev disk'. A RAM node must netboot on EVERY
boot — pointed at its disk it would silently boot whatever a previous tenant left there,
with no error anywhere

# CONTROL B — make it wait for a poweroff, like install does
FAIL: REGRESSION: the ramdisk driver polled chassis power 7 times — it is waiting for a
power-off that a RAM-resident node never performs; that wait would time out and roll back
a healthy node
```

### 6c. Author-run — an actual RAM boot

```bash
cd examples/metal-as-a-service
export MAAS_IMAGES_DIR=~/.cache/lab-create/maas/images
drivers/verify-lib.sh gen-keys --dir "$MAAS_IMAGES_DIR/trust"
drivers/ramdisk.sh stage micro-linux-x86_64      # copies + signs
./create-fleet.sh up                             # rootful fleet
# serve $MAAS_NETBOOT_DIR/maas/ from the PXE HTTP endpoint (:8181), then:
./maas-lab.sh deploy node1 --driver ramdisk --image micro-linux-x86_64
```

**Expected signature:** the driver writes `~/netboot/maas/node1.ipxe` (kernel + initrd +
`imgverify` on both), sets `bootdev pxe`, powers on, confirms the chassis is up — and
**stops there**. No `bootdev disk`, no wait for a power-off. The health gate then watches
the console for the catalog entry's marker; each payload's boot signature is the one its
own lab documents. `maas-lab.sh show node1` reports `persistence=none`.

---

## 7. Chaos — how gracefully does it fall? (increment 4a)

`chaos-run.sh` injects a fault at each point a deploy can break and grades where the
node lands. **Fallback and a graceful halt are the acceptable intermediate rungs; the
goal is that a fault never becomes a failure at all.** A run passes at zero criticals.

```console
$ ./chaos-run.sh

  VERDICT    SCENARIO                  OUTCOME
  ---------  ------------------------  -------
  ABSORBED   none (control)            deployed "good-v2" and it is healthy
  ABSORBED   verify-fail (had good)    still active on "good-v1"; "bad-v2" was refused before it was deployed
  HALTED     verify-fail (fresh)       stopped in "error" — retry/abort can pick it up
  DEGRADED   deploy-fail (had good)    fell back to "good-v1" after "bad-v2" was deployed and failed
  DEGRADED   deploy-crash (had good)   fell back to "good-v1" after "bad-v2" was deployed and failed
  HALTED     deploy-crash (fresh)      stopped in "error" — retry/abort can pick it up
  DEGRADED   partial (had good)        fell back to "good-v1" after "bad-v2" was deployed and failed
  DEGRADED   health-fail (had good)    fell back to "good-v1" after "bad-v2" was deployed and failed
  HALTED     health-fail (fresh)       stopped in "error" — retry/abort can pick it up
  HALTED     health-flap (had good)    passed its gate then died; `recheck` caught it and demoted it to "error"
  HALTED     bmc-drop (had good)       stopped in "error" — retry/abort can pick it up
  HALTED     control-plane-killed      was stuck mid-deploying; `abort` recovered it to "error", then `retry`

  12 scenarios: 2 absorbed (goal), 4 degraded, 6 halted honestly, 0 CRITICAL
PASS: no injected fault became a critical failure — every one was absorbed, fell back to
a good image, or halted honestly with a verb that can recover it
```

### 7a. What the first run actually looked like

The matrix did **not** pass the first time. It found two critical outcomes, both real:

```console
  STALE      health-flap (had good)    active on "bad-v2" — true at the gate, unhealthy now, nothing re-checks
  STRANDED   control-plane-killed      stuck in transient state "deploying"; no verb accepts it

  11 scenarios: … 2 CRITICAL
FAIL: 2 of 11 injected faults became a CRITICAL failure
```

- **STRANDED** — killing `maas-lab.sh` mid-deploy left the node in `deploying`, which no
  verb accepted. `maintenance` accepted any state and looked like an escape, but
  `unmaintenance` restored `prior_state` and handed the node **straight back into
  `deploying`**. Fixed with **`abort`** (transient → `error`, with a reason, where
  `retry` works) and by making `unmaintenance` refuse to restore a transient state.
- **STALE** — a node that passed its activation gate and then died kept reporting
  `active`, because the gate is a one-time question and nothing asked again. Fixed with
  **`recheck`**, which re-runs the current driver's health against the current image and
  demotes a node that no longer passes.

### 7b. The negative controls

Both fixes were removed and the matrix re-run, so the report is known to depend on them:

```console
# CONTROL A — remove `abort`
  STRANDED   control-plane-killed      stuck in transient state "deploying"; no verb accepts it
FAIL: 1 of 12 injected faults became a CRITICAL failure

# CONTROL B — remove `recheck`
  STALE      health-flap (had good)    active on "bad-v2" — true at the gate, unhealthy now, nothing re-checks
FAIL: 1 of 12 injected faults became a CRITICAL failure
```

`tests/test-chaos-matrix.sh` additionally refuses to accept "zero criticals" on its own:
it requires all three acceptable rungs to be **occupied**, because a matrix that never
broke anything is all-ABSORBED, one that breaks everything unrecoverably is all-HALTED,
and one where the A/B path is dead never reaches DEGRADED.
