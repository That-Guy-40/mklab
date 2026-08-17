# Phase 6 — One TUI to surface them all

## What it gives you

Read-only inventory across **every resource Phases 1–5 produce** —
chroots, VMs, docker containers, podman pods, LXD instances — in one
keyboard-driven Textual UI, **plus** a topology screen that drives a
unified `lab.toml` through all five phase scripts in dependency order.
No new provisioning logic; every mutation shells out to the existing
`lab-*.sh` script via `subprocess`, every read pulls from the state
surfaces (`$LAB_STATE_DIR/{chroots,vms,podman,lxd,fc}/` plus engine label
queries) the bash phases already maintain. **If Phase 6 is deleted,
nothing in Phases 1–5 breaks.**

## 60-second demo

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2/phase6-tui
uv sync                     # one-time: pins textual + watchfiles + pydantic
uv run python -m lab_tui    # browser screen on whatever is currently running
```

To drive the cross-phase demo through all five phases without leaving
the TUI:

```bash
uv run python -m lab_tui --topology ../examples/lab-unified-demo.toml
# press `u` to bring everything up; output streams live into the lower pane.
```

Sample browser tree once the unified demo is running:

```
🧪 demo-ctf
  chroot (1)
    demo-ctf-attacker-tools  ● built    [chroot]
  vm (1)
    demo-ctf-victim          ● running  [vm]
  docker (1)
    edge-proxy               ● running  [container]
  podman (2)
    scanner-alpine           ● running  [container]
    attacker-kali            ● running  [container]
  lxd (1)
    attacker-lxd             ● running  [instance]
```

(sample output)

## Feature tour

### The browser screen — every resource, every backend, one tree

Left pane: a tree grouped **lab → backend → resource**, each leaf
carrying a Rich-rendered status pill (green `running`, yellow
`stopped`, cyan `built`, red `missing`, bold-red `error`, dim
`unknown`). Backends whose underlying daemon isn't reachable (no
Docker, Incus daemon down, etc.) collapse into a dim "unavailable
backends" group at the bottom — the TUI stays usable instead of
crashing on the missing surface. Bindings (footer-visible always):
`r` refresh, `t` topology, `l` logs, `d` destroy, `q` / `Ctrl+C` quit.

### The detail pane — `inspect --json` from each phase

Selecting a resource fires `inspect()` on a worker thread. **All five
phases now ship `inspect --json`** (commits `6f2119e`, `00b1fb1`,
`f1caefc`, `add0e44`, `f8bd14e`), and each backend prefers the JSON
surface over the engine's raw output — pretty-printed via
`json.dumps(indent=2)`. So the LXD detail shows the schema_version=1
fold (labels, network state, project, image lineage) instead of
`incus config show --expanded`'s raw YAML; the docker detail shows
the folded-labels surface instead of `docker inspect`'s deeply nested
array. Each backend falls back to the raw engine output on non-JSON,
so older Phase deployments still render.

### Live updates — watchfiles + a 5s tick

`lab_tui/state.py` combines two sources: **`watchfiles.awatch`**
subscribes to the five filesystem-backed state dirs (`chroots/`,
`vms/`, `podman/`, `lxd/`, `fc/`) under `$LAB_STATE_DIR` — when `lab-lxd up`
writes in another terminal, the inotify event reaches the TUI within
~10 ms; and **a 5 s asyncio tick** yields `"docker"` on every fire,
because Docker is label-only and has no filesystem signal to watch.
Each yield names the backend whose surface changed; the browser
re-runs only that backend's `list_resources()`. "Redraw everything
every tick" is structurally avoided.

### The topology screen — bring-up + tear-down across every phase driver

`t` from the browser, or launch with `--topology <path>` to pre-load.
The screen parses any `lab.toml` and renders a dispatch plan:

- **Up order:** `chroot → vm → fc → docker → podman → lxd`. Phases 1 and
  2 go first because Phase 4/5 may `from_chroot` Phase 1's output and
  Phase 5 may `from_qcow2` Phase 2's. Phase 7 (`fc`) has no dependents;
  it sits beside `vm` because it is the same kind of thing — a machine
  whose disk outlives the lab. Phases 3/4/5 have no inter-phase deps.
- **Down order:** reverse — but **chroot and vm entries are skipped**,
  since those typically persist across lab tear-down (you'll reuse
  them). The plan pane surfaces this with
  `phase chroot: skipped (chroots persist)`. Phase 7 is the middle
  case: its microVMs are **stopped** (`stop <name> --force`, a verb that
  polls until the process is gone rather than trusting `kill(2)`) and
  never destroyed, because `destroy` would delete a per-instance rootfs
  copy — the same persistent state the two slots above refuse to reap.

`u` runs bring-up; stdout streams into the output pane in real time,
halting on the first non-zero exit. `d` routes through the confirm
modal and runs the tear-down.

The cross-phase routing relies on **each phase's existing `engine`
filter** — the TUI runs all relevant scripts against the same TOML and
lets each claim its own rows.

**With one exception, found by measuring the filters instead of trusting
them.** A `[[service]]` that names no `engine` is not routed by them: it
is claimed by *both*. `lab-docker.sh` skips a service only when `engine`
is **set** and is not `docker`; `lab-podman.sh` selects on
`(.engine // "podman")`. So a cross-phase bring-up created that service
**twice** — one container per engine, under a single declared identity —
and the reconcile diff below would then have found both converged. Phase
6 cannot pick a winner without contradicting whichever driver it
overrules, so it **refuses at plan time** and names the two candidates.
A spec run through one driver directly is unaffected; the ambiguity
exists only because phase 6 is the thing that runs both.

### The confirm modal — every destructive action shows the literal argv

Browser `d` (destroy a resource), topology `d` (tear down a lab) —
both route through `screens/confirm.py`. The modal renders with a
heavy yellow warning border and shows the **literal argv** that's
about to run:

```
⚠ Destroy demo-ctf/edge-proxy?
Command to run:
/media/sqs/COLD_STORAGE/LAB_CREATE_V2/phase3-docker/lab-docker.sh destroy demo-ctf/edge-proxy --force
```

`y` runs it (output streams into a `Log` widget inside the modal
before it closes); `n` / `Esc` cancels. **No keyboard bypass** — the
modal can't be skipped by holding a key down or by hitting return on
a stale focus.

### Log tail viewport

`l` on a selected resource opens `screens/logs.py`, which spawns the
backend's `log_command` as an asyncio subprocess and streams stdout
into a Textual `Log` widget. Each backend wires this differently:

| Backend | `log_command` |
|---|---|
| docker  | `docker logs --tail 200 -f <name>` |
| podman  | `podman logs --tail 200 -f <name>` (or `pod logs` for pods) |
| vm      | `tail -n 200 -F <vm-dir>/qemu.log` |
| lxd     | `incus console --show-log <name>` (`--project` if non-default) |
| chroot  | (empty — no log surface; `l` shows a notify, no screen push) |

Closing the screen cancels the worker, which SIGTERMs the tail
process and waits up to 3 s for it to drain. No leaked `tail` or
`docker logs` processes after a `q`.

### The CLI dispatcher (no TUI required)

The same topology planner exposed as a plain CLI for scripting / CI:

```bash
uv run python -m lab_tui.topology up   ../examples/lab-unified-demo.toml
uv run python -m lab_tui.topology down ../examples/lab-unified-demo.toml
```

Prints the per-phase argv lines the TUI would execute — one comment
line + one shell command per phase — without launching Textual.

### The reconcile diff — declared vs actual, issuing nothing

```bash
uv run python -m lab_tui.reconcile ../examples/lab-unified-demo.toml
```

```
  converged  chroot  base  present and built
  stopped    fc      api1  present but stopped        → would start
  absent     docker  web   declared, not present      → would create
  undeclared podman  old   running under lab 'mc' but not in this spec — reported, never removed
  unknown    lxd     c1    the lxd engine could not be queried — this row was not
                           checked, and an unchecked row is not a converged one
```

Exit **0** converged · **2** differences · **3** incomplete. `apply`'s
read-only half, built first on purpose: a reconcile loop's one hard rule
is that it must not trust its own view of the world, and that cannot be
honoured until the *"what is actually true"* half is correct alone.

**Three properties do the work, and each has a negative control in
[`tests/test_reconcile.py`](tests/test_reconcile.py):**

- **`unknown` is not `absent`.** Every backend returns `[]` when it cannot
  reach its engine (`docker.py`: `if cp.returncode != 0: return []`).
  Harmless for the browser pane; for a diff it is a lie in the most
  expensive direction — a stopped daemon reads as *"every declared service
  is missing"*, and the `apply` built on it would create duplicates of what
  is already running. So an empty list means absence **only** when
  `is_available()` confirmed the engine could be asked. An engine that
  could not be asked also does not get to report that there are no strays.
- **The declared identity is the `lab-create.svc` label, not the engine's
  name.** Phases 3/4/5 rename what they create (`lab-<lab>-<svc>`), so
  matching on the engine name yields the classic double fault: every
  declaration `absent` *and* every live container `undeclared` — two wrong
  rows that read like a real finding.
- **Strays are reported and never actioned.** Deleting what nobody declared
  is the half of a reconcile loop that destroys work.

There is **no registry** — that is [decision G](../MICRO_CLOUD_LAB_PLAN.md#84a-decision-g--settled-2026-08-16-derive-the-facts-record-only-the-intent)
in code. MAAS's `apply` opens by *grounding the registry in reality*; here
that phase is absent because it is not a phase, it is what reading the
state is.

`converged` means **exists and is up** — not that contents match the spec.
The one comparison beyond existence is `drifted`, covering the two fc
fields the manifest binds to the built instance (`tap`, `kernel`).

### `apply` — the half that issues

```bash
uv run python -m lab_tui.apply --dry-run ../examples/lab-unified-demo.toml
uv run python -m lab_tui.apply           ../examples/lab-unified-demo.toml
```

```
would issue:
  $ phase1-chroot/lab-chroot.sh   up --config mc.toml
  $ phase7-firecracker/lab-fc.sh  create --name api1 --kernel /srv/vmlinux \
                                         --rootfs /srv/api.ext4 --tap mc-api1 --lab mc
  $ phase7-firecracker/lab-fc.sh  start api1
  $ phase3-docker/lab-docker.sh   up --config mc.toml
```

A **separate module** from the diff on purpose: the read-only guarantee is
worth something only if you can see, from the import list, which file could
have broken it.

**It acts on two of the diff's six kinds and holds the rest** — and each
refusal is a decision, not an unimplemented feature:

| kind | | why |
|---|---|---|
| `absent` | **issue** | create |
| `stopped` | **issue** | start — never re-create, which would copy a rootfs the driver refuses to overwrite |
| `undeclared` | **held, and no flag changes it** | deleting what nobody declared is the half of a reconcile loop that destroys work. On this repo's ladder a stray is at worst DEGRADED; a wrong deletion is unrecoverable |
| `unknown` | **held** | issuing `create` against a row nobody could read is exactly the duplicate-creation bug the unknown/absent distinction exists to prevent — and it would do it while reporting progress |
| `drifted` | **held** | the repair is destroy-and-recreate, which deletes a per-instance rootfs copy |

**Minimum transitions, per engine.** Five drivers are declarative, so one
`up --config` converges every row they own. Phase 7 is not — it has no
`up`, and `create --config` refuses the whole file the moment one instance
exists, which is precisely the mixed state a reconcile loop is *for*. So fc
is issued **per instance**, with flags built from its block; the flag table
is checked against `lab-fc.sh`'s own `KNOWN_KEYS` by a test, because a key
added there without a line here would be silently dropped from every
`create` — the driver's own stated bug class, committed against it.

**And it is honest when it does not converge.** A pass that produces the
identical diff to the one before it stops and says *something is refusing
to progress*, rather than burning its remaining passes; a failing command
is reported with its `rc` and not re-issued as a retry; an `unknown` row
makes the whole run `INCOMPLETE` no matter how much else succeeded. The
negative control for all of that is a runner that returns 0 and changes
nothing — the shape of a driver that exits cleanly having done nothing at
all. It must report **NOT converged**, and it does.

## How the integration actually works

### Backend wrappers — one per phase, all label/state-driven

`lab_tui/backends/{chroot,vm,docker,podman,lxd,fc}.py` each define one
`BackendRunner` subclass. They wrap their phase script via
`subprocess` for mutations and read inventory from the same place the
script does — `$LAB_STATE_DIR/<backend>/` files for Phase 1/2/4/5/7,
label-filtered `docker ps … --format=json` for Phase 3.

`fc.py` (Phase 7 microVMs, added 2026-08-16 as slice 6's first increment) is the
one that does **not** copy `vm.py`'s liveness check: it requires `firecracker`
**and this instance's `config.json`** in the process's argv, because REVIEW-phase7
P7-5 measured a bare `os.kill(pid, 0)` reporting a recycled pid as running.
**Framework-agnostic — no `textual` imports anywhere in `backends/`** —
so Phase 6b can reuse the surface verbatim by lifting it into HTTP
handlers.

### `inspect --json` is the schema contract

Each phase's `inspect --json` returns a stable `schema_version: 1`
document (folded labels, live state, file/socket existence, network
reachability). The TUI never parses these — it just pretty-prints —
so the schemas can grow new fields without a TUI release. This is the
contract that lets the detail pane be backend-agnostic from Textual's
side.

### Topology dispatch order

`lab_tui/topology.py` parses the TOML, calls `phases_present()` to
find which phases the file invokes (`[[chroot]]` → Phase 1, `[[vm]]`
→ Phase 2, `[[service]] engine=docker|podman` → Phase 3/4,
`[[instance]]`/`[[project]]`/`[[profile]]` → Phase 5, `[[microvm]]` →
Phase 7), and emits a list of `PhasePlan(slot, argv, description)`.
For five of the six slots the argv is literally `<phase-script> up
--config <toml>` — Phase 6 doesn't re-implement the cross-phase shape;
it just calls the scripts in order.

**Phase 7 is the exception, and it is the interesting one.** `lab-fc.sh`
has no `up` verb and no `down --lab`: it speaks `create` (whole config)
and `start`/`stop`/`destroy`/`inspect` (one instance). Adding `fc` to
the table like the others would have produced a plan that renders
perfectly in the plan pane and dies with `unknown verb: up` on
execution, for every lab. So the `fc` slot expands to the verbs that
driver actually has:

```
Up order:
  → phase fc: create --config mc.toml (2 microvms; refuses if one already exists)
  → phase fc: start api1
  → phase fc: start api2
Down order:
  → phase fc: stop api2 --force
  → phase fc: stop api1 --force
  → phase fc: state persists (stopped, not destroyed)
```

That is [the micro-cloud plan's](../MICRO_CLOUD_LAB_PLAN.md) decision E,
shape **(b)** — *per-engine drivers, a common contract, engine-specific
verbs; the control plane speaks the intersection* — arriving exactly
where it was predicted to. Two consequences are stated in the plan pane
rather than left to be discovered: `create` refuses to overwrite an
existing instance, so a **second** `up` on a live lab halts by design;
and the tap is not the TUI's to make (`fabric.sh` owns tap lifecycle and
needs root), so `create`'s preflight refuses by name if the fabric has
not run.

`tests/test_topology.py` asks the driver instead of reading it: every
verb the planner emits is executed with no arguments and must fail for
its *own* reason, never with `unknown verb` — with `up` as the negative
control, since a driver that had lost its verb check would otherwise
pass the positive half.

### State watcher — filesystem events vs polling

The watchfiles/tick split is deliberate: file events are free (kernel
inotify) but only fire on real filesystem changes, and Docker doesn't
write to disk in any way the TUI cares about. Polling at 5 s on
Docker alone gives a soft upper bound on docker-row staleness without
paying the redraw cost on the four phases that already get
free-fast events.

### Framework-agnostic backends (Phase 6b's foundation)

Because `backends/*.py` import zero Textual symbols, Phase 6b imports
`BackendRunner` and `Resource` from this same module and puts each
runner behind a FastAPI route handler. The Pydantic `Resource` model is
JSON-serialisable out of the box — exactly the foundation the now-shipped
[`../phase6b-web/`](../phase6b-web/) web UI sits on.

## The cross-phase showcase

### A unified TOML, five engines, one bring-up

[`examples/lab-unified-demo.toml`](../examples/lab-unified-demo.toml)
is the canonical cross-phase example. **One file** describes a Kali
chroot (Phase 1), an Alpine microvm (Phase 2), an nginx edge-proxy
(Phase 3, `engine = "docker"`), a scanner pod with a sleep container
(Phase 4, `engine = "podman"`, `manager = "pod"`), a rootless Kali
container imported from the Phase 1 chroot's exported tarball
(Phase 4, `from_tarball`), and an LXD/Incus system container imported
from the same tarball (Phase 5, `engine = "lxd"`).

Each phase script reads only the blocks it owns — the `engine` filter
on `[[service]]`/`[[instance]]` rows, plus natural ownership of
`[[chroot]]`/`[[vm]]`/`[[pod]]`/`[[project]]`/`[[profile]]` — and
silently ignores the rest. The TUI's topology screen runs all five
in dep order against the same file:

```
Up order:
  → phase chroot: up --config lab-unified-demo.toml
  → phase vm:     up --config lab-unified-demo.toml
  → phase docker: up --config lab-unified-demo.toml
  → phase podman: up --config lab-unified-demo.toml
  → phase lxd:    up --config lab-unified-demo.toml
Down order:
  → phase lxd:    down --lab demo-ctf
  → phase podman: down --lab demo-ctf
  → phase docker: down --lab demo-ctf
  → phase vm:     skipped (vms persist)
  → phase chroot: skipped (chroots persist)
```

The `lab-create.lab=demo-ctf` label/manifest field ties them together
in the browser tree afterwards — one `🧪 demo-ctf` group containing
six rows across five backends. The "single pane of glass" the
phase-script architecture was designed to deliver — this is where it
becomes visible.

### The netboot lab in the TUI — busybox direct-boot pipeline

[`examples/netboot-lab.toml`](../examples/netboot-lab.toml) is a unified
cross-phase TOML for the full Debian netboot pipeline: a busybox initrd
chroot ([Phase 1](../phase1-chroot/SHOWCASE.md)), a rootless nginx server
([Phase 4](../phase4-podman/SHOWCASE.md)), and a QEMU direct-boot VM
([Phase 2](../phase2-qemu-vm/SHOWCASE.md)) — three phases, one file.

Load it in the topology screen and the TUI groups everything under one
`🌐 netboot` label:

```text
🌐 netboot
  chroot (1)
    netboot-busybox  ● built    [chroot]
  podman (1)
    http             ● running  [container]
  vm (1)
    netboot-direct   ● running  [vm]
```

Pressing `u` on the topology screen runs the phases in dependency order:

```
→ phase chroot: up --config netboot-lab.toml
→ phase podman: up --config netboot-lab.toml
→ phase vm:     up --config netboot-lab.toml
```

There is one manual step between Phase 1 and Phase 4 that the TUI cannot
automate: packaging the chroot into a cpio+gzip initrd (it requires root
and produces files outside the phase state dirs). The plan pane surfaces
this with a note in the Phase 1 output; the bash quick-start in
[`README.md`](../README.md) shows the exact commands. Once the kernel and
initrd are in `~/netboot/`, the TUI handles the rest.

The `backend = "kernel+initrd"` VM entry skips the iPXE chain entirely —
QEMU's `-kernel`/`-initrd` flags load the exported artifacts directly into
memory and jump to the kernel entry point. This makes `netboot-lab.toml`
the fastest path to validating a new initrd before wiring up the full
nginx → iPXE chain.

## Interactive surfaces (shipped)

Beyond read-only inventory + topology orchestration, v0.1 ships two
interactive surfaces built on the same `BackendRunner` foundation:

- **Five create wizards** (`n`, one per phase): each is a non-trivial
  modal TOML generator with backend-specific fields and live
  validation. (You can still author TOML in `$EDITOR` and bring it up
  via the topology screen.)
- **Console attach** (`c`): Textual-suspend → `lab-vm.sh console
  <name>` → resume on exit, for VMs with a live serial socket.

(The **Phase 6b web UI** — FastAPI + HTMX — also ships on this exact
`BackendRunner` foundation. See [`../phase6b-web/`](../phase6b-web/).)

The fixture-based suite (`uv run pytest -v` — no live daemons) gives
that "proven stable" claim its teeth.

## Where next

- [`PLAN.md` §Phase 6](../PLAN.md) — design rationale, exit criteria, the
  full v0.2 deferral list
- [`MANUAL_TESTING.md`](MANUAL_TESTING.md) — copy-paste verification walkthrough,
  preflight → live inventory → topology → destroy
- [`README.md`](README.md) — install, bindings, architecture cheat sheet
- [`examples/lab-unified-demo.toml`](../examples/lab-unified-demo.toml) — the
  cross-phase TOML the topology screen above runs against
- Sibling SHOWCASEs:
  [Phase 1 (chroots)](../phase1-chroot/SHOWCASE.md) ·
  [Phase 2 (VMs)](../phase2-qemu-vm/SHOWCASE.md) ·
  [Phase 3 (docker)](../phase3-docker/SHOWCASE.md) ·
  [Phase 4 (podman)](../phase4-podman/SHOWCASE.md) ·
  [Phase 5 (LXD/Incus)](../phase5-lxd/SHOWCASE.md)
