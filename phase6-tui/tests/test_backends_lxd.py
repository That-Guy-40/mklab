from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from lab_tui.backends.lxd import LXDBackend


@pytest.fixture
def patched_lxd(monkeypatch: pytest.MonkeyPatch, fixtures_dir: Path):
    """Pin the LXD backend's engine probe to a fake 'incus' and replace
    `run_capture` so `incus list --all-projects --format=json` returns
    our fixture."""
    fixture = (fixtures_dir / "lxd-list.json").read_text()

    # Class-level cache; reset between tests.
    LXDBackend._engine_cmd = None  # noqa: SLF001
    monkeypatch.setattr(
        LXDBackend, "_probe_engine",
        lambda self: "incus",
    )

    def fake_run_capture(argv, *, env=None):
        if argv[:4] == ["incus", "list", "--all-projects", "--format=json"]:
            return subprocess.CompletedProcess(argv, 0, fixture, "")
        if argv[:1] == ["incus"] and "config" in argv and "show" in argv:
            return subprocess.CompletedProcess(argv, 0, "name: stub\n", "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected argv")

    # Patch the run_capture symbol that lxd.py imported.
    import lab_tui.backends.lxd as lxd_mod
    monkeypatch.setattr(lxd_mod, "run_capture", fake_run_capture)
    monkeypatch.setattr(
        lxd_mod, "run_json",
        lambda argv: (0, json.loads(fixture))
        if argv == ["incus", "list", "--all-projects", "--format=json"]
        else (1, None),
    )
    return LXDBackend()


def test_list_filters_by_label(patched_lxd: LXDBackend) -> None:
    """Only instances with user.lab-create.tool=lab-lxd should appear —
    the fixture has 3 instances, 2 are tagged, 1 is a manual instance
    that must be excluded."""
    rs = patched_lxd.list_resources()
    assert len(rs) == 2
    names = {r.name for r in rs}
    assert names == {"lab-demo-shell", "lab-demo-vm"}
    # Manual instance excluded.
    assert "manual-instance" not in names


def test_list_classifies_container_vs_vm(patched_lxd: LXDBackend) -> None:
    rs = {r.name: r for r in patched_lxd.list_resources()}
    assert rs["lab-demo-shell"].type == "instance"
    assert rs["lab-demo-shell"].status == "running"
    assert rs["lab-demo-vm"].type == "vm"
    assert rs["lab-demo-vm"].status == "stopped"


def test_list_propagates_project_to_log_command(patched_lxd: LXDBackend) -> None:
    rs = {r.name: r for r in patched_lxd.list_resources()}
    # Default project: no --project flag.
    assert "--project" not in rs["lab-demo-shell"].log_command
    # Non-default project: --project demo-proj should appear.
    assert "--project" in rs["lab-demo-vm"].log_command
    assert "demo-proj" in rs["lab-demo-vm"].log_command


def test_list_lab_filter(patched_lxd: LXDBackend) -> None:
    assert len(patched_lxd.list_resources(lab="demo")) == 2
    assert len(patched_lxd.list_resources(lab="nonexistent")) == 0


def test_destroy_argv_uses_lab_slash_svc(patched_lxd: LXDBackend) -> None:
    rs = patched_lxd.list_resources()
    shell = next(r for r in rs if r.svc == "shell")
    argv = patched_lxd.destroy_argv(shell)
    assert argv[-2:] == ["destroy", "demo/shell"]
