# phase6b-web — FastAPI + HTMX web UI for LAB_CREATE_V2

A Python 3.11+ web app that surfaces the same resources as the Phase 6 Textual
TUI (chroots, VMs, Docker/Podman containers, LXD/Incus instances) in a browser.
Designed for SSH port-forward use — run it on a lab host and open it from your
laptop. No SPA, no build step, no JS framework.

## Install

```bash
cd phase6b-web
uv sync
```

`uv sync` creates a local `.venv/` and installs everything into it, including
`lab-tui` (the shared backends from `../phase6-tui`) as an editable dependency.
Nothing is installed system-wide.

## Run

The `lab-web` command lives inside `.venv/bin/` — not on your system `PATH`.
There are three ways to invoke it:

**Option 1 — activate the venv (sticks for the shell session):**

```bash
source .venv/bin/activate
lab-web                        # http://127.0.0.1:8080
```

**Option 2 — `uv run` (no activation needed):**

```bash
uv run lab-web                 # http://127.0.0.1:8080
```

**Option 3 — direct path:**

```bash
.venv/bin/lab-web
```

All three are equivalent. Option 1 is the most convenient if you're working
interactively; option 2 is the most portable in scripts and aliases.

### Flags

```
lab-web --port 9090                    # bind on a different port
lab-web --host 0.0.0.0                 # bind all interfaces (prints a warning)
lab-web --reload                       # auto-reload on source changes (dev mode)
lab-web --help
```

### SSH port-forward recipe

Run on the lab host, open from your laptop:

```bash
# On the lab host:
source .venv/bin/activate
lab-web                        # listens on 127.0.0.1:8080 by default

# On your laptop (separate terminal):
ssh -L 8080:localhost:8080 labhost

# Then browse to:
http://localhost:8080
```

## Textual TUI via browser (`textual serve`)

The Phase 6 TUI can also be served in a browser — no Phase 6b needed:

```bash
cd ../phase6-tui
source .venv/bin/activate
lab-tui --serve                # http://localhost:8080  (WebSockets + xterm.js)
lab-tui --serve 0.0.0.0:8080  # bind all interfaces
```

This runs the full Textual keyboard-driven UI in the browser.
Phase 6b gives a more conventional point-and-click web UI; choose whichever fits.

## What you get

Two-pane layout: resource tree on the left, detail panel on the right.

- **Resource tree** — grouped by lab → backend, auto-refreshed every 10 s.
  Status pills are colour-coded (green = running, gray = stopped).
  Type tags distinguish `vm`, `container`, `pxe-install`, `netboot-vm`, `pod`, etc.
- **Detail panel** — click any row to inspect it. Shows the same output as
  `lab-*.sh inspect --json`, collapsed into a `<details>` block.
- **Log tail** — expand the "Log tail" section and click "load" to stream
  the resource's log via Server-Sent Events directly into the panel.
- **Destroy** — red button with a browser confirmation dialog; POSTs to the
  action route and swaps in the result.
- **JSON API** — `GET /api/v1/resources` returns all resources as JSON.
  `GET /docs` is the auto-generated OpenAPI UI (FastAPI).

## Architecture

```
lab_web/
  app.py              FastAPI instance, lifespan (loads backends once)
  routes/
    resources.py      GET / (full page), /partials/resources (HTMX poll),
                      /resources/{b}/{n} (detail), /api/v1/resources (JSON)
    actions.py        POST /actions/destroy/{b}/{n}
    stream.py         GET /stream/logs/{b}/{n}  (SSE log tail)
  templates/
    base.html.j2      Full-page layout, HTMX loaded from CDN
    partials/
      resources.html.j2    Resource tree tbody (polled every 10 s)
      detail_panel.html.j2 Inspect + log + console hint + destroy button
      log_tail.html.j2     SSE-connected log stream fragment
  static/
    style.css         Dark terminal-inspired theme, no external CSS framework
```

Backends are imported from `../phase6-tui/lab_tui/backends/` — the same
`BackendRunner` subclasses the Textual TUI uses, installed as an editable
path dependency so changes there are picked up immediately.

## Tests

```bash
uv run pytest -v
```

Tests use `httpx.AsyncClient` against the ASGI app directly — no live server,
no phase scripts executed. Backends are stubbed via `MagicMock`.

## Security note

`lab-web` binds to `127.0.0.1` by default and ships **no authentication**.
The intended deployment model is SSH port-forward (see above). If you pass
`--host 0.0.0.0` to expose it on the network, put it behind a reverse proxy
with authentication (nginx basic-auth, Caddy, Authelia, etc.).
