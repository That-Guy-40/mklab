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


def test_inspect_prefers_inspect_json_when_available(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """When Phase 4's `inspect --json` returns valid JSON, the backend
    should pretty-print it instead of falling back to `podman inspect`."""
    import lab_tui.backends.podman as podman_mod

    ps = json.loads((fixtures_dir / "podman-ps.json").read_text())
    pods = json.loads((fixtures_dir / "podman-pod-ps.json").read_text())
    fake_doc = {
        "schema_version": 1,
        "name": "lab-pwn-attacker",
        "labels": {"lab": "pwn", "svc": "attacker", "tool": "lab-podman"},
        "container": {"id": "abcdef0123", "image": "kali-rolling"},
        "state": {"status": "running", "running": True, "pid": 4242},
    }
    # Marker that ONLY appears in the podman-inspect fallback output, so
    # the assertion can prove which path the backend took.
    fallback_payload = '[{"Id":"abcdef0123","FALLBACK_MARKER":"yes"}]'

    def fake_run_json(argv):
        if argv[:3] == ["podman", "ps", "-a"]:
            return 0, ps
        if argv[:3] == ["podman", "pod", "ps"]:
            return 0, pods
        return 1, None

    def fake_run_capture(argv, *, env=None):
        # Phase 4 script's `inspect <name> --json` — preferred path.
        if argv[1:] == ["inspect", "lab-pwn-attacker", "--json"]:
            return subprocess.CompletedProcess(argv, 0, json.dumps(fake_doc), "")
        # Bare `podman inspect <name>` — fallback path.  Must NOT be hit
        # when the phase script succeeds.
        if argv == ["podman", "inspect", "--", "lab-pwn-attacker"]:
            return subprocess.CompletedProcess(argv, 0, fallback_payload, "")
        if argv[:2] == ["podman", "version"]:
            return subprocess.CompletedProcess(argv, 0, "5.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(podman_mod, "run_json", fake_run_json)
    monkeypatch.setattr(podman_mod, "run_capture", fake_run_capture)
    backend = PodmanBackend()
    target = next(r for r in backend.list_resources() if r.name == "lab-pwn-attacker")
    assert target.type == "container"  # sanity

    out = backend.inspect(target)
    # Pretty-printed JSON, two-space indent — distinguishes from the
    # single-line fallback payload.
    assert '"schema_version": 1' in out
    assert '"image": "kali-rolling"' in out
    # The fallback's marker must NOT appear — proves we took the script path.
    assert "FALLBACK_MARKER" not in out


def test_inspect_falls_back_to_podman_inspect_when_inspect_fails(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """If `inspect --json` exits non-zero, the backend should fall back
    to bare `podman inspect <name>` (for containers) and return its
    stdout verbatim."""
    import lab_tui.backends.podman as podman_mod

    ps = json.loads((fixtures_dir / "podman-ps.json").read_text())
    pods = json.loads((fixtures_dir / "podman-pod-ps.json").read_text())
    fallback_payload = '[{"Id":"abcdef0123","Name":"lab-pwn-attacker","FALLBACK_MARKER":"yes"}]'

    def fake_run_json(argv):
        if argv[:3] == ["podman", "ps", "-a"]:
            return 0, ps
        if argv[:3] == ["podman", "pod", "ps"]:
            return 0, pods
        return 1, None

    def fake_run_capture(argv, *, env=None):
        # Phase 4 script's `inspect --json` fails (older deployment, missing jq, …).
        if argv[1:] == ["inspect", "lab-pwn-attacker", "--json"]:
            return subprocess.CompletedProcess(argv, 1, "", "no such verb\n")
        # Bare `podman inspect <name>` — should be exercised here for container.
        if argv == ["podman", "inspect", "--", "lab-pwn-attacker"]:
            return subprocess.CompletedProcess(argv, 0, fallback_payload, "")
        if argv[:2] == ["podman", "version"]:
            return subprocess.CompletedProcess(argv, 0, "5.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(podman_mod, "run_json", fake_run_json)
    monkeypatch.setattr(podman_mod, "run_capture", fake_run_capture)
    backend = PodmanBackend()
    target = next(r for r in backend.list_resources() if r.name == "lab-pwn-attacker")
    assert target.type == "container"  # sanity

    out = backend.inspect(target)
    # The returned text should be the fallback's stdout verbatim, not a
    # pretty-printed JSON document from the script.
    assert out == fallback_payload
    assert "FALLBACK_MARKER" in out
    # And it should NOT have been pretty-printed (no two-space indent).
    assert '"schema_version": 1' not in out


def test_inspect_pod_fallback_uses_podman_pod_inspect(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
) -> None:
    """When the script fails AND resource.type == 'pod', the fallback
    must invoke `podman pod inspect` (NOT `podman inspect`).  The bare
    podman CLI doesn't auto-detect pod-vs-container the way the phase
    script does, so picking the right verb is on us."""
    import lab_tui.backends.podman as podman_mod

    ps = json.loads((fixtures_dir / "podman-ps.json").read_text())
    pods = json.loads((fixtures_dir / "podman-pod-ps.json").read_text())
    pod_fallback_payload = '[{"Id":"podid000","Name":"ctf-pod","FALLBACK_MARKER":"pod"}]'

    def fake_run_json(argv):
        if argv[:3] == ["podman", "ps", "-a"]:
            return 0, ps
        if argv[:3] == ["podman", "pod", "ps"]:
            return 0, pods
        return 1, None

    def fake_run_capture(argv, *, env=None):
        # Phase 4 script's `inspect --json` fails — exercise the fallback.
        if argv[1:] == ["inspect", "ctf-pod", "--json"]:
            return subprocess.CompletedProcess(argv, 1, "", "no such verb\n")
        # `podman pod inspect ctf-pod` — the correct fallback for a pod.
        if argv == ["podman", "pod", "inspect", "--", "ctf-pod"]:
            return subprocess.CompletedProcess(argv, 0, pod_fallback_payload, "")
        # `podman inspect ctf-pod` — WRONG; would be silently empty in
        # real life (pods aren't containers).  If the backend takes this
        # path we want the test to fail loudly: return a sentinel.
        if argv == ["podman", "inspect", "ctf-pod"]:
            return subprocess.CompletedProcess(argv, 0, "WRONG_VERB", "")
        if argv[:2] == ["podman", "version"]:
            return subprocess.CompletedProcess(argv, 0, "5.0.0\n", "")
        return subprocess.CompletedProcess(argv, 0, "", "")

    monkeypatch.setattr(podman_mod, "run_json", fake_run_json)
    monkeypatch.setattr(podman_mod, "run_capture", fake_run_capture)
    backend = PodmanBackend()
    target = next(r for r in backend.list_resources() if r.type == "pod")
    assert target.name == "ctf-pod"  # sanity from the fixture

    out = backend.inspect(target)
    assert out == pod_fallback_payload
    assert "FALLBACK_MARKER" in out
    # Belt-and-braces: prove we did NOT take the container-fallback branch.
    assert "WRONG_VERB" not in out
