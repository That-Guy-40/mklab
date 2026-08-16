# Review — Phase 6b (`phase6b-web`)

**Date:** 2026-08-16
**Scope:** the FastAPI + HTMX web UI **only** — `phase6b-web/lab_web/`
(1564 LOC incl. templates and vendored static assets) and its 3 test modules
(583 LOC). The shared backend core lives in `phase6-tui/lab_tui/backends/` and is
Phase 6's; it is treated here as a dependency, not a subject.
**Method:** each module, template and static asset read end-to-end; every finding
reproduced **in-process** against the real app (httpx + ASGI transport, backends
stubbed exactly as `conftest.py` does) with a control before being recorded.
**Relationship to prior reviews.** [`REVIEW-phase6.md`](REVIEW-phase6.md)
(2026-07-08) covered both UIs and fixed eleven items.
[`REVIEW-phase6-2026-08.md`](REVIEW-phase6-2026-08.md) (2026-08-16) was a
second pass over both, and **two of its three findings are Phase 6b's** — the
missing `Host` validation (**P6-1**, DNS rebinding defeats both the loopback
default and the CSRF token) and `stream.py`'s unescaped reflections (**P6-3**).
Those are **not re-raised here**; this pass deliberately targets what that one did
not read: `routes/resources.py`, the four Jinja templates, and the vendored
`static/` assets.

---

## 1. Verdict

Phase 6b's security posture was already audited twice and is genuinely strong —
one argv-list subprocess choke point, explicit `.html.j2` autoescaping,
constant-time Basic Auth, a normalized static-path exemption, CSP on every
response including the 401. Reading the parts the previous passes skipped does not
overturn any of that. The templates in particular are clean: **no `|safe`, no
`{% autoescape false %}`, no `Markup`** anywhere, so the F-1 autoescape fix is
intact and undefeated, and backend-controlled `inspect_text` lands in
`<pre>{{ inspect_text }}</pre>` properly escaped. Suite green: **44 passed**.

What the unread surface does contain is **three defects**, none of them an
injection, and all three about consistency rather than about a missing idea:

- **P6B-1 (MED)** — `index` calls `is_available()` **unguarded** while
  `_gather_resources`, twenty lines above, wraps the identical call in
  `try/except`. One backend raising takes down the whole page while the polling
  partial keeps serving normally.
- **P6B-2 (LOW/MED)** — `htmx.min.js` and `sse.js` are vendored with **no
  version, no upstream URL, no retrieved-date, and no `sha256`**, while the
  README presents vendoring as the supply-chain mitigation. `sse.js`'s version is
  not recoverable from the file at all.
- **P6B-3 (LOW)** — `actions.py:72` `html.escape()`s a value and then hands it to
  a template that autoescapes it again. A resource named `lab-a&b-web` renders as
  `lab-a&amp;b-web`. This is an artifact of the F-1 autoescape fix changing the
  contract without revisiting the one caller that feeds a template.

---

## 2. Findings

### P6B-1 — MED — `index` trusts `is_available()`; `_gather_resources` does not

`routes/resources.py` calls `is_available()` in two places, twenty lines apart,
with opposite assumptions about whether it can fail:

```python
async def _gather_resources(runners):
    for backend_name, runner in runners.items():
        try:
            available = await asyncio.to_thread(runner.is_available)   # ← guarded (line 36-41)
            ...
        except Exception:  # noqa: BLE001
            continue

@router.get("/")
async def index(request):
    grouped = await _gather_resources(runners)
    unavailable = [
        n for n, runner in runners.items()
        if not await asyncio.to_thread(runner.is_available)            # ← unguarded (line 63-66)
    ]
```

The guarded one is the considered version: a backend probe reaches out to a
daemon (`docker version`, `podman version`, the LXD engine probe), and the whole
point of `_gather_resources`'s `except` is that such a probe is untrusted. The
comprehension in `index` re-asks the same question with no such protection.

**Reproduced, with the sibling route as the control** — two stubbed backends, one
healthy, one whose `is_available()` raises `OSError`:

```
_gather_resources  (guarded, line 40)    → 200
index              (unguarded, line 63-66) → EXCEPTION OSError: daemon socket vanished
```

So a single flaky backend 500s the **entire page** while `/partials/resources` —
which renders the same inventory from the same runners — serves fine. The failure
is also the least useful shape: the user loses the whole UI rather than one row,
and the reason is a daemon hiccup that the code one function away already treats
as expected.

Whether a real backend's `is_available()` can raise is worth stating precisely
rather than assuming: `docker.py` and `podman.py` both guard with `shutil.which()`
before calling `run_capture`, and `run_capture` converts a timeout into a
`CompletedProcess`, so the common paths are covered. But `run_capture` catches
**only** `subprocess.TimeoutExpired` — a `PermissionError` on a non-executable
binary, or any `OSError` from `subprocess.run`, propagates. The defect is that the
two call sites disagree about this, not that a specific exception is known to be
common today.

**Fix direction:** compute `unavailable` inside `_gather_resources` (it already
iterates every runner and already knows which ones it skipped) and return it
alongside `grouped`. That removes the second call entirely — which also fixes the
double-probe in §3 — and leaves exactly one place where the trust decision is
made.

### P6B-2 — LOW/MED — the vendored JS has no provenance, and the README calls vendoring the mitigation

`lab_web/static/` ships two third-party files:

```
48101 bytes  htmx.min.js
 9186 bytes  sse.js
```

Neither carries a version, an upstream URL, a retrieval date, or a checksum.
`sse.js`'s header is the extension's prose description only; `htmx.min.js` is
minified with no banner. The README (line 190) presents this as hardening:

> *"vendored htmx/sse.js (no CDN supply-chain dependency)"*

Vendoring **is** the right call, and it does remove the CDN as a live dependency.
But it moves the supply-chain question rather than answering it: with no recorded
provenance you cannot verify that what is on disk is what upstream published, you
cannot tell which release you are on when a CVE lands, and you cannot reproduce
the fetch. Measured, that asymmetry is concrete:

| file | version recoverable from the bytes? |
|---|---|
| `htmx.min.js` | yes — `version:"1.9.12"` is embedded in the minified source |
| `sse.js` | **no** — nothing in the file identifies which htmx release its extension came from |

This is the same class as [`AUDIT.md`](AUDIT.md)'s **F5** (*"iPXE built from moving
`master` ref; base image unpinned"*), which is marked RESOLVED for netboot by
[`netboot/versions.env`](netboot/versions.env) — that file pins the release, **the
commit that release must resolve to**, and the base image by digest, and the
builder refuses a moved tag by name. The repo also has a written convention for
vendored upstream material (CLAUDE.md, *Provenance*): a table of Title / Author /
Canonical URL / Published / **Retrieved**, a per-file **`sha256`** table, and an
attribution paragraph. Neither standard was applied here.

**Fix direction:** a short `static/PROVENANCE.md` (or a `versions.env` sibling)
recording, for each file, the upstream URL, the release tag, the retrieved date,
and the `sha256` — which is all that is needed to make the README's claim
checkable. For the record, today's bytes are:

```
449317ade7881e949510db614991e195c3a099c4c791c24dacec55f9f4a2a452  htmx.min.js   (htmx 1.9.12)
c07c53b007c0898bc70493e55479019684dcfb9e21ab5368534f6b36ada7502b  sse.js        (version unknown)
```

Establishing `sse.js`'s provenance requires going back to upstream — which is the
cost of not recording it at vendor time, and the reason the convention exists.

### P6B-3 — LOW — one value is escaped twice

`actions.py` escapes URL-derived values before reflecting them (finding F-3), and
for the two bare-`HTMLResponse` paths that is exactly right:

```python
return HTMLResponse(f"<p class='error'>Unknown backend: {html.escape(backend)}</p>")   # 51 ✓ raw response
return HTMLResponse(f"<p class='error'>Resource not found: {html.escape(name)}</p>")   # 56 ✓ raw response
```

The third one goes into a **template** context instead:

```python
context={"inspect_text": f"✓ {html.escape(name)} destroyed."}    # 72 — template autoescapes it AGAIN
```

**Reproduced** with an ordinary name — no hostile input required:

```
resource name            : lab-a&b-web
rendered success message : <pre>✓ lab-a&amp;amp;b-web destroyed.</pre>
```

The user sees `lab-a&amp;b-web`. It is cosmetic — double-escaping is fail-safe, never
fail-open — but it is worth recording for *why* it exists: before the F-1 fix,
`.html.j2` templates were **not** autoescaped, so this manual `html.escape` was
load-bearing. F-1 changed the contract for every template variable and the callers
were not revisited, so the escape that used to be necessary is now redundant. The
same edit is what makes `stream.py`'s missing escapes (P6-3 in the sibling review)
*not* covered — one file gained a second layer, another kept zero.

**Fix direction:** drop `html.escape` at line 72 only, keeping it at 51 and 56.
The distinction to encode is "is this string going into a template or into a bare
`HTMLResponse`?" — worth a one-line comment at each site, since the two look
identical at a glance and the correct answer differs.

---

## 3. Minor / robustness (not standalone findings)

- **`is_available()` runs twice per backend per page load.** Measured: 2 calls per
  backend per `GET /`. For docker and podman each call is a `docker version` /
  `podman version` subprocess; for LXD it is an engine probe. With the six
  registered backends that is up to twelve subprocess round-trips to render one
  page, on a page that refreshes itself via `hx-trigger`. Each is subject to the
  120 s `DEFAULT_TIMEOUT`. P6B-1's fix removes the second call as a side effect.

- **`_find_resource` re-lists an entire backend on every call.** It calls
  `runner.list_resources()` and scans linearly for a name match. `stream_progress`
  calls it **every 2 seconds** for the lifetime of each connected SSE client, so a
  progress panel left open is a sustained engine query loop. Correct, and cheap for
  a single-user lab, but it is the one place where an idle browser tab generates
  continuous daemon load.

- **`stream.py` returns bare `Response` objects with no `media_type`** (lines 38,
  41, 87). Noted in the sibling review as load-bearing for P6-3's
  non-exploitability; repeated here because it is 6b's code and the fix belongs
  with the escaping fix.

## 3b. Not verified by this pass — UNKNOWN, not PASS

- **No live browser and no live daemons.** Every reproduction used stubbed runners
  over the ASGI transport, exactly as the existing suite does. That is the right
  seam for route logic, but it means none of the real backends' `is_available()` /
  `list_resources()` behaviour was exercised through the web layer.
- **No CVE research was performed on htmx 1.9.12.** P6B-2 is a finding about
  *unrecorded provenance*, not a claim that the vendored version is vulnerable. I
  did not check it against any advisory database, and the review should not be read
  as saying it is clean.
- **The auth-enabled and network-exposed paths were not exercised end-to-end.**
  `_basic_auth_check` was read and the `--host`/`--allow-network` gate was read;
  neither was driven with a running uvicorn on a real socket.
- **`sse.js` / `htmx.min.js` were checked for hand-written DOM sinks and reviewed
  as vendored artifacts** — they were **not** audited as source. `sse.js` contains
  no `innerHTML`/`eval`/`document.write`/`insertAdjacentHTML` and delegates
  swapping to htmx; htmx itself is a framework whose internals were not reviewed
  and are covered by P6B-2 instead.

## 4. Investigated and cleared (so it is not re-raised)

- **The templates do not defeat autoescaping.** No `|safe`, no
  `{% autoescape false %}`, no `Markup` in any of the four `.html.j2` files. The
  only matches for "safe" are the `safe_id` **filter** — correctly applied to the
  two `id`/`hx-target` attributes where a resource name would otherwise produce an
  invalid selector (F-13). Backend-controlled `inspect_text` reaches the page at
  three sites, all as escaped text nodes.
- **The JSON API's unescaped f-strings are safe.** `resources.py:170,173` build
  `{"error": f"unknown backend: {backend}"}` from URL-derived values without
  escaping, but they are serialized by `JSONResponse`, so the value is
  JSON-encoded and lands as a string, not markup. Unlike `stream.py`'s bare
  `Response`, this one is correct by construction.
- **`_gather_resources`' broad `except Exception: continue`** looks like it could
  hide a real failure, and does — but deliberately and correctly: a backend whose
  daemon is down must not remove the other five from the page. The information it
  swallows is recovered by the `unavailable` list, which is exactly what P6B-1 is
  about computing safely.
- **P6-1 (`Host`/DNS rebinding) and P6-3 (`stream.py` escaping)** are Phase 6b
  defects, are already recorded in
  [`REVIEW-phase6-2026-08.md`](REVIEW-phase6-2026-08.md), and are deliberately not
  restated as new findings here. They remain open.

## 5. Feature completeness

Phase 6b's surface is small and complete for its stated role as a read-mostly
console: a grouped resource index, an HTMX-refreshed inventory partial, a detail
panel with lazy inspect, an SSE log tail, an SSE progress bar, one mutating action
(destroy), and a versioned JSON API (`/api/v1/resources`, `schema_version: 1`) so
something other than the browser can consume the same inventory. Deployment is
genuinely thought through: loopback default, a two-flag gate for network exposure,
Basic Auth, `docs_url` off unless `LAB_WEB_DEV=1`, and a documented SSH-forward
recipe. No missing feature rises to a finding.

## 6. Calibration — good patterns preserved

The autoescape fix is the model: `Jinja2Templates` is constructed with an explicit
`select_autoescape(enabled_extensions=("html.j2", …))` and a comment naming what
was rendered raw before — because the framework default *looks* like it covers
templates and does not match `.html.j2`. That is the outcome-over-mechanism rule
applied to a third-party default. `safe_id` exists because a resource name is not
a valid HTML `id`, and it is applied at both sites that need it rather than being
defined and forgotten. The JSON API is versioned at the schema level, not the URL
level alone. Backends are stubbed in `conftest.py` so the suite never touches a
real daemon or state dir — which is why 44 tests run in 0.2 s and why this review
could reproduce every finding in-process. And `_gather_resources`' decision to
degrade to a partial inventory rather than fail whole is the right instinct; P6B-1
is that instinct not being carried twenty lines further down the same file.
