from __future__ import annotations

import os
import shutil
from pathlib import Path

from lab_tui.backends.vm import VMBackend, _pid_alive


def _seed_vm(fake_state_dir: Path, fixtures_dir: Path, name: str) -> Path:
    vm_dir = fake_state_dir / "vms" / name
    vm_dir.mkdir(parents=True)
    src = fixtures_dir / "vm-alpine-manifest.toml"
    dst = vm_dir / "manifest.toml"
    text = src.read_text().replace("alpine-microvm", name)
    dst.write_text(text)
    return vm_dir


def test_pid_alive_with_live_pid(fake_pid_path: Path) -> None:
    assert _pid_alive(fake_pid_path) is True


def test_pid_alive_with_dead_pid(dead_pid_path: Path) -> None:
    assert _pid_alive(dead_pid_path) is False


def test_pid_alive_with_missing_pidfile(tmp_path: Path) -> None:
    assert _pid_alive(tmp_path / "nope") is False


def test_list_resources_running(fake_state_dir: Path, fixtures_dir: Path) -> None:
    vm_dir = _seed_vm(fake_state_dir, fixtures_dir, "myvm")
    (vm_dir / "qemu.pid").write_text(str(os.getpid()))
    (vm_dir / "qemu.log").write_text("[boot] hello\n")

    rs = VMBackend().list_resources()
    assert len(rs) == 1
    r = rs[0]
    assert r.backend == "vm"
    assert r.name == "myvm"
    assert r.status == "running"
    assert r.lab == "vmlab"
    assert r.type == "netboot-vm"   # fixture uses backend=kernel+initrd
    assert r.log_command[0] == "tail"
    assert str(vm_dir / "qemu.log") in r.log_command


def test_list_resources_stopped(fake_state_dir: Path, fixtures_dir: Path) -> None:
    _seed_vm(fake_state_dir, fixtures_dir, "stoppedvm")
    rs = VMBackend().list_resources()
    assert len(rs) == 1
    assert rs[0].status == "stopped"
    assert rs[0].log_command == []  # no qemu.log → no tail


def test_inspect_prefers_inspect_json_when_available(
    fake_state_dir: Path,
    fixtures_dir: Path,
    monkeypatch,
) -> None:
    """When Phase 2's `inspect --json` returns valid JSON, the backend
    should pretty-print it instead of falling back to the raw manifest."""
    import subprocess
    import lab_tui.backends.vm as vm_mod

    _seed_vm(fake_state_dir, fixtures_dir, "myvm")
    rs = VMBackend().list_resources()
    assert len(rs) == 1
    target = rs[0]
    assert target.name == "myvm"  # Resource.name is the VM's name, not a path

    fake_doc = {
        "schema_version": 1,
        "name": target.name,
        "manifest": {"name": target.name, "backend": "kernel+initrd"},
        "runtime": {"pid_alive": False, "ssh_reachable": False},
        "disk": {"path": "", "size_bytes": 0},
    }

    def fake_run_capture(argv, *, env=None):
        if argv[1:3] == ["inspect", target.name] and "--json" in argv:
            import json as _j
            return subprocess.CompletedProcess(argv, 0, _j.dumps(fake_doc), "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected")

    monkeypatch.setattr(vm_mod, "run_capture", fake_run_capture)
    out = VMBackend().inspect(target)
    # Pretty-printed JSON, two-space indent.
    assert '"schema_version": 1' in out
    assert '"backend": "kernel+initrd"' in out


def test_inspect_falls_back_to_manifest_when_inspect_fails(
    fake_state_dir: Path,
    fixtures_dir: Path,
    monkeypatch,
) -> None:
    """If `inspect --json` exits non-zero or returns garbage, the
    backend gracefully falls back to the raw manifest TOML."""
    import subprocess
    import lab_tui.backends.vm as vm_mod

    _seed_vm(fake_state_dir, fixtures_dir, "myvm")
    rs = VMBackend().list_resources()
    target = rs[0]

    monkeypatch.setattr(
        vm_mod, "run_capture",
        lambda argv, *, env=None: subprocess.CompletedProcess(argv, 1, "",
                                                              "no such verb"),
    )
    out = VMBackend().inspect(target)
    # Manifest fallback contains the literal field names from the fixture.
    assert 'backend     = "kernel+initrd"' in out
    assert 'distro      = "alpine"' in out
