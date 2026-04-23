"""Log tail viewport.

Runs the resource's log_command as a subprocess and streams stdout into
a Textual Log widget.  Fire-and-forget: closing the screen cancels the
worker which sends SIGTERM to the tail process.
"""

from __future__ import annotations

import asyncio
from contextlib import suppress

from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import Footer, Header, Log

from lab_tui.backends.base import Resource


class LogsScreen(Screen):
    BINDINGS = [
        Binding("escape,q", "app.pop_screen", "Back"),
    ]

    CSS = """
    LogsScreen { layout: vertical; }
    Log { height: 1fr; border: solid $primary-background; }
    """

    def __init__(self, resource: Resource) -> None:
        super().__init__()
        self._resource = resource

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        yield Log(highlight=True, id="log")
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = f"logs: {self._resource.display_name}"
        self.run_worker(self._tail(), exclusive=True)

    async def _tail(self) -> None:
        log: Log = self.query_one("#log", Log)
        log.write_line(f"$ {' '.join(self._resource.log_command)}")
        try:
            proc = await asyncio.create_subprocess_exec(
                *self._resource.log_command,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except FileNotFoundError as e:
            log.write_line(f"[error] {e}")
            return

        try:
            assert proc.stdout is not None
            while True:
                line = await proc.stdout.readline()
                if not line:
                    break
                log.write_line(line.decode(errors="replace").rstrip("\n"))
        except asyncio.CancelledError:
            raise
        finally:
            if proc.returncode is None:
                proc.terminate()
                with suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(proc.wait(), timeout=3.0)
