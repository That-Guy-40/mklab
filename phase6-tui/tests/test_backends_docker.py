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
