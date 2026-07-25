"""Unit tests for the milestones.toml loader/validator — malformed input must ERROR."""
import os
import sys
import unittest

LAB = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, LAB)
from control_pane.milestones import MilestoneError, load, parse  # noqa: E402


def doc(entries, profile="p"):
    return {"milestone": {profile: entries}}


class MilestoneTests(unittest.TestCase):
    def test_parse_ok(self):
        profs = parse(doc([
            {"match": "a", "label": "x", "at": 10},
            {"match": "login:", "label": "up", "at": 100, "terminal": True},
        ], profile="install"))
        self.assertIn("install", profs)
        self.assertEqual(len(profs["install"]), 2)
        self.assertTrue(profs["install"][1].terminal)
        self.assertEqual(profs["install"][0].at, 10)

    def test_bad_regex_errors(self):
        with self.assertRaises(MilestoneError):
            parse(doc([{"match": "(", "label": "x", "at": 1}]))

    def test_at_out_of_range_errors(self):
        with self.assertRaises(MilestoneError):
            parse(doc([{"match": "a", "label": "x", "at": 150}]))

    def test_at_wrong_type_errors(self):
        with self.assertRaises(MilestoneError):
            parse(doc([{"match": "a", "label": "x", "at": "nope"}]))
        with self.assertRaises(MilestoneError):
            parse(doc([{"match": "a", "label": "x", "at": True}]))  # bool is not a valid at

    def test_missing_key_errors(self):
        with self.assertRaises(MilestoneError):
            parse(doc([{"match": "a", "at": 1}]))  # no label

    def test_terminal_wrong_type_errors(self):
        with self.assertRaises(MilestoneError):
            parse(doc([{"match": "a", "label": "x", "at": 1, "terminal": "yes"}]))

    def test_shipped_file_loads(self):
        profs = load(os.path.join(LAB, "control_pane", "milestones.toml"))
        for want in ("install", "ramdisk", "image"):
            self.assertIn(want, profs)
        self.assertTrue(any(m.terminal for m in profs["install"]))


if __name__ == "__main__":
    unittest.main()
