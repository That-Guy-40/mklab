"""Regression (Review phase6 T5): hostile-input branches of the topology
dispatcher.

Covers the F-05 lab-name validation in plan_down (a name that could confuse
the bash `--lab` parser must raise BEFORE any argv is built) and malformed /
incomplete TOML handling in parse_topology.  Injection strings use inert
placeholders — they are only ever data read by tomllib, never executed.
"""

from __future__ import annotations

import pytest

from lab_tui.topology import parse_topology, plan_down, plan_up

_DOCKER_SVC = '[[service]]\nname = "s"\nengine = "docker"\n'


def _write(tmp_path, body: str):
    p = tmp_path / "lab.toml"
    p.write_text(body)
    return p


@pytest.mark.parametrize("bad", [
    "--evil",          # leading -- : would look like a flag to --lab
    "-x",              # leading -  : same
    "a b",             # embedded space : splits the argv token
    "a;INJECTED",      # shell metacharacter (inert placeholder)
    "$(echo INJECTED)",  # command-substitution shape (inert placeholder)
    "web/../etc",      # path-ish
])
def test_plan_down_rejects_unsafe_lab_name(tmp_path, bad) -> None:
    cfg = _write(tmp_path, f'[lab]\nname = "{bad}"\n\n{_DOCKER_SVC}')
    with pytest.raises(ValueError):
        plan_down(cfg)


def test_plan_down_accepts_clean_name_and_scopes_by_lab(tmp_path) -> None:
    cfg = _write(tmp_path, f'[lab]\nname = "web1"\n\n{_DOCKER_SVC}')
    plans = plan_down(cfg)  # must NOT raise
    docker_plan = next(p for p in plans if p.slot == "docker")
    assert docker_plan.argv[-3:] == ["down", "--lab", "web1"]


# ── the same question for a [[microvm]] name, which is a POSITIONAL ──────────
# The lab name above is refused because it could confuse `--lab`'s parser.  A
# microvm name is worse-placed: it is passed bare to `lab-fc.sh start <name>`,
# whose arg loop reads ANY `-`-leading token as a flag — and `--force` is a real
# one, so `start --force` would parse cleanly and then die for the wrong reason.
# The driver validates it too (P7-3); this refuses at plan time, where the plan
# pane can show the operator what is wrong with their file.

@pytest.mark.parametrize("bad", [
    "-force",            # leading - : the driver's arg loop reads it as a flag
    "Api1",              # uppercase : not in the driver's regex
    "api/../etc",        # path-ish : it becomes a directory name under the state dir
    "a" * 32,            # 32 chars : the regex caps the tail at 30
    "api 1",             # embedded space
    "$(echo INJECTED)",  # command-substitution shape (inert placeholder)
])
def test_microvm_name_is_refused_at_plan_time(tmp_path, bad) -> None:
    cfg = _write(tmp_path, f'[lab]\nname = "mc"\n\n[[microvm]]\nname = "{bad}"\n')
    with pytest.raises(ValueError, match="microvm"):
        plan_up(cfg)
    with pytest.raises(ValueError, match="microvm"):
        plan_down(cfg)


def test_a_nameless_microvm_is_refused(tmp_path) -> None:
    """A block with no name would `create` and then be unreachable forever.

    `create --config` names the instance from the block; every other verb takes
    the name as a positional.  Emitting the create with no matching start is a
    plan that half-works and reports success for the half it did.
    """
    cfg = _write(tmp_path, '[lab]\nname = "mc"\n\n[[microvm]]\nmemory = "256M"\n')
    with pytest.raises(ValueError, match="no `name`"):
        plan_up(cfg)


def test_microvm_as_a_table_is_a_value_error_not_a_crash(tmp_path) -> None:
    """`[microvm]` instead of `[[microvm]]` must not reach the TUI as a traceback.

    The topology screen catches ValueError and renders it in the plan pane; an
    AttributeError from calling .get() on a string would take the worker down
    with an empty pane — a failure whose only symptom is that nothing happened.
    """
    cfg = _write(tmp_path, '[lab]\nname = "mc"\n\n[microvm]\nname = "api1"\n')
    with pytest.raises(ValueError, match=r"\[\[microvm\]\]"):
        plan_up(cfg)


def test_parse_topology_rejects_malformed_toml(tmp_path) -> None:
    cfg = _write(tmp_path, '[lab]\nname = "ok"\nthis is = = not valid ][\n')
    with pytest.raises(Exception):  # tomllib.TOMLDecodeError (subclasses ValueError)
        parse_topology(cfg)


def test_parse_topology_requires_lab_name(tmp_path) -> None:
    cfg = _write(tmp_path, '[other]\nx = 1\n')
    with pytest.raises(ValueError):
        parse_topology(cfg)
