"""Unit tests for the tree progress-bar widget (pure Rich rendering)."""
from __future__ import annotations

from lab_tui.widgets.progress_bar import progress_bar


def test_full_bar_at_terminal():
    s = progress_bar({"percent": 100, "label": "first boot", "terminal": True}).plain
    assert "100%" in s and "first boot" in s
    assert "█" in s and "░" not in s          # fully filled


def test_partial_bar_has_fill_and_empty():
    s = progress_bar({"percent": 50, "label": "base system"}).plain
    assert "50%" in s and "base system" in s
    assert "█" in s and "░" in s


def test_zero_percent_is_all_empty():
    s = progress_bar({"percent": 0, "label": "waiting"}).plain
    assert "  0%" in s and "░" in s and "█" not in s


def test_stalled_is_flagged():
    s = progress_bar({"percent": 55, "label": "base system", "stalled": True}).plain
    assert "STALLED" in s


def test_bad_percent_is_clamped():
    assert "  0%" in progress_bar({"percent": "nope"}).plain
    assert "100%" in progress_bar({"percent": 250}).plain
    assert "  0%" in progress_bar({"percent": -5}).plain
