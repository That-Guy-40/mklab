"""A tiny Rich-rendered boot/install progress bar for the resource tree.

Rendered inline in a tree leaf for any resource whose backend put a `percent` in its
`extra` (currently the control-pane inventory source). Poll-refreshed like the rest of the
tree, so the bars *fill* as a node provisions. Colour: cyan filling, green at terminal,
red when stalled — mirroring the status pill.
"""
from __future__ import annotations

from rich.text import Text

_BAR_WIDTH = 12


def progress_bar(extra: dict, width: int = _BAR_WIDTH) -> Text:
    """Return a Rich Text like `██████░░░░░░  85% post-install` from a Resource.extra."""
    try:
        pct = int(extra.get("percent", 0))
    except (TypeError, ValueError):
        pct = 0
    pct = max(0, min(100, pct))
    stalled = bool(extra.get("stalled", False))
    terminal = bool(extra.get("terminal", False))
    label = str(extra.get("label", ""))

    filled = round(pct / 100 * width)
    fill_style = "red" if stalled else ("green" if terminal else "cyan")

    bar = Text()
    bar.append("█" * filled, style=fill_style)
    bar.append("░" * (width - filled), style="dim")
    suffix = f"  {pct:3d}% {label}" + (" STALLED" if stalled else "")
    bar.append(suffix, style="red" if stalled else "dim")
    return bar
