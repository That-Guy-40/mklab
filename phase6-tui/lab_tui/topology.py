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
  3. Phase 7 (microvms)           — no deps; grouped with vm, see _UP_ORDER
  4. Phase 3, 4, 5  (parallel)    — no inter-phase deps

ONLY THREE OF THE SIX DRIVERS HAVE AN `up` VERB.
-----------------------------------------------------------------------------
`lab-fc.sh` has no `up` and no `down --lab`: its verbs are `create` (whole
config) and `start`/`stop`/`destroy`/`inspect` (one instance).  It was tempting
to add `fc` to the table like the others and be done in three lines; that would
have produced a plan that renders perfectly in the plan pane and dies with
`unknown verb: up` on execution, for every lab.

**And phase 7 turned out not to be the exception.**  `lab-chroot.sh` and
`lab-vm.sh` have no `up` either — they create with `create --config` (each
iterating every block in the file) and phase 2 runs with `start <name>`.  This
module emitted `up` for both from the beginning, so the two slots the dependency
order below calls STRICT PREREQUISITES failed at their first step in every
cross-phase bring-up.  Found by generalising the fc verb check to all six slots
(`tests/test_topology.py`), which is now the durable guard.

That is the micro-cloud plan's decision E, shape **(b)**, arriving where it was
predicted to: *per-engine drivers, a common contract, engine-specific verbs; the
control plane speaks the intersection.*  So the `fc` slot expands to the verbs
Phase 7 actually has — `create --config` once, then `start <name>` per
`[[microvm]]` — which is exactly the sequence micro-cloud's own root harness
(`tests/test-edge-on-the-fabric.sh`) runs by hand.  One slot, several plans; the
executor already runs a list in order and halts on the first non-zero.

Two consequences worth stating rather than discovering:
  * `create` refuses to overwrite an existing instance (it would clobber a
    per-instance rootfs copy), so a SECOND `up` on a live lab halts here by
    design.  An honest refusal naming the instance, not a silent re-create.
  * the tap is NOT ours to make.  `lab-fc.sh` validates a tap and never creates
    one — micro-cloud's `fabric.sh` owns tap lifecycle, and it needs root.  A
    bring-up through this screen therefore assumes the fabric already ran; the
    preflight inside `create` refuses by name if it did not.
"""

from __future__ import annotations

import json
import re
import shlex
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from lab_tui.paths import phase_script

PhaseSlot = Literal["chroot", "vm", "fc", "docker", "podman", "lxd"]

# `lab-fc.sh`'s own FC_NAME_RE, and tests/test_topology.py reads that line out of
# the driver and asserts these two agree — a copied constant is a cached fact, and
# this repo has been bitten by every one it has failed to bind to its source.
# It is enforced HERE as well as there because a microvm name becomes a positional
# argument: a name starting with `-` would be read by the driver's arg loop as a
# flag (`--force` is a real one), so the refusal belongs at plan time, where it is
# legible in the plan pane, rather than in a subprocess log.
FC_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,30}$")


@dataclass(slots=True, frozen=True)
class PhasePlan:
    """One phase script to invoke as part of a topology op."""

    slot: PhaseSlot
    argv: list[str]
    description: str


SERVICE_ENGINES: tuple[PhaseSlot, ...] = ("docker", "podman")


def services_by_engine(parsed: dict) -> dict[PhaseSlot, list[str]]:
    """`[[service]]` names grouped by the engine that owns them, in file order.

    AN UNSET `engine` IS REFUSED HERE, NOT ROUTED — and that is a correction.

    This function used to answer "does any service want docker / podman?" and
    counted an omitted `engine` as a yes for BOTH, on the stated theory that each
    script's own filter would do the routing.  Measured in the two drivers, it does
    not:

        lab-docker.sh   skips a service only when `engine` is SET and is not docker
        lab-podman.sh   selects on `(.engine // "podman") == "podman"`

    Both defaults CLAIM an unset service.  So a cross-phase bring-up ran both
    scripts and created the service twice — one container per engine, under a
    single declared identity — and the `apply` now being built on top of this would
    have created both and then reported both converged.

    Phase 6 cannot pick a winner without contradicting whichever driver it
    overrules, so it refuses and says which two candidates disagree.  A file run
    through ONE driver directly is unaffected: this is phase 6's ambiguity, and
    it exists only because phase 6 is the thing that runs both.
    """
    out: dict[PhaseSlot, list[str]] = {}
    for i, svc in enumerate(parsed.get("service", []), start=1):
        if not isinstance(svc, dict):
            raise ValueError("service must be an array of tables — write [[service]]")
        name = svc.get("name") or f"#{i}"
        engine = (svc.get("engine") or "").lower()
        if not engine:
            raise ValueError(
                f"[[service]] {name!r} has no `engine`. Phase 3 and Phase 4 BOTH claim "
                "a service that does not name one (lab-docker.sh skips only when engine "
                "is set and is not docker; lab-podman.sh selects on "
                '`(.engine // "podman")`), so a cross-phase run would create it twice '
                'under one name. Set engine = "docker" or engine = "podman" — a spec run '
                "through a single phase script directly does not need this."
            )
        if engine not in SERVICE_ENGINES:
            raise ValueError(
                f"[[service]] {name!r}: engine {engine!r} is not one this dispatcher "
                f"knows — expected one of {', '.join(SERVICE_ENGINES)}"
            )
        out.setdefault(engine, []).append(svc.get("name") or name)
    return out


def parse_topology(toml_path: Path) -> dict:
    """Parse the TOML and return the dict.  Validates `[lab].name` is set."""
    raw = tomllib.loads(toml_path.read_text())
    if not raw.get("lab", {}).get("name"):
        raise ValueError(f"{toml_path}: missing [lab].name")
    return raw


LAB_NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$")


def validated_lab_name(parsed: dict) -> str:
    """`[lab].name`, refused unless it is safe to hand to a phase script.

    F-05: a name starting with `--` or containing a space would confuse the bash
    `--lab` parser.  It matters a second time in `reconcile.py`, where an invalid
    name reaches `docker ps --filter label=lab-create.lab=<name>` — and *that*
    failure is silent in the worse direction: the engine matches nothing, the
    query returns cleanly, and every declared resource reads as MISSING.  One
    definition, called from both, rather than a copy that drifts.
    """
    name = parsed["lab"]["name"]
    if not isinstance(name, str) or not LAB_NAME_RE.match(name):
        raise ValueError(
            f"lab name {name!r} contains characters not safe for --lab; "
            "use only [a-zA-Z0-9_-]"
        )
    return name


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
    out.update(services_by_engine(parsed).keys())
    if parsed.get("instance") or parsed.get("project") or parsed.get("profile"):
        out.add("lxd")
    if parsed.get("microvm"):
        out.add("fc")
    return out


def _script_for(slot: PhaseSlot) -> Path:
    return {
        "chroot": phase_script("phase1-chroot/lab-chroot.sh"),
        "vm":     phase_script("phase2-qemu-vm/lab-vm.sh"),
        "fc":     phase_script("phase7-firecracker/lab-fc.sh"),
        "docker": phase_script("phase3-docker/lab-docker.sh"),
        "podman": phase_script("phase4-podman/lab-podman.sh"),
        "lxd":    phase_script("phase5-lxd/lab-lxd.sh"),
    }[slot]


def microvm_names(parsed: dict, toml_path: Path) -> list[str]:
    """The `[[microvm]]` names, in file order, refused early if unusable.

    A block with no `name` cannot be started or stopped — the plan would be a
    `create` with no matching `start`, which reads as success and leaves a VM
    nobody can address.  Both refusals raise ValueError because that is what the
    topology screen catches and renders; an AttributeError from `[microvm]`
    written as a table instead of an array would crash the worker instead.
    """
    blocks = parsed.get("microvm") or []
    if not isinstance(blocks, list) or not all(isinstance(b, dict) for b in blocks):
        raise ValueError(
            f"{toml_path}: microvm must be an array of tables — write [[microvm]], "
            "not [microvm]"
        )
    names: list[str] = []
    for i, block in enumerate(blocks, start=1):
        name = block.get("name")
        if not name:
            raise ValueError(
                f"{toml_path}: [[microvm]] #{i} has no `name` — lab-fc.sh addresses "
                "an instance by name for start/stop/destroy, so a nameless block "
                "could be created and never reached again"
            )
        if not isinstance(name, str) or not FC_NAME_RE.match(name):
            raise ValueError(
                f"{toml_path}: [[microvm]] name {name!r} does not match "
                f"{FC_NAME_RE.pattern} — lab-fc.sh uses it as a directory name under "
                "the state dir (and as a positional argument), so a path is not a name"
            )
        names.append(name)
    return names


# Order in which `up` invocations should run — chroots first because
# Phase 4/5 may from_chroot the output, then vms (Phase 5 may from_qcow2),
# then the remaining engines in parallel-friendly order.
#
# `fc` sits beside `vm` because it is the same KIND of thing: a machine whose
# disk is an expensive per-instance file that outlives the lab.  Nothing consumes
# a microVM, so its position is not a dependency — it is what makes the reversal
# below correct, since both slots are torn down by stopping and neither by
# destroying.
_UP_ORDER: tuple[PhaseSlot, ...] = ("chroot", "vm", "fc", "docker", "podman", "lxd")
# `down` reverses so dependent resources die before their providers.
_DOWN_ORDER: tuple[PhaseSlot, ...] = tuple(reversed(_UP_ORDER))


#: Slots whose driver has NO `up` verb.  Measured, not read off the usage text:
#: each verb was run and its reply compared byte-for-byte against the reply to a
#: deliberately bogus verb — if a driver answers `up` exactly as it answers
#: `zzznotaverb`, it does not have `up`.
#:
#: `plan_up` emitted `lab-chroot.sh up --config …` and `lab-vm.sh up --config …`
#: from the beginning.  Neither has ever existed: both fall through to usage and
#: exit 1.  These are the two slots the module docstring calls STRICT
#: PREREQUISITES, so every cross-phase bring-up through this screen failed at its
#: first step — the repo's own recorded bug class, *"the CLI verbs a doc cites all
#: exist" while its first command had never worked at any commit*.
#:
#: They are not exceptions to a rule.  THREE of the six drivers create with
#: `create` and run with `start`; only docker, podman and lxd have `up`.
_NO_UP_VERB: frozenset[PhaseSlot] = frozenset({"chroot", "vm", "fc"})

#: Slots with a per-instance `start`.
#:
#: Was `{"vm", "fc"}`: the three container drivers had no `start` at all, and their
#: `up` is create-if-absent — over a stopped container it logs *"container exists …
#: leaving as-is"* and returns 0 — so a stopped container was a state this control
#: plane could not repair and `apply` HELD it (TODO A.3, found by driving real
#: podman).  The fix went where the gap was: `lab-docker.sh`, `lab-podman.sh` and
#: `lab-lxd.sh` each grew a `start <name|lab/service>` that asserts the outcome
#: rather than trusting the engine's exit status.
#:
#: `chroot` is still absent, and always will be: a chroot has no run state at all.
_HAS_START_VERB: frozenset[PhaseSlot] = frozenset(
    {"vm", "fc", "docker", "podman", "lxd"}
)

#: Slots whose `start` takes `<lab>/<service>` rather than a bare name.  Phases 3,
#: 4 and 5 rename what they create (`lab-<lab>-<svc>`) and resolve a BARE target to
#: `lab-<name>` — so passing the declared service name alone would address
#: `lab-web` instead of `lab-<lab>-web`: a different container, or none.  Measured
#: while writing phase 4's test, where the first version refused `lab-lab-…-dies`.
_START_TAKES_LAB_SLASH_SVC: frozenset[PhaseSlot] = frozenset(
    {"docker", "podman", "lxd"}
)


def instance_names(parsed: dict, block: str, toml_path: Path) -> list[str]:
    """Declared names for a `[[<block>]]` array, refused early if unusable."""
    blocks = parsed.get(block) or []
    if not isinstance(blocks, list) or not all(isinstance(b, dict) for b in blocks):
        raise ValueError(
            f"{toml_path}: {block} must be an array of tables — write [[{block}]]"
        )
    names = []
    for i, b in enumerate(blocks, start=1):
        name = b.get("name")
        if not name or not isinstance(name, str):
            raise ValueError(
                f"{toml_path}: [[{block}]] #{i} has no `name` — the driver addresses "
                "it by name for start/stop/destroy"
            )
        names.append(name)
    return names


def _fc_up_plans(parsed: dict, toml_path: Path) -> list[PhasePlan]:
    """`create --config` once, then `start` per instance — Phase 7's own verbs."""
    script = str(_script_for("fc"))
    names = microvm_names(parsed, toml_path)
    plans = [PhasePlan(
        slot="fc",
        argv=[script, "create", "--config", str(toml_path)],
        # The refusal is in the description because the plan pane is where an
        # operator decides whether to press `u` on a lab that is already up.
        description=(
            f"phase fc: create --config {toml_path.name} "
            f"({len(names)} microvm{'' if len(names) == 1 else 's'}; "
            "refuses if one already exists)"
        ),
    )]
    plans += [
        PhasePlan(
            slot="fc",
            argv=[script, "start", name],
            description=f"phase fc: start {name}",
        )
        for name in names
    ]
    return plans


def plan_up(toml_path: Path) -> list[PhasePlan]:
    parsed = parse_topology(toml_path)
    present = phases_present(parsed)
    plans: list[PhasePlan] = []
    for slot in _UP_ORDER:
        if slot not in present:
            continue
        if slot == "fc":
            plans.extend(_fc_up_plans(parsed, toml_path))
            continue
        script = str(_script_for(slot))
        if slot in _NO_UP_VERB:
            # `create --config` — the verb this driver actually has.  Both
            # `lab-chroot.sh` and `lab-vm.sh` iterate EVERY block in the file
            # (`create_one` per spec), so one invocation is still the whole slot.
            plans.append(PhasePlan(
                slot=slot,
                argv=[script, "create", "--config", str(toml_path)],
                description=f"phase {slot}: create --config {toml_path.name}",
            ))
            if slot in _HAS_START_VERB:
                # A VM is created stopped; `up` for this slot means it is running.
                plans += [
                    PhasePlan(slot=slot, argv=[script, "start", n],
                              description=f"phase {slot}: start {n}")
                    for n in instance_names(parsed, slot, toml_path)
                ]
            continue
        plans.append(PhasePlan(
            slot=slot,
            argv=[script, "up", "--config", str(toml_path)],
            description=f"phase {slot}: up --config {toml_path.name}",
        ))
    return plans


def plan_down(toml_path: Path) -> list[PhasePlan]:
    parsed = parse_topology(toml_path)
    present = phases_present(parsed)
    lab_name = validated_lab_name(parsed)

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
        if slot == "fc":
            # Phase 7 HAS a real per-instance stop that asserts the outcome (it polls
            # until the process is gone rather than trusting kill(2)), so unlike chroot
            # and vm this slot does something rather than printing advice.  What it does
            # not do is destroy: `destroy` deletes the per-instance rootfs copy, which is
            # the same expensive persistent state the two slots above refuse to reap.
            #
            # `--force` is not enthusiasm.  Firecracker under `--no-api` has no
            # SendCtrlAltDel path, so whether SIGTERM is honoured is a fact about the
            # guest; without the escalation, one guest that ignores it returns non-zero
            # after five seconds and the executor halts the whole tear-down there.
            # micro-cloud's own cleanup has always passed `--force` for this reason.
            script = str(_script_for("fc"))
            plans += [
                PhasePlan(
                    slot=slot,
                    argv=[script, "stop", name, "--force"],
                    description=f"phase {slot}: stop {name} --force",
                )
                for name in reversed(microvm_names(parsed, toml_path))
            ]
            plans.append(PhasePlan(
                slot=slot,
                argv=["echo", f"# phase 7: microVM state persists (each keeps its own "
                              f"rootfs copy); destroy with: {script} destroy <name>"],
                description=f"phase {slot}: state persists (stopped, not destroyed)",
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
    """The plan, on stdout — the raw path's way of asking what the guided path would do.

    Two output shapes, because they answer to two different readers:

      text (default)  a pasteable script.  Each argv is joined with ``shlex.quote`` and
                      NOT a bare space: a path containing a space rendered as
                      ``--config /my labs/x.toml`` is two arguments, and the reader who
                      pastes it gets a different command from the one the TUI runs.
      ``--json``      the argv **as arrays**, for a consumer that must not re-parse a
                      joined string.  ``examples/micro-cloud/micro-cloud.sh`` reads this;
                      splitting the text form on whitespace would reintroduce, in the one
                      script whose whole job is fidelity, exactly the lossy seam quoting
                      exists to remove.
    """
    argv = sys.argv[1:]
    as_json = False
    if "--json" in argv:
        as_json = True
        argv = [a for a in argv if a != "--json"]
    if len(argv) != 2 or argv[0] not in {"up", "down"}:
        print("usage: python -m lab_tui.topology [--json] {up|down} <lab.toml>",
              file=sys.stderr)
        return 2
    op, path = argv[0], Path(argv[1])
    plans = plan_up(path) if op == "up" else plan_down(path)
    if as_json:
        json.dump([{"slot": p.slot, "argv": list(p.argv),
                    "description": p.description} for p in plans],
                  sys.stdout, indent=2)
        print()
        return 0
    for p in plans:
        print(f"# {p.description}")
        print(shlex.join(p.argv))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
