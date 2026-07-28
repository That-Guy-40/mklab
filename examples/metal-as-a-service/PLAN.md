# metal-as-a-service — build plan & increment ladder

The design roadmap is the repo-root [`METAL_AS_A_SERVICE_LAB_PLAN.md`](../../METAL_AS_A_SERVICE_LAB_PLAN.md).
This file tracks the **build increments** and records each one's outcome as it lands.

## Increment ladder (roadmap §9 build order)

| # | Increment | Status |
|---|---|---|
| **1** | **Fleet + registry + full state machine** (`create-fleet.sh` + `maas-lab.sh`: all transitions, `power`/`bootdev`, guarded `cleaning`, `error`/`maintenance`, `rescue`) | ✅ **DONE** — headless |
| **2** | **`inspect` RAM probe + NoCloud metadata + `milestones.toml`/`watch`** (feeds `tools/control-pane`) | ✅ **DONE** — headless |
| **3** | **`install` driver + health-gated activation + A/B rollback (§4b)** + F2 verify gate | ✅ **DONE** — headless (real install author-run) |
| **4** | **`ramdisk` driver + catalog** (RAM-INFRA / micro-linux / floppinux / busybox), signed + `imgverify` | ✅ **DONE (this increment)** — headless |
| **4a** | **chaos driver + resilience matrix** (`drivers/chaos.sh`, `chaos-run.sh`) — and the `abort`/`recheck` verbs it found were missing | ✅ **DONE (this increment)** — headless |
| **5** | **`image` driver** (dd golden whole-disk, Tier-B reuse) | ✅ **DONE (this increment)** — headless |
| **6** | **`apply` declarative reconcile (§3a)** — diff desired-vs-actual, idempotent | ✅ **DONE (this increment)** — headless |
| **7** | **Phase-6 actions panel** — declared verbs, driven through `tools/control-pane` | ✅ **DONE (this increment)** — v1 COMPLETE |

| **F1** | **`image+measured`** — the TPM-attested activation gate | ✅ **DONE** |
| **F2** | **`ramdisk`→region wiring** — a RAM node must JOIN the region to count | ✅ **DONE** |
| **F3** | **flavor/tag scheduler atop `apply`** — claims resolved by inspected facts | ✅ **DONE** |

All three documented fast-follows are now built as well.

**The ladder being all-✅ is not the same as "nothing left to prove."** The live path found
thirteen defects that the green headless suite could not see, and three gaps remain that a
*passing* run cannot reveal by construction — the on-node half of F2, the drivers that have
never met a real machine, and a BMC that answers for the wrong one. They are catalogued,
with the evidence trail and the first concrete step for each, in **[`DEFERRED.md`](DEFERRED.md)**.
Read that before concluding this lab is finished.

## The house rule this lab is built under

**Every discrete layer gets a fault-injection point, and every deploy driver gets a
test that drives the REAL driver — not the mock.** Written up in the repo's
[`CLAUDE.md`](../../CLAUDE.md) and *enforced* by
[`tests/test-chaos-matrix.sh`](tests/test-chaos-matrix.sh), which fails by name when a
declared layer has no scenario or a driver has no real-driver test. The layers:

| layer | seam | injected with |
|---|---|---|
| `driver` | `MAAS_DRIVER_DIR` | `drivers/chaos.sh` (`CHAOS_FAULT`) |
| `oob` | `MAAS_BMC` | `MOCK_BMC_FAIL` — the controller stops answering |
| `artifact` | `MAAS_IMAGES_DIR` | the signed payload vanishes after staging |
| `registry` | `MAAS_STATE` | the state store goes read-only mid-deploy |
| `process` | — | `maas-lab.sh` killed mid-transition (by PID) |

| `metadata` | `metadata-serve.sh` :8282 | no facts ever arrive at the sink |
| `console` | the node's console log | the stream `watch` and the health gates read is absent — **or recorded and never written** |
| `reconcile` | `apply` | the registry says active; the payload is dead |
| `ui` | the actions panel | a key that fires twice; a row that is stale by the time it is pressed |

All nine are covered. The last three landed with increment 6 — they were *declared*
uncovered in increment 5 rather than left implicit, so this increment started with its
chaos work already named instead of discovering it late.

## Increment 1 — outcome (2026-07-25)

**Built:** the control-plane spine, fully headless.

- `maas-lab.sh` — a **directory-tree registry** (`$MAAS_STATE/<node>/`: one small,
  atomically-written file per field + an append-only `history.log`) and the **12-state
  Ironic-faithful machine** as pure transitions. Every verb validates its precondition
  and refuses an illegal transition with a message that **names the required state**.
- **The BMC seam** (`MAAS_BMC` → `bmc.sh <node> <verb>`): `maas-lab.sh` never calls
  `ipmitool`; it shells out to [`bmc-toolkit`](../bmc-toolkit/README.md) using a
  `fleet-bmc.toml` it **regenerates from the registry on `enroll`**. Tests point the seam
  at `tests/mock-bmc.sh`, so the whole lifecycle drives with no libvirt/root.
- `create-fleet.sh` — `enroll` (headless registry population, verifiable) and `up`/`down`
  (author-run, rootful) that **wrap the sibling `virtualbmc-ipmi-lab`** (`create-node.sh`
  + `vbmc-lab.sh`) — 3 domains + one `vbmcd` hosting BMCs on 6230–6232.
- `fleet.toml` + `lib/fleet.py` — the hand-edited fleet spec (hardware + declared
  end-state for `apply`) and its stdlib TOML projector.

**Design decisions this increment:**
1. **Registry = a directory of single-value files**, not one TOML blob. Atomic writes
   (tmp + `mv`) keep `state` always readable; trivially greppable; no TOML writer in bash.
2. **One injectable seam** for every out-of-band effect. This is what makes "fully
   headless-verifiable without an install" (roadmap §9 step 1) literally true.
3. **`cleaning` never auto-wipes.** A node with a real backing disk **stays in
   `cleaning`** until the operator runs the handed-over `blkdiscard`/`dd` and re-runs
   with `--wiped`; a disk outside the lab allow-list is **refused**. F7, enforced + tested.
4. **Honest stand-ins.** `inspect` (facts) and `deploy` (boot) are transitions whose real
   mechanisms are later increments — each prints that it's state-only rather than faking
   success.

**Verified (headless, this host, 2026-07-25):** `tests/run-all.sh` → **3 passed, 0
skipped, 0 failed**; `shellcheck -S warning` clean; the generated `fleet-bmc.toml`
**round-trips through bmc-toolkit's real `registry.py`**. Transcripts in
[MANUAL_TESTING.md](MANUAL_TESTING.md).

**Author-run (handed over):** `create-fleet.sh up` / `down` (rootful libvirt + podman) —
the real IPMI round-trip through the fleet. Command + expected signature in
MANUAL_TESTING.md §2.

## Increment 2 — outcome (2026-07-25)

**Built:** hardware introspection, per-node metadata, and watchable progress — the
`manageable → available` path now carries **real schedulable facts**, and the fleet
lights up in `tools/control-pane`.

- **The inspection probe.** `probe-init.sh` is a busybox `/init` that reads
  cpus/mem/MAC from `/proc`+`/sys`, POSTs them as JSON to the metadata service, and
  powers off (`maas.node=`/`maas.md=` on the kernel cmdline give it identity + sink).
  `build-probe-initramfs.sh` packages it into a bootable, diskless initramfs
  (rootless `find | cpio | gzip`; static busybox). HTTP client = busybox
  `wget --post-data` (no curl in these images) — the sink reads the raw body, so the
  form-urlencoded content-type is a non-issue.
- **The metadata service.** `lib/metadata.py` (+ `metadata-serve.sh`) serves NoCloud
  `meta-data`/`user-data` per node (DRY fleet from one image) **and** is the
  introspection sink: `POST /facts/<node>` → atomic `facts.json` + a `facts.received`
  marker. Binds loopback (F1); refuses a POST for an un-enrolled node.
- **`inspect` gains three modes.** `--facts F` (headless inject), `--from-metadata`
  (ingest what the probe POSTed — the headless integration path), `--boot` (the REAL
  probe over the BMC: bootdev pxe → power on → await `facts.received` → power off;
  author-run). Any mode distils a **schedulable summary** (`cpus=N mem_mb=M mac=…`)
  into the registry for `show`/scheduling.
- **`watch` wires MAAS into `tools/control-pane`.** MAAS ships the milestone
  **profiles** (`milestones.toml`: `probe`/`install`/`ramdisk`/`image`); `watch`
  picks one from the node's deploy driver, **registers the node under the
  control-pane fleet dir** (`node.toml` → Phase-6 surfaces it with a live bar), and
  delegates streaming to `control-pane watch`. The engine is the repo tool, not
  MAAS-local code — one declaration drives the headless stream *and* the Phase-6 bars.

**Design decisions this increment:**
1. **Metadata sink on :8282, NOT :8181.** `:8181` is the netboot nginx (read-only
   static kernel/initrd delivery); `:8080` is SABnzbd on this host (CLAUDE.md). A
   POST-capable sink must be a separate listener — kernel/initrd off `:8181`, facts to
   `:8282`. (The port-refactor discipline: verify what the host actually uses first.)
2. **The engine stays in `tools/control-pane`.** `watch` shells out to the CLI (no
   Python import across the boundary), exactly as the plan settled — MAAS is a consumer.
3. **`probe-init.sh` has a `--emit` test seam.** The fact-gathering runs against
   `$PROC_ROOT`/`$SYS_ROOT` fixtures, so the exact `/init` that ships is unit-tested
   without a boot.

**Verified (headless, this host, 2026-07-25):** `tests/run-all.sh` → **6 passed, 0
skipped, 0 failed** (the 3 spine smokes + `test-inspect-metadata.sh`,
`test-watch.sh`, `test-probe-build.sh`). The probe's facts round-trip through a live
metadata service; `watch` drives MAAS's `milestones.toml` through the real
control-pane engine to its terminal milestone; the built initramfs contains a runnable
probe `/init`. Transcripts in MANUAL_TESTING.md §3.

**Author-run (handed over):** the real `inspect <node> --boot` (PXE-boot the probe on
a live fleet) — serve the initramfs + a kernel over `:8181`, run `metadata-serve.sh`,
then `inspect --boot`. Steps in MANUAL_TESTING.md §3c.

## Increment 3 — outcome (2026-07-25)

**Built:** `deploy` stops being a state-only stub. It is now a **pluggable, health-
gated, verify-gated activation** with **A/B rollback** — the crux of §4b.

- **Driver interface.** A driver is `drivers/<name>.sh` implementing
  `verify`/`deploy`/`health`/`describe`; `maas-lab.sh` dispatches to it (context via
  env). `install.sh` is the real driver (PXE kickstart/preseed → boot from disk;
  wraps the `virtualbmc-ipmi-lab` finale; **author-run**). `ramdisk`/`image` are
  honest not-yet (deploy names the build step). `MAAS_DRIVER_DIR` lets tests inject
  `tests/mock.sh`.
- **The health gate.** `deploying → active` is **not** "the boot command returned" —
  every driver declares a success signal and `deploy` polls it. For `install` the
  signal is the installed OS's **`login:`** on the node console — the *same* line
  `watch`'s terminal milestone renders (§5c: the terminal milestone doubles as the
  health-gate marker). Only a pass advances to `active`.
- **A/B rollback.** `current`/`previous` image slots per node. A new image that fails
  **verify or health** rolls the node back to its previous good image (**degraded but
  up**) instead of bricking; **both** slots bad → `error`; no previous → `error`.
  `deploy` is allowed from `available` (fresh) *and* `active` (A/B upgrade-in-place).
- **F2 verify gate.** `drivers/verify-lib.sh` signs/verifies payloads with **OpenSSL
  CMS** (detached, DER, `-binary -noattr`, codeSigning EKU) — the exact format
  `netboot/sign-payload.sh` produces for iPXE `imgverify`. Host-side verify is the
  deploy-time gate; iPXE's in-firmware `imgverify` is the author-run boot complement.
  A tampered image **fails verification and is never activated** (the required
  tamper→rollback drill, mirroring RAM-INFRA §13).

**Design decisions this increment:**
1. **One `gate()` = verify → deploy → health**, reused for the new image *and* the
   rollback image, so both slots are held to the same bar.
2. **Verify-fail and health-fail both trigger rollback** (worst case = "stayed on the
   previous good image", never "booted an untrusted/broken image over a working one").
   A hard `--no-verify` escape hatch exists and the test proves the gate was load-bearing.
3. **Own the F2 crypto, cite the tool.** A small self-contained `verify-lib.sh` (repo
   self-containment) in the *same* CMS format as `netboot/sign-payload.sh`, which it
   cites as the production/iPXE-side companion rather than duplicating.

**Verified (headless, this host, 2026-07-25):** `tests/run-all.sh` → **8 passed, 0
skipped, 0 failed** — added `test-deploy-rollback.sh` (healthy→active, fail→previous
degraded, both-bad→error, no-prev→error, unimplemented-driver refusal) and
`test-verify-tamper.sh` (**real OpenSSL CMS**: clean verifies, a flipped byte fails,
tampered image never activated, `--no-verify` bypass). `test-state-machine.sh`'s
deploy step now drives the real gate via the mock driver. shellcheck clean.

**Author-run (handed over):** a real `install` deploy end-to-end (PXE kickstart on a
live fleet, health = the OS `login:`). Steps + expected signature in MANUAL_TESTING §4.

## Increment 3a — the seam leak in `install.sh` (2026-07-27)

**Found while auditing what the mock driver does *not* prove.** Every deploy test
drove `tests/mock.sh`, so `drivers/install.sh` — the only shipped driver — had never
executed a single verb under test. Reading it turned up why: to decide the installer
had finished, it called **`virsh domstate`**.

That is one bug wearing two hats:

1. **It is not faithful.** There is no `virsh` for a machine in a rack. Reaching around
   the BMC into the hypervisor is a capability a real control plane does not have, so
   the driver was silently assuming its "nodes" were VMs on the same host as the
   control plane. The lab's whole claim is *one injectable seam for every out-of-band
   effect* (increment 1, decision 2) — this was a hole in it.
2. **It is untestable.** It was the one call no seam could intercept. That is exactly
   why nothing tested this driver: the honest test could not be written.

**The fix — ask the BMC, because that is what the operator would have.** A
kickstart/preseed ends in `poweroff`, so the node powering *itself* off is the
completion signal, and `chassis power status` is how you observe it out-of-band. The
driver now does two distinct waits, because they fail for different reasons and the
operator needs to know which happened:

- `await_power on` — did the machine actually come up? (BMC accepted `power on` but
  nothing powered: a dead PSU, a wedged BMC.)
- `await_power off` — did the installer run to completion?

Timing is injectable (`MAAS_POLL_INTERVAL`, `MAAS_POWERON_TIMEOUT`,
`MAAS_INSTALL_TIMEOUT`) so the real loops can be driven at test speed instead of an
install's real 20 minutes.

**`tests/mock-bmc.sh` gained real power state**, which the fix forced and which was
worth doing anyway: `power status` used to answer a hardcoded `off`. Harmless while
nothing polled it — but a driver waiting for a machine to power off would have
"succeeded" instantly, and the wait it exists to perform would have gone untested.
`MOCK_BMC_OFF_AFTER=N` makes the node power itself down on the Nth poll: the installer
finishing, on a clock the test controls.

**`tests/test-install-driver.sh`** now drives the **real** driver end to end. Its
sharpest assertion is a **refusing `virsh` stub on `PATH`** — if the leak ever returns,
the stub logs the call and the test names it. (The stub only logs and exits: a test
guarding "we never call virsh" must not be able to call it.) It also pins the boot
order (`bootdev pxe` before `bootdev disk`, and the power polls *between* them —
getting this wrong does not error, it silently installs nothing), and proves both gates
are load-bearing: an installer that never finishes must **not** be switched to
boot-from-disk, and a node that installs but never reaches `login:` must **not** reach
`active`.

**Both negative controls verified** rather than assumed: re-introducing the `virsh`
call trips the seam guard, and deleting the power-off wait trips the poll-count
assertion.

**Verified (headless, this host, 2026-07-27):** `tests/run-all.sh` → **9 passed, 0
skipped, 0 failed**; shellcheck clean.

## Increment 4 — outcome (2026-07-27)

**Built:** the `ramdisk` driver and its catalog — the control plane becomes a **single
front door to every RAM-bootable artifact in the repo**.

- **`ramdisk-catalog.toml`** — the `--image` registry: the RAM-INFRA trio
  (`anycast-dns-ram`, `cdn-edge-ram`, `package-mirror-ram`), `micro-linux-x86_64`,
  `floppinux`, and `busybox-netboot`. Each entry names the **lab that owns the
  artifact**, the **exact command that builds it**, its kernel/initrd paths, and the
  signal that means `active`. **The catalog builds nothing** — owning the builds here
  would fork six labs into a seventh copy.
- **`lib/catalog.py`** — sibling of `lib/fleet.py`: projects the catalog for bash, and
  `check` validates it. Paths are expanded in Python, so bash never eval's a string out
  of a config file. A catalog is data; the `build` field is only ever *printed*.
- **`drivers/ramdisk.sh`** — `describe` / `stage` / `verify` / `deploy` / `health`.
  `stage` is an **operator** verb (outside the 4-verb dispatch contract): it copies the
  lab's artifacts into the signed image store and signs them, and when the payload has
  not been built it refuses **with that lab's own build command**, because "file not
  found" is useless when the fix is a different lab's build.
- **`build-probe-initramfs.sh --shell`** — the same packer with an `/init` that gives
  you a shell instead of the fact-poster. That is the `busybox-netboot` payload; the
  alternative was a second near-identical script.

**Design decisions this increment:**

1. **The differences from `install` ARE the lesson, so they are the assertions.**
   A RAM deploy must **not** end with `bootdev disk` (the node netboots on *every* boot;
   pointed at its disk it would silently boot whatever a previous tenant left there),
   and must **not** wait for the node to power itself off (a RAM service never does —
   powering off *is* the failure). Both are `REGRESSION:`-guarded, and both negative
   controls were run.
2. **Health is per-image, declared in the catalog**, with three kinds: `console`
   (an ERE grepped from the node's console), `http` (curl a URL, optionally match a
   marker), `dns` (dig must return an answer). The tiny-OS payloads have no service to
   probe, so reaching a shell *is* their payload; the RAM-INFRA nodes are services, so
   answering *is* theirs. `catalog.py check` refuses an entry that declares a health
   kind without the field that kind needs — otherwise the gap surfaces on a node that
   is already booting.
3. **F2 spans both halves of the chain.** Host-side `verify` gates *before* any
   hardware is touched; the generated per-node iPXE script carries **`imgverify`** so
   the firmware re-checks at boot. Either alone is not a chain.
4. **`persistence=none` is recorded, but `cleaning` is not weakened.** The registry can
   now say *why* a RAM node's wipe is a no-op (§3's teaching contrast) — while a node's
   disk may still hold a **previous** tenant's data that this deploy simply never
   touched, so the guard stays exactly as strict.

**Verified (headless, this host, 2026-07-27):** `tests/run-all.sh` → **10 passed, 0
skipped, 0 failed**. `test-ramdisk-driver.sh` drives the real driver on a fixture
catalog (real OpenSSL CMS throughout), validates the **shipped** catalog, and then
stages + signs + verifies **every catalog entry this host has actually built** —
`micro-linux-x86_64` (13 MB kernel, 1.2 MB initramfs) does so here. Payloads this host
has not built are **reported, not failed**: building them is each lab's job.

**Author-run (handed over):** an actual RAM boot. Serve `$MAAS_NETBOOT_DIR/maas/` over
the PXE HTTP endpoint (`:8181`), bring up the fleet, and deploy — each catalog entry's
boot signature is the one its own lab documents. Steps in MANUAL_TESTING §6.

## Increment 4a — the chaos driver, and the two gaps it found (2026-07-27)

**Built:** a driver that fails on purpose, and a harness that grades how the control
plane falls.

**The ladder, which is the point.** Fallback and graceful failure are the acceptable
*intermediate* rungs; the goal is that a fault never becomes a failure at all:

| rung | meaning | |
|---|---|---|
| **ABSORBED** | the bad image was refused **before** it was deployed — the node never stopped serving | ← the goal |
| **DEGRADED** | the bad image deployed, failed, and the node fell back to its previous one | acceptable |
| **HALTED** | not serving, but it stopped **honestly** — `error`, a recorded reason, and a verb that recovers it | acceptable |
| **STRANDED** | stuck in a transient state no verb accepts | **critical** |
| **LIED / STALE** | the registry claims an image that never deployed, or that has since died with nothing re-checking | **critical** |

A run passes at **zero criticals**. The intermediate rungs are counted, not punished.

- **`drivers/chaos.sh`** — a real driver implementing the real contract, with the fault
  injected at a chosen point: `verify-fail`, `deploy-fail`, `deploy-crash` (dies with no
  message — not the same as a clean refusal), `deploy-slow`, `partial` (deploy reports
  success, the payload is broken — the step that reports success is not the step that
  would notice), `health-fail`, `health-flap` (healthy exactly once: it passes the gate
  and then dies). Faults apply **only to the targeted image**, which is what makes the
  A/B fallback observable — a fault that broke every image would send every scenario to
  `error` and the rollback path would never run.
- **Two layers, because they fail differently.** The deploy driver is one; the **BMC
  seam** is the other (`MOCK_BMC_FAIL`) — an out-of-band controller that stops answering
  mid-deploy is a different failure class from a payload that will not boot.
- **`chaos-run.sh`** — the 12-scenario matrix and the report. It attempts the recovery
  the control plane offers *before* grading, because "critical" should mean *nothing can
  be done about it*, not *the first thing I looked at was still wrong*.

### The two critical outcomes it found — and the fixes

1. **STRANDED: kill the control plane mid-deploy and the node is stuck forever.** No
   verb accepted `deploying`. `maintenance` accepted any state, so it looked like an
   escape — but `unmaintenance` restored `prior_state`, handing the node **straight back
   into `deploying`**. The strand survived a round trip through the only verb that could
   touch it. → **`abort`** takes a node out of a transient state into `error` (with a
   recorded reason) where `retry` can pick it up, and `unmaintenance` now refuses to
   restore a transient prior state. Real Ironic has the same hazard and solves it the
   same way: an explicit abort plus a conductor that reaps stranded nodes on takeover.
2. **STALE: a node that passes its gate and then dies keeps reporting `active`.** The
   activation gate is a **one-time** question, and nothing asked it again — so everything
   downstream believed a dead node. → **`recheck`** re-runs the current driver's health
   against the current image and demotes a node that no longer passes. Honest scope: this
   is a manual/cron re-check, not a continuous monitor; the continuous version is
   `apply` (§3a, increment 6), which will call it.

**Design decisions this increment:**

1. **The driver layer is the right place to inject.** Below it there is only "the command
   failed"; above it only "the operator sees an error". Everything worth being graceful
   about — does the node stay up, does the registry tell the truth, is there a verb that
   recovers it — is decided between those two points.
2. **Grade after attempting recovery.** Otherwise the harness measures how bad things
   look at the moment of failure rather than whether they can be fixed.
3. **The matrix must be provably non-vacuous.** `test-chaos-matrix.sh` asserts zero
   criticals **and** that all three acceptable rungs are occupied — a matrix that never
   broke anything is all-ABSORBED, one that breaks everything is all-HALTED, and one
   where the A/B path is dead never reaches DEGRADED. Zero criticals alone proves none
   of that.

**Verified (headless, this host, 2026-07-27):** `tests/run-all.sh` → **11 passed, 0
skipped, 0 failed**; `chaos-run.sh` → **12 scenarios: 2 absorbed, 4 degraded, 6 halted,
0 critical**. Both negative controls run: removing `abort` puts `control-plane-killed`
back to **STRANDED**; removing `recheck` puts `health-flap` back to **STALE**.

## Increment 5 — outcome (2026-07-27)

**Built:** the `image` driver — lay a **golden whole-disk image** onto a node — and,
under the house rule above, its chaos coverage at two more layers.

- **`drivers/image.sh`** routes to [`nixos-ipxe-deploy`](../nixos-ipxe-deploy/)'s
  proven **Tier B** mechanism (a deployer ramdisk netboots, `dd`s a raw whole-disk
  image, registers a UEFI boot entry). `stage --from <raw>` copies + signs; `verify` is
  the same F2 gate; `deploy` publishes the raw, netboots the deployer, **waits for the
  write to complete**, then points the node at its own disk.

**The three drivers now differ in exactly the ways their mechanisms differ**, and each
difference is a way to break a machine silently — so each is asserted:

| | `install` | `ramdisk` | `image` |
|---|---|---|---|
| completion signal | the node powers **itself** off | *never* — a RAM service stays up | a **console marker** from the deployer |
| ends with | `bootdev disk` | **nothing** (netboots every boot) | `bootdev disk` |
| persistence | full | **none** | full, and **destructive** |

**Design decisions this increment:**

1. **The completion signal is a console marker, not a power state.** A deployer ramdisk
   reboots rather than powering off, so `install`'s "wait for the chassis to go off"
   does not apply. The marker is the same line `watch` renders as the `image` profile's
   *writing image* milestone (§5c: one event, two consumers).
2. **Never point a node at a half-written disk.** If the write does not report
   completion, the driver times out and leaves the node in `error` — because booting a
   partially-written disk yields an unbootable machine **with nothing in the log to say
   why**. This is the assertion the increment exists for; its negative control was run.
3. **`persistence=full`, recorded.** This driver overwrites the whole disk, previous
   tenant included. The registry has to say so, or nothing downstream can tell an imaged
   node from a diskless one whose wipe is a no-op — the third point of §3's contrast
   (`ramdisk`=none, `install`=full, `image`=full-and-destructive).

### The bug the new chaos layers found

Adding the **registry** layer (state store goes read-only mid-deploy) immediately turned
up a critical one, and it was the worst shape yet — worse than the stranded node:

```console
$ deploy n1 --driver chaos --image bad-v2      # with $MAAS_STATE/n1 read-only
./maas-lab.sh: line 78: …/.state.tmp: Permission denied
active n1 (driver=chaos image=bad-v2, healthy)     ← printed success
$ echo $?
0                                                   ← exited 0
$ cat $MAAS_STATE/n1/image
good-v1                                             ← the registry never changed
$ grep '^deploy n1' chaos-calls.log | tail -1
deploy n1 bad-v2 current                            ← the machine really got bad-v2
```

`_write` was a bare `printf > tmp && mv` whose exit status nobody read. **The record and
the machine diverged, silently, with an exit 0** — so every later decision (the rollback
target, `recheck`, `apply`'s diff) would be made against a lie. Fixed: `_write` and
`set_state` now `die` with a specific message when the store is unwritable, because an
*unrecorded* change is worse than a *refused* one.

The grader was fixed too — it had reported this as `DEGRADED` because it only ever read
the registry. It now compares the registry against **what the driver actually deployed**,
which is the only reality check available from outside.

**Verified (headless, this host, 2026-07-27):** `tests/run-all.sh` → **12 passed, 0
skipped, 0 failed**; `chaos-run.sh` → **14 scenarios across 5 layers: 4 absorbed, 4
degraded, 6 halted, 0 critical**. Negative controls run for every new assertion:
skipping the write-completion wait trips the half-written-disk guard; dropping
`bootdev disk` trips the owns-its-disk guard; restoring the silent registry write puts
`registry-readonly` back to **LIED**; declaring a layer with no scenario, or adding a
driver with no real-driver test, each fail the house-rule guard **by name**.

**Author-run (handed over):** a real image lay-down — build a golden raw with
`nixos-ipxe-deploy/stage-deploy.sh --tier-b`, stage the deployer ramdisk under
`$MAAS_NETBOOT_DIR/maas/deployer/`, then `deploy <node> --driver image --image <name>`.

## Increment 6 — outcome (2026-07-27)

**Built:** `maas-lab.sh apply` — the declarative reconcile loop (§3a), and the three
chaos layers increment 5 had declared but not yet covered.

`apply` reads the desired end-state from `fleet.toml`, diffs it against the registry,
issues **exactly** the missing transitions, and loops to steady state. It is the
control loop every real fleet manager is built on: *state is declared, drift is
corrected, and the same command is safe to run forever.*

```console
$ ./maas-lab.sh apply fleet.toml --dry-run
  pass 1
  NODE      CURRENT                     ACTION   WHY
  n1        active (mock/v1)            deploy   running mock/v1, declared mock/v2
  n2        active (mock/v1)            -        converged
  DRY RUN: 1 transition(s) would be issued, 1 converged, 0 held
```

**Design decisions this increment:**

1. **IT DOES NOT TRUST THE REGISTRY — and that is the whole point.** A reconcile loop
   computes its actions from the record, and increment 5's registry-layer fault proved
   the record can diverge from the machine silently. A node recorded `active` whose
   payload is dead would *satisfy* its declared state, so `apply` would converge on a
   fleet that is not serving and report success. Every node claiming `active` is
   therefore re-checked against its driver's own health signal **before the diff**
   (reusing `recheck` from 4a). `--no-recheck` exists for the negative control and says
   loudly what it is giving up.
2. **Loop to steady state, not one step per run.** A pass moves each node one
   transition (`enrolled → manageable → available → active`), so a single pass is not
   convergence. `apply` repeats until a pass issues nothing, bounded by
   `MAAS_APPLY_MAX_PASSES` — a loop that never terminates would hide the stall rather
   than report it.
3. **Held states are reported, never steamrollered.** `error`, `maintenance` and the
   transient states are listed as `HELD` and left alone. A loop that runs on a timer
   must not re-drive a machine an operator is in the middle of debugging.
4. **`--dry-run` prints the plan and mutates nothing.** A plan that mutates is not a
   plan, and nobody trusts the next one.

### The three layers that came with it

- **`metadata`** — no facts ever reach the sink. `inspect --from-metadata` refuses;
  recording facts it never received would put invented hardware into the scheduler's view.
- **`console`** — the console log is absent. `watch` refuses and names it; a progress
  bar invented from a stream that is not there is worse than no bar, because the
  operator watches it and believes it.
  A **second** console scenario arrived from the field rather than from design (see
  "What the first live run found", below): the console is *recorded* and nothing writes
  to it. Strictly nastier than absent — absent fails loudly at the first `watch`, silent
  looks fully instrumented and surfaces minutes later as a health-gate timeout, having
  sent the operator after the wrong defect. `show` now flags a recorded console as
  `ABSENT` or `empty`, which is what moves it to **ABSORBED**; remove that flag and the
  scenario grades **STALE** and the run fails.
- **`reconcile`** — the registry says active, the payload is dead. `apply`'s pre-flight
  catches it (**HALTED**). With `--no-recheck` the same scenario grades **STALE** — the
  control that proves the pre-flight is load-bearing.

**Verified (headless, this host, 2026-07-27):** `tests/run-all.sh` → **13 passed, 0
skipped, 0 failed**; `chaos-run.sh` → **17 scenarios across 8 layers: 6 absorbed, 4
degraded, 7 halted, 0 critical**. `test-apply-reconcile.sh` pins the invariant (a
second run issues **0** transitions), that only the drifted node is redeployed, that a
node in maintenance is untouched, and — with `--no-recheck` — that the pre-flight is
what catches a dead-but-recorded-healthy node.

## Increment 7 — outcome (2026-07-27) — **v1 COMPLETE**

**Built:** the actions panel — and it is a *surface*, not a second CLI.

The `ui` layer was **declared in `chaos-run.sh` before a line of it was written**, so
the house-rule guard failed until it was covered. That is the practice working as
intended: the increment's fault work was scoped by the tooling rather than remembered.

- **`tools/control-pane` gains `actions` and `run`.** A node's `node.toml` may carry
  `[[action]]` entries — `key`, `label`, `argv`, and two flags. The control pane
  **deliberately does not know what any verb means**: a lab declares the exact argv, the
  panel lists and runs it. An action nobody declared is refused, and nothing executes.
- **MAAS declares its own verbs** when it registers a node. `apply` is **first** and
  marked `reconciling`; `release` is marked `destructive` and needs `--yes`.
- **Phase-6 binds `a`** → `ActionsScreen` lists what the node declared → the chosen
  action goes through the existing confirm screen. The backend passes the declarations
  through untouched.

**Design decisions this increment:**

1. **A reconcile button, not a rack of imperative ones.** A panel of `deploy`/`release`
   buttons is a remote control; a panel whose first key is `apply` **converges the
   fleet** and is safe to press twice. That distinction only became available in
   increment 6, and it matters far more on a surface where a key can auto-repeat than
   on a command line where the whole thing is typed out. The `reconciling` flag is
   carried through to consumers so a panel can tell *converges* from *repeats* before
   binding a key to it.
2. **The panel never composes a command.** Every runnable verb is declared by the lab
   that owns the node. This is what keeps §5b's invariant literally true rather than
   aspirational — and it is now **asserted mechanically**: every declared action's
   `argv[0]` must be `maas-lab.sh`, so deleting Phase 6 loses nothing that exists
   nowhere else.
3. **`destructive` is gated even though it is one keystroke away** — *because* it is.
   A key can be pressed by accident; a typed command line cannot.

### The `ui` layer's faults

| fault | why a panel has it and a shell does not | outcome |
|---|---|---|
| undeclared verb | a surface can offer what nobody sanctioned | refused; **LIED** if it ran (control verified) |
| double press | a key auto-repeats; a typed line does not | node stays `active` — `apply` converges |
| stale row | the node moved on between render and keypress | the verb's own precondition refuses it |

**Verified (headless, this host, 2026-07-27):** `tests/run-all.sh` → **13 passed**;
`chaos-run.sh` → **18 scenarios across 9 layers: 7 absorbed, 4 degraded, 7 halted, 0
critical**; `tools/tests/test-actions.sh` green; **phase6-tui 111 pytest passed**
(CI-gated). Negative control run: letting `control-pane run` execute an undeclared verb
turns the `ui` row **LIED** and fails the matrix.

**The ladder is complete.** All 7 increments of the v1 build order are done. Remaining
work is the documented fast-follows: `image+measured` (the TPM-attested activation
gate), `ramdisk`→region wiring, and a flavor/tag scheduler atop `apply`.

## Fast-follows — outcome (2026-07-28)

The three documented fast-follows, built together.

### `image+measured` — the attested activation gate

`drivers/image-measured.sh` delegates the lay-down to `image.sh` and adds the last
question: *did the machine that came up measure into the state we expected?* A node
reaches `active` only on a PCR quote that **verifies against the trusted attestation
key** and **matches the image's expected PCR policy**. Five refusals, each by name: no
quote, unsigned quote, quote signed by an untrusted key, a PCR mismatch, and a quote
that simply omits a required register.

**The refusal that matters most is at `verify`:** an image with **no** `pcrs.expected`
policy is rejected outright. Silently skipping the gate for an image with nothing to
attest against would be the worst possible failure — the node would activate unmeasured
while the driver's own name promised otherwise.

> **Honest framing, load-bearing.** The TPM here is **swtpm under QEMU**: faithful
> plumbing, **not a trust anchor**. Anything that can read the emulator's userspace can
> forge both the PCR state and the AK. This proves the *mechanism* and the *refusal
> path*, not the integrity of a machine. On real hardware the anchor is a discrete TPM
> whose EK is certified by the manufacturer, and the verifier must pin *that* chain —
> the same caveat [`../systemd261-nixos-measured-boot/`](../systemd261-nixos-measured-boot/README.md)
> states about its own spikes D/G, which is where these mechanics were proven.

### `ramdisk` → region wiring

`deploy --driver ramdisk --region R` is **not** satisfied by "the service answered". The
catalog entry declares a `region_check` (console/http/dns) and the node must pass it
*after* local health. The failure this exists to catch is the nastiest shape available:
a RAM node that is **up but never announced** passes every local check while the region
routes nothing to it — and every dashboard says healthy. An image that declares no
`region_check` **cannot be deployed into a region at all**, because the control plane
would be claiming a membership it has no way to verify.

### Flavor/tag scheduler atop `apply`

`fleet.toml` gains `[[claim]]`: declare *what* is wanted — `count`, `driver`, `image`,
`min_cpus`, `min_mem_mb`, optional `region` — and `apply` picks `available` nodes whose
**inspected facts** satisfy it. A node nobody ever inspected has no facts and is
therefore **not schedulable**, which is correct rather than a limitation: scheduling
onto hardware you have never looked at is exactly the surprise increment 2's probe
exists to prevent. An unsatisfiable claim is **reported**, not silently under-filled.

**A bug the test found, and it was a real one:** the first version counted any active
node running the claim's driver+image as satisfying it. Two claims wanting the same
image with different constraints would then collide — one would consume the other's
nodes and both would report satisfied while one was under-filled. Ownership is now
**recorded on the node** (`claim = <name>`), not inferred.

**Verified (headless, this host, 2026-07-28):** `tests/run-all.sh` → **15 passed, 0
skipped, 0 failed**; `chaos-run.sh` → 18 scenarios across 9 layers, **0 critical**.
Negative control run: removing the attestation step from `image-measured`'s health lets
a node with **no quote at all** activate, and the test says so.

## What the first live run found (2026-07-28)

The first end-to-end run of [`run-e2e.sh`](run-e2e.sh) against real libvirt domains
failed at phase 5 and again at phase 7, with two different-looking errors:

```
maas: inspect --boot: timed out after 120s with no facts from 'node1'
ramdisk: 'node1' never printed /(login:|~ #)/ within 120s (health gate FAIL)
```

Both had **one cause**, and it was not in the control plane. `setup-pxe-net.sh` serves
a single `<bootp file='boot.ipxe'/>` to the whole network with the payload baked in, so
both times the node dutifully netbooted **busybox** — not the probe, not the signed RAM
payload — reported nothing, and timed out. Everything upstream had worked: enroll, the
BMC round-trip, `provide` through `cleaning`, the F2 signing, the per-node iPXE script.
Nothing ever *fetched* that script.

The second defect only became visible once the first was understood: **nothing was
writing a console log.** In every headless test the test writes that file by hand; on a
live fleet the domains had a `pty` console, which records nothing when no one is
attached. So the run was blind, and the two failures above were indistinguishable from
each other and from a node that never powered on.

The fixes, and where each belongs:

| defect | fix | whose job |
|---|---|---|
| the network serves one payload to everyone | [`netboot-chain.sh install`](netboot-chain.sh) — chain to `maas/${hostname}.ipxe`, then MAC, then a self-explaining dead end | the lab's PXE glue |
| `${hostname}` needs a DHCP reservation | `create-fleet.sh` adds `<host mac= name=/>` per node and records the MAC | the fleet |
| `inspect --boot` never said what to boot | `_write_probe_ipxe` — a per-node script carrying `maas.node=` and `maas.md=`, and a **refusal before the BMC is touched** when the URL, the initramfs or the kernel is missing | the **control plane** |
| the console recorded nothing | file-backed serial ([`lib/console_xml.py`](lib/console_xml.py)) + `set-console` in the registry | the fleet |
| a recorded-but-silent console is invisible | `show` flags a console as `ABSENT`/`empty`; new `console-silent` chaos scenario | the control plane |

**The lesson, which is the same one increment 4a taught in a different key:** a green
headless suite proves the control plane's *decisions*, and every one of these defects
lived in a **seam the mocks stand in for** — the PXE network, the console device, the
DHCP option. The suite could not have caught them; only running it for real could. What
the suite *can* do is hold the line afterwards, which is why the probe boot script now
has [`tests/test-probe-boot-script.sh`](tests/test-probe-boot-script.sh) (five checks,
both negative controls run) and the silent console has a chaos row.

**Still author-run, still unverified:** the fixed `run-e2e.sh` has not yet completed a
live run. What is verified here is headless — `tests/run-all.sh` → **16 passed, 0
skipped, 0 failed**; `chaos-run.sh` → **19 scenarios across 9 layers: 8 absorbed, 4
degraded, 7 halted, 0 critical**; and the XML transform against a real `virsh dumpxml`
of `node1`. Whether libvirt's AppArmor policy permits qemu to write the console file at
`/var/lib/libvirt/maas-console/<node>.log` needs the rootful run to answer.

## What the SECOND live run found (2026-07-28) — the seam answered for the wrong machine

The chain and console fixes above all worked: `netboot-chain.sh` installed, the
file-backed serial was accepted by libvirt **and by AppArmor** (30 KB of kernel log on
the first real boot — the known unknown is now answered, positively), and `show`
reported the console as `empty` exactly as designed. The run still failed, and the
console being empty is what made the cause findable.

Buried in `create-fleet.sh up`'s output:

```
| Domain name | Status  | Address | Port |
| alpine-node | running | ::      | 6230 |     <-- the sibling lab's own node
| node1       | error   | ::      | 6230 |     <-- ours, could not bind
```

**Two BMCs on port 6230.** VirtualBMC registers both; only one binds; the loser sits in
`error`; and the winner answers IPMI **for both**. `alpine-node` — this lab's sibling,
whose `vbmc-lab.sh add` defaults to 6230, which is also `node1`'s port — had been
answering for `node1` all along:

| command | result | truthfully about |
|---|---|---|
| `manage node1` | `manageable node1 (BMC creds verified)` | alpine-node |
| `power node1 status` | `Chassis Power is on` | alpine-node |
| `bootdev node1 pxe` | `Set Boot Device to pxe` | alpine-node |
| `power on` | `Chassis Power Control: Up/On` | alpine-node |

Four successes, all true, none of them about node1 — which never powered on, which is
why its console stayed at zero bytes. On this lab's own ladder that is **LIED**: the
record and reality disagreed and every check said healthy. It is strictly worse than an
unreachable BMC, which fails at once and honestly.

**This was also why the FIRST run failed.** The chain and console defects were real and
had to be fixed — the console is what made this visible — but the node was never going
to boot either time.

**The control plane cannot catch this, by construction.** `MAAS_BMC` is the seam whose
entire job is to hide which machine is on the other end; a control plane that could tell
would not have a seam. So the check lives in the fleet plumbing, which still knows it is
vbmcd: [`lib/vbmc_check.py`](lib/vbmc_check.py), run by `create-fleet.sh` **before
enroll**, refusing by name — the node, the port, and the squatter.

Two smaller defects the same run surfaced, both of the "kept going after a step failed"
family:

- **The facts sink never started.** A `metadata-serve.sh` left over from the previous
  run still held `:8282`; the new one died with `OSError: Address already in use` into
  the log, and `run-e2e.sh` — having backgrounded it — carried on with a dead PID and
  blamed the probe two phases later. It now checks the process is alive and answering,
  and names the leftover holder.
- **No DHCP reservation was ever added.** `net-update add ip-dhcp-host` needs an IP
  (`Missing IP address in static host definition`); a `mac`+`name` entry is rejected.
  All three failed and the script said "already present or not addable — continuing".
  Fixed by allocating above the dynamic range from the network's own subnet, and by
  saying what was *lost* when it fails rather than "continuing".

### Named, not yet covered

`chaos-run.sh`'s `oob` layer covers a BMC that stops answering (`bmc-drop`). It does
**not** yet cover a BMC that answers *for a different machine* — the shape above. That
needs the mock BMC to actuate another node's power state on request, and it is the
highest-value chaos scenario outstanding, because it is the only one so far that passed
every gate on the way to failing.

**Verified headless (this host, 2026-07-28):** `tests/run-all.sh` → **17 passed, 0
skipped, 0 failed**; `chaos-run.sh` → **19 scenarios across 9 layers, 0 critical**.
Negative control on the new check: blinding it to other domains on the port makes
`test-bmc-binding-check.sh` fail. **Verified live:** the file-backed console writes
(30 KB on a real boot), and the DHCP failure was reproduced by hand
(`Missing IP address in static host definition`).

## What the THIRD live run found (2026-07-28) — the probe had never booted

`vbmc_check: all 3 nodes own their BMC port and are running`. The collision was gone,
and node1 **netbooted our script** — the console proves it, with the cmdline the control
plane wrote:

```
Command line: console=ttyS0 ip=dhcp maas.node=node1 maas.md=http://192.168.123.1:8282
```

The chain, the DHCP hostname, the per-node script, the file-backed console: all working.
And then:

```
Run /init as init process
Failed to execute /init (error -40)
Starting init: /bin/sh exists but couldn't execute it (error -40)
Kernel panic - not syncing: No working init found.
```

`-40` is `ELOOP`. `build-probe-initramfs.sh` symlinked **every** name in
`busybox --list` to `/bin/busybox` — and `busybox` is itself in that list, so the last
link replaced the binary with a symlink to itself. Every applet then resolved to
nothing. **The probe had never once booted**, across every run of this lab.

**Why the test said otherwise, twice over.** `test-probe-build.sh` asserted
`[[ -f "$un/bin/busybox" ]]`. `-f` *follows* symlinks — and the link is **absolute**, so
it escaped the unpack directory and resolved against the **host's** real
`/usr/bin/busybox`. The test was validating a file that had never been in the archive.
The size was a second tell nobody read: the broken artifact was **8.0K**, a real one is
**1.1M**. Now: not-a-symlink, executes, >200 KB, and `/bin/sh` resolves — asserted both
in the builder (before packing) and in the test (after unpacking). Negative control:
restore the clobbering loop, strip the builder's guards, and the test fails by name.

### …and the deploy failed for an unrelated reason the same run proved

The deploy boot left **zero bytes** on the console. Not a slow boot — nothing at all.
The run had already performed the controlled experiment: same node, same network,
minutes apart,

| script | `imgverify`? | result |
|---|---|---|
| `maas/node1.ipxe` (introspection) | no | booted, full kernel log on serial |
| `maas/node1.ipxe` (deploy) | **yes** | nothing, no output whatsoever |

A libvirt virtio NIC boots **QEMU's stock iPXE ROM**, which is built without
`IMAGE_TRUST_CMD`. `imgverify` is an unknown command, the script aborts — and that ROM
has no serial console either, so the abort message goes to VGA and the console log stays
empty. The on-node half of F2 needs a firmware that can honour it.

`run-e2e.sh` now **refuses** rather than booting into that silence, naming both ways
out: build a verifying iPXE with MAAS's CA (`netboot/build-ipxe.sh --imgverify
--certfile …`, attach via `<rom file=…/>`, then `MAAS_IPXE_TRUSTS_CA=1`), or drop the
signatures to exercise the rest of the path with the host-side gate still running.

### Named, not yet built

- **A verifying iPXE ROM for the fleet.** The builder exists (`netboot/build-ipxe.sh
  --imgverify`, proven in the RAM-infra lab); what is missing is attaching it to the
  fleet's NICs and recording the capability per node. Until then the on-node half of F2
  is **unexercised on this path** — the host-side `verify` still runs, and says so.
- **iPXE with a serial console.** The same ROM would fix the debuggability hole this run
  exposed: the chain's own `echo` lines never reach the console log, so every iPXE-level
  failure is invisible to exactly the instrument built to see it.
- **A chaos scenario for a BMC that answers for a different machine** (carried over).

**Verified headless (this host, 2026-07-28):** `tests/run-all.sh` → **17 passed, 0
skipped, 0 failed**. **Verified live:** the boot chain delivers the control plane's own
script with the right cmdline, and the console records it.

## The leftover that cost three cycles (2026-07-28)

`run-e2e.sh` backgrounds the facts sink, which holds `:8282` for the whole run. Three
runs in a row ended on a timeout and left it behind, and the next run's sink then failed
to bind. The **first** time that was silent — backgrounding a server hides its exit
status — and the blame landed on the probe two phases later. The second time the new
guard caught it, but the operator still had to go find a pid by hand.

The script's own rule — *"does not kill processes it did not start"* — is right, and did
not apply: **this one it did start, and it has the pid.** It now reaps it on `EXIT`
(and on `INT`/`TERM`, which route through `EXIT`), by the recorded PID. Everything else
— watchers, the fleet, vbmcd — is still the operator's, because the script did not start
those.

[`tests/test-e2e-reaps-sink.sh`](tests/test-e2e-reaps-sink.sh) extracts the **shipped**
`reap()` out of `run-e2e.sh` with `sed` and exercises it, rather than re-implementing it:
the recorded PID dies; an identical process that was *not* recorded **survives** (the
pkill footgun, which has already cost this repo a QEMU VM and a shell); an empty
`MD_PID` reaps nothing; and the trap does not alter the exit status — an `EXIT` trap that
swallows a failure would turn a failed live run into a passing one, the worst possible
outcome for a script whose whole job is a verdict. Both negative controls run.

## The fourth run: the driver walked past its own failure (2026-07-28)

Phase 3 failed outright:

```
qemu-img: /var/lib/libvirt/images/node1.qcow2: error while converting qcow2: Failed to get "write" lock
create-fleet: create-node node1 failed
```

`create-node.sh` rewrites the node's disk with `qemu-img convert` **before** it destroys
the domain, and node1 was still running from the previous failed run — a fleet run that
ends on a health-gate failure leaves its nodes powered on, so the *next* `up` hits this
every time. `create-fleet.sh` now stops any running fleet domain first, by name and with
the lifecycle verb, before create-node.sh touches a disk.

**But the real defect was the driver's own.** `run()` invoked each phase and never looked
at its exit status. So no domain was recreated, no console instrumented, no BMC verified,
nothing enrolled — and phases 4 through 10 ran anyway. Phase 4 then failed too (`cannot
'manage' from state 'manageable'`), was also ignored, and the run ended blaming a health
gate **eight phases downstream of the actual defect**. Two of the four live runs were
read wrong the first time because of this, including by me.

The line now drawn, and pinned by
[`tests/test-e2e-fails-fast.sh`](tests/test-e2e-fails-fast.sh):

| | | |
|---|---|---|
| `run()` | **setup** — everything after depends on it | aborts, names the step, does not paraphrase the tool's own error |
| `run_soft()` | the things **under test** (deploy, apply, watch) | continues *and says so* — their failure is the result, and aborting would throw away the state, the `apply` report and the verdict |

Making `run_soft` fatal too would be the obvious "fix" and would be wrong, so the test
asserts it stays non-fatal **and** stays visible.

One more, found while reading the log: **`--dry-run` was writing to the real run log.**
It skipped the truncation but still `tee -a`'d, so every dry run appended a ghost run to
the last real one — and a log with two interleaved runs in it is worse than no log when
you are trying to read a failure. (I did this to the user's log myself, twice, while
verifying the previous fix.)

**Verified headless:** `tests/run-all.sh` → **19 passed, 0 skipped, 0 failed**. Negative
controls: restoring the status-blind `run()`, and restoring the log-writing `--dry-run`,
each make the test fail by name.

## The fifth run: the probe measured the machine and had no wire (2026-07-28)

Setup finally held — phases 1–5 all green, the reap trap fired on the way out. Phase 6
failed, and this time the console said exactly why:

```
MAAS inspection probe: DHCP failed (continuing)
MAAS inspection probe: collected facts cpus=1 node=node1
MAAS inspection probe: FAILED to post facts to http://192.168.123.1:8282
```

The probe booted, ran, and measured the machine correctly. It had **no network device at
all** — not a down link, not a DHCP timeout: the kernel never registered an interface.

```
Unknown kernel command line parameters "ip=dhcp", will be passed to user space.
```

**The cause is the kernel, not the NIC.** The probe boots an *initramfs*, which carries
no modules, so every driver it needs must be built in. `~/netboot/kernel` is Debian
stock — `virtio_net` **and** `e1000` are both modules there. `run-e2e.sh` now stages
micro-linux's defconfig kernel as `probe-kernel` and points `MAAS_PROBE_KERNEL` at it.

Proven by booting the real probe initramfs under QEMU
([`tests/test-probe-nic.sh`](tests/test-probe-nic.sh)), which is the only kind of check
that could have caught this: a NIC model and a kernel are configured in two different
files by two different tools, and every static check on either passes — `model=virtio`
is a perfectly good NIC and the kernel is a perfectly good kernel. Only running them
together shows there is no driver between them.

**A correction, because the test's own control produced it.** The fleet now defaults to
`e1000` (`FLEET_NIC_MODEL`), and that change is **belt-and-braces, not the fix**: the
control run shows micro-linux's kernel drives virtio-net perfectly well. With the right
kernel the original virtio NIC would have worked. `e1000` is kept because it is built
into both kernels and so widens the margin, but the defect was the kernel and it would
be wrong to let the NIC take the blame.

Also fixed: `run()`'s abort message reported **`rc=0` every time** — `$?` was clobbered
by the `printf` between the failing command and the message. Captured before anything
else runs now.

**Verified headless:** `tests/run-all.sh` → **19 passed, 0 failed**. `test-probe-nic.sh`
is deliberately **not** in `run-all.sh`: it boots QEMU twice and takes ~2 minutes. Run it
directly when touching the probe, the fleet's NIC, or the probe kernel.

## The sixth run: the registry outlives the fleet (2026-07-28)

Setup went further than any previous run. Phase 3 was **fully** green for the first time:
`vbmc_check` passed all three nodes, all three consoles were recorded, and the DHCP
reservations finally landed now that they carry an IP (`node1 @ 192.168.123.101`). Then
phase 4 died:

```
maas: cannot 'manage' node 'node1' from state 'manageable' — needs one of: enrolled error
FAIL: the step above failed (rc=1)
```

**Nothing was broken.** `create-fleet.sh` rebuilds the domains but skips enrolling a node
the registry already knows (`node1 already enrolled (state=manageable) — skipping`), so
on the second run node1 arrived at phase 4 already past `enrolled`. `manage` is a
transition **from** `enrolled`/`error` — not a re-verification you can spam — and it
refused, correctly.

**This is the first finding of the six that touches the control plane at all, and it
still isn't a control-plane bug.** The state machine behaved exactly as designed and the
*harness* was wrong about it: `run-e2e.sh` assumed a fresh registry every run. The
previous five were all in the plumbing the headless suite substitutes for — a baked
`boot.ipxe`, a colliding BMC port, a self-symlinked busybox, a disk write lock, a kernel
with no NIC driver. That the live path had to get this deep before the control plane's
own logic came up at all is the most useful thing this run reported.

Phase 4's decision is now `ensure_manageable()` — hoisted into a **function** precisely
so it can be exercised without a fleet, since inlined in the phase body it could only
ever be tested by running the real thing, which is how it shipped wrong. Three cases,
which must stay distinct:

| state | what phase 4 does | why |
|---|---|---|
| `enrolled` / `error` | run `manage` | the transition it exists for |
| anything else | skip, say why, carry on | already past it; calling `manage` is an *illegal* transition, not a harmless retry |
| **no state at all** | **abort** | the node was never enrolled ⇒ phase 3 did not finish. Folding this into the skip branch is the tempting wrong fix and turns phase 4 into a silent no-op |

`power status` stays **outside** the conditional: it is the assertion that the BMC seam
answers, and hiding it behind the state check would mean a re-run never tests the seam.

**Verified headless:** [`tests/test-e2e-manage-idempotent.sh`](tests/test-e2e-manage-idempotent.sh)
`sed`s the shipped `ensure_manageable()` out of `run-e2e.sh` and drives it against a stub
control plane. `tests/run-all.sh` → **20 passed, 0 skipped, 0 failed**. Three negative
controls, each run for real: restoring the unconditional `manage`, folding the
un-enrolled case into the skip branch, and moving `power status` inside the conditional
each make the test fail by name.

## The seventh run: introspection worked, and the escape hatch was cut at the wrong seam (2026-07-28)

**Phase 6 passed.** The whole introspection path ran against a real domain for the first
time — PXE chain → the per-node script `inspect --boot` wrote → a kernel with a NIC
driver built in → DHCP → facts POSTed to the sink → power off:

```
inspected node1 (cpus=1 mem_mb=3925 mac=52:54:00:22:86:a1)
```

Every previous run's fix is load-bearing in that one line: the chain (run 1), the right
BMC (run 2), a probe initramfs that is not a symlink loop (run 3), a fleet that could be
rebuilt at all (run 4), and a kernel that has a NIC (run 5).

**Phase 8 failed, and it was my mechanism that was wrong.** F2 has two halves that read
the *same artifacts*:

| half | where | what it reads |
|---|---|---|
| host-side | `verify`, before the node is touched | `kernel.sig` / `initrd.sig` via OpenSSL CMS |
| on-node | `imgverify` in the iPXE script | **the same two files**, fetched by the firmware |

This fleet's ROM has no `IMAGE_TRUST_CMD`, so the on-node half must be skippable — and
run 3's fix skipped it by re-staging the image `--unsigned`, on the reasoning that no
signatures means no `imgverify` line. That is true, and it also disarms the half that
was supposed to keep running:

```
maas: F2 signature verification failed for image 'micro-linux-x86_64'
maas: ... and no previous image to roll back to — node 'node1' -> error
```

The deploy never reached the firmware at all. **And printed directly above it was my own
message claiming "the host-side gate still runs at `verify`"** — an assertion contradicted
by the very next line. A wrong knob is a bug; a wrong knob that narrates its own success
is the rung this lab's own chaos ladder calls **LIED**, found in the harness rather than
in anything the harness was pointed at.

**The seam that separates them is the generated boot script, not the signing step.**
`MAAS_NO_IMGVERIFY=1` omits the `imgverify` lines at the point the firmware reads them,
leaves the payload signed, and writes a comment into the script saying the check was
dropped deliberately — because a boot script that quietly lacks a line is
indistinguishable from one written before signing existed. `run-e2e.sh` takes
`E2E_NO_IMGVERIFY=1` (old name `E2E_UNSIGNED` still accepted).

`stage --unsigned` stays, with its docs corrected to say what it actually does: it
produces a genuinely unsigned image that the host-side gate **refuses**, which is how you
exercise the gate failing closed.

**Verified headless:** [`tests/test-imgverify-halves.sh`](tests/test-imgverify-halves.sh)
drives the shipped boot-script writer and asserts both halves independently — the default
arms `imgverify` for kernel *and* initrd; `MAAS_NO_IMGVERIFY=1` drops it while the
signatures survive and `ramdisk.sh verify` still passes; and the unsigned image is still
refused. `tests/run-all.sh` → **21 passed, 0 skipped, 0 failed**. Three negative controls,
each run for real: restoring the unconditional emission, making the skip delete the
signatures (the old mechanism), and putting `stage --unsigned` back into `run-e2e.sh`
each fail the test by name.

### Still not built

The on-node half of F2 remains **unexercised on this fleet**, and this run does not
change that — it makes the fact explicit rather than papering over it. Closing it needs
a verifying ROM: `netboot/build-ipxe.sh --imgverify --certfile <ca.crt>`, attached with
`<rom file=…/>` on each domain's `<interface>`, then `MAAS_IPXE_TRUSTS_CA=1`. That same
ROM would also give iPXE a serial console and close the debuggability hole that made run
3's failure a silence.

## The eighth run: the first defect in the control plane itself (2026-07-28)

**Phase 8 passed.** The deploy path ran end to end on a real domain:

```
ramdisk: 'node1' matched its console marker (active)
active node1 (driver=ramdisk image=micro-linux-x86_64, healthy)
```

Signed payload → host-side F2 gate → netbooted into RAM → health gate matched a real
console marker → `active`. Nine phases of this script now do what they say.

**Phase 9 then looked like a hang** — half an hour of no output — and was not one. Three
findings, one of them the first real control-plane bug the live path has produced.

### 1. A/B rollback rolled back the image but not the driver — CRITICAL

`fleet.toml` declares node1 as `install/almalinux9-ks`; phase 8 had just put it on
`ramdisk/micro-linux-x86_64`. So `apply` correctly issued a deploy. The install failed,
§4b rolled back to the previous image — and reused the *new* driver, because `cmd_deploy`
had already overwritten the node's driver field:

```
$ ps: drivers/install.sh deploy node1 micro-linux-x86_64 previous
```

A RAM payload handed to the installer. `install.sh` netbooted the live node and entered
`await_power off`, waiting for an installer that did not exist to power off a machine
sitting at a micro-linux login prompt — `MAAS_HEALTH_TIMEOUT × 15` = **1800s**. And the
registry recorded the result as fact:

```
driver      install
image       micro-linux-x86_64 (previous: -)
```

A pair that cannot exist, written down as though it did: the **LIED** rung of this lab's
own chaos ladder, this time inside the control plane rather than the harness.

**The rollback candidate is a PAIR, not an image.** `cmd_deploy` now captures the previous
*driver* alongside the previous image, records `previous_driver`, rolls back through the
driver that actually deployed the image, and moves the `driver` field back with it. When
the previous driver cannot be resolved it **refuses to roll back at all** and errors,
naming what is missing — a node left on a failed image is honestly broken and says so;
one driven by a driver that does not own its image is a machine nobody can reason about.
`show` now prints `driver/image` on both slots, because a view that shows only the images
hides exactly this mismatch.

**And `gate` now asks `describe <image>` before deploying.** `describe` is the contract's
ownership question and nothing was asking it. F2 could not have caught this: the image
was correctly signed — it was simply the wrong driver's image. `install.sh` answered
"yes" to every image in existence; it now refuses a payload staged as kernel+initrd+
cmdline, the triple only `ramdisk.sh stage` writes.

**Why no test caught it.** Every rollback test deployed both images with the *same*
driver, and the shared `make_image` fixture produces one generic payload with no notion
of which driver owns it. The mock could not express the mismatch, so the mismatch could
not fail — untestable and unfaithful being, as usual, the same code.
[`tests/test-rollback-driver-pair.sh`](tests/test-rollback-driver-pair.sh) introduces two
fixture drivers that each own their own images, which is the fixture that was missing.

**Verified headless:** `tests/run-all.sh` → **22 passed, 0 skipped, 0 failed**. Four
negative controls, each run for real: restoring the `$drv` reuse, dropping the driver-field
restore, making `gate` stop asking `describe`, and making `install.sh` claim every image
again — each fails the test by name.

### 2. `apply` swallows every deploy's output — named, not yet fixed

`( cmd_deploy … ) >/dev/null 2>&1`. That is why 22 minutes of a doomed 30-minute wait
produced zero bytes and read as a hang. The reasoning behind the redirection (a
per-node table, not a wall of driver logs) is sound; the fix is to tee it into the run
log rather than discard it.

### 3. The reconciliation invariant is not actually being tested — named, not yet fixed

Phase 9 runs `apply --dry-run` and then `apply`. A dry run converges nothing, so the real
run afterwards issues exactly what the dry run predicted — the "second run must issue
ZERO transitions" claim is checking a property it has not set up. It needs *real* then
*real*.

### 4. `fleet.toml` declares a spec this script cannot finish — open decision

node1 is declared `install/almalinux9-ks`: the ~30-minute Anaconda path that
`run-e2e.sh`'s own header says it deliberately avoids, and which contradicts what phase 8
deploys. Either the declaration should match the ramdisk deploy, or phase 9 should
converge a spec it can actually finish. Left open deliberately — it is a decision about
what the e2e is *for*, not a defect.

### The three follow-ups, fixed (2026-07-28)

All three came out of the same run and were named above before being fixed.

**`apply` no longer swallows what its transitions said.** Every branch was
`( cmd_x … ) >/dev/null 2>&1` followed by a paraphrase — "deploy 'node1' failed — see its
state" — so a deploy that blocked for half an hour produced *zero bytes* and read as a
hang, and when it finally failed the reason had already been discarded. One `apply_run`
helper now announces each transition **before** running it (a long one is visibly in
progress rather than indistinguishable from a wedge) and, on failure, reprints the tool's
own words indented instead of a vaguer sentence about them. Success stays quiet — the
per-node table is the deliverable. `MAAS_APPLY_LOG`, when set, additionally keeps every
transition's output, which is what a live driver points at its run log.

**The reconciliation invariant is now tested with a sequence that can fail.** Phase 9 ran
`apply --dry-run` then `apply` and called the second one "must issue ZERO transitions". A
dry run converges nothing, so the real run after it issues exactly what the dry run
predicted — the label described a property the sequence had not set up, and the check
would have passed for any `apply` at all, including one that never converges. It is now
dry (for the plan) → **real** (converge) → **real** (assert zero), with the transition
count *parsed* out of the summary rather than eyeballed, because "the fleet is converged"
is the one claim in this run a reader will nod along to without checking.

**`fleet.toml` declares what the run actually deploys.** node1 was `install/almalinux9-ks`
while phase 8 deploys `ramdisk/micro-linux-x86_64`, so pass 1 always spent itself undoing
the deploy that had just succeeded — onto the ~30-minute Anaconda install this script's
own header says it avoids, which is how the rollback bug above got its chance. A spec that
fights the run can never converge, so the invariant was unreachable regardless of the
code. The AlmaLinux path stays proven where it belongs, in
`../virtualbmc-ipmi-lab/run-finale.sh`; what `apply` is here to exercise is the reconcile
loop.

**Verified headless:** [`tests/test-apply-reports-and-converges.sh`](tests/test-apply-reports-and-converges.sh),
`tests/run-all.sh` → **23 passed, 0 skipped, 0 failed**. Five negative controls run for
real. Two of them **passed on the first attempt** and had to be fixed rather than
accepted: the quiet-on-success assertion was written against the mock driver, which exits
*silently* when it succeeds and so could not demonstrate the property either way; and the
real-then-real assertion counted `apply` lines without excluding `--dry-run`, so the old
dry-then-real sequence satisfied it. Both were assertions that would have passed forever
without testing anything — the same defect class as the invariant they were written to
protect, which is why the controls get run rather than reasoned about.

## The ninth run: a node stranded by the run before it (2026-07-28)

The eighth run was killed while `apply` was mid-deploy, which left node1 in `deploying` —
a transient state, and by design no verb accepts one. Phase 4 waved it through:

```
'node1' is already 'deploying' (registry from an earlier run) — skipping 'manage'
```

and phase 6 then failed with a message about a completely different verb:

```
maas: cannot 'inspect' node 'node1' from state 'deploying' — needs one of: manageable
```

**The control plane was right again; `ensure_manageable`'s `*)` branch was too
permissive.** "Anything that is not `enrolled`/`error`" quietly folded together two
opposite situations: a node that has legitimately *advanced past* `manage`, and a node
**stuck mid-flight** that nothing downstream can touch. Waving the second through pushes
the failure two phases away from its cause — the same defect shape as the one this branch
was originally added to fix, which is worth noticing: a permissive default that reads as
success is a pattern, not an accident.

`abort` already exists for exactly this (transient → `error`, with the reason recorded —
it came out of `chaos-run.sh` killing the control plane mid-deploy). Phase 4 now drives
`abort` → `manage`, and says loudly that it is doing so: a node stranded by the previous
run is information the operator wants, not something to paper over silently.

**The list is duplicated, so the duplication is pinned.** `run-e2e.sh` names the transient
states itself; the test asserts its list is character-for-character `maas-lab.sh`'s
`TRANSIENT_STATES`. Two hand-kept copies of one fact drift, and this drift would be
silent: a state added to the control plane and not to the driver goes straight back to
being swallowed by the permissive branch.

**Verified headless:** [`tests/test-e2e-manage-idempotent.sh`](tests/test-e2e-manage-idempotent.sh)
now covers all five transient states, asserting `abort` precedes `manage` (the order *is*
the fix — `manage` cannot accept a transient state). `tests/run-all.sh` → **23 passed, 0
skipped, 0 failed**. Three negative controls run for real: emptying the transient list,
aborting without the follow-up `manage`, and letting the two lists drift by one state —
each fails by name.

### One payload for the whole fleet, and a preflight that says so (2026-07-28)

node2 and node3 were cleared out of `error` with `retry` (a real BMC round-trip —
`error → verifying → manageable`, creds verified), and that turned out not to be enough.
They declared `busybox-netboot` and `anycast-dns-ram`, whose artifacts are built by *other*
labs and are absent on a fresh host. `apply` refused them by name — correctly; the driver
prints the build command — both nodes returned to `error`, and pass 2 could never issue
zero transitions.

**A spec the fleet cannot satisfy makes the reconciliation invariant unreachable however
right the code is.** That is the same trap node1's `install/almalinux9-ks` set, in a
quieter form: node1 converged onto something *slow*, node2/node3 converged onto *nothing
at all*. All three nodes now declare `micro-linux-x86_64`. Payload variety is what
`ramdisk-catalog.toml` and `drivers/ramdisk.sh describe` are for; neither needs a node
declared against it to be worth reading, and the comment in `fleet.toml` says how to make
the fleet heterogeneous again (build the artifacts first).

**Two checks, at the two different levels, because they are two different questions.**
"The catalog does not own this image" is a spec nobody can ever satisfy — a repo defect,
so `tests/test-apply-reports-and-converges.sh` asks the *driver* about every ramdisk node
in the spec. "The artifact is not built here" is a **host** condition, so `run-e2e.sh`'s
preflight resolves each declared image's kernel and initrd and refuses up front, naming
every missing file. Failing the headless suite for an unbuilt artifact would fail it for
the wrong thing.

The preflight also moved **above** the sudo gate: everything it checks is a config
question the operator can answer without privilege, and demanding `sudo -v` before telling
someone their spec is wrong wastes the trip.

**Found by running it, not by reasoning about it.** The first version of the artifact check
reported *every* payload missing, including one staged minutes earlier: `catalog.py`
returns paths that are absolute **or repo-relative**, and the check resolved them against
`$PWD`. It now resolves them exactly as `drivers/ramdisk.sh` does. Negative control:
declaring node3 back onto `anycast-dns-ram` fails preflight in two seconds, naming the
file.

## PASS — the whole path, on real domains (2026-07-28)

```
PASS: end-to-end on real domains — BMC round-trip, probe-reported facts, a SIGNED
payload netbooted into RAM, and apply converged. node1 is active.
```

Ten phases, nine live runs, thirteen defects. What the registry records for the passing
run — worth reading, because each line is a fix from an earlier run doing its job:

```
deploying   -> error       (abort)      the strand recovery, firing live
error       -> verifying   (manage)
verifying   -> manageable  (manage)
manageable  -> manageable  (inspect)    facts from a probe that booted and had a wire
manageable  -> cleaning    (provide)
cleaning    -> available   (provide)
available   -> deploying   (deploy)
deploying   -> active      (deploy)     signed payload, host-gated, into RAM
```

**All three nodes ended `active` on `ramdisk/micro-linux-x86_64`.** That matters more than
the verdict line: phase 9's "pass 2 issued 0 transitions" is a genuine fixed point over
the whole fleet, not two nodes being held in `error` and quietly ignored — which is what
"zero transitions" would also have looked like.

### The thirteenth defect, found by wrecking the evidence

The log was truncated *before* preflight, so a run refused at the sudo gate — or at any
preflight check — destroyed the log of the last run that **actually finished**. Found by
doing it to the passing run's log while testing a preflight check.

Same class as the `--dry-run` ghost log: the record of a completed run wrecked by a run
that never started. Preflight now writes to a scratch file, and `commit_log` hands the
real log over only once the run commits to doing work; the reap trap removes the scratch.
Both halves are pinned in [`tests/test-e2e-fails-fast.sh`](tests/test-e2e-fails-fast.sh) —
a refused run leaves the previous log byte-for-byte, **and** a committed run replaces it,
because "never truncate" would satisfy the first assertion while quietly restoring the
ghost-log bug by another route. Two negative controls, both run.

### What a green run still does NOT prove

- **The on-node half of F2 is unexercised.** This fleet's ROM has no `IMAGE_TRUST_CMD`, so
  every passing run so far skipped `imgverify` (`E2E_NO_IMGVERIFY=1`). The host-side gate
  is real; the firmware half has never run. Closing it needs
  `netboot/build-ipxe.sh --imgverify --certfile <ca.crt>` attached via `<rom file=…/>`,
  then `MAAS_IPXE_TRUSTS_CA=1`. That ROM would also give iPXE a serial console.
- **The `install` and `image` drivers never touched a real node in this run** — only
  `ramdisk` did. Their headless coverage is real but it is not this.
- **A BMC that answers for a different machine** remains the highest-value chaos scenario
  not yet written (the vbmc port collision found in run 2 was a *live* accident, not an
  injected fault).

### The tenth run: `available` was a one-way door (2026-07-28)

Re-running over the fleet the passing run left behind failed at phase 6:

```
maas: cannot 'inspect' node 'node1' from state 'active' — needs one of: manageable
```

**Two defects, one in each layer.**

**The state machine was missing an edge Ironic has.** `manage` accepted `enrolled|error`
only, so nothing led from `available` back to `manageable`: a node that had ever been
provisioned could never be inspected again. In Ironic that edge is `manage` itself — the
**unprovide** transition, the way a node is pulled back out of the free pool. It is now
accepted here too, which is the Ironic-faithful answer and not a workaround.

**And `ensure_manageable` was, for the third time, too permissive.** Its `*)` branch meant
"already advanced, carry on" — right for `manageable`, wrong for a transient state (run 9),
wrong for `available`, and wrong for `active`. Each time the run failed two phases later
with a message about a *different verb*, nowhere near the cause.

The function is now named for what it does. It drives the node to `manageable` from
wherever the last run left it — `manage` from `enrolled`/`error`/`available`, `abort` then
`manage` from a strand, `release` then `manage` from `active`/`rescue` — and **there is no
permissive default any more**: a state it cannot drive there stops the run *here*, naming
the state.

Releasing an `active` node deserves its own note, because a script that silently tears
down something believed to be serving would be a worse thing than the bug. By phase 4,
**phase 3 has already rebuilt that node's domain and disk** — so an `active` record is
stale and the machine behind it is blank. The release reconciles the record with reality;
for a ramdisk node the wipe is a documented no-op. The run says all of that out loud
before doing it.

**Three permissive-default failures in one file is a pattern, not three accidents.** The
lesson recorded here for the next person: *a default branch that means "carry on" is a
claim that every unlisted case is safe* — and in a state machine that claim is almost
never true. Enumerate what you can handle; stop on the rest.

**Verified headless:** [`tests/test-e2e-manage-idempotent.sh`](tests/test-e2e-manage-idempotent.sh)
now covers `active`/`rescue` (release → manage, in that order), `available` (manage alone —
no needless second wipe), and asserts the permissive default stays gone. It also pins the
control plane's acceptance of the unprovide edge, since two files carry one claim.
`tests/run-all.sh` → **23 passed, 0 failed**; `chaos-run.sh` → **19 scenarios, 0 critical**.
Three negative controls run for real: restoring the permissive default, skipping `active`
instead of releasing it, and dropping `available` from `manage` — each fails by name.
