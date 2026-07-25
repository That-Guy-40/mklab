# MANUAL_TESTING — control-pane (engine + watch slice)

Headless, no deps (stdlib only). Reproduce with `bash tests/run-all.sh`.

## Success signature

```
== unit tests: engine + milestones (python3 -m unittest) ==
Ran 14 tests in 0.001s
OK
PASS: engine + milestones unit tests
== integration: control-pane watch ==
PASS: control-pane watch drove install -> 'first boot' (100%) from file + stdin; unknown profile refused
==== control-pane: all green ====
```

## What the 14 unit tests pin (the honesty rules)

- **engine** — reaches the terminal milestone; **monotonic** (a later line matching an
  earlier marker does not regress); an **unmatched** line is never a fake 100%; the
  `advanced` flag; **stall** is time-based (deterministic via injected timestamps); a
  **terminal** node is never stalled; no clock ⇒ no stall.
- **milestones** — a valid file parses; a **bad regex**, an **`at` out of range/wrong
  type** (incl. `bool`), a **missing key**, and a **non-bool `terminal`** each raise
  `MilestoneError`; the shipped `milestones.toml` loads (`install`/`ramdisk`/`image`).

## Live watch (file input)

```
$ ./control-pane watch --profile install tests/fixtures/install-boot.console
[ 25%] [#####---------------] install: partitioning  | Starting partitioner on /dev/vda
[ 55%] [###########---------] install: base system  | Installing the base system
[ 85%] [#################---] install: post-install  | Running post-install scripts
[100%] [####################] install: first boot (done)  | almalinux login:
control-pane: install reached 'first boot' (100%) — done
```

## Live-stream path (the emitter feeds the watcher)

```
$ python3 ../../tools/serial-source.py --replay tests/fixtures/install-boot.console --once --interval 0.1 \
    | ./control-pane watch --profile install -
… (same bars) …
control-pane: install reached 'first boot' (100%) — done

$ printf 'Freeing initrd memory\nRun /init as init process\nWelcome to u-root\n/ # \n' \
    | ./control-pane watch --profile ramdisk -
[ 40%] [########------------] ramdisk: unpacking  | Freeing initrd memory
[ 80%] [################----] ramdisk: RAM userspace  | Run /init as init process
[100%] [####################] ramdisk: RAM login (done)  | / #
control-pane: ramdisk reached 'RAM login' (100%) — done
```

## Fleet enumeration (`control-pane list` / `inspect`)

```
$ LAB_STATE_DIR=$SD ./control-pane list        # $SD/control-pane/<node>/node.toml
edge1          100%  install   first boot
edge2            0%  install   waiting

$ LAB_STATE_DIR=$SD ./control-pane inspect edge1
node:    edge1
profile: install
now:     100%  first boot  [terminal]
milestones:
  *  25%  partitioning
  *  55%  base system
  *  85%  post-install
  * 100%  first boot  (terminal)
```

`tests/test-list.sh` pins `list --json` (edge1 → 100% terminal), `inspect` (the timeline),
and an unknown-node error.

## Phase-6 integration (the read-only inventory source)

The `control-pane` backend surfaces the fleet in **both** the Textual TUI and phase6b-web
(shared backend layer). Verified via each package's pytest (CI-gated):

```
phase6-tui:   103 passed     # incl. tests/test_backends_control_pane.py (4)
phase6b-web:   40 passed
```

`test_backends_control_pane.py` proves the end-to-end shell-out: a registered `node.toml`
+ a console → a `Resource` with `extra.percent`/`label` and a progress-mapped `status`
(`built` at terminal, `stopped` before start), an empty fleet → `[]`, and an **inert**
read-only `destroy_argv` (an `echo`, never a destructive verb).

## Not yet (next increment)
The progress-bar **rendering** — a Textual `ProgressBar` in the tree + a phase6b-web **SSE**
progress feed (plan §4c/§5). The inventory + progress data are already flowing; what's left
is drawing the bar.
