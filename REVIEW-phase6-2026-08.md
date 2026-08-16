# Review — Phase 6 UIs, second pass (`phase6-tui` + `phase6b-web`)

**Date:** 2026-08-16
**Scope:** the two Python front-ends over the Phase 1–5 Bash drivers — the
**Textual TUI** (`phase6-tui/lab_tui/`, 3376 LOC) and the **FastAPI + HTMX** web
UI (`phase6b-web/lab_web/`, 1564 LOC incl. templates/static), plus their 23 test
modules. Both share one backend core, `phase6-tui/lab_tui/backends/`, so
`run_capture` remains the single subprocess choke point for both.
**Method:** each package read end-to-end; every finding reproduced **in-process**
against the real app (httpx + ASGI transport for the web UI, the suite's own
`generate_toml()` harness for the wizards) with a control before being recorded.
No live browser and no `sudo` were involved — see §3b for exactly what that
leaves unproven.
**Relationship to [`REVIEW-phase6.md`](REVIEW-phase6.md)** (2026-07-08): that pass
found eleven items and fixed all of them. This is a second pass, and it begins by
**re-deriving** those fixes rather than trusting the table — §4. Ten of eleven
still hold; the eleventh (**W1**) turns out to have been fixed in two of the three
files it applies to, which is **P6-3** below.

---

## 1. Verdict

This is the most defensively-written code in the repo, and the gap between it and
the Bash phases is not small. Every mutation in both UIs funnels through one
`subprocess.run(argv, …)` — an argv **list**, no `shell=True`, no `os.system`, no
string-joining anywhere in either package. HTTP- and TUI-supplied names only
*match* engine-derived `Resource` objects; they never *build* commands. Jinja2
autoescaping is explicitly widened to `.html.j2` (the default `select_autoescape`
misses it). The Basic Auth comparison is `hmac.compare_digest` on both fields with
no short-circuit. The static-path auth exemption normalizes before the prefix
test. `add_security_headers` is deliberately registered *after* `basic_auth` so
the 401 short-circuit still carries CSP. The wizard's TOML escaper handles the
full basic-string set and `\u`-escapes every other C0/DEL byte — stricter than any
escaper in Phases 1–5. Both suites are green: **TUI 111 passed, web 44 passed**
(99/40 at the previous review).

The residue is **three defects**, all reproduced, and the interesting one is not
in the code that was hardened — it is in an assumption *underneath* the hardening:

- **P6-1 (MED)** — ✅ **FIXED 2026-08-16.** Nothing validates the `Host` header, so **DNS rebinding**
  collapses both of the web UI's defences at once: the "loopback only, no auth"
  default *and* the per-process CSRF token, which the attacker can simply read.
  Demonstrated end-to-end in-process, and the destroy it reaches runs under
  **`sudo`** for chroot and VM resources.
- **P6-2 (MED)** — ✅ **FIXED 2026-08-16.** Of the ~30 TOML values the five create-wizards emit, **exactly
  one** skips `_toml_str`: the Phase-3 wizard's `volumes` list. A multi-line paste
  there makes the wizard write a **valid** spec containing a top-level key the
  user never typed — and the key it injects is `command`, which is the field
  [`REVIEW-phase3.md`](REVIEW-phase3.md) P3-2 showed injects a compose attribute.
- **P6-3 (LOW)** — ✅ **FIXED 2026-08-16.** The previous review's **W1** (escape URL-derived values before
  reflecting them) was applied to `actions.py` and `resources.py` and never
  reached `stream.py`. Measured: it reflects raw, and is non-exploitable today
  only because the response carries **no `Content-Type`** and `nosniff` is set.

The through-line of this five-review series lands here too, in its purest form:
**a guard that exists in the codebase, absent from one of its call sites.** P6-2
is one emitter of thirty; P6-3 is one file of three.

---

## 2. Findings

### P6-1 — MED — no `Host` validation: DNS rebinding defeats the loopback default *and* the CSRF token — ✅ FIXED 2026-08-16

The web UI's security model rests on two documented pillars, both stated in
`__main__.py`'s own docstring:

```
lab-web                                      # loopback only, no auth
SSH-forward recipe (no auth needed — tunnel is the auth layer)
```

and, in `routes/actions.py`, on a CSRF token whose docstring reasons:

> *"A cross-origin page cannot read it, and setting a custom header cross-origin
> triggers a CORS preflight this app never approves."*

Both statements are true of a **genuinely cross-origin** attacker. Neither
survives DNS rebinding, which makes the attacker *same-origin*: the user visits
`evil.example`, whose DNS record flips to `127.0.0.1`, and the browser then sends
requests to the local server carrying `Host: evil.example` — while treating the
responses as same-origin, so the page can **read** them.

Nothing in the app rejects that `Host`. There is no `TrustedHostMiddleware`, no
`allowed_hosts`, no origin check anywhere in `lab_web/` (the only greps that hit
are comments and vendored `htmx.min.js`). The test suite is itself unwitting
evidence: `conftest.py` uses `base_url="http://test"`, so **every one of the 44
web tests already sends a foreign `Host`** and nothing notices.

**Reproduced in-process**, with the control first:

```
1. GET / with Host: evil.example        → 200
   per-process CSRF token readable in body? True
2. POST destroy, no token (CONTROL)     → 403 'Forbidden: HTMX-only endpoint.'
3. POST destroy, token from step 1      → 200
   runner.destroy actually called?      True
```

Step 2 is the important line: **the CSRF guard works exactly as designed.** It is
not broken and it is not bypassed — it is *satisfied*, because a same-origin page
may read the token out of `<body hx-headers>` and echo it back. The token defends
against the threat it was built for and is inert against this one.

**What it reaches.** `actions.destroy` calls `runner.destroy(resource, True)`,
and for the two root-owned backends that argv is:

```
chroot  → ['sudo', '…/phase1-chroot/lab-chroot.sh', 'destroy', '--', 'demo', '--force']
vm      → ['sudo', '…/phase2-qemu-vm/lab-vm.sh',   'destroy', '--', 'demo', '--force']
```

So on a workstation with passwordless sudo — which this repo's own conventions say
to assume — a page the user merely *visits* can destroy chroots and VMs as root.
Note this is the **default** configuration: loopback, no auth. Adding `--auth`
mitigates it (the attacker cannot supply credentials), which inverts the
documentation's advice — the "no auth needed" loopback path is the exposed one.

**Fix direction:** add Starlette's `TrustedHostMiddleware` with
`allowed_hosts=["localhost", "127.0.0.1", "[::1]"]` (plus whatever `--host` was
bound, when `--allow-network` is used), registered so it runs before auth. That is
the standard mitigation and it is a few lines. Optionally also reject requests
whose `Origin` is present and not same-origin. A regression test is cheap and
would have caught this: assert a foreign `Host` gets 421/400 — noting that such a
test requires *changing* `conftest.py`'s `base_url`, which is exactly why the gap
survived a full review pass.

### P6-2 — MED — one wizard emitter skips `_toml_str`, and it injects a spec key — ✅ FIXED 2026-08-16

`screens/wizards/base.py:_toml_str` is the strictest escaper in the repo: the
named TOML escapes (`\\ \" \b \t \n \f \r`) plus `\u`-escaping of every other
C0/DEL byte. Its docstring explains precisely why the control characters matter:

> *"a multi-line paste in any single-line wizard field wrote a broken spec to
> disk (masked in the live preview as '(invalid input)')."*

So multi-line paste into a single-line field is an acknowledged, reachable input.
Across all five wizards, ~30 emitted values route through the escaper. **One does
not** — `phase3.py:103`:

```python
port_list = ", ".join(f'"{_toml_str(p.strip())}"' for p in ports.split(",") if p.strip())   # 89 ✓
vol_list  = ", ".join(f'"{v.strip()}"'            for v in vols.split(",")  if v.strip())   # 103 ✗
```

Its own siblings escape: ports on line 89, env values on 100, phase-4's volumes on
123, phase-5's profiles on 120.

**Reproduced, with the control inside the same generated file** — one hostile
value, two adjacent fields of one wizard:

```
ports    (escaped, line 89)   ports   = ["data:/mnt\"", "evil = \"yes"]   parses OK
volumes  (raw,     line 103)  volumes = ["data:/mnt"", "evil = "yes"]     INVALID TOML
```

Corruption is the mild outcome. Using the multi-line paste the escaper's docstring
already anticipates, the wizard writes a **valid** spec with an injected key:

```toml
[[service]]
name     = "web"
image    = "nginx:alpine"
networks = ["front"]
volumes  = ["a"]
command = "INJECTED-BY-THE-WIZARD"      ← never typed by the user
x = ["b"]
```
```
parses as valid TOML: True
service keys: ['command', 'image', 'name', 'networks', 'volumes', 'x']
```

The wizard then writes this to `examples/docker-<lab>.toml` and tells the user to
run `lab-docker.sh up --config <path>`. **And the injected key is `command`** —
the exact field [`REVIEW-phase3.md`](REVIEW-phase3.md) P3-2 showed is emitted raw
by Phase 3's compose exporter, where a newline in it resolves to
`privileged: true` plus a bind mount of `/`. Neither defect needs the other, but
they compose into: paste a volume spec copied from a web page → the TUI writes a
spec with a `command` you never wrote → `export` turns it into a privileged
compose service.

**Fix direction:** wrap line 103's value in `_toml_str` like its five siblings.
The durable version is a test that asserts the **outcome** rather than the
mechanism — see §3, because `test_toml_str_escaping.py` already tests the helper
thoroughly and cannot see this class of bug by construction.

### P6-3 — LOW — W1's escaping fix reached two of three route files — ✅ FIXED 2026-08-16

The previous review's **W1** was *"reflected-XSS inconsistency — `detail_panel`
interpolated `{backend}`/`{name}` raw while `actions.py` wraps the identical
strings in `html.escape`"*, and it was fixed. Re-deriving that fix across the
whole route layer today:

| file | URL-derived reflections | escaped? |
|---|---|---|
| `actions.py` | 3 (lines 51, 56, 72) | ✓ all |
| `resources.py` | 3 (95, 98, 107) + a JSONResponse (170) | ✓ all |
| **`stream.py`** | **2 (lines 38, 87)** | **✗ neither** |

```python
return Response(f"unknown backend: {backend}", status_code=404)   # stream.py:38, 87
```

**Measured** rather than assumed, because the interesting question is whether it
is actually exploitable:

```
stream.py:38   status=404  content-type=(none)              payload reflected RAW? True
actions.py:51  status=200  content-type=text/html; charset=utf-8   reflected RAW? False
```

A bare Starlette `Response` with no `media_type` sends **no `Content-Type`**, and
`add_security_headers` sets `X-Content-Type-Options: nosniff`, so a browser will
not render the reflected payload as HTML. **It is not exploitable today** — but it
is protected by the absence of a header plus a second header set elsewhere, not by
the code at the reflection site. Adding an explicit `media_type="text/plain"` for
clarity would, on its own, make nothing worse; removing `nosniff` would make it
live.

**Fix direction:** `html.escape(backend)` at both sites, matching the two sibling
files. One line each, and it restores the invariant W1 established.

---

## 3. Minor / robustness (not standalone findings)

- **`test_toml_str_escaping.py` tests the helper, not the emitters** — and by
  construction cannot catch P6-2. It round-trips `_toml_str` output through
  `tomllib` (`tomllib.loads(f'x = "{_toml_str(val)}"')`), which proves the escaper
  is correct and says nothing about whether the wizards *call* it. This is
  CLAUDE.md's bug class #2 in the test layer: asserting the mechanism. The outcome
  version is roughly as short and would have failed on line 103 —
  for each of the five wizards, feed a hostile value to every free-text field in
  turn, call `generate_toml()`, and assert `tomllib.loads()` succeeds **and** that
  the parsed key set is exactly what the user supplied. The harness for this
  already exists (`tests/test_wizards.py::_make_wizard`), which is how P6-2 was
  reproduced.

- **`stream.py` returns bare `Response` objects with no `media_type`.** Three of
  them (lines 38, 41, 87). Today this is load-bearing for P6-3's non-exploitability,
  which is a fragile thing to depend on silently. An explicit
  `media_type="text/plain"` documents the intent and survives someone later adding
  an escape without one.

- **CSP allows `style-src 'unsafe-inline'`** (`app.py:153`), annotated as needed
  for "Textual-style theming". Accurate, and worth revisiting only if inline styles
  are ever removed — noted so the exception stays a conscious one rather than
  drifting into "that's just what the CSP says".

- **The `--host` loopback test is a string equality** (`__main__.py:59`,
  `args.host != "127.0.0.1"`), which is the shape that has been wrong twice
  elsewhere in this repo — but here it errs **safe** in every direction I could
  construct (`localhost`, `::1`, `127.0.0.2`, `0.0.0.0`, `""` all compare unequal
  and are therefore treated as *exposed*, demanding `--allow-network --auth`).
  Recorded in §4 as cleared rather than as a defect, so a future "improvement" to
  make it smarter does not accidentally widen it.

## 3b. Not verified by this pass — UNKNOWN, not PASS

- **No live browser was involved.** P6-1 was demonstrated at the HTTP layer: the
  server accepts a foreign `Host`, serves the CSRF token to it, and performs the
  destroy. What that does **not** prove is that a specific browser will complete a
  rebind against a given target — browsers implement DNS pinning of varying
  strength, and some block rebinding to loopback outright (Chrome's private-network
  access work in particular). So the *server-side* precondition is measured and the
  *client-side* feasibility is not. The fix is cheap enough that this does not
  change the recommendation, but the severity depends on a browser behaviour this
  pass did not test.
- **`sudo` was never invoked.** The argv containing `sudo` is measured; whether a
  destroy actually completes as root depends on the host's sudoers policy, which
  this reviewer cannot exercise (no sudo available). P6-1's impact statement is
  conditional on passwordless sudo, and is written that way.
- **The TUI was not driven interactively.** Findings in the TUI half were reached
  through `generate_toml()` and the backends directly, as the suite's own tests do.
  The Textual pilot tests (`test_app_pilot.py`) cover the interactive layer and
  pass; I did not add to them.

## 4. Investigated and cleared (so it is not re-raised)

- **Ten of the previous review's eleven fixes re-derived as still present**, by
  reading today's code rather than the status table: **S1** (`DEFAULT_TIMEOUT=120`,
  `TIMEOUT_RC=124`), **W2** (the three `LAB_WEB_AUTH*` vars popped in
  `run_capture`'s default env — the shared choke point), **W3** (per-process
  `CSRF_TOKEN` + `hmac.compare_digest`), **W4** (`posixpath.normpath` before the
  `/static` prefix test), **W5** (`add_security_headers` registered *after*
  `basic_auth` at lines 125/144, so it is the outer middleware and decorates the
  401), **T2** (the tautological docker assertion is genuinely rewritten — it now
  asserts `argv[1:4] == ["destroy","--","web/nginx"]` and that the raw
  double-prefixed name is *not* passed), **T3** (`_toml_str`'s full escape set),
  **T4** (the `--` terminators, with the VM-console exception still documented).
  **W1 is the exception** and is P6-3.
- **The `--host` / `--allow-network` gate.** Non-loopback without
  `--allow-network` exits 2; `--allow-network` without `--auth` exits 2; the
  credential is validated for a colon and non-empty halves. The string-equality
  test errs safe (see §3). Correct as written.
- **The Basic Auth comparison.** Both `compare_digest` calls execute
  unconditionally and are combined with `and` afterwards, so neither field
  short-circuits the other; the decode is exception-guarded; a missing credential
  disables auth rather than failing open to a wrong-credential accept.
- **The subprocess surface.** `run_capture` and `asyncio.create_subprocess_exec`
  both take argv **lists**; no `shell=True`, `os.system`, or `Popen(str)` anywhere
  in either package. Resource names are used to *match* engine output, never to
  build commands — the property the whole design rests on, and it holds.

## 5. Feature completeness

Both UIs are complete against their stated scope: a five-backend browser tree with
lazy inspect, log tail, console attach, and five create-wizards in the TUI; a
resource list, detail panel, SSE log stream, SSE progress bar, and destroy action
in the web UI — sharing one backend core so a new backend appears in both. The web
UI ships a real deployment story (loopback default, an explicit two-flag gate for
network exposure, Basic Auth, a documented SSH-forward recipe, and a "put TLS in
front" warning). `docs_url` is off unless `LAB_WEB_DEV=1`. No missing feature rises
to a finding.

## 6. Calibration — good patterns preserved

The single-choke-point design is the reason this review is short: because *every*
mutation in both UIs goes through one `run_capture`, the timeout (S1) and the
credential scrub (W2) each needed exactly one implementation, and a reviewer can
verify the no-shell property by reading one function. Compare Phases 3/4/5, where
`_yaml_str` exists three times and was fixed twice. The Jinja2 autoescape fix is a
model of the outcome-over-mechanism rule — `select_autoescape()`'s defaults
*look* like they cover templates, and the code explicitly widens them to
`html.j2` with a comment naming what was rendered raw before. `_is_static_path`
normalizes before testing rather than trusting the raw prefix. `add_security_headers`
is ordered deliberately so the short-circuited 401 is still decorated, with the
reason in the comment. And `test_docs_reflect_shipped_features.py` is a genuinely
unusual test — it fails if the README's "deferred to v0.2" claim returns while the
wizard modules exist, which is a doc-drift guard of the kind the Bash phases
achieve only through `link_check.py`.

---

## 7. Resolution (2026-08-16)

All three findings fixed, plus the three in [`REVIEW-phase6b.md`](REVIEW-phase6b.md).
Suites: **62 web / 113 TUI, 0 failed.**

### 7.1 What changed

| item | change | regression test |
|---|---|---|
| **P6-1** | a `trusted_host` middleware: loopback-only Host allowlist, extensible via `LAB_WEB_ALLOWED_HOSTS`, disabled by `--allow-network` (where `--auth` is already mandatory) | `test_routes.py` ×7 |
| **P6-2** | phase3's `volumes` emitter routes through `_toml_str`, like its four siblings | `test_toml_str_escaping.py` ×2 |
| **P6-3** | `stream.py`'s two reflections are `html.escape`d **and** given a `media_type` | `test_routes.py` |
| **P6B-1** | `_gather_resources` returns the availability it already learned; `index` stops re-probing | `test_routes.py` ×3 |
| **P6B-2** | `static/PROVENANCE.md` with version, URL, date and **enforced** sha256 | `test_vendored_provenance.py` ×6 |
| **P6B-3** | the route stops escaping a value the template already escapes | `test_routes.py` |

### 7.2 P6-1: the fix is ordering as much as code

The middleware is registered **after** `basic_auth` in `app.py`, which reads backwards
until you know that Starlette inserts each `@app.middleware` at the *head* of the stack —
so the last registered runs first. That is required: an unauthenticated foreign-Host probe
must not reach the credential comparison. `test_foreign_host_is_refused_before_auth`
asserts it, so the ordering cannot silently invert.

`--allow-network` sets the allowlist to `*` rather than guessing a hostname. That is not a
hole: `--auth` is already **mandatory** on that path, so credentials are the control there,
and the Host allowlist exists to protect the configuration that has no credentials — the
loopback default the docs recommend.

**The conftest change is the finding.** The suite used `base_url="http://test"`, so all 44
requests already carried a foreign Host and nothing noticed — which is exactly why a full
review pass missed it. Three files needed the change, not one; the two beyond `conftest.py`
were found by the suite going red, not by grepping.

### 7.3 Two of this pass's own tests passed for the wrong reason

Both were caught by running the negative control, not by reading:

1. **The double-escape test never reached the code it was about.** It posted a name the
   stub did not know, so the route took the *not-found* branch — which reflects the name
   escaped exactly once whatever the bug is doing — and went green against the
   double-escaping driver. The finding lives on the success branch; the test now stubs a
   resource that exists, and was watched failing.
2. **A stray `X-CSRF-Token` header** (the app expects `X-CSRFToken`) made a manual probe
   return 403, which briefly looked like a routing problem rather than a typo of mine.

### 7.4 Not verified

- **No CVE research on htmx 1.9.12.** P6B-2 was about unrecorded provenance, and the
  record says so explicitly rather than implying the pin is known-good.
- **`sse.js`'s version is still unknown** and is recorded as unknown. It carries no
  version string, so the pairing with htmx 1.9.12 is an inference from file mtime, not a
  fact read from the bytes — writing the guess down would have made it a "fact" three
  sessions later.
- **No browser-level test of the rebinding scenario.** The guard is asserted in-process at
  the seam that implements it; an actual rebinding harness (DNS TTL games plus a real
  browser) was out of scope.
