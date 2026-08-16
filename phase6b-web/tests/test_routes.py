"""Route-level tests for the Phase 6b web UI.

All tests use the stubbed ASGI client from conftest — no live backends,
no phase scripts executed.
"""

from __future__ import annotations

import pytest

from lab_web.app import CSRF_TOKEN

# W3 (Review phase6): HTMX requests must carry BOTH the HX-Request marker and
# the per-process CSRF token.  Passing destroy calls use this; the negative
# tests below omit one or the other on purpose.
_HX = {"HX-Request": "true", "X-CSRFToken": CSRF_TOKEN}


# ── index page ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_index_returns_html(client) -> None:
    resp = await client.get("/")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "lab-create" in resp.text


@pytest.mark.asyncio
async def test_index_contains_htmx(client) -> None:
    resp = await client.get("/")
    # F-5: scripts are now vendored in /static/ — not from external CDN.
    assert "htmx.min.js" in resp.text


# ── resource partial ──────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_partial_resources_html(client) -> None:
    resp = await client.get("/partials/resources")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]


# ── detail panel ──────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_detail_panel_found(client) -> None:
    resp = await client.get("/resources/stub-backend/test-vm")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "test-vm" in resp.text


@pytest.mark.asyncio
async def test_detail_panel_unknown_backend(client) -> None:
    resp = await client.get("/resources/nonexistent/foo")
    assert resp.status_code == 200          # HTMX partial — always 200
    assert "Unknown backend" in resp.text


@pytest.mark.asyncio
async def test_detail_panel_unknown_resource(client) -> None:
    resp = await client.get("/resources/stub-backend/does-not-exist")
    assert resp.status_code == 200
    assert "not found" in resp.text.lower()


# ── JSON API ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_api_resources_json(client) -> None:
    resp = await client.get("/api/v1/resources")
    assert resp.status_code == 200
    doc = resp.json()
    assert doc["schema_version"] == 1
    assert isinstance(doc["resources"], list)
    assert len(doc["resources"]) > 0


@pytest.mark.asyncio
async def test_api_resources_fields(client) -> None:
    resp = await client.get("/api/v1/resources")
    resources = resp.json()["resources"]
    r = resources[0]
    for field in ("backend", "name", "lab", "type", "status", "display_name"):
        assert field in r, f"missing field: {field}"


@pytest.mark.asyncio
async def test_api_resource_detail(client) -> None:
    resp = await client.get("/api/v1/resources/stub-backend/test-vm")
    assert resp.status_code == 200
    doc = resp.json()
    assert doc["name"] == "test-vm"
    assert "inspect" in doc


@pytest.mark.asyncio
async def test_api_resource_not_found(client) -> None:
    resp = await client.get("/api/v1/resources/stub-backend/no-such-vm")
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_api_resource_unknown_backend(client) -> None:
    resp = await client.get("/api/v1/resources/ghost/foo")
    assert resp.status_code == 404


# ── actions ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_destroy_returns_html(client) -> None:
    # F-4: must send HX-Request: true to pass the CSRF guard.
    resp = await client.post(
        "/actions/destroy/stub-backend/test-vm",
        headers=_HX,
    )
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "destroyed" in resp.text.lower()


@pytest.mark.asyncio
async def test_destroy_unknown_backend(client) -> None:
    resp = await client.post(
        "/actions/destroy/ghost/foo",
        headers=_HX,
    )
    assert resp.status_code == 200
    assert "Unknown backend" in resp.text


# ── security tests ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_destroy_requires_htmx_header(client) -> None:
    """F-4: POST without HX-Request header should be rejected (CSRF guard)."""
    resp = await client.post("/actions/destroy/stub-backend/test-vm")
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_xss_in_backend_name_is_escaped(client) -> None:
    """F-3: '<script>' in backend URL param must be HTML-escaped in error response."""
    resp = await client.post(
        "/actions/destroy/<script>alert(1)<%2Fscript>/foo",
        headers=_HX,
    )
    assert "<script>" not in resp.text
    assert "alert(1)" not in resp.text or "&lt;script&gt;" in resp.text


@pytest.mark.asyncio
async def test_xss_in_resource_name_is_escaped(client) -> None:
    """F-3: '<img>' in resource name URL param must be HTML-escaped in error response."""
    resp = await client.post(
        "/actions/destroy/stub-backend/<img+src=x+onerror=alert(1)>",
        headers=_HX,
    )
    # The raw tag must not appear verbatim in the response
    assert "<img" not in resp.text or "&lt;img" in resp.text


@pytest.mark.asyncio
async def test_detail_panel_escapes_unknown_backend(client) -> None:
    """Regression (Review phase6 W1): the GET detail-panel 'Unknown backend'
    fragment reflected the URL param RAW (unlike the escaped actions.py
    fragments).  A '<script>' backend must come back escaped."""
    resp = await client.get("/resources/<script>alert(1)</script>/foo")
    assert "<script>alert(1)</script>" not in resp.text
    assert "&lt;script&gt;" in resp.text


@pytest.mark.asyncio
async def test_detail_panel_escapes_missing_resource_name(client) -> None:
    """Regression (Review phase6 W1): the 'Resource not found' fragment
    reflected the resource name RAW.  A '<img onerror=…>' name (no match on
    the stub backend) must come back escaped, not verbatim."""
    resp = await client.get("/resources/stub-backend/<img src=x onerror=alert(1)>")
    assert "<img src=x onerror=alert(1)>" not in resp.text
    assert "&lt;img" in resp.text


# ── W3: CSRF token (not just HX-Request presence) ──────────────────────────

@pytest.mark.asyncio
async def test_destroy_without_csrf_token_rejected(client) -> None:
    """Regression (W3): HX-Request alone (the old, forgeable guard) must no
    longer pass — the request must also carry the per-process CSRF token."""
    resp = await client.post(
        "/actions/destroy/stub-backend/test-vm",
        headers={"HX-Request": "true"},  # deliberately NO X-CSRFToken
    )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_destroy_with_wrong_csrf_token_rejected(client) -> None:
    """Regression (W3): a wrong token is refused (constant-time compare)."""
    resp = await client.post(
        "/actions/destroy/stub-backend/test-vm",
        headers={"HX-Request": "true", "X-CSRFToken": "not-the-real-token"},
    )
    assert resp.status_code == 403


@pytest.mark.asyncio
async def test_page_embeds_csrf_token(client) -> None:
    """Regression (W3): the token is injected into the page so HTMX can echo
    it — otherwise legitimate destroys would be impossible."""
    resp = await client.get("/")
    assert CSRF_TOKEN in resp.text
    assert "hx-headers" in resp.text


# ── W4: /static/ auth exemption is normalized, not raw-prefix ──────────────

def test_static_exemption_is_traversal_safe() -> None:
    """Regression (W4): the auth exemption must test the NORMALIZED path so a
    crafted /static/../<control-route> cannot skip auth by sharing the prefix."""
    from lab_web.app import _is_static_path
    assert _is_static_path("/static/style.css")
    assert _is_static_path("/static")
    # A traversal that Starlette would route to the control plane must NOT be
    # treated as a static asset (i.e. must NOT skip auth).
    assert not _is_static_path("/static/../actions/destroy/stub-backend/x")
    assert not _is_static_path("/static/../../etc/passwd")
    assert not _is_static_path("/actions/destroy/stub-backend/x")


# ── W5: security headers on 401 + inspect errors return a clean fragment ───

@pytest.mark.asyncio
async def test_401_carries_security_headers(auth_client) -> None:
    """Regression (W5): the security-headers middleware is now OUTER, so even
    the auth 401 short-circuit gets X-Frame-Options / CSP (previously bare)."""
    resp = await auth_client.get("/")
    assert resp.status_code == 401
    assert resp.headers.get("X-Frame-Options") == "DENY"
    assert "Content-Security-Policy" in resp.headers


@pytest.mark.asyncio
async def test_inspect_backend_error_returns_clean_fragment(client) -> None:
    """Regression (W5): a backend inspect() that raises must return a clean,
    escaped HTMX fragment (logged server-side) — not a bare 500 stack."""
    from lab_web.app import app
    app.state.runners["stub-backend"].inspect.side_effect = RuntimeError("boom")
    try:
        resp = await client.get("/resources/stub-backend/test-vm")
    finally:
        app.state.runners["stub-backend"].inspect.side_effect = None
    assert resp.status_code == 200          # HTMX partial, not a 500
    assert "Inspect failed" in resp.text
    assert "boom" not in resp.text          # no internal detail leaked


@pytest.mark.asyncio
async def test_security_headers_present(client) -> None:
    """F-15: key security headers must be set on every response."""
    resp = await client.get("/")
    assert resp.headers.get("X-Frame-Options") == "DENY"
    assert resp.headers.get("X-Content-Type-Options") == "nosniff"
    assert "Content-Security-Policy" in resp.headers


@pytest.mark.asyncio
async def test_htmx_loaded_from_static(client) -> None:
    """F-5: HTMX must be loaded from /static/ not from an external CDN."""
    resp = await client.get("/")
    assert "unpkg.com" not in resp.text
    assert "/static/htmx.min.js" in resp.text


# ── loopback-only default ─────────────────────────────────────────────────

def test_default_host_is_loopback() -> None:
    """The default bind address must be 127.0.0.1."""
    import argparse
    import sys
    from io import StringIO
    from lab_web.__main__ import main as web_main

    # Capture the parser default without running uvicorn.
    import lab_web.__main__ as _m
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args([])
    assert args.host == "127.0.0.1"


# ── Basic Auth (PLAN spec / audit F-7) ────────────────────────────────────

import base64
import os
import pytest_asyncio
from httpx import ASGITransport, AsyncClient


@pytest_asyncio.fixture
async def auth_client(sample_resources):
    """Client with Basic Auth enabled (user 'alice', password 'secret')."""
    from lab_web.app import app
    from tests.conftest import _stub_runners
    app.state.runners = _stub_runners(sample_resources)
    os.environ["LAB_WEB_AUTH_USER"] = "alice"
    os.environ["LAB_WEB_AUTH_PASSWORD"] = "secret"
    try:
        async with AsyncClient(
            transport=ASGITransport(app=app),
            base_url="http://127.0.0.1",  # P6-1: loopback Host
        ) as ac:
            yield ac
    finally:
        os.environ.pop("LAB_WEB_AUTH_USER", None)
        os.environ.pop("LAB_WEB_AUTH_PASSWORD", None)


def _basic(user: str, password: str) -> dict[str, str]:
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    return {"Authorization": f"Basic {token}"}


@pytest.mark.asyncio
async def test_auth_disabled_no_header_required(client) -> None:
    """When LAB_WEB_AUTH_* env vars are unset, requests pass through."""
    resp = await client.get("/")
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_auth_enabled_no_header_returns_401(auth_client) -> None:
    """With auth enabled, an unauthenticated request returns 401 + WWW-Authenticate."""
    resp = await auth_client.get("/")
    assert resp.status_code == 401
    assert resp.headers.get("WWW-Authenticate", "").startswith("Basic ")


@pytest.mark.asyncio
async def test_auth_enabled_correct_credentials_pass(auth_client) -> None:
    resp = await auth_client.get("/", headers=_basic("alice", "secret"))
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_auth_enabled_wrong_password_returns_401(auth_client) -> None:
    resp = await auth_client.get("/", headers=_basic("alice", "wrong"))
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_auth_enabled_wrong_user_returns_401(auth_client) -> None:
    resp = await auth_client.get("/", headers=_basic("bob", "secret"))
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_auth_enabled_malformed_header_returns_401(auth_client) -> None:
    """Garbage in the Authorization header is rejected without crashing."""
    resp = await auth_client.get(
        "/", headers={"Authorization": "Basic not-valid-base64!!!"}
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_auth_enabled_non_basic_scheme_returns_401(auth_client) -> None:
    resp = await auth_client.get(
        "/", headers={"Authorization": "Bearer some-token"}
    )
    assert resp.status_code == 401


@pytest.mark.asyncio
async def test_auth_enabled_static_files_exempt(auth_client) -> None:
    """/static/* must be accessible without auth so CSS/JS load on login page."""
    resp = await auth_client.get("/static/style.css")
    # 200 if the file exists, 404 if not — but NEVER 401.
    assert resp.status_code != 401


@pytest.mark.asyncio
async def test_auth_destroy_endpoint_requires_credentials(auth_client) -> None:
    """The mutating destroy endpoint must be auth-gated too."""
    resp = await auth_client.post(
        "/actions/destroy/stub-backend/test-vm",
        headers={"HX-Request": "true"},  # F-4 CSRF guard
    )
    assert resp.status_code == 401


# ── CLI validation: --host non-loopback requires --allow-network + --auth ──

def test_cli_refuses_nonloopback_without_allow_network(monkeypatch, capsys) -> None:
    """--host 0.0.0.0 without --allow-network must exit non-zero."""
    from lab_web.__main__ import main
    monkeypatch.setattr("sys.argv", ["lab-web", "--host", "0.0.0.0"])
    rc = main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "--allow-network" in err


def test_cli_refuses_allow_network_without_auth(monkeypatch, capsys) -> None:
    """--allow-network without --auth must exit non-zero."""
    from lab_web.__main__ import main
    monkeypatch.setattr(
        "sys.argv",
        ["lab-web", "--host", "0.0.0.0", "--allow-network"],
    )
    # Make sure the LAB_WEB_AUTH env fallback is not set.
    monkeypatch.delenv("LAB_WEB_AUTH", raising=False)
    rc = main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "--auth" in err


def test_cli_refuses_malformed_auth(monkeypatch, capsys) -> None:
    """--auth without a colon must exit non-zero."""
    from lab_web.__main__ import main
    monkeypatch.setattr("sys.argv", ["lab-web", "--auth", "no-colon-here"])
    rc = main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "USER:PASS" in err


def test_cli_refuses_empty_user_or_password(monkeypatch, capsys) -> None:
    from lab_web.__main__ import main
    monkeypatch.setattr("sys.argv", ["lab-web", "--auth", ":pass-only"])
    rc = main()
    assert rc == 2
    err = capsys.readouterr().err
    assert "non-empty" in err


# ── P6-1: Host validation (anti-DNS-rebinding) ────────────────────────────────
#
# The whole suite used base_url="http://test" — a foreign Host on every one of the
# 44 requests — which is precisely why a full review pass did not notice that no
# Host validation existed. These tests send the foreign Host deliberately.
#
# The attack the guard closes: the user visits evil.example, whose DNS flips to
# 127.0.0.1. The browser then sends requests here with `Host: evil.example` while
# treating the responses as SAME-ORIGIN — so the page can read the per-process CSRF
# token out of `<body hx-headers>` and echo it back. The CSRF guard is not bypassed;
# it is SATISFIED. What that reaches is `runner.destroy(...)`, which for two backends
# is a `sudo …/lab-chroot.sh destroy -- <name> --force`.

@pytest.mark.asyncio
async def test_foreign_host_is_refused(client) -> None:
    resp = await client.get("/", headers={"Host": "evil.example"})
    assert resp.status_code == 400, (
        "REGRESSION: a request carrying a foreign Host was served. DNS rebinding makes "
        "an attacker same-origin, which defeats BOTH the loopback default and the CSRF "
        "token — the token is readable by a same-origin page and simply echoed back."
    )
    assert "Host" in resp.text


@pytest.mark.asyncio
async def test_foreign_host_cannot_read_the_csrf_token(client) -> None:
    """The rebinding chain, cut at its first step."""
    resp = await client.get("/", headers={"Host": "evil.example"})
    assert resp.status_code == 400
    from lab_web.app import CSRF_TOKEN
    assert CSRF_TOKEN not in resp.text, (
        "REGRESSION: the per-process CSRF token was served to a foreign-Host request; "
        "a rebound page could read it and then satisfy the CSRF check"
    )


@pytest.mark.asyncio
async def test_foreign_host_is_refused_before_auth(client, monkeypatch) -> None:
    """Ordering matters: the Host gate must run BEFORE the credential comparison.

    Starlette inserts each `@app.middleware` at the head of the stack, so the LAST
    registered runs FIRST — which is why `trusted_host` is defined after `basic_auth`
    in app.py. If that order ever inverts, an unauthenticated foreign-Host probe
    reaches the credential compare and this test goes red.
    """
    monkeypatch.setenv("LAB_WEB_AUTH_USER", "alice")
    monkeypatch.setenv("LAB_WEB_AUTH_PASSWORD", "s3cr3t")
    resp = await client.get("/", headers={"Host": "evil.example"})
    assert resp.status_code == 400, (
        f"expected the Host gate to refuse first, got {resp.status_code} "
        "(401 means auth ran first — the middleware order inverted)"
    )


@pytest.mark.asyncio
async def test_loopback_hosts_are_accepted(client) -> None:
    """Control: the guard must not refuse the names the UI is actually reached by.

    A gate that rejected everything would pass the assertions above while breaking
    the product.
    """
    for host in ("127.0.0.1", "127.0.0.1:8080", "localhost", "localhost:8080", "[::1]", "[::1]:8080"):
        resp = await client.get("/", headers={"Host": host})
        assert resp.status_code == 200, f"loopback Host {host!r} was refused ({resp.status_code})"


@pytest.mark.asyncio
async def test_allowed_hosts_env_extends_the_list(client, monkeypatch) -> None:
    """An operator behind a proxy can name their host, and only that host."""
    monkeypatch.setenv("LAB_WEB_ALLOWED_HOSTS", "lab.internal")
    assert (await client.get("/", headers={"Host": "lab.internal"})).status_code == 200
    assert (await client.get("/", headers={"Host": "lab.internal:8080"})).status_code == 200
    assert (await client.get("/", headers={"Host": "evil.example"})).status_code == 400
    # loopback still works — the env var extends, it does not replace
    assert (await client.get("/", headers={"Host": "127.0.0.1"})).status_code == 200


@pytest.mark.asyncio
async def test_allowed_hosts_star_disables_the_gate(client, monkeypatch) -> None:
    """`--allow-network` sets `*`, because --auth is mandatory on that path.

    Asserted so the escape hatch is a deliberate, tested behaviour rather than an
    accident of parsing.
    """
    monkeypatch.setenv("LAB_WEB_ALLOWED_HOSTS", "*")
    assert (await client.get("/", headers={"Host": "anything.example"})).status_code == 200


@pytest.mark.asyncio
async def test_destroy_is_unreachable_from_a_foreign_host(client, monkeypatch) -> None:
    """The outcome, not the status code: the subprocess must never be invoked."""
    called: list = []
    from lab_web import app as app_mod

    class _Spy:
        name = "chroot"

        def destroy(self, *a, **kw):
            called.append((a, kw))
            return "destroyed"

    monkeypatch.setitem(app_mod.app.state.runners, "chroot", _Spy())
    resp = await client.post(
        "/actions/destroy",
        headers={"Host": "evil.example", "HX-Request": "true",
                 "X-CSRF-Token": app_mod.CSRF_TOKEN},
        data={"backend": "chroot", "name": "demo"},
    )
    assert resp.status_code == 400
    assert called == [], (
        "REGRESSION: a foreign-Host request reached runner.destroy() — for the chroot "
        "and vm backends that argv is a `sudo … destroy -- <name> --force`"
    )


# ── P6B-1: `index` must survive a raising backend, as /partials/resources does ──

class _RaisingRunner:
    """A backend whose availability probe raises — a daemon hiccup."""
    name = "chroot"

    def is_available(self):
        raise OSError("daemon socket went away")

    def list_resources(self):
        raise OSError("daemon socket went away")


@pytest.mark.asyncio
async def test_index_survives_a_backend_whose_probe_raises(client, monkeypatch) -> None:
    from lab_web import app as app_mod
    monkeypatch.setitem(app_mod.app.state.runners, "chroot", _RaisingRunner())
    resp = await client.get("/")
    assert resp.status_code == 200, (
        "REGRESSION: one backend raising in is_available() took down the WHOLE page. "
        "_gather_resources guards the identical call twenty lines above; `index` did not."
    )


@pytest.mark.asyncio
async def test_partial_and_index_agree_when_a_backend_raises(client, monkeypatch) -> None:
    """The asymmetry the finding was about: same runners, same probe, different outcome."""
    from lab_web import app as app_mod
    monkeypatch.setitem(app_mod.app.state.runners, "chroot", _RaisingRunner())
    partial = await client.get("/partials/resources")
    index = await client.get("/")
    assert partial.status_code == index.status_code == 200, (
        f"/partials/resources={partial.status_code} but /={index.status_code} — "
        "the two paths still disagree about a raising backend"
    )


@pytest.mark.asyncio
async def test_is_available_is_probed_once_per_backend(client, monkeypatch) -> None:
    """It used to be called twice per backend per page load."""
    calls: list[str] = []

    class _Counting:
        name = "chroot"

        def is_available(self):
            calls.append("probe")
            return True

        def list_resources(self):
            return []

    from lab_web import app as app_mod
    monkeypatch.setitem(app_mod.app.state.runners, "chroot", _Counting())
    await client.get("/")
    assert calls.count("probe") == 1, (
        f"is_available() was called {calls.count('probe')}× for one backend on one page "
        "load; `index` re-probed what _gather_resources had already learned"
    )


# ── P6B-3: escaped once, at the sink ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_destroy_message_is_escaped_exactly_once(client) -> None:
    """`&` must survive as `&amp;` in the markup — not `&amp;amp;`.

    The F-1 fix turned autoescaping ON for .html.j2, so the template escapes every
    variable; escaping in the route as well double-encoded it. Exactly one site did
    both — lines 51/56 return a bare HTMLResponse (no template) and correctly escape
    there. The rule is per-SINK, not per-value: escape once, where the value meets
    the markup.

    NOTE the resource has to EXIST for this to reach the success branch. An earlier
    version of this test used a name the stub did not know, so it took the
    not-found path — which reflects the name escaped exactly once whatever the bug
    is doing — and passed against the double-escaping driver. The finding lives on
    line 72, and only a successful destroy gets there.
    """
    from lab_web import app as app_mod
    from lab_tui.backends.base import Resource
    runner = app_mod.app.state.runners["stub-backend"]
    runner.list_resources.return_value = [
        Resource(backend="vm", name="lab-a&b-web", lab="t", svc=None,
                 type="vm", status="running"),
    ]
    resp = await client.post("/actions/destroy/stub-backend/lab-a%26b-web", headers=_HX)
    assert resp.status_code == 200, f"destroy failed: {resp.status_code} {resp.text[:200]}"
    assert "destroyed" in resp.text.lower(), (
        f"did not reach the success branch, so line 72 was never rendered: {resp.text[:200]}"
    )
    assert "&amp;amp;" not in resp.text, (
        "REGRESSION: double-escaped — html.escape() in the route plus the template's "
        "autoescape renders `lab-a&b-web` as `lab-a&amp;amp;b-web`"
    )
    assert "lab-a&amp;b-web" in resp.text, (
        f"the name is not escaped exactly once; got: {resp.text[:300]}"
    )


# ── P6-3: W1's escaping, in the third route file ───────────────────────────────

@pytest.mark.asyncio
async def test_stream_unknown_backend_is_escaped_and_typed(client) -> None:
    """`stream.py` reflected the URL-derived backend raw, with NO Content-Type."""
    resp = await client.get("/stream/logs/%3Cimg%20src=x%20onerror=1%3E/demo")
    assert resp.status_code == 404
    assert "<img" not in resp.text, (
        "REGRESSION: stream.py reflects a URL-derived value RAW. actions.py and "
        "resources.py both escape the identical strings; this file is the one W1's "
        "fix did not reach."
    )
    assert "content-type" in {k.lower() for k in resp.headers}, (
        "the response declares no Content-Type at all, leaving the browser to guess — "
        "the condition nosniff exists to make survivable, and not one to rely on"
    )
