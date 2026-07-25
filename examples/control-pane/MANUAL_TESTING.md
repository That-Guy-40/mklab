# MANUAL_TESTING — control-pane

The reusable core is the repo tool [`tools/control-pane`](../../tools/control-pane); this
lab is its demo + Phase-6 integration. All headless, stdlib-only.

## The tool's own tests

```
$ bash tools/tests/test-control-pane.sh
Ran 14 tests in 0.00s — OK                # engine + milestones (stdlib unittest)
PASS: engine + milestones unit tests
PASS: control-pane watch drove install -> 'first boot' (100%) from file + stdin; unknown profile refused
PASS: control-pane list --json + inspect enumerate a fleet with live progress
==== control-pane: all green ====
```

The 14 unit tests pin the honesty rules: monotonic progress, an unmatched line is never a
fake 100%, `terminal` is the only "done", stall is time-based (deterministic via injected
timestamps); the loader rejects a bad regex / an out-of-range `at` / a missing key.

## The lab demo (`demo.sh`)

```
$ bash examples/control-pane/demo.sh
### the fleet, with live progress ###
edge1          100%  install   first boot
edge2           55%  install   base system

### watch edge1 reach its terminal milestone ###
[ 25%] [#####---------------] install: partitioning  | Starting partitioner
[ 55%] [###########---------] install: base system   | Installing the base system
[ 85%] [#################---] install: post-install  | Running post-install
[100%] [####################] install: first boot (done)  | login:
control-pane: install reached 'first boot' (100%) — done

### inspect edge2 (still mid-install) ###
now:     55%  base system
  *  25%  partitioning
  *  55%  base system
     85%  post-install
    100%  first boot  (terminal)
```

## Phase-6 integration (TUI + web + SSE)

Verified via each package's pytest (CI-gated):

```
phase6-tui:   109 passed   # incl. test_backends_control_pane.py, test_progress_bar.py,
                           #       test_control_pane_tree.py (a node → a filled bar in the tree)
phase6b-web:   44 passed   # incl. test_progress.py (inventory bar, SSE stream, detail-panel SSE, 404)
```

The `control-pane` backend shells out to `tools/control-pane`; a registered `node.toml` +
a console → a `Resource` with `extra.percent`/`label` and a progress-mapped `status`, drawn
as a live bar in **both** the Textual TUI and phase6b-web (the latter with a server-pushed
SSE feed on the detail panel). `destroy` is inert (read-only source).
