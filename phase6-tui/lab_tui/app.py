"""Top-level LabApp.  Keeps per-screen state out of the App itself so
the screens stay swappable with minimal coupling."""

from __future__ import annotations

from pathlib import Path

from textual.app import App

from lab_tui.screens.browser import ResourceBrowserScreen
from lab_tui.screens.topology import TopologyScreen


class LabApp(App):
    TITLE = "lab-create"
    SUB_TITLE = ""
    CSS = """
    Screen { background: $surface; }
    """

    def __init__(self, topology_path: Path | None = None) -> None:
        super().__init__()
        self._topology_path = topology_path

    def on_mount(self) -> None:
        if self._topology_path is not None:
            self.push_screen(TopologyScreen(initial_toml=self._topology_path))
        else:
            self.push_screen(ResourceBrowserScreen())
