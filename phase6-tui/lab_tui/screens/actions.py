"""ActionsScreen — run one of the verbs a node's OWNER declared.

Shown when the user presses 'a' on a resource whose backend exposes declared actions
(today: the control-pane source, whose nodes carry `[[action]]` entries in their
`node.toml`).

The panel never invents a command. A lab declares the exact argv it wants driven, this
lists them, and the chosen one is handed to the confirm screen to run — so the TUI is
never a second implementation of a lab's CLI. That is what keeps the invariant true:
delete Phase 6 and every one of these still works in a shell, because they *are* the
shell commands.

Two flags a declaration may carry, both of which change how a key press is treated:

  reconciling = true   safe to press repeatedly — it converges rather than repeats.
                       Marked in the list, because on a surface where a key can
                       auto-repeat, "what happens if this fires twice" is the first
                       question worth answering.
  destructive = true   requires the confirm step even though it is one keystroke away.
"""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import ModalScreen
from textual.widgets import Label, OptionList
from textual.widgets.option_list import Option


class ActionsScreen(ModalScreen[dict | None]):
    """Dismiss value: the chosen action dict (key/label/argv/…), or None."""

    BINDINGS = [
        Binding("escape,q", "dismiss_none", "Close"),
    ]

    CSS = """
    ActionsScreen { align: center middle; }
    #dialog {
        width: 70%;
        height: auto;
        padding: 1 2;
        background: $panel;
        border: heavy $primary;
    }
    #title { margin-bottom: 1; }
    #hint  { margin-top: 1; color: $text-muted; }
    OptionList { height: auto; border: none; }
    """

    def __init__(self, node: str, actions: list[dict]) -> None:
        super().__init__()
        self._node = node
        self._actions = actions

    def compose(self) -> ComposeResult:
        from textual.containers import Vertical

        options = []
        for i, a in enumerate(self._actions):
            marks = []
            if a.get("reconciling"):
                marks.append("[green]safe to repeat[/green]")
            if a.get("destructive"):
                marks.append("[red]destructive[/red]")
            suffix = ("  " + " · ".join(marks)) if marks else ""
            options.append(Option(f"{a.get('label', '?')}{suffix}", id=str(i)))
        with Vertical(id="dialog"):
            yield Label(f"[b]✦ Actions — {self._node}[/b]", id="title")
            if options:
                yield OptionList(*options, id="choices")
            else:
                yield Label(
                    "This node's owner declared no actions.\n"
                    "Add [[action]] entries to its node.toml.",
                    id="choices",
                )
            yield Label("declared by the lab that owns this node — the panel runs them, "
                        "it does not define them", id="hint")

    def on_mount(self) -> None:
        try:
            self.query_one(OptionList).focus()
        except Exception:      # no options — nothing to focus
            pass

    def on_option_list_option_selected(self, event: OptionList.OptionSelected) -> None:
        try:
            self.dismiss(self._actions[int(event.option.id or "-1")])
        except (ValueError, IndexError):
            self.dismiss(None)

    def action_dismiss_none(self) -> None:
        self.dismiss(None)
