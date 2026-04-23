"""Cross-phase topology dispatcher.

Reads a lab.toml, identifies which phase scripts need to run, and emits
ordered (phase, argv) plans for the screen layer to execute as workers.

Routing leans on each phase script's existing `engine` filter — we don't
re-implement cross-phase routing.  We just call all relevant scripts
against the same TOML and let each claim its own rows.

Dependency order (matters because Phase 4/5 may `from_chroot` Phase 1's
output):
  1. Phase 1 (chroots)            — strict prerequisite
  2. Phase 2 (vms)                — strict prerequisite for from_qcow2
  3. Phase 3, 4, 5  (parallel)    — no inter-phase deps
"""

from __future__ import annotations

import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from lab_tui.backends.base import phase_script

PhaseSlot = Literal["chroot", "vm", "docker", "podman", "lxd"]


@dataclass(slots=True, frozen=True)
class PhasePlan:
    """One phase script to invoke as part of a topology op."""

    slot: PhaseSlot
    argv: list[str]
    description: str


def _has_engine(items: list[dict], engines: set[str]) -> bool:
    """True if any item has `engine` matching one of `engines`,
    OR if `engine` is omitted (the script's default-engine semantics)."""
    for it in items:
        engine = (it.get("engine") or "").lower()
        if engine in engines or engine == "":
            return True
    return False


def parse_topology(toml_path: Path) -> dict:
    """Parse the TOML and return the dict.  Validates `[lab].name` is set."""
    raw = tomllib.loads(toml_path.read_text())
    if not raw.get("lab", {}).get("name"):
        raise ValueError(f"{toml_path}: missing [lab].name")
    return raw


def phases_present(parsed: dict) -> set[PhaseSlot]:
    """Which phase scripts the TOML actually invokes.

    A `[[service]]` block with `engine = "docker"` invokes Phase 3 only;
    `engine = "podman"` invokes Phase 4 only; un-set engine matches both
    scripts but each script's filter has its own default — we err on the
    side of running both so the per-script filter does the routing.
    """
    out: set[PhaseSlot] = set()
    if parsed.get("chroot"):
        out.add("chroot")
    if parsed.get("vm"):
        out.add("vm")
    services = parsed.get("service", [])
    if services and _has_engine(services, {"docker"}):
        out.add("docker")
    if services and _has_engine(services, {"podman"}):
        out.add("podman")
    if parsed.get("instance") or parsed.get("project") or parsed.get("profile"):
        out.add("lxd")
    return out


def _script_for(slot: PhaseSlot) -> Path:
    return {
        "chroot": phase_script("phase1-chroot/lab-chroot.sh"),
        "vm":     phase_script("phase2-qemu-vm/lab-vm.sh"),
        "docker": phase_script("phase3-docker/lab-docker.sh"),
        "podman": phase_script("phase4-podman/lab-podman.sh"),
        "lxd":    phase_script("phase5-lxd/lab-lxd.sh"),
    }[slot]


# Order in which `up` invocations should run — chroots first because
# Phase 4/5 may from_chroot the output, then vms (Phase 5 may from_qcow2),
# then the remaining engines in parallel-friendly order.
_UP_ORDER: tuple[PhaseSlot, ...] = ("chroot", "vm", "docker", "podman", "lxd")
# `down` reverses so dependent resources die before their providers.
_DOWN_ORDER: tuple[PhaseSlot, ...] = tuple(reversed(_UP_ORDER))


def plan_up(toml_path: Path) -> list[PhasePlan]:
    parsed = parse_topology(toml_path)
    present = phases_present(parsed)
    return [
        PhasePlan(
            slot=slot,
            argv=[str(_script_for(slot)), "up", "--config", str(toml_path)],
            description=f"phase {slot}: up --config {toml_path.name}",
        )
        for slot in _UP_ORDER if slot in present
    ]


def plan_down(toml_path: Path) -> list[PhasePlan]:
    parsed = parse_topology(toml_path)
    present = phases_present(parsed)
    lab_name = parsed["lab"]["name"]

    plans: list[PhasePlan] = []
    for slot in _DOWN_ORDER:
        if slot not in present:
            continue
        # Phase 1 has no `down` verb (chroots are persistent by design);
        # Phase 2's destroy is per-VM not per-lab.  Use --config when
        # supported, fall back to --lab.
        if slot == "chroot":
            # Phase 1: list & destroy by `lab` field — but that's manual.
            # Don't auto-destroy chroots on tear-down (they may be reused).
            plans.append(PhasePlan(
                slot=slot,
                argv=["echo", f"# phase 1: chroots persist; manually destroy with: "
                              f"sudo {_script_for('chroot')} destroy <name>"],
                description=f"phase {slot}: skipped (chroots persist)",
            ))
            continue
        if slot == "vm":
            plans.append(PhasePlan(
                slot=slot,
                argv=["echo", f"# phase 2: vms persist; manually destroy each via "
                              f"sudo {_script_for('vm')} destroy <name>"],
                description=f"phase {slot}: skipped (vms persist)",
            ))
            continue
        # Phase 3, 4, 5 all support `down --lab NAME`.
        plans.append(PhasePlan(
            slot=slot,
            argv=[str(_script_for(slot)), "down", "--lab", lab_name],
            description=f"phase {slot}: down --lab {lab_name}",
        ))
    return plans


def main() -> int:
    """CLI for testing without the TUI: dump the up/down plan."""
    if len(sys.argv) != 3 or sys.argv[1] not in {"up", "down"}:
        print("usage: python -m lab_tui.topology {up|down} <lab.toml>",
              file=sys.stderr)
        return 2
    op, path = sys.argv[1], Path(sys.argv[2])
    plans = plan_up(path) if op == "up" else plan_down(path)
    for p in plans:
        print(f"# {p.description}")
        print(" ".join(p.argv))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
