"""Textual pilot smoke tests — run the app headless, exercise bindings."""

from __future__ import annotations

import pytest

from lab_tui.app import LabApp


@pytest.mark.asyncio
async def test_app_launches_browser_screen() -> None:
    """The app boots into the browser screen and the tree widget exists."""
    from lab_tui.screens.browser import ResourceBrowserScreen
    app = LabApp()
    async with app.run_test() as pilot:
        # Wait for on_mount → push_screen to settle.
        await pilot.pause()
        await pilot.pause()
        assert isinstance(app.screen, ResourceBrowserScreen)
        from textual.widgets import Tree
        tree = app.screen.query_one(Tree)
        # The tree may or may not have children depending on the host —
        # a clean dev machine with no lab-create resources yields an
        # empty tree, and that's fine.  We're just checking the widget
        # wired up.
        assert tree is not None


@pytest.mark.asyncio
async def test_refresh_binding_runs_without_error() -> None:
    app = LabApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("r")
        await pilot.pause()


@pytest.mark.asyncio
async def test_topology_screen_opens_from_browser(tmp_path) -> None:
    """Pressing 't' opens the topology screen."""
    app = LabApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("t")
        await pilot.pause()
        from lab_tui.screens.topology import TopologyScreen
        assert isinstance(app.screen, TopologyScreen)


@pytest.mark.asyncio
async def test_quit_binding() -> None:
    app = LabApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("q")
        await pilot.pause()
    # If app.run_test() returns cleanly, quit worked.
