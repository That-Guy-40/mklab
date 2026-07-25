# Control Pane — watch a fleet come up (a demo of the `control-pane` runner)

Turn a lab's static node states into a **live, watchable** surface. The reusable engine +
CLI is a first-class repo tool — **[`tools/control-pane`](../../tools/control-pane)** — and
**this lab is its demo/teaching layer**: how a lab registers a fleet, watches it, and wires
it into Phase 6. The tool is **framework-free, stdlib-only** (no TUI, no deps); the Phase-6
Textual bars and the phase6b-web SSE feed are renderers over the same engine.

Design roadmap: [`CONTROL_PANE_LAB_PLAN.md`](../../CONTROL_PANE_LAB_PLAN.md).

```
   a node's console  ──►  tools/control-pane (engine)  ──►  progress
      (any stream)         pure · monotonic · no clock       (percent,label,terminal,stalled)
        rendered by:  control-pane watch  (headless CLI)
                      Phase-6 Textual ProgressBar   (the tree)
                      phase6b-web SSE feed          (the detail panel)
```

## Try it

```bash
bash examples/control-pane/demo.sh        # register a fleet, list it, watch a node finish

# or drive the tool directly:
tools/control-pane watch --profile install <console.log>          # a file / stdin / --exec
tools/control-pane list --json                                     # the fleet + live progress
tools/control-pane inspect <node>                                  # a node's milestone timeline

bash tools/tests/test-control-pane.sh     # the tool's own tests (engine + watch + list)
```

## The milestones contract (user-editable)

Profiles live in [`tools/control_pane/milestones.toml`](../../tools/control_pane/milestones.toml)
(`install` / `ramdisk` / `image`); pass your own with `--milestones`.

```toml
[[milestone.install]]  match = "Starting partitioner"  label = "partitioning"  at = 25
[[milestone.install]]  match = "login:"                label = "first boot"    at = 100  terminal = true
```

Honesty rules the [engine](../../tools/control_pane/engine.py) enforces:
- **`at` is an explicit percent** — never interpolated between markers.
- **`match` is plain regex over text** — compiled at load, **never eval**; a bad regex errors.
- **Monotonic** — a stray line matching an earlier marker never regresses progress.
- **An unmatched console** keeps its last percent — **never a fake 100%**.
- **`terminal = true`** is the only "done" signal (== a driver's "reached active").
- **`stalled`** is time-based (pass timestamps); a terminal node is never stalled.

## The reuse contract — how a lab plugs into Phase 6

A lab registers a node by dropping a `node.toml` under the control-pane state dir; Phase 6
(and the CLI) discover it there and compute live progress by running the engine over the
node's console. **No Python import** crosses a boundary — the Phase-6 backend
([`lab_tui/backends/control_pane.py`](../../phase6-tui/lab_tui/backends/control_pane.py))
**shells out to `tools/control-pane`**, exactly like the `vm`/`docker` backends shell out to
their phase scripts.

```toml
# $LAB_STATE_DIR/control-pane/<node>/node.toml
profile = "install"                 # a profile in milestones.toml
console = "/path/to/<node>.console" # the log the engine tails for progress
# milestones = "/path/to/custom.toml"   # optional; else the tool's default profiles
```

The node then appears in the Phase-6 browser tree **and** the phase6b-web inventory as a
`control-pane` resource whose `status` reflects progress (`stopped`→not started,
`running`→provisioning, `built`→terminal, `error`→stalled) and whose bar **fills live** (a
Textual `ProgressBar` in the tree; an SSE-pushed bar on the web detail panel). It's a
**read-only** source — it observes nodes it doesn't own, so `destroy` is inert.

## Files

| File | Role |
|---|---|
| [`../../tools/control-pane`](../../tools/control-pane) | the runner (executable) |
| [`../../tools/control_pane/`](../../tools/control_pane/engine.py) | the engine + `milestones.py` loader + `cli.py` + default `milestones.toml` |
| [`../../tools/tests/test-control-pane.sh`](../../tools/tests/test-control-pane.sh) | the tool's tests (engine + watch + list) |
| [`demo.sh`](demo.sh) | this lab's runnable demo (register a fleet → list → watch → inspect) |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | verified transcripts (tool + Phase-6) |

## Prereqs
Python **3.11+** (for `tomllib`). No third-party packages. The optional live-stream path
uses [`../../tools/serial-source.py`](../../tools/serial-source.py) (the fake serial
emitter): `serial-source.py --replay <boot> | control-pane watch --profile install -`.
