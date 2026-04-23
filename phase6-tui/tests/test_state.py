from __future__ import annotations

from pathlib import Path

import pytest

from lab_tui import state


def test_lab_state_dir_explicit_override(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", "/tmp/explicit-lab-dir")
    assert state.lab_state_dir() == Path("/tmp/explicit-lab-dir")


def test_lab_state_dir_xdg(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("LAB_STATE_DIR", raising=False)
    monkeypatch.setenv("XDG_STATE_HOME", "/tmp/xdg-state")
    # Don't run as root in test environment.
    if hasattr(state.os, "geteuid") and state.os.geteuid() == 0:
        pytest.skip("running as root; XDG path skipped")
    assert state.lab_state_dir() == Path("/tmp/xdg-state/lab-create")


def test_state_subdir_layout(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", "/x")
    assert state.state_subdir("chroot") == Path("/x/chroots")
    assert state.state_subdir("vm") == Path("/x/vms")
    assert state.state_subdir("podman") == Path("/x/podman")
    assert state.state_subdir("lxd") == Path("/x/lxd")
