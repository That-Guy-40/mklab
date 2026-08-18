"""`apply` and the diff against a REAL engine — rootless podman on this host.

Everything else asserted about `apply` runs against injected backends.  That is
the right way to reach the interesting branches (an engine that cannot be asked
is hard to arrange on demand), but it leaves one honest gap: **no test had ever
driven the thing end to end against an engine that can disagree with it.**  A
fake converges because the fixture says so.

These tests create and destroy real containers under rootless podman, named
`lab-mklabselftest*`, and tear them down through the phase tool's own `down`
verb whether they pass or fail.  They SKIP — never silently pass — when podman
or the busybox image is absent, because an unmet precondition is an UNKNOWN and
has to be legible as one.

The load-bearing one is `test_the_derivation_answers_for_the_right_lab`: two labs
each declaring a service called `web`, which is slice 6's break-it row in
miniature — §8.4a moved that fault from *make the registry disagree with reality*
(there is no registry) to **make the derivation answer for the wrong subject**.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from collections.abc import Iterator
from pathlib import Path

import pytest

from lab_tui.apply import apply
from lab_tui.reconcile import diff

IMAGE = "docker.io/library/busybox:latest"
LAB_A = "mklabselftesta"
LAB_B = "mklabselftestb"
TOOL = Path(__file__).resolve().parents[2] / "phase4-podman" / "lab-podman.sh"


def _podman(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["podman", *args], capture_output=True, text=True, timeout=60)


def _have_image() -> bool:
    cp = _podman("image", "exists", IMAGE)
    return cp.returncode == 0


pytestmark = pytest.mark.skipif(
    shutil.which("podman") is None or not _have_image(),
    reason=(
        f"needs rootless podman and a local {IMAGE} — this suite drives a real "
        "engine and will not pull over the network to do it"
    ),
)


def _spec(tmp_path: Path, lab: str) -> Path:
    p = tmp_path / f"{lab}.toml"
    p.write_text(
        f'[lab]\nname = "{lab}"\n\n'
        '[[service]]\nname = "web"\nengine = "podman"\n'
        f'image = "{IMAGE}"\nmanager = "plain"\ncommand = "sleep 600"\n'
    )
    return p


def _container(lab: str) -> dict | None:
    """The live container for `<lab>/web`, straight from podman — not via the
    backend under test, so the assertion has an independent witness."""
    cp = _podman("ps", "-a", "--format", "{{json .}}",
                 "--filter", f"label=lab-create.lab={lab}")
    for line in cp.stdout.splitlines():
        if line.strip():
            row = json.loads(line)
            if row.get("Labels", {}).get("lab-create.svc") == "web":
                return row
    return None


@pytest.fixture
def live(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Iterator[Path]:
    """A private state dir, and teardown of BOTH labs however the test ends."""
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path / "state"))
    try:
        yield tmp_path
    finally:
        for lab in (LAB_A, LAB_B):
            subprocess.run(["bash", str(TOOL), "down", "--lab", lab],
                           capture_output=True, text=True, timeout=120)


def test_apply_converges_a_real_engine_and_the_second_pass_is_a_no_op(
    live: Path,
) -> None:
    """The contract, against something that can actually disagree with it."""
    spec = _spec(live, LAB_A)
    assert _container(LAB_A) is None, "a leftover from a previous run — refusing"

    first = apply(spec)
    assert first.converged, first
    assert first.issued, "nothing was issued for a lab that did not exist"
    row = _container(LAB_A)
    assert row is not None and row["State"] == "running"

    second = apply(spec)
    assert second.issued == [], (
        "REGRESSION: apply issued against a converged lab — the no-op property "
        f"holds against fakes but not against podman: {second.issued}"
    )
    assert second.converged and second.passes == 1


def test_a_really_stopped_container_is_started_and_not_recreated(live: Path) -> None:
    """THE FINDING THIS SUITE MADE, NOW ON THE OTHER SIDE OF ITS FIX.

    Written expecting `apply` to start it.  Live podman said otherwise, and the
    driver said so out loud:

        [warn] service 'web' container exists (lab-mklabselftesta-web); leaving as-is

    `up` on the three container engines is create-if-absent, not converge, and
    none of them had a `start` at all — invisible to every earlier test, because a
    fake converges when the fixture says so.  For one commit `apply` HELD the row;
    the durable fix was TODO A.3, which gave phases 3/4/5 the verb they lacked
    rather than having phase 6 reach around them to `podman start` and put a
    second owner on the lifecycle.

    So this now asserts the repair — and asserts it is a repair and not a rebuild:
    the container ID must be unchanged, because a destroy-and-recreate would
    satisfy "running again" while losing everything inside it.
    """
    spec = _spec(live, LAB_A)
    apply(spec)
    before = _container(LAB_A)
    assert before is not None
    assert _podman("stop", "-t", "1", before["Names"][0]).returncode == 0

    d = [x for x in diff(spec) if x.slot == "podman"]
    assert [x.kind for x in d] == ["stopped"], d

    r = apply(spec)
    assert r.converged, f"apply did not converge a stopped container: {r.held} {r.issued}"
    assert any(a[1] == "start" for a in r.issued), (
        f"converged without issuing a start — what closed it? {r.issued}"
    )

    after = _container(LAB_A)
    assert after is not None and after["State"] == "running"
    assert after["Id"] == before["Id"], (
        "REGRESSION: the container was re-created rather than started — its data "
        "and any manual state inside it are gone"
    )


def test_apply_is_still_a_no_op_once_it_has_started_something(live: Path) -> None:
    """The pass-two property, over the path that was broken until TODO A.3.

    `start` is idempotent by design (a reconcile loop may issue it against a row
    that started between the diff and the transition), so a driver that reported
    "already running" as an error would break convergence here rather than in the
    first pass.
    """
    spec = _spec(live, LAB_A)
    apply(spec)
    _podman("stop", "-t", "1", _container(LAB_A)["Names"][0])
    apply(spec)
    again = apply(spec)
    assert again.issued == [], f"apply kept issuing after convergence: {again.issued}"
    assert again.converged and again.passes == 1


def test_the_derivation_answers_for_the_right_lab(live: Path) -> None:
    """Slice 6's break-it row: make the derivation answer for the WRONG subject.

    Two labs, each declaring a service called `web`.  Both containers exist; one
    lab's is then removed.  If the derivation is not scoped by lab, B's container
    answers A's question and the diff reports A converged over nothing — the exact
    shape of the two faults this repo has already been caught by (a seam answering
    for the wrong instance; one pidfile read three ways).
    """
    spec_a, spec_b = _spec(live, LAB_A), _spec(live, LAB_B)
    apply(spec_a)
    apply(spec_b)
    a, b = _container(LAB_A), _container(LAB_B)
    assert a and b and a["Id"] != b["Id"]
    # Same declared identity, different labs — which is the whole point.
    assert a["Labels"]["lab-create.svc"] == b["Labels"]["lab-create.svc"] == "web"

    # Remove A's, leave B's running.  A's `web` is now absent; B's is not.
    assert _podman("rm", "-f", a["Names"][0]).returncode == 0

    da = [x for x in diff(spec_a) if x.slot == "podman"]
    assert [x.kind for x in da] == ["absent"], (
        "REGRESSION: the diff answered lab A's question with lab B's container — "
        f"got {[(x.name, x.kind) for x in da]}"
    )
    db = [x for x in diff(spec_b) if x.slot == "podman"]
    assert [x.kind for x in db] == ["converged"], (
        "...and the control: B really is still running, so a diff that said "
        "`absent` for everything would not have proved the scoping either"
    )
    # Nor is A's declared row reported as a stray under B.
    assert not any(x.kind == "undeclared" for x in diff(spec_b))
