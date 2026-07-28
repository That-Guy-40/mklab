# Metal-as-a-Service — a miniature bare-metal control plane

Treat each libvirt domain as a **node with an Ironic-faithful lifecycle**, driven
by a control plane (`maas-lab.sh`) that enrolls a fleet, verifies each node's BMC,
inspects it, cleans it between tenants, deploys an OS through a **pluggable deploy
interface**, and rescues or releases it — the shape every real metal cloud
(OpenStack **Ironic**, Canonical **MAAS**, **Tinkerbell**) is built around.

This lab **composes proven repo pieces** rather than inventing plumbing: the
out-of-band layer is [`bmc-toolkit/`](../bmc-toolkit/README.md) (which generalizes
[`virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/README.md)); the surfacing layer is
[`tools/control-pane`](../../tools/control-pane); the deploy drivers route to the
PXE-install / RAM-boot / golden-image labs. Design roadmap:
[`METAL_AS_A_SERVICE_LAB_PLAN.md`](../../METAL_AS_A_SERVICE_LAB_PLAN.md).

> **Build status — increments 1–3 of the roadmap (§9 steps 1–3).** Shipped: the
> fleet **registry** + **full state machine** + guarded `cleaning` + `rescue` (step 1);
> the **`inspect` RAM probe** + **NoCloud metadata service** + **`watch`** wiring the
> fleet into [`tools/control-pane`](../../tools/control-pane) for live progress bars
> (step 2); and the **`install` deploy driver + health-gated activation + A/B rollback
> + F2 signature gate** (step 3) — `deploy` now only reaches `active` when the image
> **verifies** (OpenSSL CMS) and passes its **health gate**, and a failing image
> **rolls back to the previous good one** instead of bricking. All **verifiable
> headlessly** (mock BMC + mock driver, real crypto; `tests/run-all.sh` → 15 passed);
> the real `install` and `inspect --boot` are author-run. Step 4 adds the **`ramdisk`
> driver + its catalog**, making the control plane a single front door to every
> RAM-bootable payload in the repo. Step 6 adds **`apply`** — the declarative reconcile loop — and step 7 the
> **actions panel**, whose first key is `apply` itself. **All 7 increments are done**, plus the three fast-follows: `image+measured`, `ramdisk`→region wiring, and a flavor/tag scheduler atop `apply`. See [PLAN.md](PLAN.md) for the ladder.

## The state machine

```
  enrolled ─manage─► verifying ─(BMC creds OK)─► manageable ◄───────────────┐
                          └─(BMC silent)─► error                            │
                                             │ inspect (schedulable facts)  │
                                             ▼                              │
   manageable ─provide─► cleaning (WIPE, guarded) ─► available              │
      available ─deploy --driver X─► deploying ─► active                    │
         active ─rescue─► rescuing ─► rescue ─unrescue─► active             │
         active ─release─► deleting ─► cleaning ─► available ───────────────┘
      (verify can fail ─► error ─retry─► …;  operator ─► maintenance ◄─► back)
```

Twelve states. Every verb **passes through** its transient state (`verifying`,
`cleaning`, `deploying`, `rescuing`, `deleting`) and records it in the node's
`history.log`, so the saga is observable — provisioning is a sequence you can
watch, not one call that either returns or hangs.

## Try it (headless — no libvirt, no root)

The whole machine drives against a **mock BMC**, so you can exercise every
transition with nothing but `bash` + `python3`:

```bash
cd examples/metal-as-a-service
export MAAS_STATE="$(mktemp -d)/maas"  MAAS_BMC="$PWD/tests/mock-bmc.sh"

./create-fleet.sh enroll                 # register the 3-node fleet from fleet.toml
./maas-lab.sh manage  node1              # verify the BMC → manageable
./maas-lab.sh inspect node1 --facts /dev/stdin <<<'{"cpus":4,"mem_kb":8192000,"mac":"52:54:00:aa:bb:01"}'
./maas-lab.sh show    node1              # note the schedulable summary (cpus=4 mem_mb=8000 …)
./maas-lab.sh provide node1              # cleaning → available
# deploy is health-gated + F2-verify-gated (real install is author-run; the mock
# driver + real-crypto rollback/tamper drills run headlessly in the test suite):
./maas-lab.sh deploy  node1 --driver install --image almalinux9-ks   # author-run (real PXE)

# watch a node's boot/install progress (delegates to tools/control-pane):
printf 'Unpacking initramfs\nMAAS inspection probe up\ncollected facts cpus=4\nfacts posted\n' > /tmp/n1.console
./maas-lab.sh watch   node1 --profile probe --console /tmp/n1.console   # live bar → terminal

bash tests/run-all.sh                    # 6 one-verdict smokes, all headless
```

## Bring up the real fleet (author-run, rootful)

`create-fleet.sh up` wraps the sibling [`virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/)
(`create-node.sh` + `vbmc-lab.sh`) to build **3 libvirt domains + one `vbmcd`
container with BMCs on 6230–6232**, then enrolls them. It needs `sudo` +
`qemu:///system` + rootful `podman` (inherited from the vbmc lab), so it is
**author-run** — see [MANUAL_TESTING.md](MANUAL_TESTING.md) for the exact handoff.
Once up, the same `maas-lab.sh` verbs drive **real** IPMI:

```bash
./create-fleet.sh up                     # rootful: domains + vbmcd + BMCs, then enroll
./netboot-chain.sh install               # rootful: point PXE at the per-node scripts
./maas-lab.sh manage node1               # real: ipmitool chassis power status via bmc.sh
./maas-lab.sh power  node1 status
./create-fleet.sh down                   # tear the fleet down
```

Or drive the whole thing once, unattended: **[`run-e2e.sh`](run-e2e.sh)** — ten phases
from `setup-pxe-net.sh` to a converged `apply`, all sudo front-loaded, `--dry-run` to
read the plan first.

### Two things a FLEET needs that a single node does not

Both were missing from the first live end-to-end run, and both failed the same way:
silently, as a timeout several minutes downstream of the actual defect.

**1. The network must ASK which payload, per node.**
[`setup-pxe-net.sh`](../virtualbmc-ipmi-lab/setup-pxe-net.sh) serves *one* `boot.ipxe`
to the whole network with the payload baked in — right for its single node, fatal here:
the per-node scripts the deploy drivers write at `<docroot>/maas/<node>.ipxe` are never
fetched, so every node netboots the same default and every gate waits for a marker that
will never appear. **[`netboot-chain.sh install`](netboot-chain.sh)** replaces the baked
script with a chain — `maas/${hostname}.ipxe` → `maas/${net0/mac}.ipxe` →
`maas/default.ipxe` — where `${hostname}` arrives via DHCP option 12 from the per-node
reservation `create-fleet.sh` adds. The last link is deliberately a **dead end that
explains itself** rather than a plausible fallback: a node quietly booting the wrong
thing looks exactly like a successful deploy.

**2. The console must be RECORDED, not attachable.**
Every health gate in this lab greps a node's console log. The sibling lab defines
`--console pty` — a terminal, which keeps nothing when no one is attached — so the first
real run was *blind*: a node that booted the wrong payload and a node that never booted
produced the identical symptom and no evidence either way. `create-fleet.sh up` now
rewrites each domain's serial to a **file** ([`lib/console_xml.py`](lib/console_xml.py))
and records the path in the registry, where the drivers already look for it.

> **The trade, stated plainly:** serial0 on a fleet node is now a log file, so
> `virsh console <node>` no longer gives you an interactive shell there. That is the
> right trade — MAAS gives you a console *log*, a file survives the power cycles the
> deploy path performs, and there is no second consumer to race (see CLAUDE.md on
> serial consoles). `FLEET_CONSOLE=pty ./create-fleet.sh up` keeps the old behaviour
> and loses every gate that reads the log.

## How the pieces connect

```
  maas-lab.sh  ──(MAAS_BMC seam)──►  bmc-toolkit/bmc.sh  ──vbmcd──► ipmitool ──► libvirt
       │                                    ▲
       │  regenerates on enroll:            └── reads MAAS's generated fleet-bmc.toml
       └─ $MAAS_STATE/fleet-bmc.toml (a bmc-toolkit registry of the fleet)
```

`maas-lab.sh` never calls `ipmitool` directly — it shells out to **`bmc.sh <node>
<verb>`** through the `MAAS_BMC` seam, using a `fleet-bmc.toml` it regenerates from
the registry on every `enroll`. That one seam is why the machine is headless: a
test points `MAAS_BMC` at [`tests/mock-bmc.sh`](tests/mock-bmc.sh) and the entire
lifecycle runs with no libvirt at all.

## Inspection, metadata & watchable progress (increment 2)

```
  bootdev=pxe ─► PROBE initramfs (probe-init.sh /init) ─wget POST facts─► metadata service (:8282)
     (kernel cmdline: maas.node=<n> maas.md=…)                                   │ writes facts.json
                                                                                 ▼
   maas-lab.sh inspect <n> --from-metadata  ──►  schedulable summary  (cpus=N mem_mb=M mac=…)

  a node's console ──► maas-lab.sh watch <n> ──► tools/control-pane (engine + milestones.toml)
                          └─ also registers $LAB_STATE_DIR/control-pane/<n>/node.toml ─► Phase-6 bar
```

- **The probe** (`probe-init.sh`, built by `build-probe-initramfs.sh`) reads
  cpus/mem/MAC from `/proc`+`/sys` and POSTs them; `inspect` distils a **schedulable
  summary** into the registry (Ironic introspection, in miniature). `inspect` has
  three modes: `--facts F` (inject), `--from-metadata` (ingest the probe's POST),
  `--boot` (real PXE probe over the BMC — author-run).
- **The metadata service** (`metadata-serve.sh`) serves NoCloud `user-data`/`meta-data`
  per node (DRY fleet from one image) and is the facts sink. It listens on **:8282** —
  a *separate* port from the netboot HTTP server on **:8181** (which is read-only
  static kernel/initrd delivery; `:8080` is SABnzbd on this host). Kernel/initrd off
  `:8181`, facts to `:8282`.
- **`watch`** picks a milestone profile from the node's deploy driver, registers the
  node under the control-pane fleet dir so **Phase-6 (TUI + web) surfaces it with a
  live bar**, and delegates streaming to `control-pane watch`. MAAS ships the
  **profiles** (`milestones.toml`); the **engine** is `tools/control-pane`.

## Deploy: pluggable drivers, health-gated activation & A/B rollback (increment 3)

```
  deploy <node> --driver X --image v2
     └─ VERIFY (F2, openssl CMS) ─► DEPLOY (driver) ─► HEALTH gate ─PASS─► active (current=v2, previous=v1)
                    │                                       └────FAIL─┐
                    └───verify FAIL──────────────────────────────────┤
                                                                      ▼ roll back to previous (v1)
                                              VERIFY ─► DEPLOY ─► HEALTH ─PASS─► active (DEGRADED, on v1)
                                                                      └────FAIL─► error (both slots bad)
```

- **`deploy` is a pluggable interface.** A driver is `drivers/<name>.sh` with
  `verify`/`deploy`/`health`/`describe`. `install.sh` PXE-installs to disk (wraps
  `virtualbmc-ipmi-lab`; **author-run**); `ramdisk.sh` netboots a payload into RAM
  from [`ramdisk-catalog.toml`](ramdisk-catalog.toml); `image` is an honest not-yet
  (`deploy` names the build step). Each driver is *mostly routing* to a lab that
  already works — the abstraction is the value.
- **`chaos-run.sh` asks the harder question: when something breaks, how gracefully does
  it fall?** `drivers/chaos.sh` injects a fault at a chosen point in the deploy path and
  the matrix grades where the node lands on a ladder — **ABSORBED** (the bad image was
  refused *before* it deployed; the node never stopped serving — the goal), **DEGRADED**
  (it deployed, failed, and the node fell back), **HALTED** (stopped honestly, with a
  verb that recovers it), and the two that are **critical**: **STRANDED** (stuck in a
  transient state no verb accepts) and **STALE/LIED** (the registry claiming something
  reality does not support). It found both criticals on its first run, which is where
  `abort` and `recheck` come from — see [PLAN.md](PLAN.md) increment 4a.
- **The `ramdisk` driver is where the contrast lives.** It must **not** end with
  `bootdev disk` (a RAM node netboots on *every* boot; pointed at its disk it would
  silently boot whatever a previous tenant left there) and must **not** wait for the
  node to power itself off (a RAM service never does — powering off *is* the failure).
  Both are asserted, with the negative controls run. Its payloads are **signed** and
  the generated per-node iPXE script carries **`imgverify`**, so F2 gates both before
  the deploy and again in the firmware.
- **The health gate.** `deploying → active` is **not** "the boot returned" — the
  driver declares a success signal and `deploy` polls it. For `install` that's the
  installed OS's **`login:`** on the node console — the *same* line `watch`'s terminal
  milestone renders (§5c). Only a pass activates.
- **A/B rollback (§4b).** A new image that fails **verify or health** rolls back to the
  node's **previous good image** (degraded-but-up) — a bad image can never take down a
  node that had a good one. Both slots bad → `error`.
- **F2 signature gate.** `drivers/verify-lib.sh` verifies payloads with **OpenSSL CMS**
  (detached DER, codeSigning EKU) — the same format
  [`netboot/sign-payload.sh`](../../netboot/sign-payload.sh) produces for iPXE
  `imgverify`. A tampered image **fails verification and is never activated** — flip one
  byte and the node stays on its previous good image (the tamper→rollback drill).

## Where the toy diverges from real Ironic/MAAS (named, not hidden)

| Real Ironic / MAAS | This lab | Why it's honest |
|---|---|---|
| Dedicated BMC hardware (iDRAC/iLO) | `vbmcd` fakes IPMI over loopback | the OOB *protocol* is real; the *hardware* is emulated (per bmc-toolkit) |
| `cleaning` wipes a real disk automatically | wipe is **handed to the operator** (F7), node waits in `cleaning` | destructive ops are never auto-run here (repo rule) |
| Introspection ramdisk reports real hardware | the busybox probe reads real `/proc`+`/sys`; `--boot` (real PXE) is author-run, `--from-metadata` proves the chain headlessly | the probe + sink + ingest are real; only the PXE boot needs the fleet |
| `deploy` writes/boots an OS + gates on health | `install` driver is real (author-run); the gate + A/B rollback + F2 verify are headless via the mock driver + real crypto | the activation logic is real & tested; only the PXE install itself needs the fleet |
| `image+measured` gates on TPM attestation | a documented fast-follow (swtpm ≠ trust anchor) | named, not faked (per the systemd261 caveat) |
| A scheduler picks nodes by inspected facts | manual verbs; `apply` reconcile = step 6 | the imperative spine lands before the declarative loop |

## Security posture (AUDIT.md)

- **F1** — BMC creds (`admin`/`password`) live on **loopback only** (`127.0.0.1:623X`).
  IPMI-over-LAN is unauthenticated by default; never point a BMC at a networked host.
- **F7** — `cleaning`'s disk wipe is **path-guarded** (lab-owned paths only) and
  **handed to the operator**, never auto-run. A diskless (ramdisk) node's clean is a
  genuine no-op — the cleanest way to show why disk-deploy needs a wipe and RAM-deploy
  doesn't.
- Processes are killed by the lifecycle verbs (`vbmc-lab.sh destroy`), never `pkill -f`.
- `vbmcd` is **rootful** (the `qemu:///system` socket is `root:libvirt`) — carried
  honestly from the vbmc lab.

## Files

| File | Role |
|---|---|
| [`maas-lab.sh`](maas-lab.sh) | the control plane — registry + state machine + verbs + BMC seam + `inspect`/`watch` |
| [`create-fleet.sh`](create-fleet.sh) | stand up (`up`, author-run) or `enroll` (headless) the fleet — incl. file-backed consoles + DHCP reservations |
| [`netboot-chain.sh`](netboot-chain.sh) | replace the PXE network's single baked payload with a per-node chain (author-run) |
| [`lib/console_xml.py`](lib/console_xml.py) | rewrite a domain's serial console from a pty to a **recorded file** |
| [`run-e2e.sh`](run-e2e.sh) | the one-shot live driver: 10 phases, real domains, real BMCs, real netboot (author-run) |
| [`fleet.toml`](fleet.toml) | the 3-node fleet spec (hardware + declared end-state for `apply`) |
| [`lib/fleet.py`](lib/fleet.py) | stdlib TOML reader projecting `fleet.toml` for bash |
| [`probe-init.sh`](probe-init.sh) | the inspection probe's busybox `/init` (gathers facts, POSTs, powers off) |
| [`build-probe-initramfs.sh`](build-probe-initramfs.sh) | package the probe into a bootable initramfs (rootless) |
| [`metadata-serve.sh`](metadata-serve.sh) + [`lib/metadata.py`](lib/metadata.py) | NoCloud user-data + the introspection facts sink (:8282) |
| [`milestones.toml`](milestones.toml) | MAAS's progress profiles (`probe`/`install`/`ramdisk`/`image`) for `watch` |
| [`drivers/install.sh`](drivers/install.sh) | the `install` deploy driver (PXE kickstart/preseed → boot from disk; author-run) |
| [`drivers/ramdisk.sh`](drivers/ramdisk.sh) | the `ramdisk` deploy driver (netboot into RAM; `stage`/`verify`/`deploy`/`health`) |
| [`drivers/image.sh`](drivers/image.sh) | the `image` deploy driver (a deployer ramdisk `dd`s a golden whole-disk image; **destructive**) |
| [`drivers/image-measured.sh`](drivers/image-measured.sh) | `image` + a **TPM attestation gate** — activates only on a signed quote matching the image's PCR policy (swtpm: mechanism, **not** a trust anchor) |
| [`drivers/chaos.sh`](drivers/chaos.sh) + [`chaos-run.sh`](chaos-run.sh) | a driver that fails on purpose, and the matrix that grades how the control plane falls across all five layers |
| [`ramdisk-catalog.toml`](ramdisk-catalog.toml) + [`lib/catalog.py`](lib/catalog.py) | the `--image` registry (RAM-INFRA trio · micro-linux · floppinux · busybox) and its validating reader |
| [`drivers/verify-lib.sh`](drivers/verify-lib.sh) | the F2 signature gate (OpenSSL CMS sign/verify, iPXE-`imgverify` format) |
| [`tests/`](tests/) | 16 headless smokes: state-machine, cleaning-guard, registry, inspect-metadata, watch, probe-build, deploy-rollback, verify-tamper, install-driver, ramdisk-driver, image-driver, image-measured-driver, apply-reconcile, region-and-scheduler, probe-boot-script, chaos-matrix (+ `mock-bmc.sh`, `mock.sh` driver, `run-all.sh`) |
| [`PLAN.md`](PLAN.md) | the increment ladder + each increment's outcome |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | verified transcripts (headless) + the author-run bring-up handoff |

## Prereqs
`bash` + **Python 3.11+** (`tomllib`) for the headless path. The real fleet
additionally needs everything [`virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/)
needs (rootful libvirt/KVM, rootful podman, `ipmitool`).
