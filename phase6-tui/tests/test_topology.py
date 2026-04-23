from __future__ import annotations

from pathlib import Path

import pytest

from lab_tui.topology import (
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


def test_phases_present_service_unset_engine_runs_both(tmp_path: Path) -> None:
    """A [[service]] without `engine` set runs both Phase 3 and Phase 4 —
    each script's own filter routes it correctly (or skips it)."""
    p = tmp_path / "ambiguous.toml"
    p.write_text('[lab]\nname = "x"\n\n[[service]]\nname = "a"\n')
    present = phases_present(parse_topology(p))
    assert "docker" in present
    assert "podman" in present


def test_plan_up_orders_chroot_first(sample_toml: Path) -> None:
    plans = plan_up(sample_toml)
    slots = [p.slot for p in plans]
    assert slots == ["chroot", "vm", "docker", "podman", "lxd"]
    # Each plan's argv should call the right script with up --config.
    for p in plans:
        assert p.argv[1] == "up"
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
