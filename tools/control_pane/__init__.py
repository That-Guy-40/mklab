"""control_pane — a headless-first, framework-free live control surface for labs.

The reusable core (this package) has zero Textual/FastAPI imports, so it drives a headless
`control-pane watch` CLI, a Phase-6 Textual widget, and a phase6b-web SSE feed alike.
"""
from .engine import Milestone, Progress, Tracker
from .milestones import MilestoneError, load, parse

__all__ = ["Tracker", "Progress", "Milestone", "load", "parse", "MilestoneError"]
