"""Slice 6's break-it row: a fault at every layer of the control plane, graded.

§8.4a changed what this row IS.  §14 originally said *"make the registry disagree
with reality — MAAS's registry-layer fault, ported"*, but decision G settled that
micro-cloud keeps **no registry of facts**: everything is derived from the engine
that owns it.  With nothing cached there is nothing to make disagree, so the fault
moves down a level to the thing that replaced the registry —

    MAKE THE DERIVATION ANSWER FOR THE WRONG SUBJECT.

That is a harder fault and a better one.  This repo has already been caught by it
twice: a seam that answered for the wrong instance, and one pidfile that three
verbs read three different ways.

THE LADDER (CLAUDE.md), worst last:
    ABSORBED   the fault never reached the service — refused before it did harm
    DEGRADED   still serving, on a fallback
    HALTED     not serving, but honestly: a named state, a reason, a way back
    STRANDED   stuck where no verb accepts it                        ← critical
    LIED       the report and reality disagree                       ← critical

A run passes at ZERO CRITICALS.  The intermediate rungs are counted, never
punished — and `test_control_plane_chaos.py` additionally asserts they are
OCCUPIED, because a matrix that never broke anything is all-ABSORBED and proves
nothing, and one whose fallback path is dead never reaches DEGRADED.

THE INJECTOR IS A REAL BACKEND.  `ChaosBackend` subclasses `BackendRunner` and is
handed to `diff()`/`apply()` through the same `backend_for` seam the real ones use,
so every fault runs through the real gates rather than a special case inside the
system under test.  It is deliberately NOT in `ALL_BACKENDS`; a test asserts that,
because a fault injector that could be picked up by the browser pane is a hazard,
not a harness.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import ClassVar, Literal

from lab_tui.backends.base import BackendRunner, Resource

Rung = Literal["ABSORBED", "DEGRADED", "HALTED", "STRANDED", "LIED"]

CRITICAL: frozenset[Rung] = frozenset({"STRANDED", "LIED"})

#: Every discrete layer of the control plane that can fail independently.  A layer
#: with no scenario is a layer nobody has watched fall over, so the matrix test
#: FAILS when one is uncovered rather than leaving the gap implicit.
LAYERS: tuple[str, ...] = (
    "engine",        # the thing that owns the resources (docker/podman/lxd/fc/…)
    "derivation",    # how we turn what the engine says into a declared identity
    "driver",        # the phase script the control plane issues commands through
    "artifact",      # what an instance was actually built from
    "control-plane",  # apply itself — the loop, and its own interruption
    "none",          # the no-fault control row
)


class ChaosBackend(BackendRunner):
    """A real backend whose answers are wrong in one specific, chosen way.

    Each fault is a property of the ANSWER, not a branch inside `reconcile`:
    an engine that cannot be reached returns `[]` with `is_available()` False,
    exactly as `docker.py` does when its daemon is down.
    """

    name: ClassVar = "docker"   # a real slot, so the real per-slot rules apply
    script: ClassVar[Path] = Path("/nonexistent/chaos")

    def __init__(
        self,
        resources: list[Resource] | None = None,
        *,
        available: bool = True,
        ignore_lab_filter: bool = False,
    ) -> None:
        self._resources = list(resources or [])
        self._available = available
        # THE INTERESTING FAULT.  A backend is trusted to scope its own answer to
        # the lab it was asked about (docker does it with `--filter label=`, fc by
        # reading each manifest).  This one does not — the shape of a filter that
        # is wrong, absent, or silently matched nothing.
        self._ignore_lab_filter = ignore_lab_filter
        self.list_calls: list[str | None] = []

    def is_available(self) -> bool:
        return self._available

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        self.list_calls.append(lab)
        if self._ignore_lab_filter or lab is None:
            return list(self._resources)
        return [r for r in self._resources if r.lab == lab]

    def inspect(self, resource: Resource) -> str:
        return f"# chaos: {resource.name}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # Abstract on BackendRunner, so it must exist — and it must never run.
        # `apply` does not destroy anything (see ACTIONABLE), and a fault injector
        # that could delete a real resource if wired up wrong is not a harness.
        raise AssertionError(
            "the chaos injector was asked for a destroy argv — nothing in the "
            "control plane should be building one during a fault run"
        )


@dataclass(slots=True)
class Scenario:
    """One row of the matrix."""

    layer: str
    fault: str
    grade: Rung
    detail: str
    recovered: bool = False
    """True when the grade was assigned only AFTER the system's own recovery was
    attempted and worked.  "Critical" must mean *nothing can be done about it*,
    not *the first thing I looked at was still wrong*."""


@dataclass(slots=True)
class Matrix:
    rows: list[Scenario] = field(default_factory=list)

    def add(self, s: Scenario) -> None:
        self.rows.append(s)

    @property
    def criticals(self) -> list[Scenario]:
        return [r for r in self.rows if r.grade in CRITICAL]

    @property
    def rungs(self) -> set[str]:
        return {r.grade for r in self.rows}

    @property
    def layers_covered(self) -> set[str]:
        return {r.layer for r in self.rows}

    @property
    def uncovered_layers(self) -> list[str]:
        return [ell for ell in LAYERS if ell not in self.layers_covered]

    def render(self) -> str:
        w = max(len(r.layer) for r in self.rows) if self.rows else 5
        lines = [f"  {'LAYER':<{w}}  {'GRADE':<9} FAULT / WHAT HAPPENED"]
        lines.append(f"  {'-' * w}  {'-' * 9} {'-' * 40}")
        for r in self.rows:
            mark = " (after recovery)" if r.recovered else ""
            lines.append(f"  {r.layer:<{w}}  {r.grade:<9} {r.fault} → {r.detail}{mark}")
        lines.append("")
        counts = {g: sum(1 for r in self.rows if r.grade == g) for g in sorted(self.rungs)}
        lines.append("  " + ", ".join(f"{v} {k}" for k, v in counts.items()))
        if self.uncovered_layers:
            lines.append(f"  UNCOVERED LAYERS: {', '.join(self.uncovered_layers)}")
        lines.append(
            f"  {len(self.criticals)} critical"
            + ("" if not self.criticals
               else ": " + "; ".join(f"{r.layer}/{r.fault}" for r in self.criticals))
        )
        return "\n".join(lines)


def grade_apply(result, *, expect_running: Callable[[], bool] | None = None) -> tuple[Rung, str]:
    """Grade one `apply` outcome on the ladder.

    Order matters and it is the ladder's own: a run that CLAIMS convergence it did
    not reach is LIED regardless of anything else, because a false success outranks
    an honest failure — you cannot debug through a lying oracle.
    """
    truly_running = expect_running() if expect_running is not None else None

    if result.converged and truly_running is False:
        return "LIED", "reported converged while the resource is not actually running"
    if result.converged and result.incomplete:
        return "LIED", "reported converged with a row it never managed to read"
    if result.converged:
        return "ABSORBED", "converged; the fault never reached the declared state"
    if result.failed:
        return "HALTED", (
            f"refused honestly — {len(result.failed)} command(s) failed, "
            f"rc={result.failed[0][1]}, and the argv is in the report"
        )
    if result.stuck:
        return "HALTED", "stopped and said so: a pass repeated the previous diff"
    if result.incomplete:
        return "ABSORBED", "declined to act on rows it could not read"
    if result.held:
        kinds = sorted({d.kind for d in result.held})
        return "HALTED", f"held for the operator: {', '.join(kinds)}"
    return "STRANDED", "not converged, nothing failed, nothing held — no verb accepts it"
