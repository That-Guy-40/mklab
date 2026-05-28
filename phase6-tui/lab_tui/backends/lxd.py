"""Phase 5 (LXD/Incus) backend.

Engine probe mirrors `phase5-lxd/lab-lxd.sh` (lines 130–180): prefer
`incus`; fall back to `lxc` (LXD).  A bare `which incus` isn't enough —
many distros ship the package but the daemon is down or restricted to
incus-admin, so we probe `… info` to confirm reachability.

inspect() prefers `lab-lxd.sh inspect --json` (Phase 5 ≥ 0.1.0) when
present so the detail panel shows the schema_version=1 surface (folded
labels, network state, project, image lineage) instead of the raw
`<engine> config show --expanded` YAML.  Falls back to that YAML if the
script doesn't recognise `inspect` (e.g. older deployments) or returns
non-JSON; the fallback preserves all existing project handling.
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
    run_json,
)
from lab_tui.state import state_subdir

# Match the script's label keys verbatim so we filter on the same thing.
_TOOL_KEY = "user.lab-create.tool"
_TOOL_VAL = "lab-lxd"
_LAB_KEY = "user.lab-create.lab"
_SVC_KEY = "user.lab-create.svc"


def _lxd_status(s: str) -> str:
    s = s.lower()
    if s == "running":
        return "running"
    if s in {"stopped", "frozen", "paused"}:
        return "stopped"
    if s in {"error", "failure"}:
        return "error"
    return "unknown"


class LXDBackend(BackendRunner):
    name: ClassVar = "lxd"
    script: ClassVar[Path] = phase_script("phase5-lxd/lab-lxd.sh")

    @classmethod
    def state_paths(cls) -> list[Path]:
        return [state_subdir("lxd")]

    # Resolved on first is_available()/list_resources() call so we don't
    # re-probe across method calls.
    _engine_cmd: str | None = None

    def _probe_engine(self) -> str | None:
        """Return 'incus' or 'lxc' (whichever is reachable), or None."""
        if self._engine_cmd is not None:
            return self._engine_cmd
        for candidate in ("incus", "lxc"):
            if not shutil.which(candidate):
                continue
            cp = run_capture([candidate, "info"])
            if cp.returncode == 0:
                self.__class__._engine_cmd = candidate
                return candidate
        return None

    def is_available(self) -> bool:
        if not super().is_available():
            return False
        ok = self._probe_engine() is not None
        # F-10: clear the cached engine command when the probe fails so a
        # daemon that comes back online after a restart is re-detected rather
        # than silently returning empty from the stale cache.
        if not ok:
            self.__class__._engine_cmd = None
        return ok

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        engine = self._probe_engine()
        if engine is None:
            return []
        rc, parsed = run_json([engine, "list", "--all-projects", "--format=json"])
        if rc != 0 or not isinstance(parsed, list):
            return []
        out: list[Resource] = []
        for row in parsed:
            cfg = row.get("config") or {}
            if cfg.get(_TOOL_KEY) != _TOOL_VAL:
                continue
            this_lab = cfg.get(_LAB_KEY)
            if lab is not None and this_lab != lab:
                continue
            this_svc = cfg.get(_SVC_KEY)
            inst_type = (row.get("type") or "container").lower()
            project = row.get("project") or "default"
            name = row.get("name", "")
            out.append(Resource(
                backend="lxd",
                name=name,
                lab=this_lab,
                svc=this_svc,
                type="instance" if inst_type == "container" else "vm",
                status=_lxd_status(row.get("status", "")),
                extra={
                    "engine": engine,
                    "project": project,
                    "instance_type": inst_type,
                    "architecture": row.get("architecture", ""),
                    "created_at": row.get("created_at", ""),
                },
                spec_path=None,
                # `engine console --show-log NAME` is the analogue of
                # docker/podman logs; `--project` is needed for non-default.
                log_command=self._log_argv(engine, name, project),
            ))
        return out

    @staticmethod
    def _log_argv(engine: str, name: str, project: str) -> list[str]:
        argv = [engine]
        if project and project != "default":
            argv += ["--project", project]
        # F-04: '--' stops option parsing so a name starting with '-' is
        # not interpreted as a flag by the engine CLI.
        argv += ["console", "--show-log", "--", name]
        return argv

    def inspect(self, resource: Resource) -> str:
        # Try Phase 5's `inspect --json` first — it folds the engine's
        # config dump into a stable schema_version=1 surface (labels,
        # network state, project, image lineage) that's much more
        # readable in the TUI's detail pane.  Pretty-print the JSON for
        # nice indentation.  `resource.name` is the literal engine-side
        # instance name (e.g. `lab-demo-shell`); the phase script's
        # resolver tries the literal form first via `lxc list <name>
        # --all-projects`, so this argv works without project threading.
        cp = run_capture([str(self.script), "inspect", resource.name, "--json"])
        if cp.returncode == 0 and cp.stdout.strip().startswith("{"):
            try:
                doc = json.loads(cp.stdout)
                return json.dumps(doc, indent=2, sort_keys=False)
            except json.JSONDecodeError:
                pass  # fall through to `<engine> config show --expanded`
        # Fallback: raw `<engine> config show --expanded` YAML.  Preserve
        # the project-flag handling for non-default projects.
        engine = self._probe_engine()
        if engine is None:
            return "# no reachable LXD/Incus daemon"
        argv = [engine]
        project = resource.extra.get("project") or "default"
        if project != "default":
            argv += ["--project", project]
        argv += ["config", "show", "--expanded", "--", resource.name]
        cp = run_capture(argv)
        if cp.returncode == 0:
            return cp.stdout
        return f"# {' '.join(argv)} failed:\n{cp.stderr}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # `lab-lxd destroy <lab/svc>` is the phase script's surface; it
        # already routes through stop+delete.
        target = resource.lab and resource.svc and f"{resource.lab}/{resource.svc}"
        target = target or resource.name
        # F-12: '--' stops option parsing in the bash script.
        argv = [str(self.script), "destroy", "--", target]
        if force:
            argv.append("--force")
        return argv
