"""control_pane.engine — a pure, framework-free boot-progress engine.

Feed it console lines + a profile's milestones; it emits Progress state. It has NO
Textual, NO network, and NO clock of its own — timestamps are passed in — so it
unit-tests as a plain function and can be driven headless (`control-pane watch`),
by a Textual widget, or by a web SSE feed alike.

Honesty rules (the whole point — see README):
  * `at` is an EXPLICIT percent from the milestone; the engine never interpolates.
  * patterns are plain regex over text (compiled in milestones.py) — NEVER eval.
  * progress is MONOTONIC: a stray line matching an earlier marker never regresses it.
  * an unmatched line leaves progress where it was — never a fake 100%.
  * `terminal` is set only by a milestone that declares it (== "reached active").
  * `stalled` is time-based and consumer-driven: it needs timestamps passed to
    feed()/tick(); with none, stalled is always False (a parser reading a file fast
    is not "stalled"). A terminal node is never stalled.
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Milestone:
    """One matcher. `pattern` is a compiled regex (see milestones.py)."""
    pattern: "re.Pattern[str]"  # noqa: F821 - forward ref, compiled in milestones.py
    label: str
    at: int
    terminal: bool = False


@dataclass(frozen=True)
class Progress:
    percent: int
    label: str
    terminal: bool
    stalled: bool
    last_line: str
    advanced: bool  # did the line just fed move progress forward?


class Tracker:
    """Stateful over a stream of lines, but every transition is pure/deterministic."""

    def __init__(self, milestones, stall_timeout=None, start_label="waiting"):
        self._ms = list(milestones)
        self._stall = stall_timeout
        self._percent = 0
        self._label = start_label
        self._terminal = False
        self._last_line = ""
        self._last_advance_t = None

    def feed(self, line, now=None):
        """Consume one console line; return the resulting Progress."""
        self._last_line = line.rstrip("\r\n")
        if now is not None and self._last_advance_t is None:
            self._last_advance_t = now  # start the stall clock at the first timed line
        advanced = False
        for m in self._ms:                 # top-to-bottom; first match wins for this line
            if m.pattern.search(line):
                if m.at >= self._percent:  # monotonic — never regress
                    if m.at > self._percent or (m.terminal and not self._terminal):
                        advanced = True
                    self._percent = m.at
                    self._label = m.label
                    if m.terminal:
                        self._terminal = True
                    if now is not None:
                        self._last_advance_t = now
                break
        return self._state(now, advanced)

    def tick(self, now):
        """Advance the clock without a line (lets a consumer detect a stall)."""
        return self._state(now, advanced=False)

    def _state(self, now, advanced):
        return Progress(self._percent, self._label, self._terminal,
                        self._is_stalled(now), self._last_line, advanced)

    def _is_stalled(self, now):
        if self._terminal or self._stall is None or now is None or self._last_advance_t is None:
            return False
        return (now - self._last_advance_t) > self._stall
