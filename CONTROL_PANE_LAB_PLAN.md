# Control Pane Lab — a live, watchable control surface for Phase 6 — Design Plan v1

> **Status**: Draft v1 — proposed 2026-07-24. **Extracted from
> `METAL_AS_A_SERVICE_LAB_PLAN.md` §5** ("Surfacing it — Phase 6 as the control pane")
> and promoted to a lab of its own, generalized into **reusable infra** any lab can plug
> into. Plan only — no lab files created yet.
>
> **Proposed name:** `examples/control-pane/` (alts: `live-control-pane/`, `fleet-watch/`).
>
> **Decisions locked (this session):**
> - **Scope = the full control-pane trilogy** — a **live inventory source**, a **node-
>   actions panel**, and the **user-definable `milestones.toml` progress engine** — as one
>   cohesive lab (not just the engine).
> - **Core shape = headless-first library + `watch` CLI.** The reusable core is
>   **framework-agnostic** (no Textual/FastAPI imports), exactly like Phase-6's existing
>   `lab_tui/backends/` layer. Any lab — MAAS, resilient-region, bmc-toolkit — uses it with
>   **no TUI** via `control-pane watch <lab>`; the Phase-6 Textual widgets and the
>   phase6b-web SSE feed are just two **renderers** on top.
> - **Deliverable = plan first (this doc) → PR.** Build on a separate go-ahead, mirroring
>   the `bmc-toolkit` flow.
>
> **Grounding (Phase-6 map, verified):** Phase 6 already shares a **framework-free backend
> layer** (`lab_tui/backends/`, zero `textual` imports) between the Textual TUI and the
> FastAPI+HTMX+**SSE** web — so a headless-first core is native to the architecture. New
> inventory source = subclass `BackendRunner` (`backends/base.py:95`) + append to
> `ALL_BACKENDS` (`backends/__init__.py:8`) + widen the `BackendName` Literal
> (`base.py:43` + `state.py:23`). There is **no** milestone/progress/serial-parsing code
> anywhere yet, and **no** libvirt awareness — both greenfield; the async line-readers in
> `screens/topology.py:117` (TUI) and `routes/stream.py:43` (web SSE) are the templates.

---

## 1. What we're building

A **live control-pane layer**: it turns Phase-6's *read-only* inventory browser into an
**actionable, watchable** surface, and does it through a **headless core** so the value
isn't locked in the TUI. Three parts, one reusable contract:

```
   any lab  ──►  gives the control pane:  (1) its nodes   (2) each node's console stream
                                          (3) a milestones.toml   (4) its action verbs
        ┌──────────────── control-pane CORE (framework-free) ─────────────────┐
        │  inventory model  ·  milestone/progress ENGINE  ·  action registry   │
        └───────┬───────────────────────┬──────────────────────┬──────────────┘
                ▼                        ▼                       ▼
        `control-pane watch`     Phase-6 Textual widgets   phase6b-web SSE feed
        (headless CLI)           (live tree + progress)    (browser progress bars)
```

**The teaching arc:** a fleet you *watch come up* — three nodes installing in parallel,
each a live progress bar driven by **your own** milestone markers — beats reading static
states. And by keeping the engine framework-free, the same `milestones.toml` drives a
headless `watch` in CI, a Textual progress bar, and a server-pushed web feed: **one
declaration, three renderers.**

---

## 2. How it maps onto LAB_CREATE_V2 (reuse vs. invent)

| Capability | Status | Foundation to reuse |
|---|---|---|
| Framework-free inventory layer (shared TUI⋈web) | ✅ exists | `lab_tui/backends/base.py` (`BackendRunner`, `Resource`), `ALL_BACKENDS` |
| Live line-by-line console stream (TUI) | ✅ exists | `screens/topology.py:117` (`_run_sequence`, async `readline` → `Log`) |
| Live console stream (web, server-push) | ✅ exists | `routes/stream.py:43` (SSE `generate`) |
| Per-resource console/log argv | ✅ exists | `Resource.console_command` / `log_command` (`base.py:76`) |
| Key-binding → action mechanism | ✅ exists | `screens/browser.py:49` `BINDINGS` → `action_*` (console attach `:34`) |
| Framework-free unit-test harness | ✅ exists | `tests/conftest.py:12` `fake_state_dir`; app-less action test `test_console_attach.py:99`; web ASGI `_stub_runners` |
| **The milestone/progress ENGINE (regex→label→at%)** | ❌ **GAP (crux)** | — invent: a pure, framework-free parser (no eval); nothing like it exists |
| **`control-pane watch` headless CLI** | ❌ **GAP** | — invent: consumes the engine + inventory with no TUI |
| **A live "control-pane" inventory source** | ❌ **GAP** | — invent: a `BackendRunner` reading a lab's node registry + state (widen `BackendName`) |
| **An actions panel calling a lab's verbs** | ❌ **GAP** | — invent: BINDINGS → a lab-declared verb table + console-stream lower pane |
| **Textual `ProgressBar` per node + web SSE progress feed** | ❌ **GAP** | — invent: two thin renderers over the engine (Textual ships `ProgressBar`, unused today) |

**Libvirt caveat (inherited honesty):** Phase 6 has **zero** libvirt awareness today (the
VM backend is raw QEMU pidfiles). A control-pane source that surfaces libvirt/`maas-lab`/
`bmc-toolkit` nodes is genuinely new plumbing — this lab is where it lands.

---

## 3. Crux ① — the headless milestone/progress engine (the reusable core)

A **pure, framework-free** function/class: feed it console lines + a `milestones.toml`,
it emits `(label, percent, terminal, stalled)` progress state. No Textual, no eval, no
network — so it unit-tests as a plain function (the map confirms this is exactly how
`topology.py`'s planner is tested apart from its screen).

```toml
# milestones.toml — matched top-to-bottom against the console; first hit sets progress.
# Keyed by a "profile" (a driver, an OS, a lab role) so different node kinds get different bars.
[[milestone.install]]  match = "Starting partitioner"        label = "partitioning"  at = 25
[[milestone.install]]  match = "Installing the base system"  label = "base system"   at = 55
[[milestone.install]]  match = "Running .*post-install"      label = "post-install"  at = 85
[[milestone.install]]  match = "login:"                      label = "first boot"    at = 100  terminal = true
[[milestone.ramdisk]]  match = "Welcome to (u-root|floppinux)"  label = "RAM login"  at = 100  terminal = true
```

Honesty rules (carried verbatim from MAAS §5c — they are the whole point):
- **Plain regex over console text**, documented, **no eval**.
- **`at` is an explicit percent** — never interpolate/guess between markers.
- **`terminal = true`** marks the done line; a driver's terminal milestone doubles as its
  health-gate "reached active" signal (one declaration, two consumers).
- An **unmatched** console shows a spinner + last line, **never a fake 100%**.
- A milestone set with **no hits within a timeout** surfaces as **stalled** — a first-class
  state that a consumer (e.g. MAAS) routes to its `error`/`maintenance` path.

`control-pane watch <lab> [--profile X]` is the headless renderer: it tails each node's
`console_command`, runs the engine, and prints a per-node milestone stream (CI-friendly,
greppable — a node reaching its `terminal` marker is the observable checkpoint). **This
CLI is the lab's proof it isn't TUI-locked.**

---

## 4. Crux ② — the live inventory source + actions panel (the Phase-6 renderer)

- **4a. A `control-pane` inventory `BackendRunner`.** Subclass `BackendRunner`
  (`base.py:95`), append to `ALL_BACKENDS`, widen the `BackendName` Literal
  (`base.py:43` + `state.py:23`). It reads a lab's **node registry + state** (a small,
  documented interface — see §6) and returns `Resource`s carrying `status` (the node's
  lifecycle state), `extra` (driver/profile), and `console_command` (for the engine).
  Read-only, in the established Phase-6 style — the tree gains a live group per lab.
- **4b. A node-actions panel.** New `BINDINGS` → `action_*` methods that call a lab's
  **declared verb table** (e.g. MAAS `inspect/deploy/rescue/release`, bmc-toolkit
  `power/bootdev/sol/insert-media`), streaming the verb's output into the **lower pane**
  using the existing `topology.py`/`stream.py` async-readline template. Console attach
  reuses the proven `console_command` suspend-and-attach (`browser.py:34`). **Invariant:**
  if Phase 6 is deleted, the lab's own CLI + `control-pane watch` still drive everything.
- **4c. Per-node progress bars.** A thin Textual `ProgressBar` (shipped, unused today)
  per node, fed by the §3 engine over each node's console stream — so you *watch* a fleet
  install in parallel. Unmatched → indeterminate spinner; stalled → a visibly distinct
  (error-tinted) bar, never a fake full bar.

---

## 5. Web parity (phase6b-web) — a server-pushed progress feed

The web UI already shares the backend layer and already streams logs over **SSE**
(`routes/stream.py:43`). Add a sibling **`GET /stream/progress/{backend}/{name}`** that
runs the *same* engine server-side and pushes `data:` progress events (label/percent/
terminal/stalled) into an HTMX progress-bar partial. Same core, third renderer;
CSRF/auth/headers inherited from the existing middleware.

---

## 6. The reusable contract — how any lab plugs in

The point of extraction: the control pane knows **nothing** about MAAS specifically. A
lab opts in by providing four small things (all already idiomatic in the repo):

1. **Nodes** — an enumerable of `(name, state, profile, console_command)`. MAAS = its
   `maas-lab` registry; bmc-toolkit = `fleet-bmc.toml`; any lab = a tiny adapter.
2. **A console stream** per node — an argv the engine tails (`Resource.console_command`).
3. **A `milestones.toml`** — the profile→markers the lab ships (or the user edits).
4. **A verb table** (optional) — `{key: (label, argv)}` for the actions panel.

Given those, the lab gets: `control-pane watch` (headless), a Phase-6 live group with
progress bars, an actions panel, and the web SSE feed — **for free**. MAAS becomes the
first consumer; bmc-toolkit's `sol`/console is a natural second.

---

## 7. New components & files

| File | Type | Notes |
|---|---|---|
| `CONTROL_PANE_LAB_PLAN.md` | **this doc** | roadmap |
| `examples/control-pane/control_pane/engine.py` | new | the framework-free milestone/progress engine (§3) — pure, no Textual |
| `examples/control-pane/control_pane/milestones.py` | new | `milestones.toml` loader + validation (regex compile, explicit `at`, `terminal`) |
| `examples/control-pane/control_pane/inventory.py` | new | the lab-opt-in contract (§6): nodes + console + verbs adapter protocol |
| `examples/control-pane/control-pane` (CLI) | new | `watch <lab> [--profile]` headless renderer |
| `examples/control-pane/milestones.toml` | new | worked example set (install/ramdisk/image profiles) |
| `phase6-tui/lab_tui/backends/control_pane.py` | new | the live inventory `BackendRunner` (§4a); widen `BackendName` |
| `phase6-tui/lab_tui/screens/` (edits) | edit | actions panel BINDINGS (§4b) + per-node `ProgressBar` (§4c) |
| `phase6b-web/lab_web/routes/stream.py` (+ template) | edit | `/stream/progress/…` SSE feed (§5) |
| `examples/control-pane/tests/` + phase6 pytest additions | new | engine unit tests (pure); source via `fake_state_dir`; actions app-less; web via ASGI stub |
| `examples/control-pane/{README,RUNBOOK,MANUAL_TESTING}.md` | new | concept + the reuse contract + a worked demo (drive a fake console → watch the bar fill) |
| `examples/00-INDEX.md` + `examples/learning-paths.toml` | edit | route it (Phase-6 / cross-cutting); observable checkpoint = a node's bar reaching its `terminal` marker |

MAAS's §5 is trimmed to a pointer; MAAS becomes a **consumer** of this lab's contract.

---

## 8. Provenance
Own code (an engine + renderers) — nothing to vendor. **Cite, don't mirror**: Textual
(`ProgressBar`), FastAPI/SSE, and the `tomllib` stdlib — URLs + as-of date in the README.
The engine's honesty rules (regex-not-eval, explicit `at`) are documented in-repo.

## 9. Security posture (AUDIT alignment)
- **No eval, ever** — `milestones.toml` patterns are compiled as **regex over text**, never
  executed; a malformed pattern is a load-time error, not a silent skip.
- **Read-only inventory + explicit verbs** — the pane never invents actions; it runs only a
  lab's **declared** verb argv (shown before running, like the existing destroy-confirm).
- Web side inherits phase6b-web's Basic-Auth + CSRF + security-headers + env-scrub.
- Destructive verbs a lab exposes stay **guarded/author-run** (the lab's concern, surfaced
  honestly by the pane — e.g. a `destroy` shows its argv first).

## 10. Build order (dependency-aware) & verified-vs-author-run
1. **The engine + `milestones.toml` loader** (§3) — pure Python; **fully unit-testable**
   headless (feed lines, assert progress state; the unmatched/stalled/terminal edges).
2. **`control-pane watch` CLI** — headless renderer over the engine + a demo console
   (a scripted `printf` stream or a lab's real `console_command`). *Verifiable in CI.*
3. **The Phase-6 inventory source (§4a)** — `BackendRunner` + `fake_state_dir` fixture
   test (mirror `test_backends_vm.py`), keeping the module Textual-free so web reuse is
   proven by the same test.
4. **Actions panel + progress bars (§4b/c)** — Textual; tested via `App.run_test()` pilot
   + the app-less action pattern (`test_console_attach.py:99`).
5. **Web SSE progress feed (§5)** — tested via the ASGI client + stubbed runner.
6. **First consumer wiring** — a worked demo lab (fake fleet) end-to-end; MAAS/bmc-toolkit
   adapters documented as fast-follows.

Each step ends in a one-verdict test; both catalogs stay green; the pytest jobs
(phase6-tui + phase6b-web) gate the renderers.

## 11. Decisions (resolved 2026-07-24) & open items
- **Scope:** full trilogy (inventory + actions + progress). ✔
- **Core shape:** headless-first framework-free engine + `watch` CLI; Phase-6/web are
  renderers. ✔
- **Deliverable:** this plan → PR; build separately. ✔

**Open (settle at build kickoff):**
- **Where the engine module lives** — under `examples/control-pane/` (self-contained lab)
  vs `phase6-tui/lab_tui/` (shared with the renderer). Leaning: a **standalone package**
  imported by both, so `watch` works with Phase 6 absent.
- **`BackendName` Literal widening** — the map flags this as a real edit point (closed
  Literal at `base.py:43` + `state.py:23`); confirm the cleanest way to add `control-pane`
  without destabilizing the state classifier.
- **Adapter granularity** — one generic `control-pane` source reading a documented registry
  format, vs one source per consumer lab. Leaning generic (§6 contract).
