"""Shared fixtures for Phase 6b web tests.

Uses httpx.AsyncClient with FastAPI's ASGI transport so tests run without
a live server — the same pattern as FastAPI's own test docs recommend.

Backends are stubbed out on app.state.runners so tests never call real
phase scripts or read real state dirs.
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from lab_tui.backends.base import Resource


def _stub_runners(resources: list[Resource]) -> dict:
    """Return a runners dict whose every backend returns *resources*."""
    runner = MagicMock()
    runner.is_available.return_value = True
    runner.list_resources.return_value = resources
    runner.inspect.return_value = '{"stub": true}'
    runner.destroy.return_value = MagicMock(returncode=0, stdout="", stderr="")
    runner.destroy_argv.return_value = ["stub", "destroy"]
    runner.log_command = []
    return {"stub-backend": runner}


@pytest.fixture
def sample_resources() -> list[Resource]:
    return [
        Resource(
            backend="vm",
            name="test-vm",
            lab="testlab",
            svc=None,
            type="vm",
            status="running",
        ),
        Resource(
            backend="docker",
            name="lab-testlab-web",
            lab="testlab",
            svc="web",
            type="container",
            status="stopped",
        ),
    ]


@pytest_asyncio.fixture
async def client(sample_resources):
    from lab_web.app import app
    app.state.runners = _stub_runners(sample_resources)
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac
