from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from lab_tui.backends.lxd import LXDBackend


@pytest.fixture
def patched_lxd(monkeypatch: pytest.MonkeyPatch, fixtures_dir: Path):
    """Pin the LXD backend's engine probe to a fake 'incus' and replace
    `run_capture` so `incus list --all-projects --format=json` returns
    our fixture."""
    fixture = (fixtures_dir / "lxd-list.json").read_text()

    # Class-level cache; reset between tests.
    LXDBackend._engine_cmd = None  # noqa: SLF001
    monkeypatch.setattr(
        LXDBackend, "_probe_engine",
        lambda self: "incus",
    )

    def fake_run_capture(argv, *, env=None):
        if argv[:4] == ["incus", "list", "--all-projects", "--format=json"]:
            return subprocess.CompletedProcess(argv, 0, fixture, "")
        if argv[:1] == ["incus"] and "config" in argv and "show" in argv:
            return subprocess.CompletedProcess(argv, 0, "name: stub\n", "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected argv")

    # Patch the run_capture symbol that lxd.py imported.
    import lab_tui.backends.lxd as lxd_mod
    monkeypatch.setattr(lxd_mod, "run_capture", fake_run_capture)
    monkeypatch.setattr(
        lxd_mod, "run_json",
        lambda argv: (0, json.loads(fixture))
        if argv == ["incus", "list", "--all-projects", "--format=json"]
        else (1, None),
    )
    return LXDBackend()


def test_list_filters_by_label(patched_lxd: LXDBackend) -> None:
    """Only instances with user.lab-create.tool=lab-lxd should appear —
    the fixture has 3 instances, 2 are tagged, 1 is a manual instance
    that must be excluded."""
    rs = patched_lxd.list_resources()
    assert len(rs) == 2
    names = {r.name for r in rs}
    assert names == {"lab-demo-shell", "lab-demo-vm"}
    # Manual instance excluded.
    assert "manual-instance" not in names


def test_list_classifies_container_vs_vm(patched_lxd: LXDBackend) -> None:
    rs = {r.name: r for r in patched_lxd.list_resources()}
    assert rs["lab-demo-shell"].type == "instance"
    assert rs["lab-demo-shell"].status == "running"
    assert rs["lab-demo-vm"].type == "vm"
    assert rs["lab-demo-vm"].status == "stopped"


def test_list_propagates_project_to_log_command(patched_lxd: LXDBackend) -> None:
    rs = {r.name: r for r in patched_lxd.list_resources()}
    # Default project: no --project flag.
    assert "--project" not in rs["lab-demo-shell"].log_command
    # Non-default project: --project demo-proj should appear.
    assert "--project" in rs["lab-demo-vm"].log_command
    assert "demo-proj" in rs["lab-demo-vm"].log_command


def test_list_lab_filter(patched_lxd: LXDBackend) -> None:
    assert len(patched_lxd.list_resources(lab="demo")) == 2
    assert len(patched_lxd.list_resources(lab="nonexistent")) == 0


def test_destroy_argv_uses_lab_slash_svc(patched_lxd: LXDBackend) -> None:
    rs = patched_lxd.list_resources()
    shell = next(r for r in rs if r.svc == "shell")
    argv = patched_lxd.destroy_argv(shell)
    assert argv[-3:] == ["destroy", "--", "demo/shell"]


def test_inspect_prefers_inspect_json_when_available(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """When Phase 5's `inspect --json` returns valid JSON, the backend
    should pretty-print it instead of falling back to `<engine> config
    show --expanded`."""
    import lab_tui.backends.lxd as lxd_mod

    fixture = (fixtures_dir / "lxd-list.json").read_text()
    fake_doc = {
        "schema_version": 1,
        "name": "lab-demo-shell",
        "labels": {"lab": "demo", "svc": "shell", "tool": "lab-lxd"},
        "instance": {"type": "container", "image": "alpine/3.23", "project": "default"},
        "state": {"status": "running", "running": True, "pid": 4242},
    }
    # Marker that ONLY appears in the `config show --expanded` fallback
    # output, so the assertion can prove which path the backend took.
    fallback_payload = "name: lab-demo-shell\nFALLBACK_MARKER: yes\n"

    # Class-level cache; reset so _probe_engine actually runs.
    LXDBackend._engine_cmd = None  # noqa: SLF001
    monkeypatch.setattr(LXDBackend, "_probe_engine", lambda self: "incus")

    def fake_run_capture(argv, *, env=None):
        # Phase 5 script's `inspect <name> --json` — preferred path.
        if argv[1:] == ["inspect", "lab-demo-shell", "--json"]:
            return subprocess.CompletedProcess(argv, 0, json.dumps(fake_doc), "")
        # Bare `incus config show --expanded <name>` — fallback path.
        # Must NOT be hit when the phase script succeeds.
        if argv == ["incus", "config", "show", "--expanded", "lab-demo-shell"]:
            return subprocess.CompletedProcess(argv, 0, fallback_payload, "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected argv")

    monkeypatch.setattr(lxd_mod, "run_capture", fake_run_capture)
    monkeypatch.setattr(
        lxd_mod, "run_json",
        lambda argv: (0, json.loads(fixture))
        if argv == ["incus", "list", "--all-projects", "--format=json"]
        else (1, None),
    )
    backend = LXDBackend()
    target = next(r for r in backend.list_resources() if r.name == "lab-demo-shell")
    assert target.extra["project"] == "default"  # sanity

    out = backend.inspect(target)
    # Pretty-printed JSON, two-space indent — distinguishes from the
    # YAML fallback payload.
    assert '"schema_version": 1' in out
    assert '"image": "alpine/3.23"' in out
    # The fallback's marker must NOT appear — proves we took the script path.
    assert "FALLBACK_MARKER" not in out


def test_inspect_falls_back_to_config_show_when_inspect_fails(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """If `inspect --json` exits non-zero, the backend should fall back
    to `<engine> config show --expanded <name>` and return its stdout
    verbatim, preserving project handling."""
    import lab_tui.backends.lxd as lxd_mod

    fixture = (fixtures_dir / "lxd-list.json").read_text()
    fallback_payload = "name: lab-demo-shell\nFALLBACK_MARKER: yes\n"
    fallback_argv_seen: list[list[str]] = []

    LXDBackend._engine_cmd = None  # noqa: SLF001
    monkeypatch.setattr(LXDBackend, "_probe_engine", lambda self: "incus")

    def fake_run_capture(argv, *, env=None):
        # Phase 5 script's `inspect --json` fails (older deployment, missing jq, …).
        if argv[1:] == ["inspect", "lab-demo-shell", "--json"]:
            return subprocess.CompletedProcess(argv, 1, "", "no such verb\n")
        # `incus config show --expanded lab-demo-shell` — should be exercised here.
        if argv[:1] == ["incus"] and "config" in argv and "show" in argv:
            fallback_argv_seen.append(list(argv))
            return subprocess.CompletedProcess(argv, 0, fallback_payload, "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected argv")

    monkeypatch.setattr(lxd_mod, "run_capture", fake_run_capture)
    monkeypatch.setattr(
        lxd_mod, "run_json",
        lambda argv: (0, json.loads(fixture))
        if argv == ["incus", "list", "--all-projects", "--format=json"]
        else (1, None),
    )
    backend = LXDBackend()
    target = next(r for r in backend.list_resources() if r.name == "lab-demo-shell")

    out = backend.inspect(target)
    # The returned text should be the fallback's stdout verbatim, not a
    # pretty-printed JSON document from the script.
    assert out == fallback_payload
    assert "FALLBACK_MARKER" in out
    # And it should NOT have been pretty-printed (no two-space indent).
    assert '"schema_version": 1' not in out
    # Verify the fallback argv shape is `incus config show --expanded <name>`.
    assert len(fallback_argv_seen) == 1
    argv = fallback_argv_seen[0]
    assert argv[0] == "incus"
    assert ["config", "show", "--expanded"] == [a for a in argv if a in {"config", "show", "--expanded"}]
    assert argv[-1] == "lab-demo-shell"
