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

## Not yet (next slice)
The Phase-6 Textual renderer + phase6b-web SSE feed (plan §4/§5) — those land in
`phase6-tui`/`phase6b-web` and are gated by their pytest jobs.
