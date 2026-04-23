# Phase 6 — One TUI to surface them all

## What it gives you

Read-only inventory across **every resource Phases 1–5 produce** —
chroots, VMs, docker containers, podman pods, LXD instances — in one
keyboard-driven Textual UI, **plus** a topology screen that drives a
unified `lab.toml` through all five phase scripts in dependency order.
No new provisioning logic; every mutation shells out to the existing
`lab-*.sh` script via `subprocess`, every read pulls from the state
surfaces (`$LAB_STATE_DIR/{chroots,vms,podman,lxd}/` plus engine label
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
subscribes to the four filesystem-backed state dirs (`chroots/`,
`vms/`, `podman/`, `lxd/`) under `$LAB_STATE_DIR` — when `lab-lxd up`
writes in another terminal, the inotify event reaches the TUI within
~10 ms; and **a 5 s asyncio tick** yields `"docker"` on every fire,
because Docker is label-only and has no filesystem signal to watch.
Each yield names the backend whose surface changed; the browser
re-runs only that backend's `list_resources()`. "Redraw everything
every tick" is structurally avoided.

### The topology screen — bring-up + tear-down across all 5 phases

`t` from the browser, or launch with `--topology <path>` to pre-load.
The screen parses any `lab.toml` and renders a dispatch plan:

- **Up order:** `chroot → vm → docker → podman → lxd`. Phases 1 and 2
  go first because Phase 4/5 may `from_chroot` Phase 1's output and
  Phase 5 may `from_qcow2` Phase 2's. Phases 3/4/5 have no inter-phase
  deps.
- **Down order:** reverse — but **chroot and vm entries are skipped**,
  since those typically persist across lab tear-down (you'll reuse
  them). The plan pane surfaces this with
  `phase chroot: skipped (chroots persist)`.

`u` runs bring-up; stdout streams into the output pane in real time,
halting on the first non-zero exit. `d` routes through the confirm
modal and runs the tear-down.

The cross-phase routing relies entirely on **each phase's existing
`engine` filter** — the TUI runs all relevant scripts against the same
TOML and lets each claim its own rows.

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

## How the integration actually works

### Backend wrappers — one per phase, all label/state-driven

`lab_tui/backends/{chroot,vm,docker,podman,lxd}.py` each define one
`BackendRunner` subclass. They wrap their phase script via
`subprocess` for mutations and read inventory from the same place the
script does — `$LAB_STATE_DIR/<backend>/` files for Phase 1/2/4/5,
label-filtered `docker ps … --format=json` for Phase 3.
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
`[[instance]]`/`[[project]]`/`[[profile]]` → Phase 5), and emits a
list of `PhasePlan(slot, argv, description)`. The argv is literally
`<phase-script> up --config <toml>` — Phase 6 doesn't re-implement
the cross-phase shape; it just calls the scripts in order.

### State watcher — filesystem events vs polling

The watchfiles/tick split is deliberate: file events are free (kernel
inotify) but only fire on real filesystem changes, and Docker doesn't
write to disk in any way the TUI cares about. Polling at 5 s on
Docker alone gives a soft upper bound on docker-row staleness without
paying the redraw cost on the four phases that already get
free-fast events.

### Framework-agnostic backends (Phase 6b's foundation)

Because `backends/*.py` import zero Textual symbols, Phase 6b will
import `BackendRunner` and `Resource` from this same module and put
each runner behind a FastAPI route handler. The Pydantic `Resource`
model is JSON-serialisable out of the box. The web UI is deferred to
v0.2, but the foundation it'll sit on is what ships in v0.1.

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

## What's deferred to v0.2

v0.1 covers read-only inventory + topology orchestration. **Three
things are intentionally deferred** so the read-only surface could
ship and be proven first:

- **Five create wizards** (one per phase): each is a non-trivial
  modal TOML generator with backend-specific fields and live
  validation. v0.1 users author TOML in `$EDITOR` and bring it up via
  the topology screen.
- **Console attach**: Textual-suspend → `lab-vm.sh console <name>` →
  resume on exit is fiddly cross-platform. v0.1 users run `console`
  in another terminal.
- **Phase 6b web UI** (FastAPI + HTMX): blocked on the
  `BackendRunner` abstraction being proven stable in v0.1, which is
  exactly what shipped.

The 44-test fixture-based suite (`uv run pytest -v` — no live
daemons) gives that "proven stable" claim its teeth.

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
