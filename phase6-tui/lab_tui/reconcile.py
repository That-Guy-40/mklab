"""`apply`'s read-only half: declared, derived, and the gap between them.

This computes a diff and **issues nothing**.  That split is deliberate and it is
the whole point of doing this first: a reconcile loop's one hard-won rule is that
it must not trust its own view of the world, and you cannot honour that rule
until the "what is actually true" half is known-correct standing on its own.

WHERE THE FACTS COME FROM — decision G, in code
-----------------------------------------------
[§8.4a] settled that micro-cloud keeps **no registry of facts**: every fact about
an instance is derivable from the engine that owns it, and everything that is not
derivable is intent or history.  So there is no state file here and none is
written.  `declared` comes from the TOML; `derived` comes from each backend's
`list_resources()`, which is the same call the browser pane makes.  MAAS's
`apply` opens with a phase whose job is *"ground the registry in reality"* — a
health re-check before the diff, plus a `--no-recheck` flag that warns the diff
would otherwise be computed from the registry alone.  That phase is absent here
because it is not a phase; it is what reading the state IS.

THE ONE THING THAT MAKES THIS HONEST: `is_available()` BEFORE AN EMPTY LIST
---------------------------------------------------------------------------
Every backend returns `[]` when it cannot reach its engine — `docker.py` does it
explicitly (`if cp.returncode != 0: return []`).  For the browser pane that is
benign: an empty tree.  For a diff it is a **lie in the most expensive
direction**: a stopped Docker daemon becomes "every declared service is missing",
and the `apply` built on top of it would set about creating containers that
already exist.

So an empty list is only ever read as "nothing is there" when the engine
confirmed it could be asked.  Otherwise the verdict is **UNKNOWN**, which is not
a difference and is certainly not convergence — it is *I could not look*.  Same
for `undeclared`: a backend that cannot be queried cannot tell you about strays,
so it does not get to say there are none.

There is a SECOND way not to know, and it was missed the first time round: the
engine answers, but with a state the backend does not map.  All three container
backends collapse anything outside their table (`restarting`, `stopping`,
`removing`) to `status="unknown"`, and this module used to read that as `stopped`
— *with `would: start`* — so a crash-looping container was described confidently
as merely off.  "I do not know what state this is in" is an UNKNOWN wherever it
comes from; only "the engine says it is not running" is `stopped`.

WHAT THIS DIFF CANNOT SEE, STATED SO NOBODY INFERS IT
-----------------------------------------------------
`converged` means **it exists and it is up** — not that its contents match the
spec.  A chroot's package list, a container's environment, a microVM's memory
size: none of that is compared here.  The one exception is `drifted`, which today
covers exactly the two fc fields the manifest records against the instance
(`tap`, `kernel`) — enough to prove the shape works, not enough to claim identity.
Widening it is named work, not an oversight; each new comparison needs a derived
fact to compare against, which is what decision G's discipline buys.
"""

from __future__ import annotations

import sys
import tomllib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from lab_tui.backends import ALL_BACKENDS
from lab_tui.backends.base import BackendRunner, Resource
from lab_tui.topology import (
    PhaseSlot,
    microvm_names,
    parse_topology,
    phases_present,
    services_by_engine,
    validated_lab_name,
)

DeltaKind = Literal[
    "converged",   # declared, present, and up
    "absent",      # declared, and the engine says it is not there
    "stopped",     # declared and present, but not running
    "drifted",     # declared and present, but built from something else
    "undeclared",  # present under this lab, absent from the spec
    "unknown",     # the engine could not be asked — NOT a pass, NOT a difference
]

#: Which `Resource.status` values count as "up" for each slot.  They are not the
#: same, and flattening them would be decision E's mistake in miniature: a chroot
#: has no run state at all (it is `built` or it does not exist), while a microVM
#: that exists but is not running is a real, actionable difference.
_UP_STATUS: dict[PhaseSlot, frozenset[str]] = {
    "chroot": frozenset({"built", "running"}),
    "vm":     frozenset({"running"}),
    "fc":     frozenset({"running"}),
    "docker": frozenset({"running"}),
    "podman": frozenset({"running"}),
    "lxd":    frozenset({"running"}),
}

#: The verb `apply` would issue for each actionable kind.  Recorded as text and
#: not executed: this module's contract is that it changes nothing.
_WOULD: dict[DeltaKind, str | None] = {
    "converged":  None,
    "absent":     "create",
    "stopped":    "start",
    "drifted":    "recreate (destroy + create — the artifact under it changed)",
    "undeclared": None,   # deliberately: see `diff()`
    "unknown":    None,
}


@dataclass(frozen=True, slots=True)
class Delta:
    """One row of the diff.  `name` is the DECLARED identity, not the engine's."""

    slot: PhaseSlot
    name: str
    kind: DeltaKind
    detail: str

    @property
    def would(self) -> str | None:
        return _WOULD[self.kind]


def declared(parsed: dict, toml_path: Path) -> dict[PhaseSlot, list[str]]:
    """The names the spec asks for, per slot, in file order.

    Service routing comes from `topology.services_by_engine`, which REFUSES a
    `[[service]]` with no `engine` rather than listing it under both — see that
    function for the measurement (both drivers claim it, so a cross-phase run made
    two containers under one declared name).  This module must not grow a second
    answer to that question: an `apply` that routed differently from the planner
    would create one thing and then reconcile against another.
    """
    out: dict[PhaseSlot, list[str]] = {}
    if parsed.get("chroot"):
        out["chroot"] = [c["name"] for c in parsed["chroot"] if c.get("name")]
    if parsed.get("vm"):
        out["vm"] = [v["name"] for v in parsed["vm"] if v.get("name")]
    if parsed.get("microvm"):
        out["fc"] = microvm_names(parsed, toml_path)
    out.update(services_by_engine(parsed))
    # Projects and profiles are LXD objects but not instances; they have no run
    # state and no `svc` label, so they are outside this diff rather than silently
    # counted as converged.  Named here so the omission is visible.
    if parsed.get("instance"):
        out["lxd"] = [i["name"] for i in parsed["instance"] if i.get("name")]
    return out


def _key(r: Resource) -> str:
    """The DECLARED identity of a live resource.

    Measured, because getting it wrong produces the classic double fault — every
    declared row `absent` AND every live row `undeclared`, with nothing obviously
    broken.  Phases 3, 4 and 5 all rename what they create (`lab-<lab>-<svc>`, via
    `container_name_for`/`instance_name_for`), so the engine-side name is NOT the
    spec's name; all three carry the declared name in a `lab-create.svc` label,
    which the backends surface as `Resource.svc`.  Phases 1, 2 and 7 do not rename
    and set `svc=None`.  `svc or name` is therefore one rule that is right for all
    six rather than a per-slot table that can rot.
    """
    return r.svc or r.name


def _backend_for(slot: PhaseSlot) -> BackendRunner | None:
    for b in ALL_BACKENDS:
        if b.name == slot:
            return b()
    return None


def _fc_drift(declared_block: dict, actual: Resource) -> str | None:
    """The two fc fields the manifest records against the built instance.

    This is the payoff from decision G: the manifest is not a registry of hearsay,
    it is a record bound to its subject (`create` writes it from the record it
    actually built with, and `start` re-derives the kernel digest and refuses a
    mismatch by name).  Comparing the spec against it is therefore comparing what
    was asked for against what was built — not against a second copy of the ask.
    """
    for field in ("tap", "kernel"):
        want = declared_block.get(field)
        got = actual.extra.get(field)
        if want and got and str(want) != str(got):
            return f"{field}: spec says {want!r}, the instance was built with {got!r}"
    return None


def diff(
    toml_path: Path,
    backend_for: Callable[[PhaseSlot], BackendRunner | None] | None = None,
) -> list[Delta]:
    """Declared vs derived.  Reads engines, writes nothing, issues nothing.

    `backend_for` exists so a caller (and the tests) can supply the engines rather
    than have them looked up — a diff whose only fixture is a live Docker daemon
    is a diff nobody can test the interesting branches of.
    """
    backend_for = backend_for or _backend_for
    parsed = parse_topology(toml_path)
    lab = validated_lab_name(parsed)
    want = declared(parsed, toml_path)
    present = phases_present(parsed)
    fc_blocks = {b["name"]: b for b in parsed.get("microvm", []) if b.get("name")}

    deltas: list[Delta] = []
    for slot in sorted(present):
        names = want.get(slot, [])
        backend = backend_for(slot)
        if backend is None:
            deltas += [Delta(slot, n, "unknown", f"no {slot} backend is registered")
                       for n in names]
            continue
        if not backend.is_available():
            # THE LOAD-BEARING BRANCH.  Without it every name below reads `absent`
            # off an empty list that means "I could not ask", and `apply` would
            # then create what already exists.
            deltas += [
                Delta(slot, n, "unknown",
                      f"the {slot} engine could not be queried — this row was not "
                      "checked, and an unchecked row is not a converged one")
                for n in names
            ]
            continue

        actual = {_key(r): r for r in backend.list_resources(lab=lab)}
        for n in names:
            r = actual.get(n)
            if r is None:
                deltas.append(Delta(slot, n, "absent", "declared, not present"))
                continue
            drift = _fc_drift(fc_blocks[n], r) if slot == "fc" and n in fc_blocks else None
            if drift:
                deltas.append(Delta(slot, n, "drifted", drift))
            elif r.status in _UP_STATUS[slot]:
                deltas.append(Delta(slot, n, "converged", f"present and {r.status}"))
            elif r.status == "unknown":
                # THE ENGINE ANSWERED — WITH SOMETHING THIS BACKEND DOES NOT MAP.
                #
                # A different failure from "the engine could not be asked", and the
                # one that was missing: `_docker_status`/`_podman_status`/`_lxd_status`
                # collapse every state outside their table (`restarting`, `stopping`,
                # `removing`) to "unknown".  This branch used to fall through to the
                # `else` below and report `stopped` — with `would: start` — so a
                # crash-looping container was described confidently as merely off,
                # and `apply` would have kept starting it.
                #
                # "I do not know what state this is in" is an UNKNOWN wherever it
                # comes from.  The raw state is named because a report that cannot
                # say WHAT it saw is a shrug rather than a finding.
                raw = r.extra.get("state") or "?"
                deltas.append(Delta(
                    slot, n, "unknown",
                    f"present, but the engine reported state {raw!r}, which this "
                    "backend does not map — so its run state was not established",
                ))
            else:
                deltas.append(Delta(slot, n, "stopped", f"present but {r.status}"))
        # Strays are REPORTED and never actioned.  Deleting something the operator
        # did not declare is the half of a reconcile loop that destroys work, and
        # nothing in this repo's ladder rewards it: an undeclared row is at worst
        # DEGRADED, while a wrong deletion is unrecoverable.
        for extra_name in sorted(set(actual) - set(names)):
            deltas.append(Delta(
                slot, extra_name, "undeclared",
                f"running under lab '{lab}' but not in this spec "
                f"(engine name: {actual[extra_name].name}) — reported, never removed",
            ))
    return deltas


CONVERGED, DIFFERENCES, INCOMPLETE = 0, 2, 3


def exit_code(deltas: list[Delta]) -> int:
    """0 converged · 2 differences · 3 at least one UNKNOWN.

    UNKNOWN outranks a difference on purpose.  A difference is a fact about the
    lab; an unknown is a fact about the *diff* — it says this answer is
    incomplete, and a caller that treated it as "2, but fine" would be acting on a
    report that never looked at part of the system.
    """
    kinds = {d.kind for d in deltas}
    if "unknown" in kinds:
        return INCOMPLETE
    if kinds - {"converged"}:
        return DIFFERENCES
    return CONVERGED


def render(deltas: list[Delta]) -> str:
    if not deltas:
        return "nothing declared in this spec"
    width = max(len(d.name) for d in deltas)
    lines = []
    for d in deltas:
        would = f"  → would {d.would}" if d.would else ""
        lines.append(f"  {d.kind:<10} {d.slot:<7} {d.name:<{width}}  {d.detail}{would}")
    counts: dict[str, int] = {}
    for d in deltas:
        counts[d.kind] = counts.get(d.kind, 0) + 1
    lines.append("")
    lines.append("  " + ", ".join(f"{v} {k}" for k, v in sorted(counts.items())))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: python -m lab_tui.reconcile <lab.toml>", file=sys.stderr)
        print("  prints the declared-vs-actual diff and issues NOTHING.",
              file=sys.stderr)
        print("  exit: 0 converged · 2 differences · 3 incomplete (something "
              "could not be checked)", file=sys.stderr)
        return 64
    try:
        deltas = diff(Path(args[0]))
    except (OSError, ValueError, tomllib.TOMLDecodeError) as e:
        print(f"reconcile: {e}", file=sys.stderr)
        return 1
    print(render(deltas))
    return exit_code(deltas)


if __name__ == "__main__":
    raise SystemExit(main())
