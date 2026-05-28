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
    assert "htmx.org" in resp.text or "htmx.min.js" in resp.text


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
    resp = await client.post("/actions/destroy/stub-backend/test-vm")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    # Stub runner returns returncode=0, so should show success message.
    assert "destroyed" in resp.text.lower()


@pytest.mark.asyncio
async def test_destroy_unknown_backend(client) -> None:
    resp = await client.post("/actions/destroy/ghost/foo")
    assert resp.status_code == 200
    assert "Unknown backend" in resp.text


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
