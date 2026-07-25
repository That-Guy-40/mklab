"""control_pane.milestones — load + validate a milestones.toml into {profile: [Milestone]}.

The file is the user-editable contract: a table of profiles, each an ordered array of
{match, label, at [, terminal]}. `match` is compiled as a REGEX here (never eval); `at`
must be an explicit int 0..100. A malformed file is a load-time error, not a silent skip.
"""
from __future__ import annotations

import re
import tomllib

from .engine import Milestone


class MilestoneError(ValueError):
    """A milestones.toml that is structurally wrong (bad regex, at out of range, …)."""


def load(path):
    with open(path, "rb") as fh:
        return parse(tomllib.load(fh))


def parse(doc):
    section = doc.get("milestone", {})
    if not isinstance(section, dict):
        raise MilestoneError("[milestone] must be a table of profiles")
    profiles = {}
    for prof, entries in section.items():
        if not isinstance(entries, list):
            raise MilestoneError(f"milestone.{prof} must be an array of tables")
        profiles[prof] = [_one(prof, i, e) for i, e in enumerate(entries)]
    return profiles


def _one(prof, i, entry):
    where = f"milestone.{prof}[{i}]"
    if not isinstance(entry, dict):
        raise MilestoneError(f"{where}: must be a table with match/label/at")
    missing = [k for k in ("match", "label", "at") if k not in entry]
    if missing:
        raise MilestoneError(f"{where}: missing {', '.join(missing)}")
    at = entry["at"]
    if not isinstance(at, int) or isinstance(at, bool) or not (0 <= at <= 100):
        raise MilestoneError(f"{where}: at must be an int 0..100 (got {at!r})")
    try:
        pattern = re.compile(entry["match"])  # regex over text — NEVER eval
    except re.error as exc:
        raise MilestoneError(f"{where}: bad regex {entry['match']!r}: {exc}")
    terminal = entry.get("terminal", False)
    if not isinstance(terminal, bool):
        raise MilestoneError(f"{where}: terminal must be true/false (got {terminal!r})")
    return Milestone(pattern, str(entry["label"]), at, terminal)
