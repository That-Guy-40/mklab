"""Unit tests for the pure progress engine — no TUI, no clock, fully deterministic."""
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from control_pane.engine import Milestone, Tracker  # noqa: E402


def ms(pat, label, at, terminal=False):
    return Milestone(re.compile(pat), label, at, terminal)


INSTALL = [
    ms("partition", "partitioning", 25),
    ms("base system", "base system", 55),
    ms("post-install", "post-install", 85),
    ms("login:", "first boot", 100, terminal=True),
]


class EngineTests(unittest.TestCase):
    def test_reaches_terminal(self):
        tr = Tracker(INSTALL)
        p = None
        for line in ["boot", "partition now", "base system go", "post-install run", "x login:"]:
            p = tr.feed(line)
        self.assertTrue(p.terminal)
        self.assertEqual(p.percent, 100)
        self.assertEqual(p.label, "first boot")

    def test_monotonic_never_regresses(self):
        tr = Tracker(INSTALL)
        tr.feed("base system")
        p = tr.feed("partition again")  # an earlier marker must NOT drop us back
        self.assertEqual(p.percent, 55)
        self.assertEqual(p.label, "base system")
        self.assertFalse(p.advanced)

    def test_unmatched_is_not_fake_100(self):
        tr = Tracker(INSTALL)
        p = tr.feed("some unrelated noise")
        self.assertEqual(p.percent, 0)
        self.assertFalse(p.terminal)
        tr.feed("base system")
        p = tr.feed("more noise")
        self.assertEqual(p.percent, 55)  # stays put, never jumps to 100

    def test_advanced_flag(self):
        tr = Tracker(INSTALL)
        self.assertFalse(tr.feed("noise").advanced)
        self.assertTrue(tr.feed("partition").advanced)
        self.assertFalse(tr.feed("partition").advanced)  # same marker again -> no advance

    def test_stall_is_time_based(self):
        tr = Tracker(INSTALL, stall_timeout=5)
        tr.feed("partition", now=0.0)
        self.assertFalse(tr.tick(now=3.0).stalled)   # within the window
        self.assertTrue(tr.tick(now=10.0).stalled)   # past it -> stalled

    def test_terminal_is_never_stalled(self):
        tr = Tracker(INSTALL, stall_timeout=1)
        tr.feed("x login:", now=0.0)
        self.assertFalse(tr.tick(now=100.0).stalled)

    def test_no_clock_means_no_stall(self):
        tr = Tracker(INSTALL, stall_timeout=1)
        self.assertFalse(tr.feed("noise").stalled)   # feed() without now= never stalls


if __name__ == "__main__":
    unittest.main()
