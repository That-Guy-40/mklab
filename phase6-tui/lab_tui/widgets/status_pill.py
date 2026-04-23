"""A tiny Rich-rendered status pill used in the resource tree."""

from __future__ import annotations

from rich.text import Text

_COLORS = {
    "running": "green",
    "stopped": "yellow",
    "built":   "cyan",
    "missing": "red",
    "error":   "bold red",
    "unknown": "dim",
}


def status_pill(status: str) -> Text:
    """Return a Rich Text suitable for rendering inline in a tree label."""
    colour = _COLORS.get(status, "dim")
    # Two-column glyph to keep tree alignment stable across labels.
    return Text(f"● {status}", style=colour)
