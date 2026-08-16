"""Web rendering of control-pane progress: the inventory bar + the SSE progress feed."""
from __future__ import annotations

from unittest.mock import MagicMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from lab_tui.backends.base import Resource


def _cp(name, percent, label, terminal=False, stalled=False, status="running"):
    return Resource(
        backend="control-pane", name=name, lab="fleet", svc=None, type="node",
        status=status,
        extra={"percent": percent, "label": label, "terminal": terminal,
               "stalled": stalled, "console": ""},
    )


def _runner(resources):
    r = MagicMock()
    r.is_available.return_value = True
    r.list_resources.return_value = resources
    r.inspect.return_value = "stub"
    r.destroy_argv.return_value = ["echo", "read-only"]
    r.log_command = []
    return r


@pytest_asyncio.fixture
async def cp_client():
    from lab_web.app import app
    app.state.runners = {"control-pane": _runner([
        _cp("edge1", 85, "post-install"),
        _cp("edge2", 100, "first boot", terminal=True, status="built"),
    ])}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://127.0.0.1") as ac:  # P6-1: loopback Host, as the app now requires
        yield ac


@pytest.mark.asyncio
async def test_inventory_renders_progress_bar(cp_client):
    resp = await cp_client.get("/partials/resources")
    assert resp.status_code == 200
    body = resp.text
    assert "progress-bar" in body               # the bar element, not the plain pill
    assert "85%" in body and "post-install" in body
    assert "width: 85%" in body
    assert "progress-bar done" in body          # edge2 terminal -> "done" class


@pytest.mark.asyncio
async def test_sse_progress_streams_a_fragment(cp_client):
    # A terminal node emits one progress event then the stream ends.
    lines: list[str] = []
    async with cp_client.stream("GET", "/stream/progress/control-pane/edge2") as resp:
        assert resp.status_code == 200
        assert resp.headers["content-type"].startswith("text/event-stream")
        async for line in resp.aiter_lines():
            if line.startswith("data:"):
                lines.append(line)
                break
    blob = "\n".join(lines)
    assert "progress-bar" in blob and "100%" in blob and "first boot" in blob


@pytest.mark.asyncio
async def test_sse_progress_unknown_backend_404(cp_client):
    resp = await cp_client.get("/stream/progress/nope/x")
    assert resp.status_code == 404


@pytest.mark.asyncio
async def test_detail_panel_wires_sse_progress(cp_client):
    # selecting a control-pane node shows a live (SSE-connected) progress section
    resp = await cp_client.get("/resources/control-pane/edge1")
    assert resp.status_code == 200
    body = resp.text
    assert 'sse-connect="/stream/progress/control-pane/edge1"' in body
    assert 'sse-swap="message"' in body
    assert "85%" in body and "post-install" in body
