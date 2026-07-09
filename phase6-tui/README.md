# phase6-tui — Textual TUI for LAB_CREATE_V2

A Python 3.11+ Textual app that surfaces resources produced by Phases 1–5
(chroots, VMs, docker/podman containers, LXD/Incus instances) in one
keyboard-driven UI, plus cross-phase topology bring-up / tear-down.

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
  it invokes, and emits an ordered list of `(script, argv)` plans.

## Tests

```bash
uv run pytest -v
```

`tests/` is fully fixture-based — no live daemons required. Live
integration is documented in `MANUAL_TESTING.md`.
