"""Phase 1 (chroot) backend.

Resources are flat TOML manifests at `$LAB_STATE_DIR/chroots/<name>.toml`.
Status is determined by whether the chroot's `target` directory exists.
"""

from __future__ import annotations

import shutil
import tomllib
from pathlib import Path
from typing import ClassVar

from lab_tui.backends.base import BackendRunner, Resource, phase_script
from lab_tui.state import state_subdir


class ChrootBackend(BackendRunner):
    name: ClassVar = "chroot"
    script: ClassVar[Path] = phase_script("phase1-chroot/lab-chroot.sh")

    @classmethod
    def state_paths(cls) -> list[Path]:
        return [state_subdir("chroot")]

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        out: list[Resource] = []
        for mp in sorted(state_subdir("chroot").glob("*.toml")):
            try:
                data = tomllib.loads(mp.read_text())
            except (OSError, tomllib.TOMLDecodeError):
                continue
            this_lab = (data.get("lab") or "") or None
            if lab is not None and this_lab != lab:
                continue
            target = data.get("target", "")
            status = "built" if target and Path(target).is_dir() else "missing"
            out.append(Resource(
                backend="chroot",
                name=data.get("name", mp.stem),
                lab=this_lab,
                svc=None,
                type="chroot",
                status=status,
                extra={k: v for k, v in data.items()
                       if k not in {"name", "lab"}},
                spec_path=mp,
                # Phase 1 has no live log; nothing to tail.
                log_command=[],
            ))
        return out

    def inspect(self, resource: Resource) -> str:
        if resource.spec_path and resource.spec_path.is_file():
            return resource.spec_path.read_text()
        return f"# no manifest on disk for {resource.name}"

    def is_available(self) -> bool:
        # Phase 1 has no daemon; the script is the only requirement.
        return super().is_available()

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # `lab-chroot.sh destroy <name>` requires sudo because chroots
        # are root-owned.  We surface the command literally so the user
        # is aware before approving.
        sudo = ["sudo"] if shutil.which("sudo") else []
        return [*sudo, str(self.script), "destroy", resource.name]
