# Review — Phase 6 UIs (`phase6-tui` + `phase6b-web`)

**Date:** 2026-07-08
**Scope:** the two Python front-ends that sit on top of the Phase 1–5 Bash
drivers — the **Textual TUI** (`phase6-tui/lab_tui/`, ~1.5k LOC + ~1.9k LOC
tests) and the **FastAPI + HTMX + uvicorn** web UI
(`phase6b-web/lab_web/`, ~270 LOC + ~370 LOC tests). Both reuse one shared
backend core, `phase6-tui/lab_tui/backends/`, so its `run_capture` is the single
subprocess choke point for *both* phases.
**Method:** each package read end-to-end (including the `backends/`, `screens/`,
`routes/`, `templates/` subtrees), both test suites run (`uv run pytest`:
78→**99** TUI, 32→**40** web after the fixes, and every finding verified against
the code (line-cited) with a concrete failure scenario. Two independent reviewer
passes (one per phase) plus a maintainer synthesis; the ✓ mark denotes a finding
re-verified by hand against the source.
**Relationship to [`REVIEW-phases-1-5.md`](REVIEW-phases-1-5.md):** that review
covered the host-touching drivers and explicitly deferred Phases 6/6b. This is
the follow-up over the UI layer. It also **fixes every item** it found; see
*Status* per row.

---

## 1. Verdict

Both UIs are **safe on the axis that matters most for this toolkit — neither can
inject a shell command or escape to the host.** Every mutation in both phases
funnels through one `subprocess.run(argv, …)` at the shared
`lab_tui/backends/base.py` — an argv **list**, no `shell=True`, no `os.system`,
no string-joining anywhere in either package. HTTP/TUI-supplied names are used
only to *match* engine-derived `Resource` objects, never to *build* commands, and
all five `destroy_argv` builders insert a `--` option terminator. Script paths are
hardcoded literals joined to a `__file__`-derived repo root — not attacker
controllable. The web app is independently well-hardened: loopback-default bind, a
fail-safe network-exposure gate, `hmac.compare_digest` Basic Auth, Jinja2
autoescape, CSP + `X-Frame-Options: DENY` + `nosniff` on every response.

**No CRITICAL or HIGH safety finding in either phase.** The residue is
correctness/quality and MEDIUM-and-below defense-in-depth — and, tellingly, a
*documentation* drift and a *tautological test* were the two most important
findings, not an open door.

## 2. Cross-cutting note — one shared core, one choke point

The valuable structural fact: `phase6b-web` imports `lab_tui.backends`
(`from lab_tui.backends import ALL_BACKENDS`), so the web routes do **not** build
argv or call `subprocess` themselves — they go through the same `BackendRunner`
subclasses and the same `run_capture`/`run_json` helpers the TUI uses. That is why
the injection surface is closed *once* for both phases, and why the single
highest-value fix (**S1**, the missing subprocess timeout) lands in one place and
protects both. Where the web phase is more exposed is not injection but the
**network + async** surface it adds on top: an event loop that a blocking call can
starve, and an auth boundary reachable by anything that can open a socket.

## 3. Findings & status

### Shared core (both phases)

| # | Finding | Sev | Where | Status |
|---|---------|-----|-------|--------|
| **S1** | **`run_capture` had no subprocess timeout.** A hung `lab-*.sh`, an unresponsive docker/podman/lxd daemon, or a `sudo` awaiting input pinned the caller forever. Worst in the **web** phase: blocking calls run in `asyncio.to_thread`, so enough stuck calls exhaust the default threadpool and **wedge uvicorn**; in the TUI it stalls a worker. | **MED** | `base.py:175` | **FIXED** — `DEFAULT_TIMEOUT=120`s; a timed-out child is killed and surfaced as `TIMEOUT_RC=124` (mirrors `timeout(1)`), never an exception up the call stack. Opt-out via `timeout=None` for legitimately long builds. Regression: `phase6-tui/tests/test_run_capture_timeout.py` (kills a 30s sleep in <10s, asserts rc 124; a normal command is unaffected). |

### phase6b-web

| # | Finding | Sev | Where | Status |
|---|---------|-----|-------|--------|
| **W1** | **Reflected-XSS inconsistency** ✓ — `detail_panel` interpolated `{backend}`/`{name}` **raw** into `HTMLResponse`, while `actions.py:43,48,64` wrap the *identical* strings in `html.escape`. CSP (`script-src 'self'`) blocks execution, so it was mitigated, not clean. | MED (CSP-mitigated → effectively LOW in a closed lab) | `routes/resources.py:90,93` | **FIXED** — both fragments now `html.escape(...)`, matching the sibling route. Regression: `phase6b-web/tests/test_routes.py::test_detail_panel_escapes_unknown_backend` + `…_missing_resource_name`. |
| **W2** | Auth password propagates into **every root-`sudo` child's environment** via `os.environ.copy()`, and `--auth u:p` on the CLI is visible in `ps`. | LOW | `__main__.py:98`, `base.py:186` | **FIXED** — `run_capture` now pops `LAB_WEB_AUTH_USER`/`LAB_WEB_AUTH_PASSWORD`/`LAB_WEB_AUTH` from the default child `env` (the shared choke point), while leaving non-secret vars intact; the `ps` vector already had an escape hatch (`--auth` defaults from `$LAB_WEB_AUTH`). Regression: `test_run_capture_env_scrub.py`. |
| **W3** | CSRF guard is header-presence only (`HX-Request: true`), not token-based. Honestly documented; adequate for the browser threat model (a custom header ⇒ CORS preflight this app won't satisfy; a plain cross-origin form can't set it). | LOW (accepted) | `routes/actions.py:20` | **FIXED** — added a per-process CSRF token (`app.CSRF_TOKEN`), injected into every page via `<body hx-headers>` and verified with `hmac.compare_digest` in `_csrf_guard` (in addition to the `HX-Request` gate). A cross-origin page can't read it; a same-origin forge of `HX-Request` alone no longer suffices. Regression: `test_destroy_without_csrf_token_rejected`, `…_with_wrong_csrf_token_rejected`, `test_page_embeds_csrf_token`. |
| **W4** | `/static/` auth exemption tests the **raw** request path — a smell, but Starlette routes `/static/../…` to the StaticFiles mount (traversal-guarded → 404), so it is **not** exploitable to reach a control route (no control route begins with `/static/`). | LOW | `app.py:123` | **FIXED** — the exemption now runs `posixpath.normpath()` first (`_is_static_path`), so a `/static/../<control-route>` collapses to a non-`/static` path and is auth-gated. Regression: `test_static_exemption_is_traversal_safe`. |
| **W5** | 401 responses skip the security-headers middleware (registration order makes `basic_auth` outer, short-circuiting before `add_security_headers`); `detail_panel`/inspect paths aren't exception-wrapped like the hardened destroy path. Cosmetic (debug off → plain "Internal Server Error", no stack leak). | LOW | `app.py:67,118` | **FIXED** — `add_security_headers` is now registered *after* `basic_auth`, making it the outer middleware, so the 401 short-circuit carries the headers; both `inspect` paths (`detail_panel` + the JSON API) are now try/except-wrapped like `destroy`. Regression: `test_401_carries_security_headers`, `test_inspect_backend_error_returns_clean_fragment`. |

### phase6-tui

| # | Finding | Sev | Where | Status |
|---|---------|-----|-------|--------|
| **T1** | **README/SHOWCASE falsely advertised create-wizards + console-attach as "deferred to v0.2"** ✓ — both are fully implemented and tested (`screens/wizards/phase{1..5}.py`, `browser.py` `n`/`c` bindings, `tests/test_wizards.py`, `tests/test_console_attach.py`). Risk: an auditor concludes "no wizard ⇒ no TOML-generation surface" and skips the code that writes specs. | MED (docs) | `README.md:7`, `SHOWCASE.md:289` | **FIXED** — both docs now describe the wizards (`n`) and console attach (`c`) as shipped. Regression: `phase6-tui/tests/test_docs_reflect_shipped_features.py` fails if the "deferred to v0.2" claim returns while the wizard modules exist. |
| **T2** | **Tautological test** ✓ — `argv[-2:] == ["destroy","lab-web-nginx"][:1] + ["--force"][:0]` reduces to `argv[-2:] == ["destroy"]` (a 2-elem slice can never equal a 1-elem list), so the whole `… or "--force" in argv` passed for **any** argv containing `--force`, verifying neither the `--` guard nor the target. A silent hole in exactly the regression guard the rest of the suite leans on. | MED (test) | `test_backends_docker.py:49` | **FIXED** — rewritten to assert `argv[1:4] == ["destroy","--","web/nginx"]`, `argv[-1] == "--force"`, that the operand after `--` is not a flag, and that the raw double-prefixed name `lab-web-nginx` is **not** passed. |
| **T3** | `_toml_str` under-escapes ✓ — only `\`/`"`, not newline/tab/control chars; a pasted multiline value writes **invalid TOML** to disk, and `_refresh_preview`'s bare `except` masks the cause as "(invalid input)". Not injection (tomllib can't exec) — a robustness bug. | LOW/MED | `screens/wizards/base.py:38` | **FIXED** — `_toml_str` now escapes the full TOML basic-string set (`\b \t \n \f \r`) and `\u`-escapes every other C0/DEL byte, so any input round-trips through `tomllib`. Regression: `test_toml_str_escaping.py` (round-trips newline/tab/CR/NUL/DEL). |
| **T4** | Three **read-path** argv builders (VM `console`, docker/podman `logs`) omit the `--` terminator that all five *destroy* paths have. Names come from tool-written manifests/engine labels, so it's defense-in-depth only — but an inconsistency worth closing. | LOW | `vm.py:87`, `docker.py:100`, `podman.py:96,132` | **FIXED** for the docker/podman `logs` paths (direct engine CLI → `--` added). **VM `console` deliberately left without `--`** and documented: `lab-vm.sh` routes post-`--` args to `EXTRA_ARGS` (the `ssh … -- <cmd>` passthrough) while `cmd_console` reads `POS_ARGS[0]`, so `--` would blank the name — and it's unnecessary because the script's `-*) die "unknown option"` already fails a `-`-leading name closed. Regression: `test_log_command_has_dashdash_before_name` (docker), `test_log_commands_have_dashdash_before_name` (podman). |
| **T5** | Hostile-input branches barely tested: no end-to-end `-`-leading/metachar name, no `plan_down` F-05 lab-name-rejection test, no malformed-TOML / missing-script coverage. Coverage skews happy-path. | LOW (test) | `phase6-tui/tests/` | **FIXED** — `test_topology_hostile_input.py` drives `plan_down` with `--evil`/space/`;`/`$( )`/path-ish names (all raise `ValueError` before argv is built), asserts a clean name scopes to `down --lab <name>`, and covers malformed-TOML + missing-`[lab].name`. The `--` guard on a hostile name is now asserted by T2/T4. |

## 4. Calibration — good patterns preserved

Both reviewers converged on the same architecture verdict, which raises
confidence in it:

- **Argv lists everywhere.** No `shell=True`, `os.system`, or joined-string
  command in either package; the one `subprocess.run` (`base.py`) takes a list.
- **Match, don't build.** HTTP/UI names only *select* an engine-derived
  `Resource`; a metacharacter/`../` name simply fails the match → "not found",
  never reaching argv. All `destroy_argv` builders add `--` before the operand.
- **Hardcoded script resolution.** `_script_for` dict-looks-up a `PhaseSlot`
  `Literal`; `phase_script(rel)` joins a literal path to a `__file__`-derived
  root. No user string reaches the path; a wheel-install mismatch warns at import.
- **Web network gate is a whitelist-of-one that fails safe** — only literal
  `127.0.0.1` runs ungated; `0.0.0.0`/`::`/`localhost`/an interface IP are all
  forced through `--allow-network` **and** `--auth`. You cannot bind a wildcard
  while believing it's loopback. `--allow-network` without `--auth` is refused at
  startup.
- **Auth is constant-time** (`hmac.compare_digest` on both fields), rejects
  non-`Basic` / malformed base64, and the `/static/` exemption is not routable to
  a control endpoint.
- **Async hygiene:** every blocking backend call is wrapped in
  `asyncio.to_thread`; the SSE log stream uses `create_subprocess_exec` and reaps
  it `terminate → wait(5s) → kill` with client-disconnect detection.
- **No eval surface:** all config/state/manifest reads go through `tomllib`
  (cannot execute); no `pickle`/`yaml.load`.
- **Confirm modal shows the literal argv** before running and disables approve on
  click (no double-fire, no keyboard bypass).

## 5. What was fixed

**Every** finding in the review is now resolved, each with a regression test.

*First pass* (`S1 + W1 + T2 + T1`):

- **S1** — subprocess timeout in the shared `run_capture` (`base.py`) →
  `tests/test_run_capture_timeout.py`.
- **W1** — escape the two `detail_panel` fragments (`routes/resources.py`) →
  two GET-based escaping tests in `tests/test_routes.py`.
- **T2** — replace the tautological docker destroy-argv assertion
  (`tests/test_backends_docker.py`) — the fix *is* its regression test.
- **T1** — correct README/SHOWCASE "deferred to v0.2" drift →
  `tests/test_docs_reflect_shipped_features.py` (guards against recurrence).

*Second pass* (the remaining `W2–W5 + T3–T5`):

- **W2** — scrub `LAB_WEB_AUTH*` from the default subprocess `env` in
  `run_capture` → `test_run_capture_env_scrub.py`.
- **W3** — per-process CSRF token (`app.CSRF_TOKEN`), injected via
  `<body hx-headers>`, verified constant-time in `_csrf_guard` → three
  CSRF tests in `test_routes.py`.
- **W4** — normalise the path before the `/static/` auth exemption
  (`_is_static_path`) → `test_static_exemption_is_traversal_safe`.
- **W5** — reorder middleware so security headers wrap the 401, and
  try/except-wrap both `inspect` paths → `test_401_carries_security_headers`,
  `test_inspect_backend_error_returns_clean_fragment`.
- **T3** — full TOML basic-string escaping in `_toml_str` →
  `test_toml_str_escaping.py`.
- **T4** — `--` on the docker/podman `logs` paths (VM `console` documented as
  already-safe and `--`-incompatible by `lab-vm.sh` design) → `--` assertions
  in `test_backends_docker.py` / `test_backends_podman.py`.
- **T5** — hostile-input coverage for the topology dispatcher →
  `test_topology_hostile_input.py`.

Suites after both passes: **phase6-tui 99 passed** (was 78),
**phase6b-web 40 passed** (was 32). No Open items remain.
