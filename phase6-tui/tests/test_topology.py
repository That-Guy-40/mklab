from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from lab_tui.backends.base import phase_script
from lab_tui.topology import (
    FC_NAME_RE,
    PhasePlan,
    parse_topology,
    phases_present,
    plan_down,
    plan_up,
)


@pytest.fixture
def sample_toml(tmp_path: Path) -> Path:
    p = tmp_path / "demo.toml"
    p.write_text(
        '[lab]\n'
        'name = "demo"\n'
        '\n'
        '[[chroot]]\n'
        'name = "kali"\n'
        '\n'
        '[[vm]]\n'
        'name = "victim"\n'
        '\n'
        '[[service]]\n'
        'name = "web"\n'
        'engine = "docker"\n'
        '\n'
        '[[service]]\n'
        'name = "scanner"\n'
        'engine = "podman"\n'
        '\n'
        '[[instance]]\n'
        'name = "container1"\n'
        'engine = "lxd"\n'
    )
    return p


def test_parse_topology_requires_lab_name(tmp_path: Path) -> None:
    p = tmp_path / "bad.toml"
    p.write_text('[lab]\ndescription = "no name"\n')
    with pytest.raises(ValueError, match="missing"):
        parse_topology(p)


def test_phases_present_full(sample_toml: Path) -> None:
    parsed = parse_topology(sample_toml)
    assert phases_present(parsed) == {"chroot", "vm", "docker", "podman", "lxd"}


def test_phases_present_lxd_only(tmp_path: Path) -> None:
    p = tmp_path / "lxd-only.toml"
    p.write_text('[lab]\nname = "x"\n\n[[instance]]\nname = "a"\n')
    assert phases_present(parse_topology(p)) == {"lxd"}


def test_a_service_with_no_engine_is_refused_not_routed(tmp_path: Path) -> None:
    """This test used to assert the opposite, and the opposite was wrong.

    It read: *"a [[service]] without `engine` runs both Phase 3 and Phase 4 — each
    script's own filter routes it correctly."*  Measured in the two drivers, neither
    filter routes anything: `lab-docker.sh` skips a service only when `engine` is SET
    and is not docker, and `lab-podman.sh` selects on `(.engine // "podman")`.  Both
    defaults CLAIM it, so a cross-phase bring-up created the service twice — one
    container per engine, under a single declared identity — and `apply` would have
    created both and then reported both converged.

    Phase 6 cannot pick a winner without contradicting whichever driver it overrules,
    so it refuses and names the two candidates.  A spec run through ONE driver
    directly is unaffected: the ambiguity exists only because phase 6 runs both.
    """
    p = tmp_path / "ambiguous.toml"
    p.write_text('[lab]\nname = "x"\n\n[[service]]\nname = "a"\n')
    with pytest.raises(ValueError, match="has no `engine`") as e:
        phases_present(parse_topology(p))
    # The refusal has to be actionable at the point it is read.
    assert "docker" in str(e.value) and "podman" in str(e.value)
    for op in (plan_up, plan_down):
        with pytest.raises(ValueError, match="has no `engine`"):
            op(p)


def test_an_engine_this_dispatcher_does_not_know_is_refused(tmp_path: Path) -> None:
    p = tmp_path / "weird.toml"
    p.write_text('[lab]\nname = "x"\n\n[[service]]\nname = "a"\nengine = "containerd"\n')
    with pytest.raises(ValueError, match="not one this dispatcher knows"):
        phases_present(parse_topology(p))


def test_an_explicit_engine_still_routes_to_exactly_one(tmp_path: Path) -> None:
    """The control: the refusal must not have swallowed the normal case."""
    p = tmp_path / "explicit.toml"
    p.write_text(
        '[lab]\nname = "x"\n\n[[service]]\nname = "a"\nengine = "docker"\n'
        '\n[[service]]\nname = "b"\nengine = "podman"\n'
    )
    assert phases_present(parse_topology(p)) == {"docker", "podman"}


def test_plan_up_orders_chroot_first(sample_toml: Path) -> None:
    plans = plan_up(sample_toml)
    assert [p.slot for p in plans] == [
        "chroot", "vm", "vm", "docker", "podman", "lxd",
    ]
    # This used to assert `argv[1] == "up"` for EVERY plan, which is how
    # `lab-chroot.sh up` and `lab-vm.sh up` — verbs neither driver has ever had —
    # went unnoticed: the test asserted the shape the planner emitted rather than
    # the vocabulary the drivers speak.  Only three of the six have `up`.
    assert [(Path(p.argv[0]).name, p.argv[1]) for p in plans] == [
        ("lab-chroot.sh", "create"),
        ("lab-vm.sh", "create"),
        ("lab-vm.sh", "start"),      # a VM is created stopped
        ("lab-docker.sh", "up"),
        ("lab-podman.sh", "up"),
        ("lab-lxd.sh", "up"),
    ]
    for p in plans:
        if p.argv[1] in {"up", "create"}:
            assert p.argv[2] == "--config"
            assert p.argv[3] == str(sample_toml)


def test_plan_down_reverses_order(sample_toml: Path) -> None:
    plans = plan_down(sample_toml)
    slots = [p.slot for p in plans]
    assert slots == ["lxd", "podman", "docker", "vm", "chroot"]


def test_plan_down_skips_chroot_and_vm_destroy(sample_toml: Path) -> None:
    """chroots & vms persist across topology tear-down — the auto plan
    must NOT destroy them, only the engine-managed runtime resources."""
    plans = plan_down(sample_toml)
    chroot_plan = next(p for p in plans if p.slot == "chroot")
    vm_plan = next(p for p in plans if p.slot == "vm")
    assert chroot_plan.argv[0] == "echo"
    assert vm_plan.argv[0] == "echo"
    # The other 3 phases use `down --lab demo`.
    for slot in ("docker", "podman", "lxd"):
        plan = next(p for p in plans if p.slot == slot)
        assert plan.argv[1:] == ["down", "--lab", "demo"]


# ── Phase 7: the slot whose driver has different verbs ───────────────────────
# Slice 6's second increment.  Every other slot is `<script> up --config <toml>`;
# `lab-fc.sh` has no `up` and no `down --lab`, so the fc slot expands to the verbs
# it does have.  These assert the OUTCOME (the emitted argv is a command the driver
# accepts, and tear-down does not reap the rootfs copies), and two of them ask the
# driver itself rather than trusting a constant copied out of it.

FC_SCRIPT = phase_script("phase7-firecracker/lab-fc.sh")

MICROVM_TOML = (
    '[lab]\n'
    'name = "mc"\n'
    '\n'
    '[[microvm]]\n'
    'name = "api1"\n'
    'kernel = "/srv/vmlinux"\n'
    'rootfs = "/srv/api.ext4"\n'
    'tap = "mc-api1"\n'
    '\n'
    '[[microvm]]\n'
    'name = "api2"\n'
    'kernel = "/srv/vmlinux"\n'
    'rootfs = "/srv/api.ext4"\n'
    'tap = "mc-api2"\n'
)


@pytest.fixture
def microvm_toml(tmp_path: Path) -> Path:
    p = tmp_path / "mc.toml"
    p.write_text(MICROVM_TOML)
    return p


def test_phases_present_detects_microvm(microvm_toml: Path) -> None:
    assert phases_present(parse_topology(microvm_toml)) == {"fc"}


def test_a_toml_without_microvms_does_not_invoke_phase_7(sample_toml: Path) -> None:
    """The control for the row above: five other block types must not summon fc."""
    assert "fc" not in phases_present(parse_topology(sample_toml))
    assert all(p.slot != "fc" for p in plan_up(sample_toml))


def test_plan_up_creates_once_then_starts_each(microvm_toml: Path) -> None:
    plans = [p for p in plan_up(microvm_toml) if p.slot == "fc"]
    assert [p.argv[1:] for p in plans] == [
        ["create", "--config", str(microvm_toml)],
        ["start", "api1"],
        ["start", "api2"],
    ]
    assert all(p.argv[0] == str(FC_SCRIPT) for p in plans)
    # The plan pane is where an operator decides whether to press `u` on a lab
    # that is already up, so the refusal has to be legible there.
    assert "refuses if one already exists" in plans[0].description


def test_plan_up_never_emits_the_up_verb_for_fc(microvm_toml: Path) -> None:
    """The three-line version of this feature would have emitted `up --config`.

    It renders identically in the plan pane and fails on execution for every lab,
    which is why this is asserted rather than left to the reader of _script_for.
    """
    for plan in plan_up(microvm_toml):
        if plan.slot == "fc":
            assert plan.argv[1] != "up", (
                "REGRESSION: the fc slot emitted `up`, which lab-fc.sh has never had"
            )


def test_fc_sits_between_vm_and_the_container_engines(tmp_path: Path) -> None:
    p = tmp_path / "all.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[chroot]]\nname = "base"\n\n[[vm]]\nname = "edge"\n\n'
        + MICROVM_TOML.split("\n", 2)[2]  # the two [[microvm]] blocks
        + '\n[[service]]\nname = "web"\nengine = "docker"\n'
        '\n[[instance]]\nname = "c1"\nengine = "lxd"\n'
    )
    slots = [pl.slot for pl in plan_up(p)]
    assert slots == ["chroot", "vm", "vm", "fc", "fc", "fc", "docker", "lxd"]
    # ...and the reversal puts the cattle down first and the machines last.
    down = [pl.slot for pl in plan_down(p)]
    assert down.index("lxd") < down.index("docker") < down.index("fc") < down.index("vm")


def test_plan_down_stops_each_microvm_and_destroys_none(microvm_toml: Path) -> None:
    """Tear-down stops; it does not delete a per-instance rootfs copy.

    Same rule the chroot and vm slots follow, for the same reason — except this
    slot can act on it, because Phase 7 has a stop that asserts the outcome.
    """
    plans = [p for p in plan_down(microvm_toml) if p.slot == "fc"]
    real = [p for p in plans if p.argv[0] != "echo"]
    # THE NAMED ASSERTION GOES FIRST.  It did not, at first, and the shape of that
    # mistake is the one this repo writes down: injecting `destroy` fired the argv
    # equality below instead, so the failure printed a list diff and the sentence
    # explaining WHY it matters never ran.  One assertion, one specific message —
    # and the most specific one has to be the one that bites.
    assert not any("destroy" in p.argv for p in real), (
        "REGRESSION: tear-down destroyed a microVM — its rootfs copy is persistent "
        "state, like a chroot or a vm, and destroy is a deliberate manual act"
    )
    assert [p.argv[1:] for p in real] == [
        ["stop", "api2", "--force"],   # reverse of file order
        ["stop", "api1", "--force"],
    ]
    # ...and the operator is told the state is still there, rather than guessing.
    note = next(p for p in plans if p.argv[0] == "echo")
    assert "persists" in note.argv[1] and "destroy" in note.argv[1]


def test_fc_name_regex_is_the_drivers_own(tmp_path: Path) -> None:
    """A copied constant is a cached fact, so bind it to its subject.

    `FC_NAME_RE` here duplicates `readonly FC_NAME_RE=` in lab-fc.sh.  If the driver
    widens or narrows the name rule, a plan-time refusal that no longer agrees is
    either a lab that cannot be planned or a name the driver will reject anyway —
    both silent.  This reads the line out of the driver and compares.
    """
    src = FC_SCRIPT.read_text()
    m = re.search(r"^readonly FC_NAME_RE='([^']*)'", src, re.MULTILINE)
    assert m, "lab-fc.sh no longer declares FC_NAME_RE as a single-quoted readonly"
    assert m.group(1) == FC_NAME_RE.pattern, (
        f"lab-fc.sh says {m.group(1)!r}, topology.py says {FC_NAME_RE.pattern!r}"
    )


def _verb_is_missing(script: Path, verb: str, tmp_path: Path) -> bool:
    """Does this driver have this verb?  Asked of the driver, driver-agnostically.

    Each driver words its refusal differently — `lab-fc.sh` says `unknown verb: up`,
    while `lab-chroot.sh` and `lab-vm.sh` just fall through to usage with no
    distinctive string at all — so there is no one message to grep for.  What IS
    universal: **a driver answers a verb it does not have exactly as it answers a
    verb nobody has.**  So run both and compare.

    The verb name is normalised out with WORD BOUNDARIES, which matters: a first
    version used `s/up/VERB/g`, which also rewrote "group" and "setup" inside the
    usage text, made the two outputs differ, and reported `up` as *present* on the
    two drivers that have never had it.  A cheap normalisation standing in for the
    real comparison — the mistake this repo keeps re-finding.
    """
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path),
           "LAB_STATE_DIR": str(tmp_path / "state")}

    def reply(v: str) -> str:
        cp = subprocess.run(["bash", str(script), v], capture_output=True,
                            text=True, timeout=60, env=env)
        return re.sub(rf"\b{re.escape(v)}\b", "VERB", cp.stdout + cp.stderr)

    return reply(verb) == reply("zzznotaverb")


@pytest.mark.skipif(shutil.which("bash") is None, reason="no bash")
def test_every_verb_every_slot_emits_is_a_verb_that_driver_has(tmp_path: Path) -> None:
    """The check that was missing, and the three defects it found.

    The fc slot got this test when it was built; the other five never had one — so
    `plan_up` emitted `lab-chroot.sh up --config …` and `lab-vm.sh up --config …`
    from the beginning, and NEITHER DRIVER HAS EVER HAD AN `up` VERB.  Both fall
    through to usage and exit 1.  Those are the two slots the module docstring
    calls strict prerequisites, so every cross-phase bring-up through this screen
    failed at its first step.

    This covers every slot, both directions, so the next driver whose vocabulary
    differs is caught by a test rather than by a lab that will not come up.
    """
    p = tmp_path / "all.toml"
    p.write_text(
        '[lab]\nname = "mc"\n\n[[chroot]]\nname = "base"\n\n[[vm]]\nname = "edge"\n\n'
        '[[microvm]]\nname = "api1"\nkernel = "/k"\nrootfs = "/r"\ntap = "t"\n\n'
        '[[service]]\nname = "web"\nengine = "docker"\n\n'
        '[[service]]\nname = "cache"\nengine = "podman"\n\n'
        '[[instance]]\nname = "c1"\nengine = "lxd"\n'
    )
    pairs = {
        (plan.argv[0], plan.argv[1])
        for plan in plan_up(p) + plan_down(p)
        if plan.argv[0] != "echo"
    }
    assert len(pairs) >= 6, f"only probed {pairs} — the fixture stopped covering slots"
    missing = [
        f"{Path(script).name} has no `{verb}` verb"
        for script, verb in sorted(pairs)
        if _verb_is_missing(Path(script), verb, tmp_path)
    ]
    assert not missing, "REGRESSION: the planner emits verbs that do not exist: " + \
        "; ".join(missing)


@pytest.mark.skipif(shutil.which("bash") is None, reason="no bash")
def test_the_verb_probe_can_actually_detect_a_missing_verb(tmp_path: Path) -> None:
    """The control for the probe above — without it, a probe that always returned
    False would make the whole sweep vacuously green.

    `up` on `lab-fc.sh` is the known-missing case (that is why the fc slot emits
    `create`/`start`), and `list` is the known-present one.
    """
    fc = phase_script("phase7-firecracker/lab-fc.sh")
    assert _verb_is_missing(fc, "up", tmp_path), "the probe cannot see a missing verb"
    assert not _verb_is_missing(fc, "list", tmp_path), "the probe calls a real verb missing"


@pytest.mark.skipif(shutil.which("bash") is None, reason="no bash")
def test_the_driver_accepts_every_verb_this_planner_emits(
    microvm_toml: Path, tmp_path: Path,
) -> None:
    """Ask the driver, do not read the driver.

    Each emitted verb is run with no further arguments and must fail for its OWN
    reason (a missing name, a missing --config), never with `unknown verb`.  The
    negative control is `up`: the verb the obvious implementation would have
    emitted must be rejected, or this test proves nothing — a driver that accepted
    everything would pass the positive half too.

    Nothing here creates or starts anything: every one of these dies in argument
    handling, before any state directory is touched (LAB_STATE_DIR is redirected
    at a tmp dir anyway, in case a future verb changes that).
    """
    env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path),
           "LAB_STATE_DIR": str(tmp_path / "state")}

    def run(*args: str) -> str:
        cp = subprocess.run(
            ["bash", str(FC_SCRIPT), *args],
            capture_output=True, text=True, timeout=30, env=env,
        )
        assert cp.returncode != 0, f"expected {args} to fail on its own terms"
        return cp.stdout + cp.stderr

    verbs = {p.argv[1] for p in plan_up(microvm_toml) + plan_down(microvm_toml)
             if p.slot == "fc" and p.argv[0] != "echo"}
    for verb in sorted(verbs):
        out = run(verb)
        assert "unknown verb" not in out, (
            f"REGRESSION: the fc plan emits `{verb}`, which lab-fc.sh does not have: {out}"
        )
    # Coverage, asserted after the loop so that a plan emitting a verb the driver
    # lacks fails with the message above rather than on this set comparison.
    assert verbs == {"create", "start", "stop"}

    # The control.  Without it, a driver that had lost its verb check entirely
    # would satisfy every assertion above.
    assert "unknown verb: up" in run("up", "--config", str(microvm_toml))


@pytest.mark.skipif(shutil.which("bash") is None, reason="no bash")
def test_phase_7_accepts_a_cross_phase_toml_it_does_not_own(tmp_path: Path) -> None:
    """The dispatcher hands ONE file to six drivers; Phase 7's parser is the strictest.

    `lab-fc.sh`'s TOML reader refuses any key it does not understand — deliberately,
    since "a config key that is silently dropped is a field that appears to work and
    does nothing".  A unified lab.toml is mostly keys it does not understand
    (`[[chroot]] name`, `[[service]] engine`), and it only survives because the
    reader stops reading at every other `[` header.  That is one line of awk holding
    up cross-phase bring-up, so it is measured here rather than assumed: this is the
    seam where a plan that renders fine gets refused wholesale by one driver.
    """
    cfg = tmp_path / "unified.toml"
    cfg.write_text(
        '[lab]\nname = "mc"\n\n[[chroot]]\nname = "base"\n\n'
        '[[service]]\nname = "web"\nengine = "docker"\n\n'
        + MICROVM_TOML.split("\n", 2)[2]
    )
    env = {**os.environ, "LAB_STATE_DIR": str(tmp_path / "state")}
    cp = subprocess.run(
        ["bash", str(FC_SCRIPT), "preflight", "--config", str(cfg)],
        capture_output=True, text=True, timeout=60, env=env,
    )
    out = cp.stdout + cp.stderr
    # The gates themselves fail here (no kernel, no rootfs, no tap on a test host) and
    # that is fine — the question is whether the FILE was understood.
    # Match the parser's refusal, NOT the word "unknown" — preflight's own summary
    # line ends `0 UNKNOWN`, and a bare substring check greps that instead (it did,
    # on the first run of this test: a broad string standing in for a precise
    # question, which is the mistake this repo's checker made twice).
    assert "unknown [[microvm]] key" not in out, (
        f"REGRESSION: lab-fc.sh refused a cross-phase TOML it should have read past: {out}"
    )
    assert "refusing" not in out, f"lab-fc.sh rejected the file outright: {out}"
    assert "preflight: api1" in out and "preflight: api2" in out

    # The control: a key that really is unknown, inside a block Phase 7 DOES own,
    # must still be refused — otherwise the assertion above only proves that this
    # driver stopped refusing anything.
    bad = tmp_path / "bad.toml"
    bad.write_text('[lab]\nname = "mc"\n\n[[microvm]]\nname = "api1"\nnot_a_key = "x"\n')
    cp2 = subprocess.run(
        ["bash", str(FC_SCRIPT), "preflight", "--config", str(bad)],
        capture_output=True, text=True, timeout=60, env=env,
    )
    assert cp2.returncode != 0
    assert "unknown [[microvm]] key not_a_key" in cp2.stdout + cp2.stderr
