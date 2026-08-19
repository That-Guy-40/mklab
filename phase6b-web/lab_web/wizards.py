"""The web wizards' adapter — and the reason it is an adapter and not a port.

MICRO_CLOUD_LAB_PLAN §8.2 lists "phase6b-web has zero wizards" as a gap, and says the work
is to *"port the form→preview→save flow to the web UI; base.py's split makes this mostly a
view layer."* The word doing the work there is **view**, and §0.2 makes it an invariant:

    The guided path is a VIEW of the raw path, never a parallel implementation.

A web wizard that defined its own fields and built its own TOML would satisfy the letter of
"the web has wizards" and break the thing the wizards are for. There would then be two
descriptions of a phase-7 microVM — one in Textual, one in Jinja — and the day they drifted,
one of them would start generating specs the tool rejects while its own tests stayed green.
§4.1 has a name for this: *a wrapper that reimplements logic is a clone in disguise.*

So nothing here describes a wizard. This module READS the TUI's wizard classes:

  * the FIELDS are obtained by running the wizard's own ``compose_form()`` and inspecting the
    Textual widgets it yields — id, placeholder, options, defaults. Add a field to the TUI
    wizard and the web form grows it, with no edit here.
  * the TOML comes from the wizard's own ``generate_toml()``.
  * the follow-up commands come from the wizard's own ``run_hint()``.

`phase6b-web` already depends on `lab-tui`, which depends on Textual, so importing the
classes costs nothing new. The widgets are constructed but never mounted, which is exactly
what `phase6-tui/tests/test_wizards.py` has always done to test `generate_toml()` — this is
that technique pointed at the form instead of the output.

WHAT THIS DOES NOT DO, ON PURPOSE
---------------------------------
It does not execute anything. §0.2: *"Wizards generate; they never execute… a novice cannot
destroy anything with one — the worst case is a text file."* The save route writes a spec and
returns the commands you would type next; running them is the raw path's job, and the hint
names them so you can.
"""

from __future__ import annotations

import importlib
from dataclasses import dataclass, field as _dc_field
from pathlib import Path
from typing import Any
from unittest.mock import patch

from textual.widgets import Checkbox, Input, Label, Select

from lab_tui.screens.wizards.base import WizardModal


@dataclass(frozen=True)
class Field:
    """One form control, as the TUI wizard declared it."""

    id: str
    kind: str                       # "text" | "select" | "checkbox"
    label: str = ""
    placeholder: str = ""
    default: str = ""
    checked: bool = False
    options: list[tuple[str, str]] = _dc_field(default_factory=list)


def discover() -> dict[str, type[WizardModal]]:
    """Every wizard in the package, keyed by its module stem ("phase1"…"phase7").

    DERIVED from the package rather than listed here, for the same reason
    tools/check-guided-path-is-a-view.sh derives it: a wizard added to the TUI and forgotten
    here would be a guided surface the web silently lacks, and nothing would say so.
    """
    import lab_tui.screens.wizards as pkg

    out: dict[str, type[WizardModal]] = {}
    for mod_path in sorted(Path(pkg.__file__).parent.glob("*.py")):
        if mod_path.stem in ("__init__", "base"):
            continue
        mod = importlib.import_module(f"lab_tui.screens.wizards.{mod_path.stem}")
        for attr in dir(mod):
            cls = getattr(mod, attr)
            if (isinstance(cls, type) and issubclass(cls, WizardModal)
                    and cls is not WizardModal and cls.__module__ == mod.__name__):
                out[mod_path.stem] = cls
    return out


def fields_of(cls: type[WizardModal]) -> list[Field]:
    """The wizard's form, read out of its own ``compose_form()``.

    A `Label` yielded immediately before a control is that control's caption — that is the
    layout every wizard in the package uses, and reading it is what lets the web form carry
    the same wording as the TUI without a second copy of it.
    """
    obj = object.__new__(cls)
    out: list[Field] = []
    pending_label = ""
    for widget in obj.compose_form():
        if isinstance(widget, Label):
            pending_label = str(widget.content)
            continue
        wid = getattr(widget, "id", None)
        if not wid:
            pending_label = ""
            continue
        if isinstance(widget, Input):
            out.append(Field(id=wid, kind="text", label=pending_label,
                             placeholder=widget.placeholder or ""))
        elif isinstance(widget, Select):
            # `_options` carries a leading blank entry when the Select allows one; it is
            # dropped so the web form offers the same choices the TUI does.
            opts = [(str(p), str(v)) for p, v in getattr(widget, "_options", [])
                    if isinstance(v, str)]
            out.append(Field(id=wid, kind="select", label=pending_label,
                             default=str(getattr(widget, "_value", "") or ""),
                             options=opts))
        elif isinstance(widget, Checkbox):
            # A checkbox carries its own caption; the pending Label (if any) belongs to
            # whatever came before it.
            out.append(Field(id=wid, kind="checkbox", label=str(widget.label),
                             checked=bool(widget.value)))
        pending_label = ""
    return out


def _rendered(cls: type[WizardModal], values: dict[str, Any], method: str,
              *args: Any) -> str:
    """Call one of the wizard's own pure methods with *values* standing in for widgets."""
    obj = object.__new__(cls)

    def _val(wid: str, _self: Any) -> str:
        v = values.get(wid, "")
        return "" if v is None or isinstance(v, bool) else str(v)

    def _chk(wid: str, _self: Any) -> bool:
        v = values.get(wid, False)
        return v is True or v in ("on", "true", "1", "yes")

    with patch.object(cls, "_val", staticmethod(_val)), \
         patch.object(cls, "_sel", staticmethod(_val)), \
         patch.object(cls, "_chk", staticmethod(_chk)):
        return getattr(obj, method)(*args)


def generate_toml(cls: type[WizardModal], values: dict[str, Any]) -> str:
    """The spec, from the wizard's own generator — never re-derived here."""
    return _rendered(cls, values, "generate_toml")


def run_hint(cls: type[WizardModal], values: dict[str, Any], path: Path) -> str:
    """The commands to run next, from the wizard's own hint — never re-worded here."""
    return _rendered(cls, values, "run_hint", path)


def default_save_path(cls: type[WizardModal], values: dict[str, Any]) -> str:
    return _rendered(cls, values, "_default_save_path")


def title_of(cls: type[WizardModal]) -> str:
    return str(getattr(cls, "TITLE", cls.__name__))
