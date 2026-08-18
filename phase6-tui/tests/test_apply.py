"""`apply` — the half that issues.

Two families of test here, and the second matters more than the first.

**The contract**: a second `apply` over a converged lab is a no-op — and it is a
no-op because the second pass's diff finds nothing to do, not because a flag was
remembered.  The fake engine below therefore ACTUALLY CONVERGES when a command is
issued against it, so pass two reads the new reality rather than a cached claim.

**The refusals**: three of the diff's six kinds are held for the operator, and each
has a test that fails if `apply` ever starts acting on it.  `undeclared` is the one
to watch — deleting what nobody declared is the half of a reconcile loop that
destroys work, and it must not become reachable by a default nobody argued for.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from lab_tui.apply import (
    ACTIONABLE,
    held_for_want_of_a_verb,  # noqa: F401  (imported so a rename breaks here too)
    FC_FLAGS,
    apply,
    report,
    transitions,
)
from lab_tui.backends.base import Resource, phase_script
from lab_tui.reconcile import Delta
from lab_tui.topology import parse_topology

SPEC = """\
[lab]
name = "mc"

[[chroot]]
name = "base"

[[microvm]]
name = "api1"
kernel = "/srv/vmlinux"
rootfs = "/srv/api.ext4"
tap = "mc-api1"
memory = "512M"

[[service]]
name = "web"
engine = "docker"
"""


@pytest.fixture
def spec(tmp_path: Path) -> Path:
    p = tmp_path / "mc.toml"
    p.write_text(SPEC)
    return p


class ConvergingEngine:
    """A backend whose state actually CHANGES when a command is issued at it.

    Without this the no-op-on-pass-two test would be circular: a fake that never
    converges makes `apply` loop to its bound, and a fake that is converged from
    the start never issues anything, so neither shows the property.
    """

    def __init__(self, slot: str, resources: list[Resource] | None = None,
                 available: bool = True):
        self.slot = slot
        self.resources = list(resources or [])
        self._available = available

    def is_available(self) -> bool:
        return self._available

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        return list(self.resources)

    # what a "command" does to this fake
    def create(self, name: str, **extra) -> None:
        self.resources.append(Resource(
            backend=self.slot, name=name, svc=None, lab="mc",
            type="thing", status="running", extra=extra,
        ))

    def start(self, name: str) -> None:
        self.resources = [
            r.model_copy(update={"status": "running"}) if (r.svc or r.name) == name else r
            for r in self.resources
        ]


def _engines(**by_slot: ConvergingEngine):
    return lambda slot: by_slot.get(slot)


def _res(**kw) -> Resource:
    kw.setdefault("type", "thing")
    return Resource(**kw)


def _runner(engines: dict[str, ConvergingEngine], log: list[list[str]]):
    """Translate an issued argv back into an effect on the fake engines.

    Deliberately keyed off the argv `apply` actually built, so a change to the
    emitted commands shows up here rather than being absorbed by a mock that
    accepts anything.
    """
    def run(argv: list[str]) -> int:
        log.append(argv)
        fc = engines.get("fc")
        if fc is not None and "lab-fc.sh" in argv[0]:
            if argv[1] == "create":
                name = argv[argv.index("--name") + 1]
                fc.create(name, tap="mc-api1", kernel="/srv/vmlinux")
                # `create` does not start it — the driver's own semantics, and the
                # reason pass one issues two commands for one absent instance.
                fc.resources[-1] = fc.resources[-1].model_copy(
                    update={"status": "stopped"})
            elif argv[1] == "start":
                fc.start(argv[2])
        return 0
    return run


# ── the contract: converge, then do nothing ──────────────────────────────────

def test_apply_converges_and_the_second_pass_is_a_no_op(tmp_path: Path) -> None:
    """The whole point of `apply`, asserted on a fake that really converges."""
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ConvergingEngine("fc")
    log: list[list[str]] = []
    engines = {"fc": fc}

    first = apply(p, backend_for=_engines(fc=fc), run=_runner(engines, log))
    assert first.converged, report(first)
    assert [a[1] for a in first.issued] == ["create", "start"]

    second = apply(p, backend_for=_engines(fc=fc), run=_runner(engines, log2 := []))
    assert second.converged
    assert second.issued == [], (
        "REGRESSION: apply issued commands against a lab that was already converged "
        f"— {log2}"
    )
    assert second.passes == 1


def test_a_stopped_instance_is_started_not_recreated(tmp_path: Path) -> None:
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ConvergingEngine("fc", [_res(
        backend="fc", name="api1", lab="mc", status="stopped",
        extra={"tap": "mc-api1", "kernel": "/srv/vmlinux"},
    )])
    log: list[list[str]] = []
    r = apply(p, backend_for=_engines(fc=fc), run=_runner({"fc": fc}, log))
    assert r.converged
    assert [a[1] for a in r.issued] == ["start"], (
        "REGRESSION: a stopped instance was re-created — `create` copies a "
        "multi-hundred-megabyte rootfs and the driver refuses to overwrite one"
    )


# ── the three refusals ───────────────────────────────────────────────────────

def test_apply_never_acts_on_an_undeclared_resource(spec: Path) -> None:
    """The one that must never become reachable by a default nobody argued for."""
    stray = _res(backend="docker", name="lab-mc-old", svc="old", lab="mc",
                 status="running")
    docker = ConvergingEngine("docker", [stray])
    log: list[list[str]] = []
    r = apply(spec, max_passes=1, backend_for=_engines(
        chroot=ConvergingEngine("chroot"), fc=ConvergingEngine("fc"), docker=docker,
    ), run=_runner({"docker": docker}, log))
    for argv in r.issued:
        assert "old" not in argv and "lab-mc-old" not in argv, (
            f"REGRESSION: apply issued a command naming an undeclared resource: {argv}"
        )
        assert not ({"destroy", "rm", "down", "kill"} & set(argv)), (
            f"REGRESSION: apply issued a destructive verb: {argv}"
        )
    assert any(d.kind == "undeclared" for d in r.held)


def test_apply_never_acts_on_a_row_it_could_not_read(spec: Path) -> None:
    """If the engine could not be asked, creating is the duplicate-creation bug
    that the diff's unknown/absent distinction exists to prevent."""
    log: list[list[str]] = []
    r = apply(spec, max_passes=1, backend_for=_engines(
        chroot=ConvergingEngine("chroot"),
        fc=ConvergingEngine("fc"),
        docker=ConvergingEngine("docker", available=False),
    ), run=_runner({}, log))
    assert not any("lab-docker.sh" in a[0] for a in r.issued), (
        "REGRESSION: apply issued against an engine it could not query — it cannot "
        "know whether the thing it is creating already exists"
    )
    assert r.incomplete and not r.converged


def test_apply_holds_a_drifted_instance_instead_of_recreating_it(tmp_path: Path) -> None:
    """The repair is destroy+create, which deletes a per-instance rootfs copy."""
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ConvergingEngine("fc", [_res(
        backend="fc", name="api1", lab="mc", status="running",
        extra={"tap": "mc-OLD", "kernel": "/srv/vmlinux"},
    )])
    log: list[list[str]] = []
    r = apply(p, backend_for=_engines(fc=fc), run=_runner({"fc": fc}, log))
    assert r.issued == []
    assert [d.kind for d in r.held] == ["drifted"]
    assert not r.converged, "a held row must not read as convergence"


def test_a_stopped_container_is_started_through_the_drivers_new_verb(
    spec: Path,
) -> None:
    """This test asserted the opposite until 2026-08-17, and the opposite was a gap.

    It read *"a stopped container is held because no driver can start one"* — true
    when it was written: `up` is create-if-absent (it logs "container exists …
    leaving as-is" and returns 0) and none of docker/podman/lxd had a `start`.
    The fix went into the drivers rather than here, because reaching around a
    driver to `podman start` puts a second owner on the lifecycle — the
    stale-record shape this repo keeps finding.

    The target form is the load-bearing detail: phases 3/4/5 resolve a BARE name
    to `lab-<name>`, so `start web` would address a container that is not ours.
    """
    live = _res(backend="docker", name="lab-mc-web", svc="web", lab="mc",
                status="stopped", extra={"state": "exited"})
    docker = ConvergingEngine("docker", [live])
    log: list[list[str]] = []
    r = apply(spec, max_passes=2, backend_for=_engines(
        chroot=ConvergingEngine("chroot"), fc=ConvergingEngine("fc"), docker=docker,
    ), run=_runner({"docker": docker}, log))
    started = [a for a in r.issued if a[1] == "start" and "lab-docker.sh" in a[0]]
    assert started, (
        "REGRESSION: a stopped container was not started — TODO A.3 gave phases "
        "3/4/5 a `start` verb precisely so this row stopped being unrepairable"
    )
    assert started[0][2] == "mc/web", (
        "REGRESSION: the target must be <lab>/<service> — a bare name resolves to "
        f"lab-<name> in the driver and would address the wrong container: {started[0]}"
    )
    assert not any(d.slot == "docker" and d.kind == "stopped" for d in r.held)


def test_a_stopped_row_is_only_held_when_the_slot_has_no_start_verb(
    tmp_path: Path,
) -> None:
    """The control for the row above.

    Holding every stopped row would satisfy that test and break the feature: the
    two drivers that DO have a per-instance `start` must still be issued at.
    """
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/k"\nrootfs = "/r"\ntap = "t"\n'
    )
    fc = ConvergingEngine("fc", [_res(
        backend="fc", name="api1", lab="mc", status="stopped",
        extra={"tap": "t", "kernel": "/k"})])
    r = apply(p, backend_for=_engines(fc=fc), run=_runner({"fc": fc}, []))
    assert r.converged and [a[1] for a in r.issued] == ["start"]
    assert r.held == []


def test_the_actionable_set_is_exactly_two_kinds() -> None:
    """Guards the refusals as a set rather than one test per kind.

    Widening this is a decision, and it should have to be made twice: once in the
    module and once here, where the reason each kind is excluded is written down.
    """
    assert ACTIONABLE == {"absent", "stopped"}


# ── honesty when it does not converge ────────────────────────────────────────

def test_an_issuer_that_does_nothing_is_reported_as_stuck(tmp_path: Path) -> None:
    """THE liar-check.  A loop that stops looking must not call that success.

    The runner here returns 0 for everything and changes nothing — the shape of a
    driver that exits cleanly having done nothing at all.
    """
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ConvergingEngine("fc")
    r = apply(p, backend_for=_engines(fc=fc), run=lambda argv: 0)
    assert not r.converged
    assert r.stuck
    assert r.passes <= 4
    assert "NOT converged" in report(r)


def test_a_failing_command_is_reported_and_not_retried_forever(tmp_path: Path) -> None:
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ConvergingEngine("fc")
    r = apply(p, backend_for=_engines(fc=fc), run=lambda argv: 7)
    assert not r.converged
    assert r.failed and r.failed[0][1] == 7
    assert r.passes == 1, "a driver that just refused must not be re-issued as a retry"
    assert "FAILED (rc=7)" in report(r)


def test_dry_run_issues_nothing(tmp_path: Path) -> None:
    p = tmp_path / "fc.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/srv/vmlinux"\nrootfs = "/srv/api.ext4"\ntap = "mc-api1"\n'
    )
    fc = ConvergingEngine("fc")
    ran: list[list[str]] = []
    r = apply(p, dry_run=True, backend_for=_engines(fc=fc),
              run=lambda argv: ran.append(argv) or 0)
    assert ran == [], "REGRESSION: --dry-run executed a command"
    assert [a[1] for a in r.issued] == ["create", "start"]
    assert "would issue:" in report(r, dry_run=True)


# ── the transitions themselves ───────────────────────────────────────────────

def test_fc_is_issued_per_instance_and_the_others_once_per_slot(spec: Path) -> None:
    """Phase 7 has no `up`, and `create --config` refuses the whole file once one
    instance exists — which is exactly the mixed state a reconcile loop is for."""
    parsed = parse_topology(spec)
    deltas = [
        Delta("docker", "web", "absent", ""),
        Delta("fc", "api1", "absent", ""),
        Delta("chroot", "base", "absent", ""),
    ]
    argvs = transitions(deltas, spec, parsed)
    verbs = [(Path(a[0]).name, a[1]) for a in argvs]
    assert verbs == [
        # `create`, not `up` — measured: lab-chroot.sh has never had an `up` verb
        # (it answers it exactly as it answers a bogus one).  Dependency order,
        # not alphabetical.
        ("lab-chroot.sh", "create"),
        ("lab-fc.sh", "create"),
        ("lab-fc.sh", "start"),
        ("lab-docker.sh", "up"),        # docker/podman/lxd are the three that DO
    ]
    # TWO creates now — chroot's and fc's — so select by script, not by verb.
    create = next(a for a in argvs if a[1] == "create" and "lab-fc.sh" in a[0])
    assert "--name" in create and "api1" in create
    assert "--memory" in create and "512M" in create
    assert "--lab" in create and "mc" in create


def test_a_valueless_flag_is_not_given_a_value(tmp_path: Path) -> None:
    """`--mmds` is a switch in the driver's arg loop; `--mmds true` would make
    `true` the next positional and be refused."""
    p = tmp_path / "m.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\n'
        'kernel = "/k"\nrootfs = "/r"\ntap = "t"\nmmds = true\n'
    )
    argvs = transitions([Delta("fc", "api1", "absent", "")], p, parse_topology(p))
    create = next(a for a in argvs if a[1] == "create")
    assert "--mmds" in create
    assert create[create.index("--mmds") + 1:] != ["true"], "--mmds took a value"


def test_converged_rows_produce_no_transitions(spec: Path) -> None:
    parsed = parse_topology(spec)
    assert transitions([Delta("docker", "web", "converged", "")], spec, parsed) == []


# ── the flag table is the driver's own ───────────────────────────────────────

def test_fc_flags_match_the_drivers_known_keys() -> None:
    """A key added to lab-fc.sh without a line here is silently dropped from every
    `create` this module issues — the driver's own stated bug class, committed
    against it.  So the list is read out of the driver rather than trusted.
    """
    src = phase_script("phase7-firecracker/lab-fc.sh").read_text()
    m = re.search(r'^readonly KNOWN_KEYS="([^"]*)"', src, re.MULTILINE)
    assert m, "lab-fc.sh no longer declares KNOWN_KEYS as a double-quoted readonly"
    assert set(m.group(1).split()) == set(FC_FLAGS), (
        f"lab-fc.sh knows {sorted(set(m.group(1).split()) - set(FC_FLAGS))} that "
        f"apply.py does not, and vice versa "
        f"{sorted(set(FC_FLAGS) - set(m.group(1).split()))}"
    )
