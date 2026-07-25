# Control Pane — a headless-first, watchable control surface for labs

Turn a lab's static node states into a **live, watchable** surface. The core is a tiny,
**framework-free** progress engine + a `control-pane watch` CLI — **no TUI, no
dependencies** (Python stdlib only) — so any lab plugs in and *watches its fleet come up*.
The Phase-6 Textual widgets and the phase6b-web SSE feed (next slice) are just renderers
over this same engine.

Extracted from `METAL_AS_A_SERVICE_LAB_PLAN.md` §5; full design in
[`CONTROL_PANE_LAB_PLAN.md`](../../CONTROL_PANE_LAB_PLAN.md).

```
   a node's console  ──►  control_pane.Tracker(milestones[profile])  ──►  Progress
      (any stream)         pure · monotonic · no clock of its own          (percent,label,
                                                                            terminal,stalled)
        rendered by:  control-pane watch (headless CLI, shipped)
                      Phase-6 Textual ProgressBar   (next slice)
                      phase6b-web SSE feed          (next slice)
```

## Status

- ✅ **The engine** (`control_pane/engine.py`) — pure, unit-tested, no TUI/clock.
- ✅ **The `milestones.toml` loader** (`control_pane/milestones.py`) — regex, never eval;
  malformed input errors at load time.
- ✅ **`control-pane watch` / `list` / `inspect`** (`control_pane/cli.py`) — the headless
  renderer + fleet enumeration with live progress.
- ✅ **Phase-6 inventory source** — a read-only `control-pane` backend surfaces the fleet in
  **both** the Textual TUI and the phase6b-web UI (shared backend layer), progress in
  `Resource.extra` (see *Phase-6 integration* below).
- ⏳ **The progress-bar *rendering*** (a Textual `ProgressBar` + a web **SSE** progress feed)
  — the next increment (plan §4c/§5).

## Quick start

```bash
cd examples/control-pane

# watch a captured console log reach its terminal milestone (a real file, or stdin, or --exec)
./control-pane watch --profile install tests/fixtures/install-boot.console

# the live-stream path: feed a console over the wire (tools/serial-source.py is the emitter)
python3 ../../tools/serial-source.py --replay tests/fixtures/install-boot.console --once --interval 0.1 \
  | ./control-pane watch --profile install -

bash tests/run-all.sh        # engine + milestones unit tests + the watch integration
```

Progress bars stream to stderr; the final one-line verdict (`reached '…' (100%)` /
`STALLED …` / ended-without-terminal) goes to stdout — greppable for CI.

## The milestones contract (user-editable, `milestones.toml`)

```toml
[[milestone.install]]  match = "Starting partitioner"  label = "partitioning"  at = 25
[[milestone.install]]  match = "login:"                label = "first boot"    at = 100  terminal = true
```

Honesty rules the engine enforces (the whole point):
- **`at` is an explicit percent** — the engine never interpolates between markers.
- **`match` is plain regex over text** — compiled at load, **never eval**; a bad regex
  is a load-time error.
- **Monotonic** — a stray line matching an earlier marker never regresses progress.
- **An unmatched console** keeps its last percent — **never a fake 100%**.
- **`terminal = true`** is the only thing that reports "done" (== a driver's "reached
  active" health-gate signal).
- **`stalled`** is time-based and consumer-driven (pass timestamps); a terminal node is
  never stalled, and a fast file replay is never "stalled".

## The reuse contract — how a lab plugs in

A lab provides: its **nodes**, each node's **console stream** (a file / socket / command),
and a **`milestones.toml`** profile. It then gets `control-pane watch` today, and the
Phase-6 live group + web feed once those renderers land — all over the one engine.

## Phase-6 integration (the fleet contract)

A lab registers a node by dropping a `node.toml` under the control-pane state dir; Phase 6
(and the CLI) discover it there and compute live progress by running the engine over the
node's console. **No Python import** crosses the boundary — the Phase-6 backend shells out
to the `control-pane` CLI, exactly like the `vm`/`docker` backends shell out to their phase
scripts.

```toml
# $LAB_STATE_DIR/control-pane/<node>/node.toml
profile = "install"                 # a profile in milestones.toml
console = "/path/to/<node>.console" # the log the engine tails for progress
# milestones = "/path/to/custom.toml"   # optional; else the lab's milestones.toml
```

```bash
control-pane list --json      # what Phase 6 calls: [{name,profile,percent,label,terminal,stalled,console}]
control-pane inspect <node>   # the node's milestone timeline + where it is now
```

The node then appears in the Phase-6 browser tree and the phase6b-web inventory as a
`control-pane` resource whose `status` reflects progress (`stopped`→not started,
`running`→provisioning, `built`→terminal reached, `error`→stalled) and whose `extra`
carries `percent`/`label` for the (next-increment) progress bar. It's a **read-only**
source — it observes nodes it doesn't own, so `destroy` is inert.

## Files

| File | Role |
|---|---|
| [`control_pane/engine.py`](control_pane/engine.py) | the pure progress engine (`Tracker`/`Progress`) |
| [`control_pane/milestones.py`](control_pane/milestones.py) | `milestones.toml` loader + validation |
| [`control_pane/cli.py`](control_pane/cli.py) | `control-pane watch` (the headless renderer) |
| [`control-pane`](control-pane) | executable wrapper (`python3 -m` the local package) |
| [`milestones.toml`](milestones.toml) | worked `install` / `ramdisk` / `image` profiles |
| [`tests/`](tests/) | stdlib-`unittest` tests [`tests/test_engine.py`](tests/test_engine.py) + [`tests/test_milestones.py`](tests/test_milestones.py), the [`tests/test-watch.sh`](tests/test-watch.sh) integration, and [`tests/run-all.sh`](tests/run-all.sh) |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | verified transcripts |

## Prereqs
Python **3.11+** (for `tomllib`). No third-party packages. The optional live-stream path
uses [`tools/serial-source.py`](../../tools/serial-source.py) (the fake serial emitter).
