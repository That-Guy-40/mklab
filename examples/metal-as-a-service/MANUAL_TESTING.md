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
of F2 skipped; the host-side gate still runs at `verify`:

```bash
E2E_UNSIGNED=1 ./run-e2e.sh
```

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
