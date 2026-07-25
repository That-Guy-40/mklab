"""Tests for the control-pane inventory backend.

This is an integration test by design: the backend shells out to the real
`examples/control-pane/control-pane` CLI (the documented contract), so it proves the
end-to-end path — a registered node.toml + a console → parsed progress in a Resource.
"""
from __future__ import annotations

from pathlib import Path

from lab_tui.backends.control_pane import ControlPaneBackend


def _register(state_dir: Path, name: str, profile: str, console: str) -> None:
    nd = state_dir / "control-pane" / name
    nd.mkdir(parents=True, exist_ok=True)
    (nd / "node.toml").write_text(f'profile = "{profile}"\nconsole = "{console}"\n')


def test_lists_nodes_with_progress(fake_state_dir: Path, tmp_path: Path) -> None:
    console = tmp_path / "edge1.console"
    console.write_text("Starting partitioner\nInstalling the base system\n"
                       "Running post-install\nlogin:\n")
    _register(fake_state_dir, "edge1", "install", str(console))
    _register(fake_state_dir, "edge2", "install", str(tmp_path / "never-started.console"))

    res = {r.name: r for r in ControlPaneBackend().list_resources()}
    assert set(res) == {"edge1", "edge2"}
    assert res["edge1"].backend == "control-pane"
    assert res["edge1"].extra["percent"] == 100
    assert res["edge1"].extra["label"] == "first boot"
    assert res["edge1"].status == "built"      # reached its terminal milestone
    assert res["edge2"].extra["percent"] == 0
    assert res["edge2"].status == "stopped"    # registered, not started


def test_empty_fleet_is_empty(fake_state_dir: Path) -> None:
    assert ControlPaneBackend().list_resources() == []


def test_destroy_is_inert_read_only(fake_state_dir: Path, tmp_path: Path) -> None:
    _register(fake_state_dir, "n1", "install", str(tmp_path / "c"))
    r = ControlPaneBackend().list_resources()[0]
    argv = ControlPaneBackend().destroy_argv(r)
    assert argv[0] == "echo"                    # never a destructive verb
    assert "not owned" in " ".join(argv)


def test_inspect_shows_milestone_timeline(fake_state_dir: Path, tmp_path: Path) -> None:
    console = tmp_path / "c.console"
    console.write_text("Starting partitioner\n")
    _register(fake_state_dir, "n", "install", str(console))
    r = ControlPaneBackend().list_resources()[0]
    text = ControlPaneBackend().inspect(r)
    assert "partitioning" in text
    assert "milestones:" in text
