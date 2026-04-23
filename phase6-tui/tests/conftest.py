"""Pytest fixtures: tmp_path-based fake $LAB_STATE_DIR for backend tests."""

from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path

import pytest


@pytest.fixture
def fake_state_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """Set LAB_STATE_DIR to a fresh tmp dir with the per-backend layout
    pre-created.  Tests drop fixture files into the right subdirs.
    """
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    for sub in ("chroots", "vms", "podman", "lxd"):
        (tmp_path / sub).mkdir(parents=True, exist_ok=True)
    yield tmp_path


@pytest.fixture
def fixtures_dir() -> Path:
    return Path(__file__).parent / "fixtures"


@pytest.fixture
def fake_pid_path(tmp_path: Path) -> Path:
    """A pidfile pointing at our own PID — guaranteed to be alive."""
    pf = tmp_path / "live.pid"
    pf.write_text(str(os.getpid()))
    return pf


@pytest.fixture
def dead_pid_path(tmp_path: Path) -> Path:
    """A pidfile pointing at PID 999999 — guaranteed dead."""
    pf = tmp_path / "dead.pid"
    pf.write_text("999999")
    return pf
