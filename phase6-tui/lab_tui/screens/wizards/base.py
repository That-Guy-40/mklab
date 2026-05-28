"""WizardModal — base class for all five phase create-wizards.

Layout (side-by-side within a modal):

  ┌──────────────────────────────────────────────────────────┐
  │  ✦ Create <Phase N> resource                             │
  ├──────────────────┬───────────────────────────────────────┤
  │  Form fields     │  Generated TOML (live preview)        │
  │  (scrollable)    │  (read-only TextArea, TOML syntax)    │
  │                  │                                       │
  ├──────────────────┴───────────────────────────────────────┤
  │  [Save to file]  [Close]                                 │
  └──────────────────────────────────────────────────────────┘

Subclasses override:
  TITLE       — modal header text
  compose_form() → ComposeResult — yield form widgets into the left pane
  generate_toml() → str          — build the TOML string from widget values

The base class wires:
  on_input_changed / on_select_changed / on_checkbox_changed
       → self._refresh_preview()   (updates the right pane)
  "Save to file" → prompts for a path, writes the TOML, notifies
  "Close"        → dismiss(None)
"""

from __future__ import annotations

import os
from abc import abstractmethod
from pathlib import Path


def _toml_str(val: str) -> str:
    """Escape a value for embedding inside a TOML double-quoted string.

    TOML double-quoted strings allow only ``\\`` and ``\"`` as escape
    sequences for the characters that would otherwise break the literal.
    F-01: without this, typing ``"`` or ``\\`` in any wizard field produces
    syntactically broken TOML that is silently swallowed by _refresh_preview
    and then written to disk on save.
    """
    return val.replace("\\", "\\\\").replace('"', '\\"')


def _sanitize_bare_key(key: str) -> str:
    """Strip characters not allowed in a TOML bare key (F-02).

    TOML bare keys may only contain ``[A-Za-z0-9_-]``.  Keys containing
    spaces, ``=``, ``[``, ``"``, or other specials are invalid and cause
    TOMLDecodeError when the file is parsed.  We strip the offenders rather
    than rejecting so the preview stays live; the user sees the cleaned key.
    """
    import re
    return re.sub(r"[^A-Za-z0-9_\-]", "", key)

from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, ScrollableContainer, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Footer, Input, Label, TextArea


class WizardModal(ModalScreen[Path | None]):
    """Base modal for all phase create-wizards.

    Dismiss value: Path to the written TOML file, or None if cancelled.
    """

    TITLE: str = "Create resource"

    # Set by _do_save after a successful write so Close/Escape return the path.
    _saved_path: Path | None = None

    BINDINGS = [
        Binding("escape", "dismiss_none", "Close"),
    ]

    CSS = """
    WizardModal {
        align: center middle;
    }
    #dialog {
        width: 95%;
        height: 90%;
        background: $panel;
        border: heavy $primary;
        padding: 0;
    }
    #wizard-header {
        background: $primary;
        color: $text;
        padding: 0 2;
        height: 3;
        content-align: left middle;
    }
    #body {
        layout: horizontal;
        height: 1fr;
    }
    #form-pane {
        width: 40%;
        border-right: solid $primary-background;
        padding: 1 2;
        overflow-y: auto;
    }
    #preview-pane {
        width: 1fr;
        padding: 1 1;
    }
    #preview {
        height: 1fr;
        border: solid $primary-background;
    }
    #footer-bar {
        height: 4;
        layout: horizontal;
        align: right middle;
        padding: 0 2;
        border-top: solid $primary-background;
    }
    #save-path-row {
        layout: horizontal;
        height: auto;
        display: none;
    }
    #save-path-row.visible {
        display: block;
    }
    Button { margin-left: 1; }
    .field-label {
        color: $text-muted;
        margin-top: 1;
        margin-bottom: 0;
    }
    """

    # ── compose ──────────────────────────────────────────────────────────────

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(f"✦ {self.TITLE}", id="wizard-header")
            with Horizontal(id="body"):
                with ScrollableContainer(id="form-pane"):
                    yield from self.compose_form()
                with Vertical(id="preview-pane"):
                    yield Label("Generated TOML", classes="field-label")
                    yield TextArea(
                        text=self.generate_toml(),
                        language="toml",
                        read_only=True,
                        id="preview",
                    )
            with Horizontal(id="footer-bar"):
                with Horizontal(id="save-path-row"):
                    yield Input(
                        placeholder="path/to/output.toml",
                        id="save-path",
                        value=self._default_save_path(),
                    )
                yield Button("Save to file", id="btn-save", variant="primary")
                yield Button("Close",        id="btn-close", variant="default")
        yield Footer()

    # ── abstract / overridable interface ─────────────────────────────────────

    def run_hint(self, path: Path) -> str:
        """Return a shell snippet shown after saving so the user knows what to run.

        The base returns "" (dismiss immediately, old behaviour).  Subclasses
        override to surface the exact command(s) needed to apply the saved TOML.
        The string is loaded into the preview TextArea; the modal stays open until
        the user presses Done or Escape.
        """
        return ""

    @abstractmethod
    def compose_form(self) -> ComposeResult:
        """Yield form widgets (Labels, Inputs, Selects, Checkboxes …)."""

    @abstractmethod
    def generate_toml(self) -> str:
        """Build and return the TOML string from current widget values.

        Called on every field change to keep the preview live.  Must not
        raise — return a comment-only string if inputs are incomplete.
        """

    # ── internals ────────────────────────────────────────────────────────────

    def _default_save_path(self) -> str:
        """Sensible default filename shown in the save-path input."""
        return ""

    def _refresh_preview(self) -> None:
        try:
            toml_text = self.generate_toml()
        except Exception:  # noqa: BLE001
            toml_text = "# (invalid input — fill in all required fields)\n"
        try:
            ta = self.query_one("#preview", TextArea)
            ta.load_text(toml_text)
        except Exception:  # noqa: BLE001
            pass

    # ── event handlers ────────────────────────────────────────────────────────

    def on_input_changed(self, _: Input.Changed) -> None:
        self._refresh_preview()

    def on_select_changed(self, _: object) -> None:
        self._refresh_preview()

    def on_checkbox_changed(self, _: object) -> None:
        self._refresh_preview()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-close":
            self.dismiss(self._saved_path)
        elif event.button.id == "btn-save":
            self._toggle_save_row()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id == "save-path":
            self._do_save()

    # ── actions ──────────────────────────────────────────────────────────────

    def action_dismiss_none(self) -> None:
        self.dismiss(self._saved_path)

    # ── helpers ──────────────────────────────────────────────────────────────

    def _toggle_save_row(self) -> None:
        row = self.query_one("#save-path-row")
        row.toggle_class("visible")
        if "visible" in row.classes:
            self.query_one("#save-path", Input).focus()
        else:
            self._do_save()

    def _do_save(self) -> None:
        raw = self.query_one("#save-path", Input).value.strip()
        if not raw:
            self.notify("Enter a file path first.", severity="warning")
            return
        path = Path(raw).expanduser().resolve()
        # F-06: warn when the target is outside the current working directory
        # so the user is aware they are writing to an unexpected location.
        # This is advisory only — we still allow the write (the user controls
        # the TUI and the filesystem).
        try:
            path.relative_to(Path.cwd())
        except ValueError:
            self.notify(
                f"Writing outside CWD: {path}",
                severity="warning",
                timeout=4,
            )
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(self.generate_toml())
            hint = self.run_hint(path)
            if hint:
                # Stay open: replace the TOML preview with the run command so the
                # user can read (and copy) it before closing.
                self._saved_path = path
                try:
                    self.query_one("#preview", TextArea).load_text(hint)
                    self.query_one("#wizard-header", Label).update(
                        f"✓ Saved — run this command to apply:"
                    )
                    self.query_one("#btn-save", Button).disabled = True
                    self.query_one("#btn-close", Button).label = "Done"
                except Exception:  # noqa: BLE001
                    pass
            else:
                self.notify(f"Saved: {path}", severity="information")
                self.dismiss(path)
        except OSError as e:
            self.notify(f"Save failed: {e}", severity="error")

    # ── shared field helpers (used by subclasses) ─────────────────────────────

    @staticmethod
    def _val(widget_id: str, screen: "WizardModal") -> str:
        """Read a string value from an Input widget by id, empty if missing."""
        try:
            return screen.query_one(f"#{widget_id}", Input).value.strip()
        except Exception:  # noqa: BLE001
            return ""

    @staticmethod
    def _sel(widget_id: str, screen: "WizardModal") -> str:
        """Read the selected value from a Select widget by id."""
        try:
            from textual.widgets import Select
            v = screen.query_one(f"#{widget_id}", Select).value
            return "" if v is Select.BLANK else str(v)
        except Exception:  # noqa: BLE001
            return ""

    @staticmethod
    def _chk(widget_id: str, screen: "WizardModal") -> bool:
        """Read the boolean value from a Checkbox widget by id."""
        try:
            from textual.widgets import Checkbox
            return screen.query_one(f"#{widget_id}", Checkbox).value
        except Exception:  # noqa: BLE001
            return False
