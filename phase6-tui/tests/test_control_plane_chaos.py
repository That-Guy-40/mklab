"""Slice 6's break-it row, as a graded matrix rather than a single scenario.

§8.4a moved this fault from *make the registry disagree with reality* (there is no
registry) to **make the derivation answer for the wrong subject**.  One scenario is
not a matrix, so this injects a fault at every layer that can fail independently
and grades each on the CLAUDE.md ladder.

Three rules from that convention are what make it worth having, and each is a
test here rather than a comment:

  * a run passes at ZERO CRITICALS (STRANDED / LIED);
  * the intermediate rungs must be OCCUPIED — a matrix that never broke anything
    is all-ABSORBED and proves nothing;
  * every layer needs a scenario, so an uncovered layer FAILS rather than being
    left implicit.

Plus a NO-FAULT CONTROL row, without which "the harness reported failures" is
indistinguishable from a system that never worked.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from lab_tui.apply import apply
from lab_tui.backends import ALL_BACKENDS
from lab_tui.backends.base import Resource
from lab_tui.chaos import LAYERS, ChaosBackend, Matrix, Scenario, grade_apply
from lab_tui.reconcile import diff

SPEC = '''\
[lab]
name = "mc"

[[service]]
name = "web"
engine = "docker"
'''


@pytest.fixture
def spec(tmp_path: Path) -> Path:
    p = tmp_path / "mc.toml"
    p.write_text(SPEC)
    return p


def _res(**kw) -> Resource:
    kw.setdefault("type", "container")
    kw.setdefault("backend", "docker")
    return Resource(**kw)


def _only(chaos: ChaosBackend):
    return lambda slot: chaos if slot == "docker" else None


def _running_web(chaos: ChaosBackend):
    """An INDEPENDENT witness of reality, not the report under test."""
    return lambda: any(
        (r.svc or r.name) == "web" and r.lab == "mc" and r.status == "running"
        for r in chaos._resources
    )


# ── the harness is held to the standard it enforces ──────────────────────────

def test_the_injector_is_not_a_registered_backend() -> None:
    """A fault injector the browser pane could pick up is a hazard, not a harness."""
    assert ChaosBackend not in ALL_BACKENDS
    assert not any(b is ChaosBackend for b in ALL_BACKENDS)


def test_the_grader_can_say_LIED() -> None:
    """The grading function must be able to reach its own worst rung.

    metal-as-a-service's control row immediately caught a GRADING bug — a
    successful deploy read as a fallback — which is why the grader is exercised
    directly and not only through the scenarios.
    """
    class R:
        converged, incomplete, failed, stuck, held = True, False, [], False, []
    grade, why = grade_apply(R(), expect_running=lambda: False)
    assert grade == "LIED" and "not actually running" in why

    class R2:
        converged, incomplete, failed, stuck, held = False, False, [], False, []
    assert grade_apply(R2())[0] == "STRANDED"


def test_an_all_absorbed_matrix_is_rejected() -> None:
    """A matrix that never broke anything is all-ABSORBED and proves nothing.

    Zero criticals is necessary and nowhere near sufficient — this is the
    assertion that stops the harness from passing by not trying.  Held to its own
    standard: the rule is exercised against a synthetic matrix, not just relied on
    in the real one.
    """
    m = Matrix([Scenario("none", "x", "ABSORBED", "-"),
                Scenario("engine", "y", "ABSORBED", "-")])
    assert not m.criticals            # ...and yet
    assert not ("ABSORBED" in m.rungs and "HALTED" in m.rungs), (
        "the occupancy rule would have accepted a matrix that broke nothing"
    )


def test_an_uncovered_layer_is_reported_by_name() -> None:
    """A layer with no scenario is a layer nobody has watched fall over."""
    m = Matrix([Scenario("engine", "x", "HALTED", "-")])
    missing = m.uncovered_layers
    assert "derivation" in missing and "control-plane" in missing
    assert "engine" not in missing
    assert "UNCOVERED LAYERS" in m.render()


def test_every_layer_the_module_declares_is_one_the_matrix_can_reach() -> None:
    """The layer list and the scenarios come from one place or they drift.

    LAYERS is the enumeration the coverage rule is checked against; a layer added
    there without a scenario should FAIL the matrix (that is the point), and a
    scenario for a layer NOT in the list would be coverage nobody counted.
    """
    assert len(set(LAYERS)) == len(LAYERS), "a layer is listed twice"
    assert "none" in LAYERS, "the no-fault control row needs a layer name too"


# ── the matrix ───────────────────────────────────────────────────────────────

def build_matrix(spec: Path) -> Matrix:
    m = Matrix()

    # ── layer: none — THE CONTROL ────────────────────────────────────────────
    # Without it, "the harness reported failures" is indistinguishable from a
    # system that never worked at all.
    healthy = ChaosBackend([_res(name="lab-mc-web", svc="web", lab="mc",
                                 status="running")])
    r = apply(spec, backend_for=_only(healthy), run=lambda a: 0)
    grade, why = grade_apply(r, expect_running=_running_web(healthy))
    m.add(Scenario("none", "no fault injected", grade, why))

    # ── layer: engine — it cannot be asked at all ────────────────────────────
    down = ChaosBackend([], available=False)
    r = apply(spec, backend_for=_only(down), run=lambda a: 0)
    grade, why = grade_apply(r)
    m.add(Scenario("engine", "daemon unreachable", grade, why))

    # ── layer: engine — it answers, with a state we do not map ───────────────
    # `restarting` / `stopping` / `removing` all collapse to status="unknown" in
    # the three container backends.  A crash-looping container must not be
    # reported as merely stopped and started again.
    weird = ChaosBackend([_res(name="lab-mc-web", svc="web", lab="mc",
                               status="unknown", extra={"state": "restarting"})])
    r = apply(spec, backend_for=_only(weird), run=lambda a: 0)
    grade, why = grade_apply(r)
    m.add(Scenario("engine", "answers with an unmappable state", grade, why))

    # ── layer: derivation — IT ANSWERS FOR THE WRONG SUBJECT ─────────────────
    # The fault §8.4a named.  A backend is trusted to scope its answer to the lab
    # it was asked about; this one does not, which is the shape of a filter that
    # is wrong, absent, or silently matched nothing.  Another lab's `web` must
    # not answer this lab's question.
    leaky = ChaosBackend(
        [_res(name="lab-other-web", svc="web", lab="other-lab", status="running")],
        ignore_lab_filter=True,
    )

    # SCOPE THE FAULT TO THE SUBJECT.  The driver here WORKS — it really creates
    # our container — so the only thing on trial is whether the leaked row fooled
    # the derivation.  A runner that did nothing would send this row to HALTED for
    # a reason that has nothing to do with the injected fault, and the matrix
    # would look like it was working while measuring the wrong thing.
    def create_ours(argv: list[str]) -> int:
        leaky._resources.append(
            _res(name="lab-mc-web", svc="web", lab="mc", status="running"))
        return 0

    r = apply(spec, backend_for=_only(leaky), run=create_ours)
    grade, why = grade_apply(r, expect_running=_running_web(leaky))
    m.add(Scenario("derivation", "another lab's resource leaks into the answer",
                   grade, why))

    # ── layer: driver — it returns 0 and does nothing ────────────────────────
    # The shape of a driver that exits cleanly having done nothing at all: `up`
    # against a stopped container used to be exactly this.
    silent = ChaosBackend([])
    r = apply(spec, backend_for=_only(silent), run=lambda a: 0)
    grade, why = grade_apply(r)
    m.add(Scenario("driver", "exits 0 having done nothing", grade, why))

    # ── layer: driver — it refuses outright ──────────────────────────────────
    refusing = ChaosBackend([])
    r = apply(spec, backend_for=_only(refusing), run=lambda a: 7)
    grade, why = grade_apply(r)
    m.add(Scenario("driver", "refuses with a non-zero exit", grade, why))

    # ── layer: artifact — what it was built from changed underneath ──────────
    drifted = ChaosBackend([_res(name="lab-mc-web", svc="web", lab="mc",
                                 status="running", extra={"state": "running"})])
    fc_spec = spec.parent / "fc.toml"
    fc_spec.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ChaosBackend([Resource(backend="fc", name="api1", lab="mc", type="microvm",
                                status="running",
                                extra={"tap": "mc-OLD", "kernel": "/srv/vmlinux"})])
    fc.name = "fc"
    r = apply(fc_spec, backend_for=lambda s: fc if s == "fc" else None,
              run=lambda a: 0)
    grade, why = grade_apply(r)
    m.add(Scenario("artifact", "instance was built from a different tap", grade, why))

    # ── layer: control-plane — apply is interrupted mid-run ──────────────────
    # A kill between two transitions.  Graded AFTER the recovery the system
    # offers, which is simply running it again: "critical" must mean nothing can
    # be done, not that the first look was still wrong.
    interrupted = ChaosBackend([])
    calls = {"n": 0}

    def die_once(argv: list[str]) -> int:
        calls["n"] += 1
        if calls["n"] == 1:
            raise KeyboardInterrupt("operator pressed ^C between transitions")
        interrupted._resources.append(
            _res(name="lab-mc-web", svc="web", lab="mc", status="running"))
        return 0

    try:
        apply(spec, backend_for=_only(interrupted), run=die_once)
        first_grade, first_why = "STRANDED", "the interruption was swallowed"
    except KeyboardInterrupt:
        first_grade, first_why = "HALTED", "the interruption propagated; nothing was claimed"
    # ...now the recovery the system offers: run it again.
    r = apply(spec, backend_for=_only(interrupted), run=die_once)
    recovered = r.converged
    m.add(Scenario(
        "control-plane", "interrupted between transitions",
        first_grade if not recovered else "DEGRADED",
        (first_why + "; a second apply converged" if recovered
         else first_why + "; a second apply did NOT converge"),
        recovered=recovered,
    ))
    return m


def test_the_chaos_matrix(spec: Path, capsys) -> None:
    m = build_matrix(spec)
    with capsys.disabled():
        print("\n" + m.render())

    assert not m.uncovered_layers, (
        f"layers with no scenario: {m.uncovered_layers} — a layer nobody has "
        "watched fall over is not a layer that works"
    )
    assert not m.criticals, (
        "CRITICAL rungs reached:\n" + m.render()
    )
    # A matrix that never broke anything is all-ABSORBED; one that breaks
    # everything unrecoverably is all-HALTED.  Zero criticals alone proves neither.
    assert "ABSORBED" in m.rungs and "HALTED" in m.rungs, (
        f"the ladder is not occupied — only {sorted(m.rungs)} were reached, so "
        "this matrix is not exercising the range it claims to"
    )
    control = next(r for r in m.rows if r.layer == "none")
    assert control.grade == "ABSORBED", (
        f"the NO-FAULT control did not converge ({control.grade}) — the harness is "
        "reporting failures a working system would also produce"
    )
