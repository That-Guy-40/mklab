"""Phase 3 (docker) backend.

Docker containers are tagged with `lab-create.tool=lab-docker`,
`lab-create.lab=<name>`, `lab-create.svc=<svc>`.  Inventory is a single
`docker ps -a --filter label=… --format=json` call — there is no
filesystem state to read.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path
from typing import ClassVar

from lab_tui.backends.base import (
    BackendRunner,
    Resource,
    phase_script,
    run_capture,
)


def _docker_status(state: str) -> str:
    """Map a docker state string ('running', 'exited', …) to our enum."""
    if state == "running":
        return "running"
    if state in {"exited", "created", "paused", "dead"}:
        return "stopped"
    return "unknown"


class DockerBackend(BackendRunner):
    name: ClassVar = "docker"
    script: ClassVar[Path] = phase_script("phase3-docker/lab-docker.sh")

    @classmethod
    def state_paths(cls) -> list[Path]:
        # Label-only: docker writes nothing to disk that the watcher would
        # notice.  Topped up by the polling tick in lab_tui.state.
        return []

    def is_available(self) -> bool:
        if not super().is_available():
            return False
        if not shutil.which("docker"):
            return False
        cp = run_capture(["docker", "version", "--format", "{{.Server.Version}}"])
        return cp.returncode == 0

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        # `docker ps --format=json` emits one JSON object PER LINE, NOT a
        # JSON array.  Parse line-wise.  --no-trunc keeps long names intact.
        argv = [
            "docker", "ps", "-a", "--no-trunc",
            "--filter", "label=lab-create.tool=lab-docker",
            "--format", "{{json .}}",
        ]
        if lab is not None:
            argv.extend(["--filter", f"label=lab-create.lab={lab}"])
        cp = run_capture(argv)
        if cp.returncode != 0:
            return []
        out: list[Resource] = []
        for line in cp.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            labels = self._parse_labels(row.get("Labels", ""))
            out.append(Resource(
                backend="docker",
                name=row.get("Names", "") or row.get("ID", ""),
                lab=labels.get("lab-create.lab"),
                svc=labels.get("lab-create.svc"),
                type="container",
                status=_docker_status(row.get("State", "")),
                extra={
                    "image": row.get("Image", ""),
                    "id": row.get("ID", ""),
                    "ports": row.get("Ports", ""),
                    "created_at": row.get("CreatedAt", ""),
                },
                spec_path=None,
                log_command=["docker", "logs", "--tail", "200", "-f", row.get("Names", "")],
            ))
        return out

    def inspect(self, resource: Resource) -> str:
        cp = run_capture(["docker", "inspect", resource.name])
        if cp.returncode == 0:
            return cp.stdout
        return f"# docker inspect {resource.name} failed:\n{cp.stderr}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # Use the phase script's `destroy` verb so it cleans up labels
        # AND the container; raw `docker rm -f` would skip the bookkeeping.
        argv = [str(self.script), "destroy", resource.name]
        if force:
            argv.append("--force")
        return argv

    @staticmethod
    def _parse_labels(raw: str) -> dict[str, str]:
        # docker prints labels as "k=v,k=v,...".  Empty-value labels exist
        # for the "lab-create.tool" presence-only key.
        if not raw:
            return {}
        out: dict[str, str] = {}
        for pair in raw.split(","):
            if "=" in pair:
                k, v = pair.split("=", 1)
                out[k.strip()] = v.strip()
        return out
