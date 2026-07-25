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

> **Build status — increment 1 of the roadmap (§9 step 1): the spine.** Shipped
> here: the fleet **registry** + the **full state machine** as pure transitions +
> `power`/`bootdev` passthrough + guarded `cleaning` + `error`/`maintenance` +
> `rescue`, all **verifiable headlessly** (mock BMC, no libvirt/root). The heavy
> actions — a real PXE install, the RAM inspection probe, dd-a-golden-image, the
> health-gated activation + A/B rollback — are build steps 2–5; each verb that
> stands in for one **says so** rather than pretending. See
> [PLAN.md](PLAN.md) for the increment ladder.

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
./maas-lab.sh inspect node1              # record schedulable facts (real probe = step 2)
./maas-lab.sh provide node1              # cleaning → available
./maas-lab.sh deploy  node1 --driver ramdisk --image busybox-netboot   # → active
./maas-lab.sh show    node1              # state + the full history saga

bash tests/run-all.sh                    # 3 one-verdict smokes, all headless
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
./maas-lab.sh manage node1               # real: ipmitool chassis power status via bmc.sh
./maas-lab.sh power  node1 status
./create-fleet.sh down                   # tear the fleet down
```

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

## Where the toy diverges from real Ironic/MAAS (named, not hidden)

| Real Ironic / MAAS | This lab | Why it's honest |
|---|---|---|
| Dedicated BMC hardware (iDRAC/iLO) | `vbmcd` fakes IPMI over loopback | the OOB *protocol* is real; the *hardware* is emulated (per bmc-toolkit) |
| `cleaning` wipes a real disk automatically | wipe is **handed to the operator** (F7), node waits in `cleaning` | destructive ops are never auto-run here (repo rule) |
| Introspection ramdisk reports real hardware | `inspect` records injected/`pending` facts (real probe = step 2) | the transition is faithful; the probe lands next increment |
| `deploy` actually writes/boots an OS | increment 1 is a **state-only** transition | the drivers (steps 3–5) do the real boot; deploy says so |
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
| [`maas-lab.sh`](maas-lab.sh) | the control plane — registry + state machine + verbs + BMC seam |
| [`create-fleet.sh`](create-fleet.sh) | stand up (`up`, author-run) or `enroll` (headless) the fleet |
| [`fleet.toml`](fleet.toml) | the 3-node fleet spec (hardware + declared end-state for `apply`) |
| [`lib/fleet.py`](lib/fleet.py) | stdlib TOML reader projecting `fleet.toml` for bash |
| [`tests/`](tests/) | 3 headless smokes: `test-state-machine.sh`, `test-cleaning-guard.sh`, `test-registry.sh` (+ `mock-bmc.sh`, `run-all.sh`) |
| [`PLAN.md`](PLAN.md) | the increment ladder + increment-1 outcomes |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | verified transcripts (headless) + the author-run bring-up handoff |

## Prereqs
`bash` + **Python 3.11+** (`tomllib`) for the headless path. The real fleet
additionally needs everything [`virtualbmc-ipmi-lab/`](../virtualbmc-ipmi-lab/)
needs (rootful libvirt/KVM, rootful podman, `ipmitool`).
