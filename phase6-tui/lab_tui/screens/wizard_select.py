"""WizardSelectScreen — pick which phase's create-wizard to open.

Shown when the user presses 'n' (new) in the resource browser.
A simple modal list of the five phases; selecting one opens the
corresponding WizardModal.
"""

from __future__ import annotations

from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import ModalScreen
from textual.widgets import Label, OptionList
from textual.widgets.option_list import Option

_OPTIONS = [
    Option("Phase 1 — Chroot       (lab-chroot.sh create)", id="phase1"),
    Option("Phase 2 — QEMU VM      (lab-vm.sh create)",     id="phase2"),
    Option("Phase 3 — Docker svc   (lab-docker.sh up)",     id="phase3"),
    Option("Phase 4 — Podman svc   (lab-podman.sh up)",     id="phase4"),
    Option("Phase 5 — LXD instance (lab-lxd.sh up)",        id="phase5"),
]


class WizardSelectScreen(ModalScreen[str | None]):
    """Dismiss value: the chosen phase id ("phase1"…"phase5"), or None."""

    BINDINGS = [
        Binding("escape,q", "dismiss_none", "Close"),
    ]

    CSS = """
    WizardSelectScreen { align: center middle; }
    #dialog {
        width: 60%;
        height: auto;
        padding: 1 2;
        background: $panel;
        border: heavy $primary;
    }
    #title  { margin-bottom: 1; }
    OptionList { height: auto; border: none; }
    """

    def compose(self) -> ComposeResult:
        from textual.containers import Vertical
        with Vertical(id="dialog"):
            yield Label("[b]✦ New resource — choose a phase[/b]", id="title")
            yield OptionList(*_OPTIONS, id="choices")

    def on_mount(self) -> None:
        self.query_one(OptionList).focus()

    def on_option_list_option_selected(
        self, event: OptionList.OptionSelected
    ) -> None:
        self.dismiss(event.option.id)

    def action_dismiss_none(self) -> None:
        self.dismiss(None)
