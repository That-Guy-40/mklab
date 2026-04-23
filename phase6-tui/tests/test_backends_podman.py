from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest

from lab_tui.backends.podman import PodmanBackend


@pytest.fixture
def patched_podman(monkeypatch: pytest.MonkeyPatch, fixtures_dir: Path) -> PodmanBackend:
    ps = json.loads((fixtures_dir / "podman-ps.json").read_text())
    pods = json.loads((fixtures_dir / "podman-pod-ps.json").read_text())

    def fake_run_json(argv):
        if argv[:3] == ["podman", "ps", "-a"]:
            return 0, ps
        if argv[:3] == ["podman", "pod", "ps"]:
            return 0, pods
        return 1, None

    def fake_run_capture(argv, *, env=None):
        if argv[:2] == ["podman", "version"]:
            return subprocess.CompletedProcess(argv, 0, "5.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    import lab_tui.backends.podman as podman_mod
    monkeypatch.setattr(podman_mod, "run_json", fake_run_json)
    monkeypatch.setattr(podman_mod, "run_capture", fake_run_capture)
    return PodmanBackend()


def test_list_combines_containers_and_pods(patched_podman: PodmanBackend) -> None:
    rs = patched_podman.list_resources()
    # 2 containers + 1 pod = 3 resources
    assert len(rs) == 3
    types = sorted({r.type for r in rs})
    assert types == ["container", "pod"]


def test_pod_label_propagates_to_container_extra(patched_podman: PodmanBackend) -> None:
    rs = patched_podman.list_resources()
    attacker = next(r for r in rs if r.svc == "attacker")
    assert attacker.extra["pod"] == "ctf-pod"
    target = next(r for r in rs if r.svc == "target")
    assert target.extra["pod"] is None  # no pod label on this one
