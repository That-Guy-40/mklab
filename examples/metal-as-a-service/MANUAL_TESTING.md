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
export MAAS_IMAGES_DIR="$(./maas-lab.sh _images-dir)"   # the store's one owner answers
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

---

## 8. The `image` driver + chaos as a house rule (increment 5)

```console
$ ./drivers/image.sh describe
image: a deployer ramdisk dd's a golden whole-disk image onto the node, then it boots
from disk; active = the deployed image's login. DESTRUCTIVE: the whole disk is overwritten

$ ./tests/test-image-driver.sh
  - an absent golden image is refused, naming the lab that produces one  ✓
  - stage copies + signs the raw; verify passes (real OpenSSL CMS)  ✓
  - the real drivers/image.sh reaches active: verify -> PXE -> write -> disk -> login  ✓
  - the driver never touched virsh: every effect went through the BMC seam  ✓
  - sequence: bootdev pxe -> power on -> write -> bootdev disk -> power cycle  ✓
  - records persistence=full: the whole disk was overwritten, so cleaning is mandatory  ✓
  - write never completes -> timeout, no boot-from-disk, node -> error  ✓
  - image written but it never boots -> health gate FAILS -> error (not active)  ✓
  - tampered golden image: refused before the BMC is touched at all  ✓
PASS: the image driver lays a golden disk down safely: verified before any hardware,
never points a node at a half-written disk, ends on bootdev disk, and records persistence=full
```

Negative controls, run:

```console
# skip the wait for the write to finish
FAIL: REGRESSION: the driver pointed a node at a HALF-WRITTEN disk…
# never point the node at its disk (behave like the ramdisk driver)
FAIL: REGRESSION: the node was never pointed at its own disk. Unlike a ramdisk node, an
imaged node OWNS its disk now — left on PXE it would re-image itself on every boot, forever
```

### 8a. Chaos across all five layers

```console
$ ./chaos-run.sh
  VERDICT    LAYER     SCENARIO                  OUTCOME
  ABSORBED   driver    none (control)            deployed "good-v2" and it is healthy
  ABSORBED   driver    verify-fail (had good)    still active on "good-v1"; "bad-v2" was refused before it was deployed
  HALTED     driver    verify-fail (fresh)       stopped in "error" — retry/abort can pick it up
  DEGRADED   driver    deploy-fail (had good)    fell back to "good-v1" after "bad-v2" was deployed and failed
  DEGRADED   driver    deploy-crash (had good)   fell back to "good-v1" after "bad-v2" was deployed and failed
  HALTED     driver    deploy-crash (fresh)      stopped in "error" — retry/abort can pick it up
  DEGRADED   driver    partial (had good)        fell back to "good-v1" after "bad-v2" was deployed and failed
  DEGRADED   driver    health-fail (had good)    fell back to "good-v1" after "bad-v2" was deployed and failed
  HALTED     driver    health-fail (fresh)       stopped in "error" — retry/abort can pick it up
  HALTED     driver    health-flap (had good)    passed its gate then died; `recheck` caught it and demoted it to "error"
  ABSORBED   artifact  artifact-gone (had good)  still active on "good-v1"; "bad-v2" was refused before it was deployed
  ABSORBED   registry  registry-readonly         still active on "good-v1"; "bad-v2" was refused before it was deployed
  HALTED     oob       bmc-drop (had good)       stopped in "error" — retry/abort can pick it up
  HALTED     process   control-plane-killed      was stuck mid-deploying; `abort` recovered it to "error", then `retry`

  14 scenarios across 5 layers (driver oob artifact registry process): 4 absorbed (goal),
  4 degraded, 6 halted honestly, 0 CRITICAL
PASS: no injected fault became a critical failure
```

### 8b. What the registry layer found

The worst shape yet — worse than a stranded node, because it **reports success**:

```console
$ ./maas-lab.sh deploy n1 --driver chaos --image bad-v2   # $MAAS_STATE/n1 read-only
./maas-lab.sh: line 78: …/.state.tmp: Permission denied
active n1 (driver=chaos image=bad-v2, healthy)
$ echo $?
0
$ cat $MAAS_STATE/n1/image
good-v1                                     # the registry never changed
$ grep '^deploy n1' chaos-calls.log | tail -1
deploy n1 bad-v2 current                    # the machine really got bad-v2
```

`_write` was a bare `printf > tmp && mv` whose exit status nobody read. Fixed — it now
`die`s with a specific message, because an *unrecorded* change is worse than a *refused*
one. The grader was fixed too: it had graded this `DEGRADED` because it only read the
registry, and now compares the registry against what the driver actually deployed.

### 8c. The house rule, enforced

`tests/test-chaos-matrix.sh` fails **by name** when coverage is missing:

```console
# declare a sixth layer with no scenario
FAIL: REGRESSION: layer 'metadata' is declared but has NO chaos scenario…
# add a driver with no real-driver test
FAIL: REGRESSION: deploy driver(s) with no real-driver test: image…
```

---

## 9. `apply` — reconcile to a declared end-state (increment 6)

```console
$ ./maas-lab.sh apply fleet.toml --dry-run
  pass 1
  NODE      CURRENT                     ACTION   WHY
  --------  --------------------------  -------- ---
  n1        <not enrolled>              enroll   declared in the spec, absent from the registry
  n2        <not enrolled>              enroll   declared in the spec, absent from the registry

  DRY RUN: 2 transition(s) would be issued, 0 converged, 0 held

$ ./maas-lab.sh apply fleet.toml
  …
  applied: 8 transition(s) over 5 pass(es), 0 failed, 2 converged, 0 held for the operator

$ ./maas-lab.sh apply fleet.toml          # ← the invariant
  pass 1
  NODE      CURRENT                     ACTION   WHY
  n1        active (mock/v1)            -        converged
  n2        active (mock/v1)            -        converged

  applied: 0 transition(s) over 1 pass(es), 0 failed, 2 converged, 0 held for the operator
```

A pass moves each node one transition, so `apply` loops until a pass issues nothing —
bounded by `MAAS_APPLY_MAX_PASSES`, because a loop that never terminates hides a stall
instead of reporting it.

### 9a. It does not trust the registry

This is the point of the increment. `apply` computes from the record, and §8b showed
the record can diverge from the machine. So every node claiming `active` is re-checked
against its driver's own health signal **before** the diff:

```console
$ MOCK_HEALTH_V2=fail ./maas-lab.sh apply fleet.toml
maas: apply: 'n1' claimed active but failed its health re-check — demoted before the diff
  …
  n1        error                       !        HELD in 'error' — apply does not touch it
```

The control that proves the pre-flight is load-bearing:

```console
$ MOCK_HEALTH_V1=fail ./maas-lab.sh apply fleet.toml --no-recheck
maas: apply: --no-recheck — the diff is computed from the REGISTRY ALONE. A node
recorded as active but actually dead will satisfy its desired state and this run will
report convergence over a fleet that is not serving.
  n1        active (mock/v1)            -        converged      ← the fleet is dead
```

And the same thing seen from the chaos matrix, which now covers the reconcile loop as
a layer of its own:

```console
  HALTED     reconcile  apply-over-dead-node  apply's pre-flight health re-check caught it before diffing
# with --no-recheck:
  STALE      reconcile  apply-over-dead-node  apply reported convergence over a node whose payload is dead
```

### 9b. All eight layers

```console
$ ./chaos-run.sh
  …
  ABSORBED   metadata   facts-sink-empty          refused; node stayed manageable with no invented facts
  ABSORBED   console    console-missing           watch refused and named the missing console
  HALTED     reconcile  apply-over-dead-node      apply's pre-flight health re-check caught it before diffing

  17 scenarios across 8 layers (driver oob artifact registry process metadata console
  reconcile): 6 absorbed (goal), 4 degraded, 7 halted honestly, 0 CRITICAL
```

The last three layers were **declared uncovered** in increment 5 rather than left
implicit, so this increment began with its fault work already named.

---

## 10. The actions panel (increment 7) — **v1 complete**

The `ui` layer was declared in `chaos-run.sh` **before the panel was written**, so the
house-rule guard failed until it was covered:

```console
$ ./tests/test-chaos-matrix.sh
FAIL: REGRESSION: layer 'ui' is declared but has NO chaos scenario. The house rule is
that every discrete layer gets a fault-injection point — an uncovered layer is one
nobody has watched fall over. Add a scenario for it in chaos-run.sh
```

### 10a. MAAS declares its verbs; the panel runs them

```console
$ ./maas-lab.sh watch n1 --register-only
$ ../../tools/control-pane actions n1 --fleet "$LAB_STATE_DIR/control-pane"
  a  R   Reconcile (apply)
       …/maas-lab.sh apply
  h      Re-check health
       …/maas-lab.sh recheck n1
  i      Show node
       …/maas-lab.sh show n1
  b      Abort (unstick a transition)
       …/maas-lab.sh abort n1
  R   !  Release (wipes + returns to the pool)
       …/maas-lab.sh release n1
```

`R` = reconciling (safe to press twice), `!` = destructive (needs `--yes`). The control
pane does not know what any of these mean — **MAAS owns the argv**.

An undeclared verb is refused, and nothing runs:

```console
$ ../../tools/control-pane run n1 destroy-everything --fleet …
control-pane: 'n1' declares no action 'destroy-everything' (has: a=Reconcile (apply), …)
```

### 10b. The invariant, asserted rather than promised

```console
  - every panel action is literally 'maas-lab.sh …', and the first one reconciles  ✓
```

Every declared action's `argv[0]` must be `maas-lab.sh`. Delete Phase 6 and every one
of those commands still works in a shell, because they *are* the shell commands.

### 10c. Nine layers

```console
$ ./chaos-run.sh
  …
  ABSORBED   ui         stale-row   declared verbs only, safe to repeat, and a stale
                                    press hit the verb's own precondition

  18 scenarios across 9 layers (driver oob artifact registry process metadata console
  reconcile ui): 7 absorbed (goal), 4 degraded, 7 halted honestly, 0 CRITICAL
```

Negative control — let `control-pane run` execute a verb nobody declared:

```console
  LIED       ui         undeclared-verb   the panel ran a command its owner never declared
FAIL: 1 of 18 injected faults became a CRITICAL failure
```

Suites: `tests/run-all.sh` → **13 passed**; `tools/tests/test-actions.sh` → PASS;
**phase6-tui 111 pytest passed** (CI-gated).

---

## 11. The three fast-follows (2026-07-28)

```console
$ ./tests/run-all.sh
=== summary: 15 passed, 0 skipped, 0 failed ===
```

### 11a. `image+measured` — the attested activation gate

```console
$ ./tests/test-image-measured-driver.sh
  - an image with no expected-PCR policy is refused at verify, not silently unmeasured  ✓
  - signed quote matching the policy -> active  ✓
  - booted but attested nothing -> refused (an unmeasured node never activates)  ✓
  - unsigned quote refused, even with the right PCR values  ✓
  - quote signed by an untrusted key refused (the AK is pinned to the trust root)  ✓
  - valid signature, wrong PCR 11 -> refused, naming the divergent register  ✓
  - a quote that omits a required PCR is refused — silence is not a measurement  ✓
PASS: image+measured activates only on a signed, trusted, matching attestation
```

Negative control — drop the attestation step and keep only the plain image health:

```console
FAIL: REGRESSION: a node that produced NO attestation quote was activated — the gate is
not running
```

⚠️ **swtpm is faithful plumbing, not a trust anchor.** This proves the mechanism and the
refusal path, not the integrity of any machine.

### 11b. Region wiring + the scheduler

```console
$ ./tests/test-region-and-scheduler.sh
  - serving but never announced -> refused (region membership is not local health)  ✓
  - serving AND announced -> active, region recorded  ✓
  - no --region: local health is enough — the region gate is selective, not blanket  ✓
  - an image with no region_check cannot be deployed into a region  ✓
  - picks only nodes whose inspected facts satisfy the claim; skips the small one and
    the uninspected one  ✓
  - fills the claim with exactly 2, and the second run reports it satisfied  ✓
  - a claim nothing can satisfy is reported, not silently ignored  ✓
PASS: region membership is proven before a RAM node counts as active, and apply
schedules claims by inspected facts — never onto a node nobody looked at
```

**The scheduler bug this test found:** the first version counted any active node running
the claim's driver+image as satisfying it, so two claims wanting the same image with
different constraints would consume each other's nodes while **both** reported
satisfied. Ownership is now recorded on the node (`claim = <name>`), not inferred.

## The one-shot live driver — `run-e2e.sh` (author-run)

Ten phases, all sudo front-loaded. Read the plan first; it touches nothing:

```bash
cd examples/metal-as-a-service
./run-e2e.sh --dry-run          # prints all 10 phases, needs no sudo
sudo -v && ./run-e2e.sh         # the real run — never stops to ask mid-boot
./run-e2e.sh --down             # tear the fleet down
```

**On firmware that cannot verify signatures** (QEMU's stock iPXE ROM — the default for
a libvirt virtio NIC — has no `IMAGE_TRUST_CMD`), the run refuses before the deploy
rather than booting into a silence. One flag runs everything with the **on-node** half
of F2 skipped:

```bash
E2E_NO_IMGVERIFY=1 ./run-e2e.sh      # E2E_UNSIGNED is the old name, still accepted
```

**Only that half is skipped.** The payload is still signed and the host-side F2 gate
still gates the deploy — the boot script simply omits the `imgverify` line, and says in
a comment that it did. **Do not try to skip it by removing the signatures** (an early
version of this flag did): both halves read the same `.sig` files, so deleting them
fails the *host-side* gate first and the node goes to `error` without ever booting:

```
maas: F2 signature verification failed for image 'micro-linux-x86_64'
maas: ... and no previous image to roll back to — node 'node1' -> error
```

`drivers/ramdisk.sh stage <image> --unsigned` still exists and does exactly that, on
purpose: it is how you exercise the gate **refusing** an unsigned payload.

**Re-running is expected, and the registry is what carries over.** `--down` tears down
the *fleet*; it does not forget the nodes. So a second run finds `node1` already at
`manageable` (or further), and phase 4 skips `manage` rather than attempting a transition
the control plane would refuse. That is correct — the state machine is being obeyed, not
worked around. To genuinely start over, tear down **and** clear the registry:

```bash
./run-e2e.sh --down
./maas-lab.sh show node1            # prints the state the next run will start from
# then, to forget it entirely — run the delete yourself:
#   rm -rf "${MAAS_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/lab-create/metal-as-a-service}"
```

**Success signature:**

```
PASS: end-to-end on real domains — BMC round-trip, probe-reported facts, a SIGNED
payload netbooted into RAM, and apply converged. node1 is active.
```

### If it fails, look here first — in this order

The failures this path produces all *look* like a timeout, and they are not the same
thing. The log is `e2e-run.log`; the node's console is now recorded, so use it.

```bash
./maas-lab.sh show node1                       # console line: bytes, "empty", or "ABSENT"
tail -40 /var/lib/libvirt/maas-console/node1.log
```

| what the console shows | what it means | fix |
|---|---|---|
| `MAAS: no boot script for this node` | the chain is installed and the control plane wrote nothing for this node | run the verb the message names (`inspect --boot` / `deploy`), then power-cycle |
| a busybox shell, or an installer you did not ask for | the PXE network is still serving its single baked payload | `./netboot-chain.sh install` |
| nothing at all (`empty`) | the domain's console is not being written | re-run `./create-fleet.sh up`; check `virsh dumpxml node1` shows `<serial type='file'>` |
| `console ... (ABSENT)` | no console was recorded for the node | `./maas-lab.sh set-console node1 <path>` |
| the probe boots and prints `maas-probe` but no facts arrive | it cannot reach the sink | `metadata-serve.sh` must bind the **PXE gateway** address, not localhost |

**Before any of that, check the console is empty for the reason you think.** If the node
never powered on at all, `create-fleet.sh up` will now have refused — but if you brought
the fleet up some other way, look for a BMC port collision:

```bash
( cd ../virtualbmc-ipmi-lab && sudo ./vbmc-lab.sh list )
```

Two rows on one port (one `running`, one `error`) means the running one answers IPMI for
both. The sibling lab's `alpine-node` defaults to **6230**, which is `node1`'s port:

```bash
( cd ../virtualbmc-ipmi-lab && sudo ./vbmc-lab.sh destroy )   # frees 6230
```

Every command against the wrong BMC *succeeds*, so nothing upstream will look wrong.

**The console file: verified working (2026-07-28).** It lives at
`/var/lib/libvirt/maas-console/<node>.log`, pre-created `0666` so qemu (running as
`libvirt-qemu`) can write it and the unprivileged control plane can read it. libvirt's
AppArmor helper **does** grant qemu that path on this host — a real boot of `node1`
produced 30 KB of kernel log within seconds. `FLEET_CONSOLE=pty ./create-fleet.sh up`
still restores the old (unlogged) behaviour if you need an interactive `virsh console`,
at the cost of every health gate that reads the log.

---

## 12. The verifying NIC ROM — the on-node half of F2, executed (2026-07-28)

Everything above verifies payloads the way the **control plane** does. This section is the
other half: the **machine** verifying, with the control plane out of the picture. It runs
headlessly under QEMU — no fleet, no sudo, no libvirt.

### 12.1 Build it

```bash
./build-verifying-rom.sh build      # docker, ~10 min
# → /home/…/.cache/lab-create/maas/ipxe/ipxe-8086100e.rom (94720 bytes)
./build-verifying-rom.sh install    # sudo: copies to /var/lib/libvirt/maas-rom/
```

`build-verifying-rom.sh show` prints what is built/installed and the XML that attaches it.
The ROM carries `IMAGE_TRUST_CMD`, `TRUST=` this fleet's CA (converted to DER from
`images/trust/ca.crt`), `CONSOLE_SERIAL`, and `netboot-chain.sh emit-chain` compiled in as
its boot script — so the firmware resolves `maas/${hostname}.ipxe` itself.

### 12.2 The instrument, measured both ways

libvirt's own QEMU invocation is `-display none`, **not** `-nographic`. That distinction
decides the answer, so both were measured:

```bash
qemu-system-x86_64 -m 512 -display none -device e1000,romfile=$ROM,netdev=n0 \
    -netdev user,id=n0,net=10.9.9.0/24 -boot n -serial file:out.log
```

| ROM | bytes in `out.log` |
|---|---|
| `/usr/lib/ipxe/qemu/pxe-e1000.rom` (stock) | **0** |
| `ipxe-8086100e.rom` (this one) | **617** |

Corroborated by the live fleet: `/var/lib/libvirt/maas-console/node1.log` from a real
passing run begins at `Linux version …` and contains **zero** SeaBIOS or iPXE lines.

> ⚠️ **Do not measure this with `-nographic`.** QEMU sets `FW_CFG_NOGRAPHIC`, SeaBIOS moves
> its console to COM1, and then the *stock* ROM appears to have a serial console while this
> one appears corrupted — two writers on one port, bytes interleaved:
> `PiXPEX Ei niintiitailailsiisnign g` is "iPXE initialising devices" twice, merged.

### 12.3 The firmware's verdict (real transcript)

```
iPXE 2.0.0+ (g3ca79) -- Open Source Network Boot Firmware -- https://ipxe.org
Configuring (net0 52:54:00:12:34:56)...... ok
MAAS: resolving a boot script for  (52:54:00:12:34:56) from http://10.9.9.2:8181/maas
http://10.9.9.2:8181/maas/.ipxe... Connection reset          ← nothing serving; falls to the shell
iPXE> imgverify
Usage:
  imgverify [-s|--signer <signer>] [-k|--keep] … <uri|image> <signature uri|image>
iPXE> nosuchcmd
nosuchcmd: command not found                                 ← so the line above means it EXISTS
iPXE> imgverify http://10.9.9.2:PORT/good.img http://10.9.9.2:PORT/good.img.sig
http://10.9.9.2:PORT/good.img... ok
http://10.9.9.2:PORT/good.img.sig... ok
iPXE>                                                        ← ACCEPTED, silently
iPXE> imgverify http://10.9.9.2:PORT/bad.img http://10.9.9.2:PORT/bad.img.sig
http://10.9.9.2:PORT/bad.img... ok
http://10.9.9.2:PORT/bad.img.sig... ok
Could not verify: Permission denied (https://ipxe.org/0227e13c)   ← REFUSED: digest mismatch
```

The host serves the payloads on loopback; slirp's gateway (`net+2`) proxies the guest to
it, so **no host port is opened**. Automated as
[`tests/test-verifying-rom.sh`](tests/test-verifying-rom.sh) — it skips cleanly when the
ROM has not been built, so CI is unaffected.

### 12.4 What it found the first time it ran

The good payload was refused too:

```
Could not verify: Permission denied (https://ipxe.org/022ae13c)     "Not a signing certificate"
```

`verify-lib.sh` minted its code-signing leaf with `extendedKeyUsage=codeSigning` only. iPXE
also requires `keyUsage=digitalSignature`, and `openssl cms -verify` ignores key usage
entirely — so the host-side gate and the whole green suite had been accepting a certificate
that no verifying firmware would. Check any keydir with:

```bash
./drivers/verify-lib.sh check-keys --dir "$(./maas-lab.sh _images-dir)/trust"
# → verify-lib: …/codesign.crt is NOT a certificate verifying firmware will accept:
#     keyUsage=digitalSignature is MISSING -> iPXE: 'Not a signing certificate' (https://ipxe.org/022ae1)
```

Re-minting is deliberately manual (`gen-keys` never overwrites an existing keydir): remove
the trust dir, `gen-keys`, **re-sign every image**, and rebuild the ROM — it bakes the CA.

### 12.5 On the fleet — RUN 2026-07-28, both directions (author-run)

```bash
./build-verifying-rom.sh install                       # sudo: ROM -> /var/lib/libvirt + the AppArmor rule
FLEET_NIC_ROM=1 MAAS_IPXE_TRUSTS_CA=1 ./run-e2e.sh     # no E2E_NO_IMGVERIFY
```

Both vars ride the e2e itself: its phase 3 re-runs `create-fleet.sh up`, which
redefines the domains. (`give_verifying_rom()` originally attached nothing when
`FLEET_NIC_ROM` was unset — after the third silent ROM-drop it now defaults ON
whenever the ROM is installed on the host, `FLEET_NIC_ROM=0` to opt out, and
both e2e runners verify the domain actually carries `<rom file=>` before a
`MAAS_IPXE_TRUSTS_CA=1` deploy.)

⚠️ **The first attempt failed before any node booted**, and the failure is worth
knowing on sight. `inspect --boot` reported `could not power on the node`; `virsh
start` gave the real error:

```
qemu-system-x86_64: -device {"driver":"e1000",…,"romfile":"/var/lib/libvirt/maas-rom/ipxe-8086100e.rom"}:
failed to find romfile "/var/lib/libvirt/maas-rom/ipxe-8086100e.rom"
```

The file existed, world-readable, sha-verified. The gate was AppArmor, not DAC:
**virt-aa-helper builds each domain's profile from its XML but does not parse
`<rom file=>`** (a dry-run against node1's XML lists the disk, the seed ISO and
the console log — no ROM), so qemu's read is denied — and profile-scoped denials
of unlisted paths are **silent**, no `DENIED` line anywhere, while QEMU's failed
`access()` reads as "not found". `build-verifying-rom.sh install` now writes the
rule into `/etc/apparmor.d/local/abstractions/libvirt-qemu` (the abstraction's
`include if exists` hook); it takes effect at the next domain start, no reload.

**The run then PASSED end to end.** node1's console (`/var/lib/libvirt/maas-console/node1.log`),
deploy boot — our ROM's banner, the chain, both `.sig` fetches, the payload:

```
iPXE 2.0.0+ (g3ca79) -- Open Source Network Boot Firmware -- https://ipxe.org
MAAS: resolving a boot script for node1 (52:54:00:5b:86:1c) from http://192.168.123.1:8181/maas
http://192.168.123.1:8181/maas/node1.ipxe... ok
http://192.168.123.1:8181/maas/micro-linux-x86_64/kernel... ok
http://192.168.123.1:8181/maas/micro-linux-x86_64/initrd... ok
http://192.168.123.1:8181/maas/micro-linux-x86_64/kernel.sig... ok
http://192.168.123.1:8181/maas/micro-linux-x86_64/initrd.sig... ok

Welcome to micro-linux (Linux 6.12.30 x86_64)
```

**The negative control, same node.** 6 bytes appended to the served kernel (its
`.sig` left intact), one IPMI power-cycle:

```
http://192.168.123.1:8181/maas/micro-linux-x86_64/kernel.sig... ok
Could not verify: Permission denied (https://ipxe.org/0227e13c)
Could not boot: Permission denied (https://ipxe.org/0227e13c)
http://192.168.123.1:8181/maas/52:54:00:5b:86:1c.ipxe... Not found (https://ipxe.org/2d0c613b)
http://192.168.123.1:8181/maas/default.ipxe... ok
```

The firmware refused the tampered kernel, **nothing booted**, and the node
stopped at the dead-end script's iPXE shell with the refusal on its console —
exactly the "done when" of DEFERRED item 1. (Note the fall-through: the chain's
`||` cannot tell "script missing" from "script aborted by a refusal", so the
dead-end banner appears *after* a refusal too — its wording now says to scroll
up. The refusal lines are always right above.) Kernel restored, power-cycled:
clean verify, `login:` again.

**Fleet-wide.** node2 and node3 (held in `error` from an earlier session) were
recovered with `retry` and `apply fleet.toml` converged the whole fleet through
the verifying firmware — each console shows the same banner/sig-fetch/login
signature — with the invariant pass issuing 0 transitions:

```
  applied: 0 transition(s) over 1 pass(es), 0 failed, 3 converged, 0 held for the operator
```

## 13. The INSTALL driver, live — three attempts, three defects, then PASS (2026-07-28)

The first live run of `run-e2e-install.sh` (DEFERRED item 2). Every attempt's
failure was a defect the 27/0 headless suite could not see; each is now fixed and
regression-tested.

### 13.1 Attempt 1 — the driver demanded context it never uses

```
== stage + sign 'almalinux9' (host-side F2) ==
drivers/install.sh: line 34: MAAS_STATE: install driver: MAAS_STATE not set (run via maas-lab.sh)
FAIL: staging 'almalinux9' failed
```

`install.sh` guarded `MAAS_STATE` at the top of the file, but `stage`/`verify` touch
only the image store. The guard is now lazy (inside `nd()`, where node context is
actually read) — and the fallout was worse than the message: following the printed
advice to "bring the fleet up" with a bare `create-fleet.sh up` rebuilt the fleet
**without its verifying ROMs** (the third silent ROM-drop). That ended the opt-in
era: the ROM now defaults ON whenever it is installed on the host, and both e2e
runners refuse a `MAAS_IPXE_TRUSTS_CA=1` deploy when the domain carries no
`<rom file=>`.

### 13.2 Attempt 2 — the sha said perfect, the perms said nobody may look

The firmware half worked on the first try — our ROM, the chain, `imgverify` over
the Anaconda kernel AND its 223 MB initrd, kernel 5.14 el9 booting — and then:

```
[  238.9] dracut-initqueue[1133]: Warning: anaconda: failed to fetch stage2 from http://192.168.123.1:8181
```

`curl -o "$(mktemp …)"` + `mv` had staged `install.img` as **0600**, so the payload
server (another user) answered 403 — after the sha256 check against `.treeinfo` had
passed. Two follow-on defects surfaced while diagnosing: **virtlogd's 2 MiB
rotation** replaced the fleet's readable 0666 console log with a fresh 0600 root
file (both console-grepping health gates would have timed out claiming "never
reached login:" — they now refuse loudly, naming the unreadable file), and an
out-of-band **power cycle raced the driver's poweroff-wait**: a ~3 s off-window
read as "installer finished" and the driver pointed the node at its EMPTY disk.
The driver now confirms the off *stays* off for one extra poll
(`MOCK_BMC_BLIP=1` in `tests/mock-bmc.sh` reproduces the race headlessly;
`test-install-driver.sh` §4b asserts no `bootdev disk` follows a blip).

### 13.3 Attempt 3 — PASS

```
   verifying ROM: attached to 'node1'
   stage2: /home/sqs/netboot/images/install.img matches .treeinfo (539f423b…)
…
install: installer finished ('node1' powered itself off); booting from disk
Set Boot Device to disk
Chassis Power Control: Up/On
install: awaiting /login:/ on /var/lib/libvirt/maas-console/node1.log (timeout 240s)…
install: 'node1' reached its login marker (active)
active node1 (driver=install image=almalinux9, healthy)
PASS: node1 reached active through the INSTALL driver — Anaconda netbooted via the
chain, the kickstart wrote the disk, the node powered itself off, and the INSTALLED
OS reached login on its own disk
```

Ground truth beyond the runner's verdict: registry `state=active`,
`driver=install image=almalinux9`; domain XML `<boot dev='hd'/>`; the console shows
`Welcome to AlmaLinux 9.8 (Olive Jaguar)` and exactly one `login:` in the
freshly-rotated log — the installed OS's own, not a stale one (the runner truncates
the console before deploying for exactly that reason).

Host prep this run needed (one-time): `virtlogd` rotation effectively disabled for
the console contract (`max_size = 536870912` appended to `/etc/libvirt/virtlogd.conf`
+ restart), and the rotated 0600 logs chmod'd 0666.

Known blemish, recorded in DEFERRED ("A failed deploy corrupts the recorded rollback
pair"): the successful deploy recorded `previous: install/micro-linux-x86_64`, a
pair that never existed, because the two failed attempts had overwritten the
`driver` field before their gates refused.

---

## 14. The UEFI netboot path — what `image+measured` was waiting on (2026-07-29)

The measured driver needs a **UEFI** node (a BIOS firmware measures no payload, §13's
sibling finding), and this fleet's PXE network only ever spoke BIOS: it hands every
client `boot.ipxe`, an iPXE *script*, which works solely because a BIOS node's option
ROM is already iPXE and executes it. A UEFI firmware TFTPs the same file, finds
`#!ipxe` where a PE binary should be, and stops. The two requirements collide, and
that collision is what blocked the first live measured run.

Building the path found that the fix this repo had written down was wrong in **both**
of its lines. Neither error is visible to any test that does not read the actual bytes
or send actual DHCP packets.

### 14.1 The binary: `~/netboot/ipxe.efi` verifies nothing

`DEFERRED.md` said the UEFI binary was "already built, at `~/netboot/ipxe.efi`". That
is the RAM-infra lab's generic build. The verifying one already existed too —
`netboot/build-ipxe.sh` emits `ipxe.efi` beside the option ROM from the *same* build,
so the ROM build had produced one months ago and nothing installed it:

```console
$ ./build-verifying-rom.sh check-efi                       # our build
  - /home/sqs/.cache/lab-create/maas/ipxe/ipxe.efi: imgverify present,
    this fleet's CA embedded — it ENFORCES

$ ./build-verifying-rom.sh check-efi ~/netboot/ipxe.efi    # the one the notes named
  - imgverify is NOT compiled into this binary.
  - this fleet's CA fingerprint (4c3fdd813cdc3364...) is NOT in this binary.
build-verifying-rom: /home/sqs/netboot/ipxe.efi does not enforce F2
```

Had the note been followed, every downstream step would have gone green with the
firmware half of F2 switched **off** on the one node whose purpose is proving a
machine refuses what the fleet did not sign.

**How the CA is actually embedded** — measured, because the first version of
`check-efi` guessed and was wrong. iPXE's `TRUST=` does not embed the certificate; it
embeds its **SHA-256 fingerprint**, so searching for the subject or the DER finds
nothing in a perfectly good binary:

```console
CA sha256: 4c3fdd813cdc3364a50d21ef2e2a7aeb51f6858e191c089f30addcdf58e32d7a
fingerprint in ipxe.efi:            True  (offset 976512)
fingerprint in ~/netboot/ipxe.efi:  False
fingerprint in the .rom:            False   ← compressed; the check is EFI-only, honestly
```

### 14.2 The DHCP config: the obvious form chainloads forever

The snippet in the notes was the one everybody writes first:

```
dhcp-match=set:efi64,option:client-arch,7
dhcp-boot=tag:efi64,ipxe.efi
```

`ipxe.efi` boots, does its own DHCP, is still architecture 7, and is handed `ipxe.efi`
again — forever. The BIOS path never showed this because a *script* is executed, not
re-loaded. iPXE announces itself in DHCP option 77, so the tag has to mean "EFI
firmware that is **not** already iPXE".

Proven against a real dnsmasq 2.90 answering real DHCP packets, rootless, in a
throwaway namespace (`tests/test-uefi-netboot-dhcp.sh`):

| client | offered |
|---|---|
| arch 0 (legacy BIOS) | `boot.ipxe` |
| no arch option | `boot.ipxe` |
| arch 7 / 9 (UEFI x86-64) | `ipxe.efi` |
| arch 7 **+ user-class iPXE** | `boot.ipxe` ← the loop break |
| arch 7 + iPXE, **naive config** | `ipxe.efi` ← the loop, reproduced as §3's control |

Two things made the harness possible. dnsmasq needs `NET_ADMIN`, so it runs inside
`unshare -rn --map-auto` — **`--map-auto` matters**: a plain `unshare -r` leaves
`/proc/self/setgroups` at `deny` and dnsmasq dies dropping privileges
(`failed to change group-id to root`), while `--map-auto` maps the `/etc/subuid` range
through `newuidmap` and sets it to `allow`. And the client is a purpose-built program
(`tests/dhcp-probe.py`), because no ordinary DHCP client will lie about its
architecture on request — which is precisely the input under test.

Two harness bugs found on the way, both worth knowing:

- **All probes must share one client port.** dnsmasq broadcasts its reply to the single
  client port it was configured with; a probe listening anywhere else waits forever on
  an answer that was correctly sent. The symptom is a `TIMEOUT` next to a dnsmasq log
  line showing the right filename going out. Replies are matched by transaction ID.
- **ElementTree re-serializes attributes with double quotes** where libvirt writes
  single ones, so a `sed` pinned to `file='...'` silently yields an *empty* untagged
  `dhcp-boot` — which looks exactly like a broken BIOS path rather than a broken
  harness.

### 14.3 Running it (author-run, sudo-gated)

`install-uefi` restarts the network, which tears down the bridge and does not give
running domains their link back — so it refuses while any fleet domain is up.

```bash
./build-verifying-rom.sh install-efi     # verifying ipxe.efi -> the TFTP root; refuses a
                                         #   binary that does not enforce
./create-fleet.sh down
./netboot-chain.sh install-uefi          # arch-conditional DHCP; verifies afterwards that
                                         #   the options are LIVE in libvirt's rendered
                                         #   dnsmasq conf, not merely defined
FLEET_TPM=node3 ./create-fleet.sh up     # ONE node gets UEFI+TPM (see 14.4)
./run-e2e-measured.sh
```

`./netboot-chain.sh show` reports the state of both halves, and distinguishes "not
configured" from "cannot read `/var/lib/libvirt/dnsmasq/vbmc-pxe.conf` without sudo" —
reporting the second as the first would be exactly the quiet lie this lab hunts.

### 14.4 `FLEET_TPM` now names nodes, not the fleet

`FLEET_TPM=1` switched **every** domain to UEFI on the first measured attempt,
including node1 and node2, whose disks had been installed under BIOS and could no
longer boot. Measured boot is a property of one node's job:

```console
$ for c in 0 1 node3 node2,node3; do ... done
FLEET_TPM=0              selects: (none)
FLEET_TPM=1              selects: node1 node2 node3      (still works; warns)
FLEET_TPM=node3          selects: node3
FLEET_TPM=node2,node3    selects: node2 node3

$ FLEET_TPM=node33 ./create-fleet.sh _check-tpm
create-fleet: FLEET_TPM names 'node33', which is not a node in this fleet.
  Known nodes: node1 node2 node3
```

The typo guard is not fussiness: a name matching nothing equips **nobody** and prints
nothing, and the failure surfaces an hour later as "the node never delivered a quote",
which reads as a bug in the measuring payload.

### 14.5 The first UEFI boot: OVMF went to the EFI shell, not to PXE

The first `FLEET_TPM=node3` run got everything above right and node3 still booted
nowhere:

```
BdsDxe: starting Boot0001 "EFI Internal Shell" ...
UEFI Interactive Shell v2.2
map: No mapping found.
Shell>
```

No PXE attempt at all — despite the NIC carrying `bootindex=1` in the QEMU command
line, so the firmware *was* told to boot the network first.

**The cause is a collision between two things this lab does deliberately.** OVMF's
`NetworkPkg` supplies the PXE protocol stack (confirmed from the `ovmf` package
changelog, which patches `NetworkPkg/*` for "UEFI network boot"), but the Simple
Network Protocol *driver* for the card has to come from somewhere. For an e1000 that
is the card's UEFI option ROM — QEMU's `efi-e1000.rom`, an iPXE image carrying both a
legacy and an EFI driver. This lab attaches its own **legacy-only** verifying ROM over
the top, so a UEFI firmware finds no driver, builds no network boot option, and falls
through to the shell. Nothing errors; the run simply waits for a quote from a machine
sitting at a firmware prompt.

⚠️ A `strings` search of `OVMF_CODE_4M.fd` for `VirtioNetDxe`/`UefiPxeBcDxe` finds
**nothing even though they are there** — OVMF's volumes are LZMA-compressed. Same trap
as the option ROM in 14.1: on a compressed binary, a negative grep is not evidence.

**The fix, and why it is the arrangement the arch-conditional DHCP was built for:**

| | node1/node2 (BIOS) | node3 (UEFI, measured) |
|---|---|---|
| NIC | e1000 | **virtio** — OVMF has `VirtioNetDxe` built in |
| option ROM | the verifying legacy ROM | **none** (`<rom enabled='no'/>`) |
| who does DHCP | our iPXE ROM | OVMF's own PXE client |
| user-class sent | `iPXE` | *none* → the `tag-if` fires |
| offered | `boot.ipxe` | **`ipxe.efi`** (the verifying build) |
| enforces F2 | the option ROM | the chainloaded `ipxe.efi` |

Leaving QEMU's **stock** iPXE oprom in place would be worse than either: it announces
itself as iPXE, so the fleet's own loop break hands it the script — which it then
cannot run, because stock iPXE has no `imgverify`.

`lib/tpm_xml.py` now sets the NIC alongside the firmware and the TPM (all three or
none — a measured node that cannot netboot is as useless as one that cannot measure),
`create-fleet.sh` skips the legacy ROM for TPM-selected nodes, and
`run-e2e-measured.sh` refuses up front rather than timing out against a firmware
prompt.

**`tpm_xml.py` had no test before this.** That is the honest reason the defect reached
a live run, and [`tests/test-tpm-xml.sh`](tests/test-tpm-xml.sh) now covers it — it is
red against the exact code that shipped the defect (`the NIC model is 'e1000', not
virtio`) and green against the fix.

### 14.6 The second UEFI boot: a late failure from the *previous* run's wreckage

With the NIC fixed, the run got all the way through preflight, the UKI build, staging,
signing and starting the attestation sink — and then:

```
== deploy #0 — image+measured must refuse an image with no PCR policy ==
   refused at verify, before the node was touched: no pcrs.expected for 'golden-measured'

== deploy #1 — enrollment boot (plain 'image' driver) ==
maas: cannot 'deploy' node 'node3' from state 'deploying' — needs one of: available active
```

Deploy #0 is the gate working exactly as intended. Deploy #1 failed on something else
entirely: the **previous** run had been interrupted while node3 sat at the EFI shell,
leaving the registry saying `deploying`. The control plane was right to refuse — a
destructive lay-down from a transient state is precisely what the state machine exists
to prevent. The harness simply asked several minutes too late, after everything
expensive had already been rebuilt.

Two things were wrong, and only one of them is the obvious one:

- **Neither runner handled a node stranded mid-transition.**
  `run-e2e-image.sh` had a "make it deployable" block covering `active`, `error` and
  `manageable`; `run-e2e-measured.sh` had no such block at all; and **neither** covered
  a transient. Two copies of the same idea, drifted apart. Now one shared
  [`lib/e2e-common.sh`](lib/e2e-common.sh) `make_deployable`, called **early in
  preflight** by both.
- **It recovers through the real verbs.** `abort` → `retry` → `provide` is the recovery
  the control plane offers for a stranded node — the same path DEFERRED's earlier
  "stranded in a transient state no verb accepted" finding produced. A harness that
  wrote `available` into the registry would be testing a state the system never
  produces, and would keep passing if that recovery path ever broke.

It says so out loud rather than quietly tidying up, because a run that silently repairs
the wreckage of the last one hides the fact that the last one did not finish:

```
· 'node3' is stuck in the transient state 'deploying' (an earlier run was
  interrupted). Recovering with the verbs the control plane offers:
  abort -> retry -> provide.
· 'node3' is 'available' — deployable
```

Covered by [`tests/test-e2e-make-deployable.sh`](tests/test-e2e-make-deployable.sh),
which stages the exact on-disk wreckage an interrupted run leaves, confirms `deploy`
really is refused from there (or the test proves nothing), and requires the recovery to
go through `abort`. §4 is its negative control: a state no verb recovers must make the
runner **stop**, or every other section would pass even if the helper did nothing.

⚠️ Writing that test reproduced one of this repo's own documented traps. A bare
`trap 'cleanup_sandboxes' EXIT` **replaces** `lib.sh`'s belt-and-suspenders net, so the
first negative-control run exited `rc=9` with no `FAIL:` line at all — a silent test
death, the exact thing CLAUDE.md forbids.

> **Closed 2026-08-06 — and this paragraph is why it took a fortnight.** It ended, as
> written, on *"several older tests in this directory use the same bare form and have
> the same gap"* — a known defect, counted in prose and left there. It was **23 of 36**,
> and prose does not fail a build. Cleanup now goes through `on_exit` and
> [`tests/test-harness-net.sh`](tests/test-harness-net.sh) refuses a test that installs
> its own EXIT trap: [§18](#18-the-safety-net-that-23-of-36-tests-had-silently-disarmed-2026-08-06).

### 14.7 The third UEFI boot: it measured, signed — and had no NIC to say it with

With the state recovered and the digest fixed, the run went the whole way:

```
MAAS-DEPLOY: verified: the bytes on /dev/vda match the published sha256
MAAS-DEPLOY: rebooting into the deployed image
...
MAAS-ATTEST: measured 10 PCRs from a real TPM 2.0
MAAS-ATTEST: PCR4 (boot device, as measured by the firmware) = 451AAEE40FF1C06F0087DD2F59EB6A110B67383FF1E6AEE0A9A417DE85EE86C8
udhcpc: SIOCGIFINDEX: No such device
MAAS-ATTEST: identity: mac= addr=none
MAAS-ATTEST: signed the quote with the image's attestation key
MAAS-ATTEST: FAILED: could not deliver the quote to http://192.168.123.1:8282 after 5 tries
MAAS-ATTEST: parking: the control plane will refuse to activate an unmeasured node, which is correct
```

**Measured boot works.** OVMF loaded the UKI, a real TPM 2.0 extended 10 PCRs, PCR4 is a
genuine non-zero value, and the node signed its own quote before anything else saw it.
Everything built today — arch-conditional DHCP, the verifying `ipxe.efi`, the virtio NIC,
the digest fix, the state recovery — held.

Then it had no network interface. Not a down link, not a DHCP timeout: **no `eth0` at
all**, so no MAC either, and therefore no identity to key a quote by.

**The cause is a kernel split that nobody chose.** The two kernels in this lab have
exactly complementary gaps:

| kernel | TPM | NIC drivers, no modules |
|---|---|---|
| AlmaLinux 9.8 `5.14.0-687.5.3` — the UKI's | ✓ built in | ✗ **modular** (dracut's job) |
| micro-linux `6.12.30` — the deployer's | ✗ none at all | ✓ built in |

AlmaLinux's kernel was chosen in §13's sibling work *because* Alpine's `-virt` flavour had
no TPM drivers — and it measures perfectly. It simply expects dracut to load
`virtio_net.ko`, and the measuring initramfs is busybox, which loads nothing. Two correct
decisions meeting.

⚠️ The kernel log is the tell, and it is easy to misread: the boot registers
`PF_INET`/`PF_PACKET`/`PF_NETLINK` and a dozen other network *protocol families* while
containing not one NIC *driver* line. A network stack is not a network card.

Also corrected: `build-golden-measured.sh` claimed to use "the AlmaLinux 9 netboot vmlinuz
already staged for the install driver". The staged deployer kernel is micro-linux's — the
comment described a kernel it was not using.

**The interim fix** lifts `failover` → `net_failover` → `virtio_net` (that dependency
chain, per the initrd's own `modules.dep`; `virtio_pci` is *not* among them because it is
built in, which is why `virtio_blk` works) out of the matching netboot initrd at build
time. The version check is the load-bearing part — `file(1)` reads the version straight
out of the bzImage, and a mismatch is refused:

```console
$ ./build-golden-measured.sh --kernel ~/netboot/maas/deployer/vmlinuz
build-golden-measured: /home/sqs/netboot/initrd.img carries no modules for kernel 6.12.30.
Available: 5.14.0-687.5.3.el9_8.x86_64
A module built for another kernel would fail 'insmod: invalid module format' and the node
would have no network — the exact failure this check exists to prevent.
```

Without it a wrong-kernel module fails as `invalid module format` inside busybox and the
node lands back at "no network interface" — the same silent symptom one layer down.

`measure-init.sh` now also distinguishes **"no interface exists"** from **"no lease"**.
Those are different faults with different fixes, and collapsing them is exactly what made
this failure read as a delivery problem when it was a missing driver. It refuses to POST a
quote with an empty MAC, too, since the sink keys on it.

`tests/test-measured-image.sh` §4b proves the modules *work* rather than merely ship: the
test VM gets a virtio NIC behind `restrict=on` slirp, so `eth0` exists only if
`virtio_net` actually loaded and bound —

```
  - the bundled NIC modules load and bind the card (mac reported; DHCP is not exercised here)  ✓
```

**The real fix, and why the module bundling is temporary.** micro-linux is built by this
repo, reproducibly, from a config the repo controls — and it already asserts
`CONFIG_VIRTIO_NET=y` and `CONFIG_E1000=y`, with a comment documenting this precise trap
from the NIC side ("an initramfs carries NO MODULES… no eth0 at all… found when
metal-as-a-service netbooted its inspection probe"). The TPM case is the same trap one
drawer over, so `mlbuild.sh` now sets and asserts `TCG_TPM`/`TCG_TIS` (+`TCG_CRB`)
alongside them. Once that kernel is rebuilt and proven, the golden image can use one
kernel with both halves and drop **two** dependencies on `~/netboot/` — the 15 MB
`vmlinuz` and the 223 MB `initrd.img`, both outside the repo and both in the periodic
reclaim path — after which the module-extraction code comes out.

### 14.8 The fourth UEFI boot: DHCP succeeded and the address was thrown away

The NIC modules worked on real hardware — `mac=` went from empty to node3's actual
address — and the run still could not deliver:

```
udhcpc: broadcasting select for 192.168.123.103, server 192.168.123.1
udhcpc: lease of 192.168.123.103 obtained from 192.168.123.1, lease time 3600
MAAS-ATTEST: identity: mac=52:54:00:14:1a:88 addr=none
```

**A success line and no address.** `udhcpc` configures nothing itself: it execs a
script (`$1` = the action, the lease in the environment) and *that* is the step which
applies the address. If the script is not where this particular busybox was compiled to
look, udhcpc obtains the lease, exits 0, and drops it — no error, no warning.

The initramfs installs the script at `/usr/share/udhcpc/default.script`, which is
micro-linux's path because micro-linux compiles its own busybox that way. But the
initramfs bundles the **host's** busybox, and Ubuntu's is built with:

```console
$ strings -a bin/busybox | grep default.script
/etc/udhcpc/default.script
```

**Why this had been invisible.** The deployer ramdisk does the same DHCP with the same
busybox and has always worked — because its kernel has `virtio_net` built in, so the
*kernel's* `ip=dhcp` configures `eth0` before init runs at all (`device=eth0,
ipaddr=192.168.123.103` in its boot log). udhcpc's fallback path was never taken.
Making the driver a module moved that job into userspace and exposed a bug that had sat
latent in `deployer-init.sh` the whole time, one kernel-config change from biting.

Fixed three ways, because the failure is silent: the script now ships at **both**
conventional paths, both inits pass `-s` explicitly so nothing depends on how busybox
was compiled, and `measure-init.sh` names this exact state rather than reporting a
generic delivery failure —

> if a lease WAS obtained above, udhcpc's script did not apply it — udhcpc configures
> nothing itself, so a missing/unfound `default.script` takes the lease and silently
> drops it.

Verified by boot:

```
udhcpc: eth0 bound to 10.0.2.15 (gw none, dns none)     <- the script's own line, absent before
MAAS-ATTEST: identity: mac=52:54:00:12:34:56 addr=10.0.2.15
```

⚠️ **This also fooled the test, and then the test recorded the wrong reason.** An earlier
version of §4b saw `addr=none` under `restrict=on` slirp and concluded DHCP simply is not
exercised there — a comment stating a limitation that did not exist. slirp serves DHCP
fine; the missing address was this defect, in the harness as well as on the metal. §4b now
*asserts* `addr=` is a real address. A caveat is a claim like any other, and this one was
never checked.

**Success signature:** `tests/run-all.sh` reports **every listed test ran, 0 skipped, 0 failed**;
`./netboot-chain.sh show` ends with `network: arch-conditional DHCP present (5/5
options ...)`; and `./build-verifying-rom.sh show` reports the UEFI binary as
`ENFORCES` both built and installed.

---

## 15. The measured run, live and PASSING — and the four defects between here and there (2026-07-29)

`./run-e2e-measured.sh` now passes end to end on real libvirt domains:

```
== deploy #0 — image+measured must refuse an image with no PCR policy ==
   refused at verify, before the node was touched: no pcrs.expected for 'golden-measured'

== deploy #1 — enrollment boot (plain 'image' driver) to learn what this image measures ==
   the node delivered a signed quote: 10 PCRs
image-measured: captured .../pcrs.expected from node3's quote:
  4:B7F9477181694AE0DD0252BB133FFE577170CF5ED9D614C37FCB43CC10EE6A7D
  7:B5710BF57D25623E4019027DA116821FA99F5C81E9E38B87671CC574F9281439

== deploy #2 — the same image must now attest and activate ==
image: 'node3' is already running (a previous deploy left it up) — powering it off so 'bootdev pxe' can take effect
image-measured: 'node3' attested to the expected PCR state for 'golden-measured'
active node3 (driver=image+measured image=golden-measured, healthy)

== deploy #3 — a policy the node cannot satisfy MUST be refused ==
   refused, correctly: the measured PCR4 did not match the policy

PASS: node3 attested to a real TPM measurement of the image it booted, activated only
      against a policy captured from that measurement, and was REFUSED when the policy
      no longer matched. swtpm is plumbing, not a trust anchor: this proves the
      mechanism and the refusal, not the integrity of a machine.
```

**Deploys #2 and #3 had never once been reached.** #2 is the whole point of the driver;
#3 is the only thing that distinguishes a real gate from one that always says yes — the
runner bends one digit of the expected PCR4 and requires the deploy to fail.

Four defects stood between the previous section and this transcript. Each is in
[`DEFERRED.md`](DEFERRED.md)'s ledger; what follows is what the metal actually printed.

### The second deploy never rebooted the node (#13)

```
Set Boot Device to pxe
Chassis Power Control: Up/On          <- no-op, the node was already on
image: awaiting /… copied/ (timeout 4800s)
```

`bootdev pxe` applies only at the **next** boot, and a running node ignores `power on`.
A successful deploy leaves the node powered on and `active`, so every second deploy on
the same node stalled at its first gate — the deployer never booted, and the node sat
happily running its **previous** image while the control plane waited eighty minutes for
a disk write nothing had started. The disk-boot phase eleven lines below had always done
`off`+`on`; the deployer boot never did.

**This is the fault #11 was hiding.** Before `console_mark`, the health gate matched the
earlier boot's login banner and reported `active` in *one second* — the node had not
rebooted then either. Fixing the liar did not make the node boot; it made the silence
visible, and nineteen minutes of silence diagnosed itself. Diagnosis, live:

```
$ stat -c%s /var/lib/libvirt/maas-console/node3.log   # 64593, mtime 17:35:09
$ date +%H:%M:%S                                      # 17:54:12
$ tail -c 3000 .../node3.log | tail -3
measured-node login: (attested)                       # ← deploy #1's boot, still running
~ #
```

### The attestation signature was truncated in flight (#14)

The node measured, signed and delivered — and the gate called it **forged**:

```
image-measured: the quote from 'node3' does NOT verify against the trusted attestation key
```

Measured with the same busybox 1.36.1 the initramfs carries:

| transport | `Content-Length` |
|---|---|
| `busybox wget --post-file` (2117-byte CMS DER) | **107** ← exactly the first NUL offset |
| `curl --data-binary` (same file) | 2117 |
| `busybox wget --post-file` (base64 of it) | 2869 |

`busybox wget` computes `Content-Length` with `strlen()`. Nothing errored anywhere: the
node printed *"delivered quote + signature"*, the sink stored 107 bytes, and a truncated
signature is indistinguishable from a bad one — so the transport broke and the **node**
took the blame. Diagnosis:

```
$ xxd -l 4 quote.json.sig
00000000: 3082 0841        # SEQUENCE, declares 0x0841 = 2113 content bytes
$ stat -c%s quote.json.sig
107
$ openssl asn1parse -inform DER -in quote.json.sig
Error in encoding                # "too long" — the object claims more than exists
```

Fixed three ways, because fixing the transport alone leaves the trap armed for the next
client: base64 on the wire to `/quote-sig-b64/`, a decoder tolerating the 64-column
wrapping `openssl base64` emits, and `_der_truncated()` refusing any signature that
declares more bytes than arrived — **HALTED instead of LIED**. Verified live:

```
size=2117  DER declares 2113 content bytes, 2113 arrived  -> INTACT
```

**Why the suite never caught it:** the delivery test posted with `curl --data-binary`,
which is binary-safe and therefore evidence about the **sink** and nothing about the
machine. The node has no curl. The seam under test was not the seam in production.

### The registry claimed BIOS for a UEFI machine (#12)

```
$ ./maas-lab.sh show node3 | grep firmware
firmware    bios
$ virsh -c qemu:///system dumpxml node3 | grep -E '<os|loader'
  <os firmware='efi'>
    <loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
```

`enroll --firmware` defaults to `bios`, nothing revisited it, and `give_tpm` converted
the node afterwards with no way to say so. The fix is **not** "make `show` read the
domain": the control plane reaches a node only through the BMC and its console, never
the hypervisor. So whoever changes the firmware reports it, via a new
`maas-lab.sh set-firmware` — and `create-fleet.sh` reconciles after `give_tpm`:

```
$ ./maas-lab.sh set-firmware node3 uefi
firmware for node3: uefi (was bios)
```

### One kernel now does both jobs (and #15)

The measured image used to borrow AlmaLinux's `vmlinuz` and carry
`failover`/`net_failover`/`virtio_net` extracted from its initrd, because neither kernel
could both read a PCR and report it. micro-linux now builds
`TCG_TPM`/`TCG_TIS`/`TCG_CRB=y` beside `VIRTIO_NET`/`E1000=y`. Proven by **boot**, not by
config:

```
$ # one-shot rdinit probe, OVMF-free, swtpm attached
tpm_tis MSFT0101:00: 2.0 TPM (device-id 0x1, rev-id 1)
--- PCR banks present ---
dev device null_name pcr-sha1 pcr-sha256 pcr-sha384 pcr-sha512 power ppi subsystem ...
```

Rebuilding it surfaced **#15**: `mlbuild.sh` reported failure for successful builds in
three places. Under `set -euo pipefail` a terminal `[[ … ]] && cmd` returns 1 when the
test is false, and that becomes the function's exit status — so `inner_build` killed the
script the instant the build succeeded, `all` never packed an initramfs, and printed
nothing, because `set -e` exits silently. Live since 2026-05-27.

**Success signature for this section:** `./run-e2e-measured.sh` ends on the `PASS:` line
above with deploy #3 refused; `tests/run-all.sh` reports **every listed test ran, 0 skipped, 0 failed**; and
`./maas-lab.sh show node3` reports `firmware uefi`. Note that node3 legitimately ends in
`error` — that is deploy #3's refusal, and the runner restores the real `pcrs.expected`
afterwards.


---

## 16. `create-fleet.sh preflight` — refusing before the disks are gone (2026-07-29)

**Why this exists.** `up` step 3 destroys any running fleet domain and step 4 runs
`create-node.sh`, whose first act is unconditional:

```
sudo qemu-img convert -f qcow2 -O qcow2 "$base" "$disk"
```

Every node's disk is replaced. But the two gates that can *kill* the run — `swtpm`
absent, a required verifying ROM absent — lived at step 9, inside `give_tpm` and
`give_verifying_rom`. So on a host missing either, `up` rewrote three disks, built and
started vbmcd, registered three BMCs and enrolled the whole fleet, and *then* died: half
a fleet, and the previous disks gone. Both answers were available from `command -v` and
`[[ -f ]]` before anything was touched. Defect **#16** — and this repo's own rule,
broken: *"a gate that fires after the `dd` is not a gate, it is a post-mortem."*

**Why it is not a Terraform `plan`.** There is no plan file and `up` does not consume
one, so it could never promise that what you read is what runs. Instead `up` calls
`do_preflight` as its **first act**, and every answer printed comes from the same helper
apply uses (`tpm_selects`, `rom_plan`, `validate_tpm_selection`). A pre-flight that
re-derived apply's decisions in a second code path would just be a new record able to
outlive its subject — the exact bug class this lab keeps finding. The interesting half of
the state is unplannable anyway: a MAC does not exist until the domain does, the firmware
mode is a *consequence* of `give_tpm` (hence `reconcile_firmware`), and BMC port ownership
can only be checked below the seam against a live vbmcd (hence `verify_bmc_bindings`). So:
everything refusable is refused; everything else is reported, not predicted.

```
$ FLEET_TPM=node3 ./create-fleet.sh preflight
==> preflight — checking everything that can refuse this run BEFORE any disk is rewritten
  - swtpm present (/usr/bin/swtpm) — required by: node3

  NODE    FIRM  TPM  MEMORY   DISK   NET:BMC        NIC / ROM
  node1   bios  no   4096MiB  10G    vbmc-pxe:6230  e1000 / ipxe-8086100e.rom
  node2   bios  no   4096MiB  10G    vbmc-pxe:6231  e1000 / ipxe-8086100e.rom
  node3   uefi  yes  4096MiB  10G    vbmc-pxe:6232  e1000 / none (UEFI)

==> preflight passed: 3 nodes, nothing refused. `up` will now DESTROY and rewrite every node disk.
```

`node3` reads `uefi`/`yes` with **no ROM** because a TPM implies UEFI (a BIOS firmware
measures no payload) and a UEFI node must not take the legacy option ROM — it would
displace the only UEFI NIC driver OVMF has for that card. All three facts come from the
two helpers `up` applies, so the table cannot drift from the run.

Ports are **reported, never gated**: on a re-run our own vbmcd already holds 6230–6232, so
refusing on "in use" would refuse the normal case. Whether the listener is the right BMC
for the right node is an identity question, and identity can only be settled below the
seam against a live vbmcd — `verify_bmc_bindings`, step 7.

### 16.1 The negative control — `tests/test-fleet-preflight.sh`

The test does **not** grep `create-fleet.sh` for a call to `do_preflight`; that asserts
the mechanism, would pass for a broken preflight, and would fail for a better one. It runs
`up` against a stub sibling lab whose `create-node.sh` is a **tripwire**, and asserts the
tripwire was never touched — the state the system must end in: *no disk rewritten*.

But "the tripwire is absent" is also what a harness that never reached `create-node.sh`
would report. So §6 runs the identical rig with the one refusal condition removed (a
`swtpm` symlink appears on the stub `PATH`) and **requires the tripwire to fire**. Same
rig, one variable, opposite verdict.

Making `command -v swtpm` fail on a host that *has* swtpm needs a `PATH` containing only
the binaries the script uses. That is deliberate: an env-var escape hatch in
`create-fleet.sh` would be a test-only branch, and a gate you can switch off in tests is
not the gate that ships.

Both directions were run. With the fix reverted (`do_up` calling `validate_tpm_selection`
instead of `do_preflight`), §5 fails naming the defect:

```
FAIL: REGRESSION: `up` reached create-node.sh (1 node(s)) before refusing — the swtpm
gate fired AFTER the node disks were rewritten. A gate that fires after the convert is a
post-mortem, not a gate. Output: ==> building the vbmcd image (rootful podman) ...
==> creating libvirt domain 'n1' (1024MiB, disk 2G, net test-net)
create-fleet: create-node n1 failed
```

That output *is* the defect: the old ordering announced it was creating a domain and died
inside `create-node`, never having looked for `swtpm`.

**Two smaller findings came out of the refactor.** `give_verifying_rom` read the
fleet-wide `FLEET_NIC_MODEL` while `create-node.sh` was given
`${NODE_NIC_MODEL:-$FLEET_NIC_MODEL}` — so a node with its own `nic_model` would have got
a ROM built for a card it does not have. And `FLEET_NIC_ROM=1` with an unrecognised NIC
model used to `return 1`, whose value nothing checked: you asked for a verifying ROM and
silently got none, which is precisely the opt-in trap that paragraph of the script warns
about. It is now fatal, in preflight, by name.

**Success signature for this section:** `./tests/test-fleet-preflight.sh` ends on `PASS:`
with seven `note` lines (§1–§6); `FLEET_TPM=node3 ./create-fleet.sh preflight` exits 0 and
prints the table above; `FLEET_NIC_ROM=/nonexistent ./create-fleet.sh preflight` exits
non-zero naming the path *and* the command that builds it, having created nothing; and
`tests/run-all.sh` reports **every listed test ran, 0 skipped, 0 failed**.

---

## 17. Re-deriving a diagnosis nobody had measured — the deployer's pool address (2026-08-06)

[`DEFERRED.md`](DEFERRED.md) carried this, from a live `run-e2e-image.sh` on 2026-07-28:

> The deployer ramdisk gets a POOL address, not the node's reservation. Observed live:
> `eth0 = 192.168.123.31` where node2's reservation is `.102`. **dnsmasq keys the
> reservation on the DHCP hostname/MAC pair and the ramdisk sends no hostname**, so it
> lands in the dynamic range. […] Fix shape: `udhcpc -x hostname:$node`.

The observation is real. The sentence in bold is an *explanation*, and it was never
measured — which makes it the worse of the two things it could be. An open question
invites work; a wrong answer retires it.

### 17.1 What a real dnsmasq actually does

Rootless, in a throwaway namespace, against dnsmasq 2.90, with libvirt's own
`dhcp-hostsfile` format (`mac,ip,name` — the shape
`/var/lib/libvirt/dnsmasq/vbmc-pxe.hostsfile` carries on the live fleet):
[`tests/test-dhcp-reservation-identity.sh`](tests/test-dhcp-reservation-identity.sh).
Its client is [`tests/dhcp-id-probe.py`](tests/dhcp-id-probe.py) — the sibling of
[`tests/dhcp-probe.py`](tests/dhcp-probe.py) (§14.2), which asks the *filename*
question; this one asks the *address* one, because no ordinary DHCP client will omit
its own client-id or claim someone else's hostname on request.

| the client presents | it is given |
|---|---|
| the reserved MAC, **no option 12 at all** | its reservation |
| the reserved MAC + its own hostname | its reservation |
| the reserved MAC + **somebody else's** hostname | its reservation |
| the reserved MAC + a client-id (option 61 — busybox `udhcpc`'s default) | its reservation |
| either identity, after the *other* already committed the lease | its reservation |
| **a MAC the reservation does not name** | **a pool address** |

The reservation is keyed on the MAC and nothing else. The recorded fix would have
changed nothing — and it addresses a code path that does not run here anyway: the
deployer's address comes from the kernel's `ip=dhcp`, with
[`deployer-init.sh`](deployer-init.sh)'s `udhcpc` only as a fallback. §14.8 above
records the same kernel path handing node3 `ipaddr=192.168.123.103` — **its
reservation** — a day after the note was written.

### 17.2 The two controls

An all-PASS matrix is indistinguishable from one that checks nothing, so the last row
above is *inside* the test: if an unreserved MAC ever answered with the reservation,
every row above it would be vacuous and the test says so by name. Both directions were
then broken deliberately and watched to bite:

| control | what fired |
|---|---|
| reservation names a MAC the node does not have | `FAIL: a client sending NO hostname was given 127.0.0.91, not its reservation 127.0.0.102` |
| every MAC reserved, so the pool is unreachable | `FAIL: … Either the pool is unreachable — in which case sections 2 and 3 proved nothing …` |

The first control is the interesting one: it is the **only** input that reproduces the
live symptom, and it reproduced it exactly — a pool address, silently.

### 17.3 So what is left is a different bug

`reserve_dhcp` reads a domain's MAC once, at fleet-creation time, and libvirt mints a
new MAC every time a domain is recreated. Nothing re-checks the pair afterwards. That
drift is not hypothetical: on this host libvirt's own `virbr-vbmc.macs` still names
node1 `52:54:00:2b:a7:7e` while `virsh domiflist node1` reports `52:54:00:09:7c:86`.
Bug class #1 — a record that outlives its subject — one layer below the note that
misdiagnosed it.

### 17.4 Two things found on the way

**dnsmasq does not refuse an unreadable `dhcp-hostsfile`.** It logs
`cannot read …: Permission denied`, starts anyway, and serves the pool to every
client — which reads exactly as "reservations do not work". It cost this test one
debugging round (dnsmasq drops privileges to `nobody`, which cannot traverse a `0700`
`mktemp -d`). §2 now fails by name on that log line, so a broken harness can never
present as a finding about dnsmasq.

**A comment is not a check.** `tests/run-all.sh` carried a note explaining that
`test-probe-nic.sh` had sat on disk in no list for weeks — addressed to whoever is
already reading, which is nobody at the moment the next test is added. The runner now
compares its list against the disk and fails naming any unlisted file. Verified by
un-listing this section's test: `FAIL: 1 test(s) exist on disk but are in no list, so
nothing runs them: test-dhcp-reservation-identity.sh`.

**Success signature for this section:** `./tests/test-dhcp-reservation-identity.sh`
ends on `PASS:` with four `note` lines, and `tests/run-all.sh` reports **every listed test ran, 0 skipped, 0 failed**. (That used to be a
hand-maintained count in five documents, one of which had drifted; §18 replaces it
with a ratio the runner derives.)

---

## 18. The safety net that 23 of 36 tests had silently disarmed (2026-08-06)

This started as a cosmetic complaint: a genuine `fail` printed **two** lines — its own
specific message, then the EXIT trap's generic *"test exited early (rc=1)"*. Mapping
where that came from found the other half, which is not cosmetic.

`tests/lib.sh` has installed the belt-and-suspenders net CLAUDE.md asks for since the
lab was written. **Bash keeps one EXIT trap per shell.** Of 36 tests:

| tests | what they did | what it cost |
|---|---|---|
| **23** | `trap 'cleanup_sandboxes' EXIT` | **replaced lib.sh's net** — a `die` inside `maas-lab.sh` slipping past the assertions ended the test with a bare rc and **no verdict line at all** |
| 11 | re-inlined the net in their own trap | the double FAIL line |
| 2 | installed no trap | correct, by accident |

The 23 are the serious ones, and they are the exact failure the rule exists to prevent
— present, and inert. `phase7-firecracker/tests/lib.sh` records finding this in its own
tests on 2026-08-02; nobody checked whether the older lab had it too.

**Neither shape was visible from any run.** A safety net is only observable when
something goes wrong, so nothing ever exercised it — the definition of an assertion
that is not known to work.

### 18.1 The fix is structural, not per-test

`lib.sh` now owns the one EXIT trap and tests register cleanup with it:

```bash
WORK="$(mktemp -d)"
on_exit 'rm -rf "$WORK"'        # evaluated at exit, so it may name a variable set later
```

`_on_exit` captures `$?` **before** running anything registered (a teardown returns 0
and would otherwise erase the status that triggered it), runs registrations in reverse,
and prints the net's line only when the rc is not 0/77 **and** no `pass`/`fail`/`skip`
already spoke — the `_VERDICT` flag, matching `phase7-firecracker` and `micro-cloud`.

### 18.2 It is now a tested thing rather than a present thing

[`tests/test-harness-net.sh`](tests/test-harness-net.sh) — five sections, and §1 makes
the structural rule enforceable instead of advisory: **no test may install its own EXIT
trap.** All four defects were re-injected and watched to bite:

| injected | what fired |
|---|---|
| a test installs `trap 'true' EXIT` | `FAIL: these tests install their own EXIT trap, which REPLACES lib.sh's safety net …: test-watch.sh` |
| `fail()` stops setting `_VERDICT` | `FAIL: REGRESSION: one failure printed 2 FAIL lines, not 1 …` |
| the net's condition removed | `FAIL: REGRESSION: a test that exited 3 with no verdict printed NO FAIL line …` |
| cleanup runs in registration order | `FAIL: cleanup ran in registration order, not reverse …` |

The second control is self-demonstrating: with `_VERDICT` broken, the meta-test's own
failure also printed twice.

### 18.3 And the count nobody could maintain

`run-all.sh` used to end on `N passed, 0 skipped, 0 failed`, which was copied by hand
into five documents and had drifted in one of them. Worse, the number said nothing
about coverage: **a runner that quietly stopped after three tests also prints a clean
`3 passed, 0 failed`.**

It now states a *ratio* and refuses the two ways it can be a lie — a listed test that
never ran, and a test file on disk that is in no list:

```console
=== summary: 37/37 listed tests ran (matching the 37 test files on disk) — 37 passed, 0 skipped, 0 failed ===
```

So the docs say *every listed test ran, 0 skipped, 0 failed* — a claim that stays true
across additions and is checkable, instead of an integer maintained in five places.
Derive the fact; don't cache it.

**Success signature for this section:** `./tests/test-harness-net.sh` ends on `PASS:`
with five `note` lines; `grep -l '^[[:space:]]*trap .*EXIT' tests/test-*.sh` prints
nothing; and `tests/run-all.sh` reports **every listed test ran, 0 skipped, 0 failed**.
