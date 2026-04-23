"""Phase 4 (podman) backend.

Podman labels mirror Phase 3's scheme but with `tool=lab-podman`.  Pods
are first-class objects — enumerate both `podman ps` and `podman pod ps`.
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import ClassVar

from lab_tui.backends.base import (
    BackendRunner,
    Resource,
    phase_script,
    run_capture,
    run_json,
)
from lab_tui.state import state_subdir


def _podman_status(state: str) -> str:
    if state == "running":
        return "running"
    if state in {"exited", "created", "paused", "dead", "stopped", "configured"}:
        return "stopped"
    return "unknown"


class PodmanBackend(BackendRunner):
    name: ClassVar = "podman"
    script: ClassVar[Path] = phase_script("phase4-podman/lab-podman.sh")

    @classmethod
    def state_paths(cls) -> list[Path]:
        return [state_subdir("podman")]

    def is_available(self) -> bool:
        if not super().is_available():
            return False
        if not shutil.which("podman"):
            return False
        cp = run_capture(["podman", "version", "--format", "{{.Server.Version}}"])
        return cp.returncode == 0

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        out: list[Resource] = []
        out.extend(self._list_containers(lab))
        out.extend(self._list_pods(lab))
        return out

    def _list_containers(self, lab: str | None) -> list[Resource]:
        argv = [
            "podman", "ps", "-a",
            "--filter", "label=lab-create.tool=lab-podman",
            "--format", "json",
        ]
        if lab is not None:
            argv.extend(["--filter", f"label=lab-create.lab={lab}"])
        rc, parsed = run_json(argv)
        if rc != 0 or not isinstance(parsed, list):
            return []
        out: list[Resource] = []
        for row in parsed:
            labels = row.get("Labels") or {}
            name = (row.get("Names") or [row.get("Id", "")])[0]
            out.append(Resource(
                backend="podman",
                name=name,
                lab=labels.get("lab-create.lab"),
                svc=labels.get("lab-create.svc"),
                type="container",
                status=_podman_status(row.get("State", "")),
                extra={
                    "image": row.get("Image", ""),
                    "id": row.get("Id", ""),
                    "pod": labels.get("lab-create.pod"),
                    "created_at": row.get("CreatedAt", ""),
                },
                spec_path=None,
                log_command=["podman", "logs", "--tail", "200", "-f", name],
            ))
        return out

    def _list_pods(self, lab: str | None) -> list[Resource]:
        argv = [
            "podman", "pod", "ps",
            "--filter", "label=lab-create.tool=lab-podman",
            "--format", "json",
        ]
        if lab is not None:
            argv.extend(["--filter", f"label=lab-create.lab={lab}"])
        rc, parsed = run_json(argv)
        if rc != 0 or not isinstance(parsed, list):
            return []
        out: list[Resource] = []
        for row in parsed:
            labels = row.get("Labels") or {}
            name = row.get("Name", "")
            out.append(Resource(
                backend="podman",
                name=name,
                lab=labels.get("lab-create.lab"),
                svc=labels.get("lab-create.pod") or name,
                type="pod",
                status=_podman_status(row.get("Status", "").lower()),
                extra={
                    "id": row.get("Id", ""),
                    "num_containers": row.get("NumberOfContainers", 0),
                    "created_at": row.get("Created", ""),
                },
                spec_path=None,
                log_command=["podman", "pod", "logs", "--tail", "200", "-f", name],
            ))
        return out

    def inspect(self, resource: Resource) -> str:
        if resource.type == "pod":
            cp = run_capture(["podman", "pod", "inspect", resource.name])
        else:
            cp = run_capture(["podman", "inspect", resource.name])
        if cp.returncode == 0:
            return cp.stdout
        return f"# podman inspect {resource.name} failed:\n{cp.stderr}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        argv = [str(self.script), "destroy", resource.name]
        if force:
            argv.append("--force")
        return argv
