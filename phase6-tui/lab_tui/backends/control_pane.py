"""Control-pane backend — a READ-ONLY inventory source over `examples/control-pane`.

Unlike the phase backends (which own the resources they list), this surfaces a lab's
*control-pane fleet*: nodes a lab registered under `$LAB_STATE_DIR/control-pane/<node>/
node.toml` (profile + console), each carrying live boot/install **progress** computed by
the control-pane engine. It shells out to the `control-pane` CLI (no Python import across
the package boundary), exactly like the vm/docker/… backends shell out to their phase
scripts. `list_resources` runs `control-pane list --json`; progress rides in `extra` for a
renderer (a Textual ProgressBar / a web SSE feed) to draw.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import ClassVar

from lab_tui.backends.base import (
    BackendRunner,
    Resource,
    ResourceStatus,
    phase_script,
    run_capture,
)
from lab_tui.state import state_subdir


def _status_for(percent: int, terminal: bool, stalled: bool) -> ResourceStatus:
    if stalled:
        return "error"
    if terminal:
        return "built"          # reached its terminal milestone ("active")
    if percent > 0:
        return "running"        # provisioning in progress
    return "stopped"            # registered but not started


class ControlPaneBackend(BackendRunner):
    name: ClassVar = "control-pane"
    script: ClassVar[Path] = phase_script("tools/control-pane")

    @classmethod
    def state_paths(cls) -> list[Path]:
        return [state_subdir("control-pane")]

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        fleet = state_subdir("control-pane")
        cp = run_capture([str(self.script), "list", "--json", "--fleet", str(fleet)])
        if cp.returncode != 0 or not cp.stdout.strip():
            return []
        try:
            nodes = json.loads(cp.stdout)
        except json.JSONDecodeError:
            return []
        out: list[Resource] = []
        for n in nodes:
            name = n.get("name", "")
            console = n.get("console", "")
            # The console is a captured log — tail it for the log pane, if present.
            log_command = ["tail", "-n", "200", "-F", console] if console else []
            out.append(Resource(
                backend="control-pane",
                name=name,
                lab=lab,
                svc=None,
                type="node",
                status=_status_for(n.get("percent", 0), n.get("terminal", False),
                                   n.get("stalled", False)),
                extra={
                    "profile": n.get("profile", ""),
                    "percent": n.get("percent", 0),
                    "label": n.get("label", ""),
                    "terminal": n.get("terminal", False),
                    "stalled": n.get("stalled", False),
                    "console": console,
                    # the verbs this node's owner declared (see ActionsScreen). The
                    # backend passes them through untouched — it does not know what
                    # any of them do, which is the point.
                    "actions": n.get("actions", []),
                },
                spec_path=fleet / name / "node.toml",
                log_command=log_command,
                console_command=[],  # observed console; the log tail is the surface
            ))
        return out

    def inspect(self, resource: Resource) -> str:
        cp = run_capture([str(self.script), "inspect", resource.name,
                          "--fleet", str(state_subdir("control-pane"))])
        if cp.returncode == 0 and cp.stdout.strip():
            return cp.stdout
        if resource.spec_path and resource.spec_path.is_file():
            return resource.spec_path.read_text()
        return f"# no node.toml on disk for {resource.name}"

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # Read-only source: it observes nodes it does not own. Return an inert command
        # so the confirm modal shows an honest no-op rather than a destructive verb.
        return ["echo", f"control-pane: '{resource.name}' is observed here, not owned "
                        "— nothing to destroy (read-only source)"]
