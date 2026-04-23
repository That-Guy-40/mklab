"""Phase 2 (QEMU VM) backend.

Per-VM state at `$LAB_STATE_DIR/vms/<name>/`:
  manifest.toml  — TOML spec
  qemu.pid       — present when qemu is running (kill -0 to verify)
  qemu.log       — appended-on-each-boot log (tailable)
  serial.sock    — Unix socket for the serial console
"""

from __future__ import annotations

import os
import shutil
import tomllib
from pathlib import Path
from typing import ClassVar

from lab_tui.backends.base import BackendRunner, Resource, phase_script
from lab_tui.state import state_subdir


def _pid_alive(pidfile: Path) -> bool:
    """True iff pidfile names a live PID (signal 0 doesn't kill, only probes)."""
    try:
        pid = int(pidfile.read_text().strip())
    except (OSError, ValueError):
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # PID exists but owned by another user — treat as "running" since
        # we can confirm the slot is taken even if we can't signal it.
        return True
    except OSError:
        return False


class VMBackend(BackendRunner):
    name: ClassVar = "vm"
    script: ClassVar[Path] = phase_script("phase2-qemu-vm/lab-vm.sh")

    @classmethod
    def state_paths(cls) -> list[Path]:
        return [state_subdir("vm")]

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        out: list[Resource] = []
        root = state_subdir("vm")
        for vm_dir in sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []:
            mp = vm_dir / "manifest.toml"
            if not mp.is_file():
                continue
            try:
                data = tomllib.loads(mp.read_text())
            except (OSError, tomllib.TOMLDecodeError):
                continue
            this_lab = (data.get("lab") or "") or None
            if lab is not None and this_lab != lab:
                continue
            pidfile = vm_dir / "qemu.pid"
            status = "running" if _pid_alive(pidfile) else "stopped"
            log_path = vm_dir / "qemu.log"
            log_command = (
                ["tail", "-n", "200", "-F", str(log_path)]
                if log_path.is_file() else []
            )
            out.append(Resource(
                backend="vm",
                name=data.get("name", vm_dir.name),
                lab=this_lab,
                svc=None,
                type="vm",
                status=status,
                extra={k: v for k, v in data.items()
                       if k not in {"name", "lab"}},
                spec_path=mp,
                log_command=log_command,
            ))
        return out

    def inspect(self, resource: Resource) -> str:
        if resource.spec_path and resource.spec_path.is_file():
            return resource.spec_path.read_text()
        return f"# no manifest on disk for {resource.name}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # `lab-vm destroy <name>` requires sudo (qemu disks live under
        # /var/lib when run as root, or under XDG_STATE_HOME otherwise).
        sudo = ["sudo"] if shutil.which("sudo") and os.geteuid() != 0 else []
        return [*sudo, str(self.script), "destroy", resource.name]
