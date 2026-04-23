"""Modal that shows the literal command about to run and asks y/n.

Every destructive action in the TUI routes through this screen — there
is no keyboard bypass.  Dismisses with `True` on approval, `False` on
cancel.  If `argv` is given, it's executed on approval and its output
streamed into a Log widget before the screen closes.
"""

from __future__ import annotations

import asyncio

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Label, Log


class ConfirmScreen(ModalScreen[bool]):
    BINDINGS = [
        Binding("escape,n", "cancel", "Cancel"),
        Binding("y", "approve", "Approve"),
    ]

    CSS = """
    ConfirmScreen { align: center middle; }
    #dialog {
        width: 80%;
        height: 70%;
        padding: 1 2;
        background: $panel;
        border: heavy $warning;
    }
    #command { margin-bottom: 1; padding: 0 1; background: $surface; }
    #buttons { layout: horizontal; align: center middle; height: 3; }
    Button { margin: 0 1; }
    """

    def __init__(self, title: str, argv: list[str]) -> None:
        super().__init__()
        self._title = title
        self._argv = argv

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(f"[b yellow]⚠ {self._title}[/b yellow]")
            yield Label("Command to run:")
            yield Label(" ".join(self._argv), id="command")
            yield Log(id="output", highlight=True)
            from textual.containers import Horizontal
            with Horizontal(id="buttons"):
                yield Button("Approve (y)", id="ok", variant="warning")
                yield Button("Cancel (n)", id="cancel", variant="primary")

    def action_cancel(self) -> None:
        self.dismiss(False)

    def action_approve(self) -> None:
        self.run_worker(self._run(), exclusive=True)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "ok":
            self.action_approve()
        elif event.button.id == "cancel":
            self.action_cancel()

    async def _run(self) -> None:
        log: Log = self.query_one("#output", Log)
        log.write_line(f"$ {' '.join(self._argv)}")
        try:
            proc = await asyncio.create_subprocess_exec(
                *self._argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
        except FileNotFoundError as e:
            log.write_line(f"[error] {e}")
            self.dismiss(False)
            return
        assert proc.stdout is not None
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            log.write_line(line.decode(errors="replace").rstrip("\n"))
        rc = await proc.wait()
        log.write_line(f"[exit {rc}]")
        self.dismiss(rc == 0)
