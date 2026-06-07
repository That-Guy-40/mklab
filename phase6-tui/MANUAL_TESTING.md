# Phase 6 — Manual Testing Walkthrough (v0.1)

Copy-pasteable exercise of `python -m lab_tui` against whatever
combination of Phases 1–5 your host has installed. Run top-to-bottom on
a Linux host with at least one phase's tooling available.

> **Working dir:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2/phase6-tui
> ```

## 0. Preflight

Python 3.11+ and `uv` are required. `uv` bootstraps the venv on first run.

```bash
uv sync                     # one-time; pins textual + watchfiles + pydantic
uv run lab-tui --version    # → lab-tui 0.1.0
uv run pytest -v            # 33 tests, all local fixtures (no live daemon)
```

Expected: `33 passed` on any host.

## 1. Empty-host smoke

On a machine with no lab-create resources yet, launch the TUI:

```bash
uv run python -m lab_tui
```

**Expect:**
- Browser screen opens with an empty tree (no labs yet).
- If some phase scripts' daemons aren't running (e.g., Docker not
  installed), they appear under an "unavailable backends" node instead
  of crashing the app.
- Footer shows the `r / t / l / d / q` bindings.

Press `q` to quit.

## 2. Live inventory parity

Bring up one resource in each available phase. Phase 5 (LXD/Incus) is
the easiest if you followed the Phase 5 bootstrap in
`../phase5-lxd/MANUAL_TESTING.md`:

```bash
../phase5-lxd/lab-lxd.sh up --config ../examples/lxd-examples/lxd-plain-single.toml
uv run python -m lab_tui
```

**Expect:**
- `🧪 hello-lxd` appears at the top of the tree.
- Expanded: `lxd (1)` → `shell  ● running  [instance]`
- Selecting `shell` populates the right pane with `incus config show
  --expanded` output including the `user.lab-create.*` label lines.

Tear down:

```bash
../phase5-lxd/lab-lxd.sh down --lab hello-lxd
```

## 3. Live updates

In terminal A, launch the TUI on the browser screen:

```bash
uv run python -m lab_tui
```

In terminal B, while the TUI is running:

```bash
../phase5-lxd/lab-lxd.sh up --config ../examples/lxd-examples/lxd-plain-single.toml
```

**Expect:** within ~2 seconds the TUI's tree re-renders and the new
`hello-lxd` lab appears. The `watchfiles` subscription on
`$LAB_STATE_DIR/lxd/` fires the refresh; you don't need to press `r`.

Press `r` any time to force a refresh.

## 4. Log tail

With an LXD instance running, select it in the tree and press `l`.

**Expect:** a new screen opens running `incus console --show-log <name>`
(or `--project <proj>` if the instance isn't in the default project).
Output streams in live. Press `Esc` or `q` to return.

## 5. Destroy + confirm modal

Select a resource, press `d`.

**Expect:** a modal appears with a bright-yellow warning border showing:

```
⚠ Destroy hello-lxd/shell?
Command to run:
/media/sqs/COLD_STORAGE/LAB_CREATE_V2/phase5-lxd/lab-lxd.sh destroy hello-lxd/shell --force
```

- `n` / `Esc` → cancels; tree untouched.
- `y` → runs the command, streams output into the modal's log pane,
  then closes the modal and refreshes the tree (the resource is gone).

## 6. Topology screen

```bash
uv run python -m lab_tui --topology ../examples/lab-unified-demo.toml
```

Or press `t` from the browser and type the path.

**Expect:**
- "Plan" pane shows the up-order (chroot → vm → docker → podman → lxd)
  and down-order (reverse), with commented notes where phases persist
  (`phase chroot: skipped (chroots persist)`).
- `u` — Bring up: runs each phase's `up --config` in order, streaming
  stdout into the output pane. Halts on first non-zero exit.
- `d` — Tear down: routes through the confirm modal, then runs the
  reverse sequence (only docker/podman/lxd by default; chroots + vms
  persist).

## 7. CLI-only dispatcher (no TUI)

For scripting the same plans without launching Textual:

```bash
uv run python -m lab_tui.topology up   ../examples/lab-unified-demo.toml
uv run python -m lab_tui.topology down ../examples/lab-unified-demo.toml
```

Prints the argv lines that the TUI would execute. Useful for CI.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Browser shows "unavailable backends" entries | That backend's daemon is not running (e.g. Docker not installed, Incus bootstrap not run) | Install the missing tooling; for Incus/LXD see `../phase5-lxd/MANUAL_TESTING.md §0a`. |
| Tree stays empty despite running resources | Resources were created outside lab-create (no `lab-create.tool=…` label). This is by design — the TUI only claims what it created. | Use `phase{N}-*/lab-*.sh up` to bring up resources; they'll land in the tree. |
| Log tail screen shows `[error] FileNotFoundError` | The engine CLI (e.g. `incus`) isn't on PATH for the TUI's venv. | `uv run` inherits your user PATH; verify with `uv run which incus`. |
| `uv sync` fails on Python 3.10 or earlier | Phase 6 requires 3.11+ for `tomllib`. | Install Python 3.11+ (`pyenv install 3.12` or system package). |
| Confirm modal shows a `sudo` prefix | `chroot` and `vm` destroys need root because phase 1/2 state lives under `/var/lib/lab-create` when created by root. | That's correct; approve to be prompted for your password in the terminal that launched the TUI. |
