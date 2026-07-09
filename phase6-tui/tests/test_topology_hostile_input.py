"""Regression (Review phase6 T5): hostile-input branches of the topology
dispatcher.

Covers the F-05 lab-name validation in plan_down (a name that could confuse
the bash `--lab` parser must raise BEFORE any argv is built) and malformed /
incomplete TOML handling in parse_topology.  Injection strings use inert
placeholders — they are only ever data read by tomllib, never executed.
"""

from __future__ import annotations

import pytest

from lab_tui.topology import parse_topology, plan_down

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


def test_parse_topology_rejects_malformed_toml(tmp_path) -> None:
    cfg = _write(tmp_path, '[lab]\nname = "ok"\nthis is = = not valid ][\n')
    with pytest.raises(Exception):  # tomllib.TOMLDecodeError (subclasses ValueError)
        parse_topology(cfg)


def test_parse_topology_requires_lab_name(tmp_path) -> None:
    cfg = _write(tmp_path, '[other]\nx = 1\n')
    with pytest.raises(ValueError):
        parse_topology(cfg)
