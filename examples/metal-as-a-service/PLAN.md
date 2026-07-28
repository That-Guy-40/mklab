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
