"""Integration: a registered control-pane node renders a progress bar in the tree."""
from __future__ import annotations

from pathlib import Path

import pytest

from lab_tui.app import LabApp


def _labels(node) -> list[str]:
    """Flatten a Tree's labels to plain strings."""
    out: list[str] = []

    def walk(n) -> None:
        label = getattr(n, "label", "")
        out.append(label.plain if hasattr(label, "plain") else str(label))
        for child in n.children:
            walk(child)

    walk(node)
    return out


@pytest.mark.asyncio
async def test_control_pane_node_shows_progress_bar(fake_state_dir: Path, tmp_path: Path) -> None:
    console = tmp_path / "edge1.console"
    console.write_text("Starting partitioner\nInstalling the base system\n"
                       "Running post-install\nlogin:\n")
    nd = fake_state_dir / "control-pane" / "edge1"
    nd.mkdir(parents=True)
    (nd / "node.toml").write_text(f'profile = "install"\nconsole = "{console}"\n')

    app = LabApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("r")          # force a refresh
        await pilot.pause()
        await pilot.pause()
        from textual.widgets import Tree
        tree = app.screen.query_one(Tree)
        blob = " ".join(_labels(tree.root))

    assert "edge1" in blob
    # the progress bar rendered: percent + label + a filled cell
    assert "100%" in blob and "first boot" in blob
    assert "█" in blob
