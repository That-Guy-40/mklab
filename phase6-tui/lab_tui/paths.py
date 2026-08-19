"""Where the phase scripts live — the one import `topology.py` is allowed to have.

This module exists because of a coupling that only shows up off the TUI.  `plan_up`
and `plan_down` are pure data: a TOML in, a list of argv out, no engine consulted and
nothing executed.  But they lived one import away from the whole Textual stack —
`topology.py` took `phase_script` from `backends/base.py`, which imports pydantic and
`lab_tui.state`, which imports **watchfiles**.  So

    python3 -m lab_tui.topology up micro-cloud.toml

died on `ModuleNotFoundError: No module named 'watchfiles'` — a *file-watching library*
that the plan generator does not use, on a machine that only wanted to be told which
commands to type.

That matters more than an import tidy-up, because MICRO_CLOUD_LAB_PLAN §0.2 says the
guided path is a VIEW of the raw path and *"delete the guided path and nothing is
lost"*.  A plan you can only obtain by installing the guided path's dependencies is not
that.  `examples/micro-cloud/micro-cloud.sh` is the raw path for the whole lab and it
asks this module for the order — so this import boundary is what keeps it from
re-deriving the order itself, which §4.1 names exactly: *a wrapper that reimplements
logic is a clone in disguise.*

`backends/base.py` re-exports both names, so every existing importer is unchanged and
there is still only ONE definition of where a phase script is.
"""

from __future__ import annotations

from pathlib import Path

#: The repo root: lab_tui/paths.py → lab_tui → phase6-tui → repo.
PHASE_ROOT = Path(__file__).resolve().parents[2]


def phase_script(rel: str) -> Path:
    """Resolve a phase-script path relative to the repo root."""
    return PHASE_ROOT / rel
