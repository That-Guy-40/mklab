# phase6-tui — Textual TUI for LAB_CREATE_V2

A Python 3.11+ Textual app that surfaces resources produced by Phases 1–5
and Phase 7 (chroots, VMs, docker/podman containers, LXD/Incus instances,
Firecracker microVMs) in one keyboard-driven UI, plus cross-phase topology
bring-up / tear-down.

This is **v0.1**: read-only inventory + cross-phase topology orchestration,
**plus** five per-phase create wizards (`n`) and interactive console attach
(`c`) — both shipped. The Phase 6b web UI
([`../phase6b-web/`](../phase6b-web/)) has since shipped on the same
`BackendRunner` foundation.

## Install + run

```bash
cd phase6-tui
uv sync
uv run python -m lab_tui
# or, with a pre-loaded topology:
uv run python -m lab_tui --topology ../examples/lab-unified-demo.toml
```

## Keybindings

- `r` — refresh the browser
- `t` — open the topology screen
- `l` — tail logs for the selected resource
- `d` — destroy the selected resource (routes through a confirm modal)
- `q` / `Ctrl+C` — quit

## Architecture

- `lab_tui/backends/*.py` — one `BackendRunner` per phase script. Uses
  `subprocess` for mutations, direct file reads / engine JSON for
  inventory. Framework-agnostic (no `textual` imports) so Phase 6b can
  reuse them.
- `lab_tui/screens/*.py` — Textual screens (browser, detail via the
  browser's right pane, topology, logs, confirm modal).
- `lab_tui/state.py` — `watchfiles`-based state watcher with a 5 s tick
  for docker (which has no filesystem surface).
- `lab_tui/topology.py` — parses a `lab.toml`, enumerates which phases
  it invokes, and emits an ordered list of `(script, argv)` plans. Five
  slots are one `up --config` each; the Phase 7 slot expands to that
  driver's own verbs (`create --config`, then `start <name>` per
  `[[microvm]]`), because `lab-fc.sh` has no `up` — see the module
  docstring for why that is a decision rather than an omission.
- `lab_tui/reconcile.py` — `apply`'s **read-only half**: what the spec
  declares vs what the engines actually report, issuing nothing.
  `uv run python -m lab_tui.reconcile <lab.toml>` — exit **0** converged,
  **2** differences, **3** incomplete (something could not be checked, and
  an unchecked row is not a converged one).
- `lab_tui/apply.py` — the half that **issues**, kept in a separate file so
  the import list shows which module could have broken the read-only
  guarantee. `uv run python -m lab_tui.apply [--dry-run] <lab.toml>`.
  It acts on exactly two of the diff's six kinds (`absent`, `stopped`) and
  holds the rest: `undeclared` (deleting what nobody declared is the half
  of a reconcile loop that destroys work), `unknown` (issuing against a row
  nobody could read is the duplicate-creation bug the diff exists to
  prevent), and `drifted` (the repair deletes a rootfs copy).

## Tests

```bash
uv run pytest -v
```

`tests/` is fully fixture-based — no live daemons required. Live
integration is documented in `MANUAL_TESTING.md`.
