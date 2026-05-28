"""Tests for the Phase-2 VM console-attach feature.

Covers:
  1. Resource.console_command is populated for running VMs with a serial.sock.
  2. Resource.console_command is empty for stopped VMs.
  3. Resource.console_command is empty for running VMs without a serial.sock
     (the socket is created by QEMU at start time; its absence means the
     VM hasn't finished starting or the socket was cleaned up).
  4. action_console() notifies when no console is available.
  5. action_console() calls app.suspend() and subprocess.run() with the
     correct argv when a console IS available.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, call, patch

import pytest

from lab_tui.backends.vm import VMBackend


# ── helpers ──────────────────────────────────────────────────────────────────

def _seed_vm(
    fake_state_dir: Path,
    fixtures_dir: Path,
    name: str,
    *,
    running: bool = True,
    has_serial_sock: bool = True,
) -> Path:
    vm_dir = fake_state_dir / "vms" / name
    vm_dir.mkdir(parents=True)
    src = fixtures_dir / "vm-alpine-manifest.toml"
    dst = vm_dir / "manifest.toml"
    dst.write_text(src.read_text().replace("alpine-microvm", name))
    if running:
        (vm_dir / "qemu.pid").write_text(str(os.getpid()))
        (vm_dir / "qemu.log").write_text("[boot] ok\n")
    if running and has_serial_sock:
        # Create the socket placeholder (real socket created by QEMU;
        # VMBackend checks .exists() not S_ISSOCK so a plain file suffices here).
        (vm_dir / "serial.sock").touch()
    return vm_dir


# ── unit: console_command population ─────────────────────────────────────────

class TestConsoleCommandPopulation:

    def test_running_vm_with_serial_sock_has_console_command(
        self, fake_state_dir: Path, fixtures_dir: Path
    ) -> None:
        _seed_vm(fake_state_dir, fixtures_dir, "myvm", running=True, has_serial_sock=True)
        rs = VMBackend().list_resources()
        assert len(rs) == 1
        r = rs[0]
        assert r.status == "running"
        assert r.console_command, "running VM with serial.sock must have console_command"
        # Must end with the VM name so lab-vm.sh can find it.
        assert r.console_command[-1] == "myvm"
        # Must include the phase script.
        assert any("lab-vm.sh" in part for part in r.console_command)

    def test_stopped_vm_has_no_console_command(
        self, fake_state_dir: Path, fixtures_dir: Path
    ) -> None:
        _seed_vm(fake_state_dir, fixtures_dir, "stoppedvm", running=False)
        rs = VMBackend().list_resources()
        assert len(rs) == 1
        assert rs[0].status == "stopped"
        assert rs[0].console_command == [], \
            "stopped VM must not have console_command (socat would fail)"

    def test_running_vm_without_serial_sock_has_no_console_command(
        self, fake_state_dir: Path, fixtures_dir: Path
    ) -> None:
        """Serial socket is created by QEMU; if it's absent the VM hasn't
        finished starting up or was torn down without cleanup."""
        _seed_vm(fake_state_dir, fixtures_dir, "nosock", running=True, has_serial_sock=False)
        rs = VMBackend().list_resources()
        assert len(rs) == 1
        assert rs[0].status == "running"
        assert rs[0].console_command == [], \
            "running VM without serial.sock must not have console_command"


# ── unit: action_console in ResourceBrowserScreen ────────────────────────────

class TestActionConsole:
    """Test the browser action, not the full Textual pilot (which would need
    App.suspend() to be a no-op, making the test meaningless).  We test the
    action method directly after injecting a fake selected resource."""

    def _make_screen(self):
        from lab_tui.screens.browser import ResourceBrowserScreen
        screen = object.__new__(ResourceBrowserScreen)
        # Minimal attrs needed by action_console.
        screen._resources_by_id = {}
        screen._runners = {}
        return screen

    def test_notify_when_no_resource_selected(self) -> None:
        screen = self._make_screen()
        screen.notify = MagicMock()
        # No tree / cursor → _selected_resource returns None.
        screen._selected_resource = lambda: None  # type: ignore[assignment]
        screen.action_console()
        screen.notify.assert_called_once()
        msg = screen.notify.call_args[0][0]
        assert "console" in msg.lower() or "running" in msg.lower()

    def test_notify_when_resource_has_no_console_command(self) -> None:
        from lab_tui.backends.base import Resource
        screen = self._make_screen()
        screen.notify = MagicMock()
        r = Resource(backend="vm", name="myvm", status="stopped", console_command=[])
        screen._selected_resource = lambda: r  # type: ignore[assignment]
        screen.action_console()
        screen.notify.assert_called_once()

    def test_suspend_and_run_called_with_correct_argv(self) -> None:
        """When a console_command is set, action_console must:
         - enter app.suspend() context
         - call subprocess.run() with exactly that argv inside the block
         - exit cleanly

        We test the _run_console() helper directly (which action_console
        delegates to) because screen.app is a read-only DOMNode property
        and cannot be monkey-patched without a live Textual app.
        """
        from lab_tui.screens.browser import _run_console

        expected_argv = ["/repo/lab-vm.sh", "console", "myvm"]

        # Fake suspend() context manager.
        class FakeSuspendCtx:
            def __enter__(self_):
                return self_
            def __exit__(self_, *_):
                return False

        app_mock = MagicMock()
        app_mock.suspend.return_value = FakeSuspendCtx()

        with patch("lab_tui.screens.browser.subprocess.run") as mock_run:
            _run_console(app_mock, expected_argv)

        # suspend() context entered exactly once.
        app_mock.suspend.assert_called_once()
        # subprocess.run called with the correct argv.
        mock_run.assert_called_once_with(expected_argv)  # noqa: S603
