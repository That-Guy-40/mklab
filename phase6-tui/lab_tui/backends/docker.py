"""Phase 3 (docker) backend.

Docker containers are tagged with `lab-create.tool=lab-docker`,
`lab-create.lab=<name>`, `lab-create.svc=<svc>`.  Inventory is a single
`docker ps -a --filter label=… --format=json` call — there is no
filesystem state to read.

inspect() prefers `lab-docker.sh inspect --json` (Phase 3 ≥ 0.1.0) when
present so the detail panel shows the schema_version=1 surface (folded
labels, network ports, mounts) instead of `docker inspect`'s raw nested
JSON. Falls back to `docker inspect <name>` if the script doesn't
recognise `inspect` (e.g. older deployments) or returns non-JSON.
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
            # F-08: a lab name containing '=' would make Docker parse the
            # filter as label key=wrong-key and value=rest, silently hiding
            # all containers.  Validate before embedding.
            import re as _re
            if not _re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$", lab):
                return []  # invalid lab name — return empty rather than wrong results
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
        # Try Phase 3's `inspect --json` first — it folds docker's nested
        # inspect output into a stable schema_version=1 surface (labels,
        # network ports, mounts) that's much more readable in the TUI's
        # detail pane.  Pretty-print the JSON for nice indentation.
        # `resource.name` is the literal docker container name (e.g.
        # `lab-web-nginx`); the phase script's resolver tries the literal
        # form first, so this argv works directly.
        cp = run_capture([str(self.script), "inspect", resource.name, "--json"])
        if cp.returncode == 0 and cp.stdout.strip().startswith("{"):
            try:
                doc = json.loads(cp.stdout)
                return json.dumps(doc, indent=2, sort_keys=False)
            except json.JSONDecodeError:
                pass  # fall through to `docker inspect`
        # Fallback: raw `docker inspect` output (a JSON array, unprettified).
        # F-11: '--' stops option parsing so a name starting with '-' is safe.
        cp = run_capture(["docker", "inspect", "--", resource.name])
        if cp.returncode == 0:
            return cp.stdout
        return f"# docker inspect {resource.name} failed:\n{cp.stderr}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # `lab-docker destroy` resolves names via _resolve_container_name():
        #   "lab/svc"  → "lab-lab-svc"   (topology container)
        #   "name"     → "lab-name"       (ad-hoc container)
        # resource.name is already the full Docker name (e.g. "lab-demo-web"),
        # so we must pass "lab/svc" to avoid the double-prefix bug.
        target = (
            f"{resource.lab}/{resource.svc}"
            if resource.lab and resource.svc
            else resource.name.removeprefix("lab-")
        )
        # F-12: '--' stops option parsing in the bash script.
        argv = [str(self.script), "destroy", "--", target]
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
