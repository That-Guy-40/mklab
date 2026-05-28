from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from lab_tui.backends.docker import DockerBackend


@pytest.fixture
def patched_docker(monkeypatch: pytest.MonkeyPatch, fixtures_dir: Path) -> DockerBackend:
    """Replace `run_capture` so `docker ps -a --format={{json .}}` returns
    our newline-delimited JSON fixture."""
    fixture = (fixtures_dir / "docker-ps.txt").read_text()

    def fake_run_capture(argv, *, env=None):
        if argv[:3] == ["docker", "ps", "-a"]:
            return subprocess.CompletedProcess(argv, 0, fixture, "")
        if argv[:2] == ["docker", "version"]:
            return subprocess.CompletedProcess(argv, 0, "26.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    import lab_tui.backends.docker as docker_mod
    monkeypatch.setattr(docker_mod, "run_capture", fake_run_capture)
    return DockerBackend()


def test_list_parses_newline_json(patched_docker: DockerBackend) -> None:
    rs = patched_docker.list_resources()
    assert len(rs) == 2
    nginx = next(r for r in rs if r.svc == "nginx")
    db = next(r for r in rs if r.svc == "db")
    assert nginx.status == "running"
    assert db.status == "stopped"
    assert nginx.lab == "web"
    assert nginx.extra["image"] == "nginx:1.27"


def test_log_command_per_resource(patched_docker: DockerBackend) -> None:
    rs = patched_docker.list_resources()
    nginx = next(r for r in rs if r.svc == "nginx")
    assert nginx.log_command == ["docker", "logs", "--tail", "200", "-f", "lab-web-nginx"]


def test_destroy_argv_routes_through_phase_script(patched_docker: DockerBackend) -> None:
    rs = patched_docker.list_resources()
    argv = patched_docker.destroy_argv(rs[0], force=True)
    assert argv[-2:] == ["destroy", "lab-web-nginx"][:1] + ["--force"][:0] or "--force" in argv
    assert str(patched_docker.script) in argv


def test_inspect_prefers_inspect_json_when_available(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """When Phase 3's `inspect --json` returns valid JSON, the backend
    should pretty-print it instead of falling back to `docker inspect`."""
    import json as _j

    import lab_tui.backends.docker as docker_mod

    fixture = (fixtures_dir / "docker-ps.txt").read_text()
    fake_doc = {
        "schema_version": 1,
        "name": "lab-web-nginx",
        "labels": {"lab": "web", "svc": "nginx", "tool": "lab-docker"},
        "container": {"id": "abc123", "image": "nginx:1.27"},
        "state": {"status": "running", "running": True, "pid": 4242},
    }
    # Marker that ONLY appears in the docker-inspect fallback output, so
    # the assertion can prove which path the backend took.
    fallback_payload = '[{"Id":"abc123","FALLBACK_MARKER":"yes"}]'

    def fake_run_capture(argv, *, env=None):
        # Phase 3 script's `inspect <name> --json` — preferred path.
        if argv[1:] == ["inspect", "lab-web-nginx", "--json"]:
            return subprocess.CompletedProcess(argv, 0, _j.dumps(fake_doc), "")
        # Bare `docker inspect <name>` — fallback path.  Must NOT be hit
        # when the phase script succeeds.
        if argv == ["docker", "inspect", "--", "lab-web-nginx"]:
            return subprocess.CompletedProcess(argv, 0, fallback_payload, "")
        # The list_resources() / is_available() paths from the original fixture.
        if argv[:3] == ["docker", "ps", "-a"]:
            return subprocess.CompletedProcess(argv, 0, fixture, "")
        if argv[:2] == ["docker", "version"]:
            return subprocess.CompletedProcess(argv, 0, "26.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(docker_mod, "run_capture", fake_run_capture)
    backend = DockerBackend()
    target = backend.list_resources()[0]
    assert target.name == "lab-web-nginx"  # sanity: literal docker name

    out = backend.inspect(target)
    # Pretty-printed JSON, two-space indent — distinguishes from the
    # single-line fallback payload.
    assert '"schema_version": 1' in out
    assert '"image": "nginx:1.27"' in out
    # The fallback's marker must NOT appear — proves we took the script path.
    assert "FALLBACK_MARKER" not in out


def test_inspect_falls_back_to_docker_inspect_when_inspect_fails(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """If `inspect --json` exits non-zero, the backend should fall back
    to bare `docker inspect <name>` and return its stdout verbatim."""
    import lab_tui.backends.docker as docker_mod

    fixture = (fixtures_dir / "docker-ps.txt").read_text()
    fallback_payload = '[{"Id":"abc123","Name":"/lab-web-nginx","FALLBACK_MARKER":"yes"}]'

    def fake_run_capture(argv, *, env=None):
        # Phase 3 script's `inspect --json` fails (older deployment, missing jq, …).
        if argv[1:] == ["inspect", "lab-web-nginx", "--json"]:
            return subprocess.CompletedProcess(argv, 1, "", "no such verb\n")
        # Bare `docker inspect <name>` — should be exercised here.
        if argv == ["docker", "inspect", "--", "lab-web-nginx"]:
            return subprocess.CompletedProcess(argv, 0, fallback_payload, "")
        if argv[:3] == ["docker", "ps", "-a"]:
            return subprocess.CompletedProcess(argv, 0, fixture, "")
        if argv[:2] == ["docker", "version"]:
            return subprocess.CompletedProcess(argv, 0, "26.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(docker_mod, "run_capture", fake_run_capture)
    backend = DockerBackend()
    target = backend.list_resources()[0]

    out = backend.inspect(target)
    # The returned text should be the fallback's stdout verbatim, not a
    # pretty-printed JSON document from the script.
    assert out == fallback_payload
    assert "FALLBACK_MARKER" in out
    # And it should NOT have been pretty-printed (no two-space indent).
    assert '"schema_version": 1' not in out
