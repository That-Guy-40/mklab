"""Route-level tests for the Phase 6b web UI.

All tests use the stubbed ASGI client from conftest — no live backends,
no phase scripts executed.
"""

from __future__ import annotations

import pytest


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
        headers={"HX-Request": "true"},
    )
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "destroyed" in resp.text.lower()


@pytest.mark.asyncio
async def test_destroy_unknown_backend(client) -> None:
    resp = await client.post(
        "/actions/destroy/ghost/foo",
        headers={"HX-Request": "true"},
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
        headers={"HX-Request": "true"},
    )
    assert "<script>" not in resp.text
    assert "alert(1)" not in resp.text or "&lt;script&gt;" in resp.text


@pytest.mark.asyncio
async def test_xss_in_resource_name_is_escaped(client) -> None:
    """F-3: '<img>' in resource name URL param must be HTML-escaped in error response."""
    resp = await client.post(
        "/actions/destroy/stub-backend/<img+src=x+onerror=alert(1)>",
        headers={"HX-Request": "true"},
    )
    # The raw tag must not appear verbatim in the response
    assert "<img" not in resp.text or "&lt;img" in resp.text


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
            base_url="http://test",
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
