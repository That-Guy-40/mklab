"""`apply`'s read-only half — the diff, which must issue nothing and lie about nothing.

The load-bearing test in this file is `test_an_unreachable_engine_is_unknown_not_absent`.
Every backend returns `[]` when it cannot reach its engine (`docker.py`: `if
cp.returncode != 0: return []`), which is harmless for the browser pane and a lie in
the most expensive direction for a diff — a stopped daemon would read as "every
declared service is missing", and the `apply` built on this would set about creating
containers that already exist.

The second is `test_the_declared_identity_is_the_svc_label`. Phases 3/4/5 rename what
they create (`lab-<lab>-<svc>`), so matching on the engine-side name produces the
classic double fault: every declared row `absent` AND every live row `undeclared`,
with nothing obviously broken and a plausible-looking report.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from lab_tui.backends.base import Resource
from lab_tui.reconcile import (
    CONVERGED,
    DIFFERENCES,
    INCOMPLETE,
    declared,
    diff,
    exit_code,
)

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

[[service]]
name = "web"
engine = "docker"
"""


@pytest.fixture
def spec(tmp_path: Path) -> Path:
    p = tmp_path / "mc.toml"
    p.write_text(SPEC)
    return p


class FakeBackend:
    """A backend that answers exactly what a test tells it to.

    `available=False` is the interesting one: it must make the diff say UNKNOWN
    rather than read the (identical) empty list as absence.
    """

    def __init__(self, resources: list[Resource] | None = None, available: bool = True):
        self._resources = resources or []
        self._available = available
        self.list_calls: list[str | None] = []

    def is_available(self) -> bool:
        return self._available

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        self.list_calls.append(lab)
        return self._resources


def _fixed(mapping: dict):
    return lambda slot: mapping.get(slot)


def _res(**kw) -> Resource:
    kw.setdefault("type", "container")
    return Resource(**kw)


def _kinds(deltas) -> dict[tuple[str, str], str]:
    return {(d.slot, d.name): d.kind for d in deltas}


# ── UNKNOWN is a verdict, distinct from "not there" ──────────────────────────

def test_an_unreachable_engine_is_unknown_not_absent(spec: Path) -> None:
    """The one that makes the rest of this module honest.

    The *same empty list* means two different things, and only `is_available()`
    separates them.  Read the wrong way, a stopped daemon reports every declared
    service as missing and `apply` creates duplicates of what is already running.
    """
    down = FakeBackend(available=False)
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend(), "docker": down,
    }))
    assert _kinds(deltas)[("docker", "web")] == "unknown"
    assert not any(d.kind == "absent" and d.slot == "docker" for d in deltas)
    # ...and it never even asked, which is the point: there was nothing to ask.
    assert down.list_calls == []
    assert exit_code(deltas) == INCOMPLETE


def test_a_reachable_engine_with_nothing_running_is_absent(spec: Path) -> None:
    """The positive control for the row above.

    Without it, a `diff` that returned UNKNOWN unconditionally would satisfy every
    assertion in that test — the two branches must be shown to differ on the same
    empty list.
    """
    up = FakeBackend(resources=[], available=True)
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend(), "docker": up,
    }))
    assert _kinds(deltas)[("docker", "web")] == "absent"
    assert up.list_calls == ["mc"]          # and it DID ask, scoped to the lab


def test_unknown_outranks_a_difference_in_the_exit_code(spec: Path) -> None:
    """An unknown is a fact about the DIFF, not about the lab.

    A caller that read "2, differences" would act on a report that never looked at
    part of the system, which is the failure this repo grades as LIED rather than
    HALTED.
    """
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(available=False),   # unknown
        "fc": FakeBackend(),                      # absent  → a difference
        "docker": FakeBackend(),
    }))
    kinds = {d.kind for d in deltas}
    assert {"unknown", "absent"} <= kinds
    assert exit_code(deltas) == INCOMPLETE


def test_no_backend_registered_for_a_slot_is_also_unknown(spec: Path) -> None:
    deltas = diff(spec, backend_for=_fixed({}))
    assert {d.kind for d in deltas} == {"unknown"}
    assert exit_code(deltas) == INCOMPLETE


# ── identity: the spec's name is not the engine's name ───────────────────────

def test_the_declared_identity_is_the_svc_label(spec: Path) -> None:
    """`lab-mc-web` in Docker IS the declared `web`, and the label says so.

    Matching on `Resource.name` here yields `absent` for the declaration and
    `undeclared` for the container — two wrong rows that look like a real finding.
    """
    live = _res(backend="docker", name="lab-mc-web", svc="web", lab="mc", status="running")
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend(),
        "docker": FakeBackend([live]),
    }))
    assert _kinds(deltas)[("docker", "web")] == "converged"
    assert not any(d.kind == "undeclared" for d in deltas), (
        "REGRESSION: the renamed container was read as a stray — the diff is "
        "matching engine names instead of the lab-create.svc label"
    )


def test_phases_that_do_not_rename_match_on_name(spec: Path) -> None:
    """The other half: chroot/vm/fc set svc=None, so `svc or name` must fall back."""
    live = _res(backend="fc", name="api1", svc=None, lab="mc", status="running",
                type="microvm", extra={"tap": "mc-api1", "kernel": "/srv/vmlinux"})
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend([live]), "docker": FakeBackend(),
    }))
    assert _kinds(deltas)[("fc", "api1")] == "converged"


# ── per-slot notions of "up" ─────────────────────────────────────────────────

def test_a_built_chroot_counts_as_up_but_a_stopped_microvm_does_not(spec: Path) -> None:
    """`stop` does not mean the same thing to six engines — §8.3, in one assertion.

    A chroot has no run state at all: `built` IS its converged state.  A microVM
    that exists and is not running is a real, actionable difference.
    """
    chroot = _res(backend="chroot", name="base", lab="mc", status="built", type="chroot")
    micro = _res(backend="fc", name="api1", lab="mc", status="stopped", type="microvm",
                 extra={"tap": "mc-api1", "kernel": "/srv/vmlinux"})
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend([chroot]), "fc": FakeBackend([micro]),
        "docker": FakeBackend(),
    }))
    k = _kinds(deltas)
    assert k[("chroot", "base")] == "converged"
    assert k[("fc", "api1")] == "stopped"
    assert next(d for d in deltas if d.kind == "stopped").would == "start"


# ── drift: the payoff from decision G ────────────────────────────────────────

@pytest.mark.parametrize("field,live_value", [
    ("tap", "mc-OLD"),
    ("kernel", "/srv/vmlinux.old"),
])
def test_fc_drift_compares_the_spec_against_what_was_built(
    spec: Path, field: str, live_value: str,
) -> None:
    """The manifest is a record bound to its subject, not a second copy of the ask.

    `create` writes it from the record it actually built with, and `start`
    re-derives the kernel digest and refuses a mismatch by name — so comparing the
    spec against it compares intent against outcome.
    """
    extra = {"tap": "mc-api1", "kernel": "/srv/vmlinux"}
    extra[field] = live_value
    live = _res(backend="fc", name="api1", lab="mc", status="running",
                type="microvm", extra=extra)
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend([live]), "docker": FakeBackend(),
    }))
    d = next(x for x in deltas if x.slot == "fc")
    assert d.kind == "drifted"
    assert field in d.detail and live_value in d.detail
    assert d.would is not None and "recreate" in d.would


# ── strays are reported, never actioned ──────────────────────────────────────

def test_undeclared_is_reported_with_no_action(spec: Path) -> None:
    """Deleting what nobody declared is the half of a reconcile loop that destroys work."""
    stray = _res(backend="docker", name="lab-mc-old", svc="old", lab="mc", status="running")
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend(),
        "docker": FakeBackend([stray]),
    }))
    d = next(x for x in deltas if x.kind == "undeclared")
    assert d.name == "old" and "never removed" in d.detail
    assert d.would is None, (
        "REGRESSION: the diff proposed an action for a resource nobody declared"
    )


def test_an_unreachable_engine_does_not_get_to_say_there_are_no_strays(spec: Path) -> None:
    deltas = diff(spec, backend_for=_fixed({
        "chroot": FakeBackend(), "fc": FakeBackend(),
        "docker": FakeBackend(available=False),
    }))
    assert not any(d.kind == "undeclared" for d in deltas)


# ── the declaration side ─────────────────────────────────────────────────────

def test_a_service_with_no_engine_is_declared_for_both(tmp_path: Path) -> None:
    """Measured from both drivers, not inferred from the routing comment.

    `lab-docker.sh` skips a service only when `engine` is SET and is not `docker`;
    `lab-podman.sh` filters on `(.engine // "podman") == "podman"`.  Both defaults
    claim an unset service, so running both really does produce two containers.
    The diff reports what the tools do.
    """
    p = tmp_path / "amb.toml"
    p.write_text('[lab]\nname = "mc"\n\n[[service]]\nname = "web"\n')
    import tomllib
    want = declared(tomllib.loads(p.read_text()), p)
    assert want["docker"] == ["web"] and want["podman"] == ["web"]


def test_converged_everywhere_is_exit_zero(tmp_path: Path) -> None:
    p = tmp_path / "one.toml"
    p.write_text('[lab]\nname = "mc"\n\n[[chroot]]\nname = "base"\n')
    live = _res(backend="chroot", name="base", lab="mc", status="built", type="chroot")
    deltas = diff(p, backend_for=_fixed({"chroot": FakeBackend([live])}))
    assert [d.kind for d in deltas] == ["converged"]
    assert exit_code(deltas) == CONVERGED
    assert deltas[0].would is None


def test_a_lab_name_a_label_filter_cannot_carry_is_refused(tmp_path: Path) -> None:
    """It would not error — it would match nothing, and read as total absence.

    `docker.py` validates the same name and returns `[]` for a bad one, so without
    this the diff's most confident output ("everything is missing") would be
    produced by a filter that never matched anything.
    """
    p = tmp_path / "bad.toml"
    p.write_text('[lab]\nname = "mc=evil"\n\n[[chroot]]\nname = "base"\n')
    with pytest.raises(ValueError, match="lab name"):
        diff(p, backend_for=_fixed({"chroot": FakeBackend()}))


# ── the contract: it issues nothing ──────────────────────────────────────────

def test_the_diff_runs_no_mutating_command(spec: Path, monkeypatch) -> None:
    """`diff` is the read-only half, asserted as an outcome rather than promised.

    Every subprocess the real backends launch is recorded and checked against the
    mutating verbs; a diff that "just started the stopped one" would be a reconcile
    loop wearing a report's clothes.
    """
    seen: list[list[str]] = []
    import subprocess as _sp
    real = _sp.run

    def spy(argv, *a, **kw):
        if isinstance(argv, list):
            seen.append([str(x) for x in argv])
        return real(argv, *a, **kw)

    monkeypatch.setattr("lab_tui.backends.base.subprocess.run", spy)
    diff(spec)   # the REAL backends this time, whatever this host has
    # A scan that matched nothing and a scan that found nothing print the same
    # green tick.  On a host with no reachable engine every backend refuses at
    # `is_available()` before spawning anything, `seen` is empty, and the loop
    # below would assert over zero commands — so say UNKNOWN rather than PASS.
    if not seen:
        pytest.skip(
            "no engine on this host was reachable enough to run a command, so this "
            "run proves nothing about what the diff would have issued"
        )
    mutating = {"create", "start", "stop", "destroy", "up", "down", "rm", "kill", "run"}
    for argv in seen:
        assert not (mutating & set(argv)), f"the diff issued a mutating command: {argv}"
