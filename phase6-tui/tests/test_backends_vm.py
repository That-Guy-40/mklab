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
    assert r.type == "vm"
    assert r.log_command[0] == "tail"
    assert str(vm_dir / "qemu.log") in r.log_command


def test_list_resources_stopped(fake_state_dir: Path, fixtures_dir: Path) -> None:
    _seed_vm(fake_state_dir, fixtures_dir, "stoppedvm")
    rs = VMBackend().list_resources()
    assert len(rs) == 1
    assert rs[0].status == "stopped"
    assert rs[0].log_command == []  # no qemu.log → no tail
