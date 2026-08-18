"""`apply` — the half that issues.  Deliberately a different file from the diff.

[`reconcile.py`](reconcile.py) computes the gap and cannot change anything; this
module is the only one that can.  Keeping them apart is not tidiness: the
read-only guarantee is worth something only if you can see, from the import list,
which module could have broken it.

THE LOOP
--------
Read reality → diff → issue **only** the missing transitions → re-read reality →
stop when a pass issues nothing.  That last clause is the whole contract: **a
second `apply` over a converged lab must be a no-op**, and it is a no-op because
the second pass's diff finds nothing to do, not because a flag was remembered.

WHAT IT WILL NOT DO, AND WHY EACH ONE IS A REFUSAL RATHER THAN A GAP
--------------------------------------------------------------------
Three of the diff's six kinds are **held for the operator**.  A reconcile loop
that acts on all six is not more useful, it is more dangerous:

* **`undeclared` — never, and there is no flag that changes it.**  Deleting what
  nobody declared is the half of a reconcile loop that destroys work.  On this
  repo's ladder a stray container is at worst DEGRADED; a wrong deletion is
  unrecoverable, and no rung rewards it.  If pruning is ever wanted it must
  arrive as an explicit, separately-argued opt-in — not as a default that was
  never decided.
* **`unknown` — never.**  This is the reason the diff distinguishes *"the engine
  says nothing is there"* from *"I could not ask the engine"* at all.  Issuing
  `create` against a row nobody could read is precisely the duplicate-creation
  bug that distinction exists to prevent, and it would do it while reporting
  progress.
* **`drifted` — held.**  The repair is destroy-and-recreate, which for a microVM
  deletes a per-instance rootfs copy.  MAAS learned the same shape the same way:
  a failed deploy *holds for the operator* because the artifact is unproven and a
  human should look.

So `apply` issues for exactly two kinds — `absent` and `stopped` — and reports
the rest.

MINIMUM TRANSITIONS, PER ENGINE (decision E, shape (b), again)
---------------------------------------------------------------
This section used to begin *"five drivers are declarative"*.  **Three are.**  Only
docker, podman and lxd have an `up` verb at all; chroot, vm and fc create with
`create` and (where they have run state) run with `start`.  That was measured by
asking each driver — see `_NO_UP_VERB` in topology.py — after `plan_up` was found
to have been emitting `lab-chroot.sh up` and `lab-vm.sh up` since the beginning.

And `up` is **create-if-absent, not converge**: against a stopped container the
three drivers that have it log *"container exists … leaving as-is"* and return 0.
That used to be the end of the story — none of them had a `start` either, so a
stopped container was a state this control plane could not repair and `apply`
HELD it.  **The fix went where the gap was** (TODO A.3): `lab-docker.sh`,
`lab-podman.sh` and `lab-lxd.sh` each grew a `start <name|lab/service>` that reads
the state back afterwards instead of trusting the engine's exit status.  `apply`
now issues it; `held_for_want_of_a_verb` stays for the slots that still have
nothing — see its docstring.
"""

from __future__ import annotations

import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

from lab_tui.backends.base import BackendRunner, phase_script
from lab_tui.reconcile import Delta, diff, render
from lab_tui.topology import (
    _HAS_START_VERB,
    _START_TAKES_LAB_SLASH_SVC,
    _NO_UP_VERB,
    _script_for,
    _UP_ORDER,
    PhaseSlot,
    parse_topology,
    validated_lab_name,
)

#: The only kinds `apply` acts on.  Everything else is reported — see the module
#: docstring for why each refusal is a decision and not an unimplemented feature.
ACTIONABLE: frozenset[str] = frozenset({"absent", "stopped"})

#: `[[microvm]]` key → the `lab-fc.sh` flag that carries it.  A copy of the
#: driver's own `KNOWN_KEYS`, and `tests/test_apply.py` reads that line out of
#: lab-fc.sh and asserts the two agree — a key added there without a line here
#: would otherwise be silently dropped from every `create` this module issues,
#: which is the driver's own stated bug class ("a config key that is silently
#: dropped is a field that appears to work and does nothing") committed against it.
FC_FLAGS: dict[str, str] = {
    "name": "--name", "kernel": "--kernel", "rootfs": "--rootfs",
    "memory": "--memory", "vcpus": "--vcpus", "tap": "--tap", "mac": "--mac",
    "ip": "--ip", "gateway": "--gateway", "netmask": "--netmask",
    "append": "--append", "lab": "--lab",
    "mmds": "--mmds",   # valueless: present or absent, never `--mmds true`
}


@dataclass(slots=True)
class ApplyResult:
    passes: int = 0
    issued: list[list[str]] = field(default_factory=list)
    failed: list[tuple[list[str], int]] = field(default_factory=list)
    held: list[Delta] = field(default_factory=list)
    final: list[Delta] = field(default_factory=list)
    converged: bool = False
    stuck: bool = False

    @property
    def incomplete(self) -> bool:
        """True when some row could not be read at all — never fold this into
        `converged`, which is what makes the whole report worth reading."""
        return any(d.kind == "unknown" for d in self.final)


def _fc_create_argv(block: dict, lab: str) -> list[str]:
    argv = [str(phase_script("phase7-firecracker/lab-fc.sh")), "create"]
    for key, flag in FC_FLAGS.items():
        if key == "lab":
            continue
        value = block.get(key)
        if value in (None, "", False):
            continue
        if key == "mmds":
            if value is True or str(value).lower() == "true":
                argv.append(flag)
            continue
        argv += [flag, str(value)]
    argv += ["--lab", block.get("lab") or lab]
    return argv


def transitions(deltas: Sequence[Delta], toml_path: Path, parsed: dict) -> list[list[str]]:
    """The minimum argv list that closes the actionable rows, in dependency order.

    Slots are ordered by `_UP_ORDER` because the dependencies are real: a podman
    container built `from_chroot` needs Phase 1's output to exist first.  Sorting
    the diff alphabetically instead would issue the container before the chroot
    and fail for a reason that looks like the driver's fault.
    """
    lab = validated_lab_name(parsed)
    fc_blocks = {b["name"]: b for b in parsed.get("microvm", []) if b.get("name")}
    todo = [d for d in deltas if d.kind in ACTIONABLE]
    argvs: list[list[str]] = []
    for slot in _UP_ORDER:
        rows = [d for d in todo if d.slot == slot]
        if not rows:
            continue
        script = str(_script_for(slot))
        if slot == "fc":
            # Per instance: `create --config` would refuse the whole file the moment
            # one instance already exists, which is exactly the mixed state a
            # reconcile loop is FOR.
            for d in rows:
                if d.kind == "absent" and d.name in fc_blocks:
                    argvs.append(_fc_create_argv(fc_blocks[d.name], lab))
                    argvs.append([script, "start", d.name])
                elif d.kind == "stopped":
                    argvs.append([script, "start", d.name])
            continue
        create_verb = "create" if slot in _NO_UP_VERB else "up"
        if any(d.kind == "absent" for d in rows):
            argvs.append([script, create_verb, "--config", str(toml_path)])
        # Which rows still need a `start` after that command:
        #   * chroot/vm/fc `create` leaves the thing STOPPED, so an absent vm needs
        #     one too (a chroot has no run state and is never in this branch);
        #   * docker/podman/lxd `up` starts what it creates, so only the rows that
        #     were already there and stopped need it.
        needs_start = ("absent", "stopped") if slot in _NO_UP_VERB else ("stopped",)
        if slot in _HAS_START_VERB:
            argvs += [[script, "start", _start_target(slot, d.name, lab)]
                      for d in rows if d.kind in needs_start]
    return argvs


def _start_target(slot: PhaseSlot, name: str, lab: str) -> str:
    """How this driver wants the instance addressed on the command line.

    Phases 3/4/5 rename what they create (`lab-<lab>-<svc>`) and resolve a BARE
    target to `lab-<name>` — so handing them the declared service name alone would
    address `lab-web`, a container that is not ours and probably does not exist.
    Measured while writing phase 4's own test, whose first version refused
    `lab-lab-startverb-…-dies` for exactly this reason.
    """
    return f"{lab}/{name}" if slot in _START_TAKES_LAB_SLASH_SVC else name


def held_for_want_of_a_verb(deltas: Sequence[Delta]) -> list[Delta]:
    """Actionable rows whose driver offers nothing that would fix them.

    It exists because of a gap that is now CLOSED, and it stays because the shape
    recurs.  `up` on the three container engines is create-if-absent, not converge
    — against a stopped container `lab-podman.sh up` logs

        [warn] service 'web' container exists (lab-…-web); leaving as-is

    and returns 0 — and until 2026-08-17 none of docker/podman/lxd had a `start`
    either, so `apply` held those rows.  The two dishonest exits were to report
    convergence, or to reach around the driver to `podman start` and put a second
    owner on the lifecycle.  Instead the fix went into the drivers (TODO A.3).

    What remains here is the general rule: a slot with no `start` verb cannot have
    a stopped row repaired, and saying so by name beats looping `up` at something
    that will keep answering "leaving as-is".  `chroot` is the only slot still in
    that position — it has no run state, so it lands here only via a status like
    `error`, which is exactly a case a human should look at.
    """
    return [d for d in deltas
            if d.kind == "stopped" and d.slot not in _HAS_START_VERB]


def _default_run(argv: list[str]) -> int:
    return subprocess.run(argv, check=False).returncode


def apply(
    toml_path: Path,
    *,
    dry_run: bool = False,
    max_passes: int = 4,
    backend_for: Callable[[PhaseSlot], BackendRunner | None] | None = None,
    run: Callable[[list[str]], int] | None = None,
) -> ApplyResult:
    """Converge the lab, or say honestly why it did not."""
    run = run or _default_run
    parsed = parse_topology(toml_path)
    result = ApplyResult()
    previous: list[tuple] | None = None

    while result.passes < max_passes:
        result.passes += 1
        deltas = diff(toml_path, backend_for=backend_for)
        result.final = list(deltas)
        result.held = [d for d in deltas
                       if d.kind not in ACTIONABLE and d.kind != "converged"]
        result.held += held_for_want_of_a_verb(deltas)
        argvs = transitions(deltas, toml_path, parsed)
        if not argvs:
            # Nothing to do.  This is the no-op-on-pass-two property, and it holds
            # because the DIFF found nothing — not because a flag was remembered.
            result.converged = not result.held
            return result
        if dry_run:
            result.issued = argvs
            return result

        # A pass that produces the identical diff to the one before it is not
        # making progress; burning the remaining passes would only delay saying so.
        signature = sorted((d.slot, d.name, d.kind) for d in deltas)
        if previous == signature:
            result.stuck = True
            return result
        previous = signature

        for argv in argvs:
            result.issued.append(argv)
            rc = run(argv)
            if rc != 0:
                result.failed.append((argv, rc))
        if result.failed:
            # Stop on the first failing pass.  Looping over a driver that just
            # refused would re-issue the same refusal and call it a retry.
            break

    if not result.failed and not result.stuck:
        # Fell out of the loop having used every pass.
        result.final = diff(toml_path, backend_for=backend_for)
        result.held = ([d for d in result.final
                        if d.kind not in ACTIONABLE and d.kind != "converged"]
                       + held_for_want_of_a_verb(result.final))
        result.converged = (
            not result.held
            and not [d for d in result.final if d.kind in ACTIONABLE]
        )
    return result


def report(result: ApplyResult, dry_run: bool = False) -> str:
    lines: list[str] = []
    if result.issued:
        lines.append("would issue:" if dry_run else "issued:")
        lines += [f"  $ {' '.join(a)}" for a in result.issued]
    elif not dry_run:
        lines.append("issued nothing — every declared row was already converged")
    if result.failed:
        lines.append("")
        lines += [f"  FAILED (rc={rc}): {' '.join(a)}" for a, rc in result.failed]
    if result.held:
        lines.append("")
        lines.append("held for you (apply does not act on these):")
        lines += [f"  {d.kind:<10} {d.slot:<7} {d.name}  {d.detail}" for d in result.held]
    lines.append("")
    if result.failed:
        lines.append(f"  NOT converged: {len(result.failed)} command(s) failed "
                     f"over {result.passes} pass(es)")
    elif result.stuck:
        lines.append(f"  NOT converged: pass {result.passes} produced the same diff as "
                     "the one before it — something is refusing to progress")
    elif dry_run:
        lines.append(f"  dry run: {len(result.issued)} command(s) NOT run")
    elif result.converged:
        lines.append(f"  converged after {result.passes} pass(es)")
    else:
        lines.append(f"  NOT converged after {result.passes} pass(es)")
    if result.incomplete:
        lines.append("  INCOMPLETE: at least one row could not be read at all — "
                     "it was neither checked nor acted on")
    return "\n".join(lines)


CONVERGED, FAILED, NOT_CONVERGED, INCOMPLETE = 0, 1, 2, 3


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    dry = False
    for flag in ("--dry-run", "-n"):
        if flag in args:
            dry = True
            args.remove(flag)
    if len(args) != 1:
        print("usage: python -m lab_tui.apply [--dry-run] <lab.toml>", file=sys.stderr)
        print("  converges the lab; issues ONLY for absent/stopped rows.",
              file=sys.stderr)
        print("  exit: 0 converged · 1 a command failed · 2 not converged · "
              "3 something could not be read", file=sys.stderr)
        return 64
    try:
        result = apply(Path(args[0]), dry_run=dry)
    except (OSError, ValueError) as e:
        print(f"apply: {e}", file=sys.stderr)
        return 1
    print(report(result, dry_run=dry))
    if result.final:
        print("\ncurrent state:")
        print(render(result.final))
    if result.failed:
        return FAILED
    if result.incomplete:
        return INCOMPLETE
    if dry:
        # A dry run that found nothing to issue IS the converged answer; one that
        # listed commands has not converged and must not report as if it had.
        return CONVERGED if not result.issued else NOT_CONVERGED
    return CONVERGED if result.converged else NOT_CONVERGED


if __name__ == "__main__":
    raise SystemExit(main())
