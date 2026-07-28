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


def test_declared_actions_pass_through_untouched(
    fake_state_dir: Path, tmp_path: Path
) -> None:
    """The backend carries a node's declared actions without interpreting them.

    The panel is a surface over whatever CLI a lab declares — it must not know what
    any verb means, and must not compose one of its own. So the contract here is
    literally "what the owner wrote is what the consumer sees".
    """
    nd = fake_state_dir / "control-pane" / "n1"
    nd.mkdir(parents=True, exist_ok=True)
    (nd / "node.toml").write_text(
        f'profile = "install"\nconsole = "{tmp_path / "c"}"\n'
        '\n[[action]]\nkey = "a"\nlabel = "Reconcile"\nreconciling = true\n'
        'argv = ["/x/maas-lab.sh", "apply"]\n'
        '\n[[action]]\nkey = "R"\nlabel = "Release"\ndestructive = true\n'
        'argv = ["/x/maas-lab.sh", "release", "n1"]\n'
    )
    r = ControlPaneBackend().list_resources()[0]
    acts = r.extra["actions"]
    assert [a["key"] for a in acts] == ["a", "R"]
    assert acts[0]["argv"] == ["/x/maas-lab.sh", "apply"]
    assert acts[0]["reconciling"] is True and acts[0]["destructive"] is False
    assert acts[1]["destructive"] is True


def test_node_without_declared_actions_gets_an_empty_list(
    fake_state_dir: Path, tmp_path: Path
) -> None:
    """No declaration is an empty list, never a missing key — the panel shows an
    honest 'nothing declared' instead of raising on a node it does not own."""
    _register(fake_state_dir, "plain", "install", str(tmp_path / "c"))
    r = ControlPaneBackend().list_resources()[0]
    assert r.extra["actions"] == []
