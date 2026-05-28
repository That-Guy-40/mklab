"""Phase 1 (chroot) backend.

Resources are flat TOML manifests at `$LAB_STATE_DIR/chroots/<name>.toml`.
Status is determined by whether the chroot's `target` directory exists.

inspect() prefers `lab-chroot.sh inspect --json` (Phase 1 ≥ 0.1.0) when
present so the detail panel shows live state (target size, owner,
os-release, package count, manager registration) alongside the manifest.
Falls back to the raw manifest if the script doesn't recognise `inspect`
(e.g. older deployments).
"""

from __future__ import annotations

import json
import os
import shutil
import tomllib
from pathlib import Path
from typing import ClassVar

from lab_tui.backends.base import (
    BackendRunner,
    Resource,
    phase_script,
    run_capture,
)
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
        # Try Phase 1's `inspect --json` first — it surfaces live state
        # (target size, owner, os-release, package count, manager
        # registration) that the static manifest can't.  Pretty-print
        # the JSON so it's readable in the TUI's detail pane.
        cp = run_capture([str(self.script), "inspect", resource.name, "--json"])
        if cp.returncode == 0 and cp.stdout.strip().startswith("{"):
            try:
                doc = json.loads(cp.stdout)
                return json.dumps(doc, indent=2, sort_keys=False)
            except json.JSONDecodeError:
                pass  # fall through to manifest
        # Fallback: raw manifest TOML.
        if resource.spec_path and resource.spec_path.is_file():
            return resource.spec_path.read_text()
        return f"# no manifest on disk for {resource.name}"

    def is_available(self) -> bool:
        # Phase 1 has no daemon; the script is the only requirement.
        return super().is_available()

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # `lab-chroot.sh destroy <name>` requires sudo because chroots
        # are root-owned.  --force skips the script's interactive
        # read-from-/dev/tty prompt (which would block a web UI request).
        sudo = ["sudo"] if shutil.which("sudo") and os.geteuid() != 0 else []
        # F-03: '--' stops option parsing so a name like '--force' is not
        # treated as a flag by the bash script.
        argv = [*sudo, str(self.script), "destroy", "--", resource.name]
        if force:
            argv.append("--force")
        return argv
