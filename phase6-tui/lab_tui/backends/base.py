"""Resource model + BackendRunner ABC.

Every concrete backend (chroot, vm, docker, podman, lxd) wraps a phase
script via subprocess for mutating actions and reads from the script's
state files / engine queries for inventory.

Keep this module framework-agnostic — Phase 6b (web UI) will reuse the
same backends. NO `textual` imports here, ever.
"""

from __future__ import annotations

import os
import subprocess
from abc import ABC, abstractmethod
from pathlib import Path
from typing import ClassVar, Literal

from pydantic import BaseModel, ConfigDict, Field

# Resolve repo root from this file's location: phase6-tui/lab_tui/backends/base.py
# → repo root is three parents up from this file's dir.
_PHASE_ROOT = Path(__file__).resolve().parent.parent.parent.parent

# F-12: warn at import time when _PHASE_ROOT doesn't look like the repo root.
# This happens when the package is installed as a wheel (site-packages),
# in which case the phase scripts are not present and every backend returns
# is_available()=False with no clear diagnostic.
import warnings as _warnings
if not (_PHASE_ROOT / "phase1-chroot").is_dir():
    _warnings.warn(
        f"lab_tui: phase scripts not found under {_PHASE_ROOT}. "
        "This package must be used in-tree from the LAB_CREATE_V2 repo, "
        "not installed as a wheel.  All backends will report unavailable.",
        RuntimeWarning,
        stacklevel=1,
    )

ResourceStatus = Literal[
    "running", "stopped", "built", "missing", "error", "unknown",
]

BackendName = Literal["chroot", "vm", "docker", "podman", "lxd"]


class Resource(BaseModel):
    """One row in the TUI's browser tree.

    Captures only what's needed to render + identify; any backend-specific
    inspection is done lazily via `BackendRunner.inspect()`.
    """

    model_config = ConfigDict(arbitrary_types_allowed=True)

    backend: BackendName
    name: str
    """Engine-side or on-disk identifier (the thing scripts/CLIs accept)."""

    lab: str | None = None
    """`lab-create.lab=<name>` label, or None if un-labelled."""

    svc: str | None = None
    """`lab-create.svc=<name>` label."""

    type: str = "unknown"
    """Free-form type tag: chroot | vm | container | instance | pod | profile | project."""

    status: ResourceStatus = "unknown"

    extra: dict = Field(default_factory=dict)
    """Backend-specific bag (qemu pid, image alias, project, etc.)."""

    spec_path: Path | None = None
    """Manifest/spec.toml path on disk (for the detail view), if any."""

    log_command: list[str] = Field(default_factory=list)
    """argv to invoke for the log tail; empty if backend has no log surface."""

    console_command: list[str] = Field(default_factory=list)
    """argv to invoke for an interactive console attach (full-TTY, blocking).
    Non-empty only when the backend has a serial/console surface AND the
    resource is currently running.  The TUI suspends itself, runs this as a
    blocking subprocess, then resumes when the command exits."""

    @property
    def display_name(self) -> str:
        """Tree-row label.  Prefer `lab/svc` over the engine-side name."""
        if self.lab and self.svc:
            return f"{self.lab}/{self.svc}"
        if self.lab:
            return f"{self.lab}/{self.name}"
        return self.name


class BackendRunner(ABC):
    """One subclass per phase script.  Methods mirror the phase CLI verbs."""

    name: ClassVar[BackendName]
    """Backend identifier (also the key the StateWatcher emits)."""

    script: ClassVar[Path]
    """Absolute path to the phase script (e.g., …/phase5-lxd/lab-lxd.sh)."""

    @classmethod
    def state_paths(cls) -> list[Path]:
        """Directories the StateWatcher should watch for this backend.

        Implemented as a classmethod (not a ClassVar) so the
        $LAB_STATE_DIR env var is resolved on each call — matters for
        tests that monkeypatch the env, and for honoring runtime
        overrides without re-importing.
        """
        return []

    # --- read paths -------------------------------------------------------

    @abstractmethod
    def list_resources(self, lab: str | None = None) -> list[Resource]:
        """Enumerate every resource the underlying backend manages.

        If `lab` is given, restrict to that lab.  Subclasses decide how
        (filter file-glob results or pass `--lab` to the engine query).
        """

    @abstractmethod
    def inspect(self, resource: Resource) -> str:
        """Return the YAML/TOML/text shown in the detail panel."""

    def is_available(self) -> bool:
        """True if this backend's underlying tooling is reachable.

        Default implementation: the phase script exists and is executable.
        Subclasses may override to also probe their daemon.
        """
        return self.script.exists() and os.access(self.script, os.X_OK)

    # --- mutating paths (default: dispatch to the phase script) ----------
    #
    # Subclasses can override if the underlying CLI needs different argv.

    def stop(self, resource: Resource) -> subprocess.CompletedProcess[str]:
        # Default: many backends use `down --lab` for lab-scoped tear-down,
        # which is the safer surface than per-instance stop.  Subclasses
        # that have a per-resource stop should override.
        raise NotImplementedError(
            f"{self.name}: stop not implemented (use destroy or override)"
        )

    def destroy(
        self, resource: Resource, force: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        argv = self.destroy_argv(resource, force=force)
        return run_capture(argv)

    @abstractmethod
    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        """argv that DESTROYS the resource — used by destroy() AND shown in
        the confirm modal so the user sees the literal command before they
        approve it."""


# --- helpers ------------------------------------------------------------


def phase_root() -> Path:
    """Repo root (the directory containing phase{1..6}-* dirs)."""
    return _PHASE_ROOT


def phase_script(rel: str) -> Path:
    """Resolve a phase-script path relative to the repo root."""
    return _PHASE_ROOT / rel


def run_capture(argv: list[str], *, env: dict | None = None) -> subprocess.CompletedProcess[str]:
    """Run `argv`, capture stdout+stderr, never raise on non-zero exit.

    Caller decides whether `cp.returncode != 0` is an error condition.
    Used for both engine queries (where non-zero often means "no daemon")
    and for actual mutations (where non-zero is a real failure to surface).
    """
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        env=env if env is not None else os.environ.copy(),
        check=False,
    )


def run_json(argv: list[str]) -> tuple[int, list | dict | None]:
    """Run `argv`; on success, parse stdout as JSON.

    Returns `(returncode, parsed_or_None)`.  Used by Phase 3/4/5 for
    `… ps --format=json` / `… list --format=json`.
    """
    import json

    cp = run_capture(argv)
    if cp.returncode != 0:
        return cp.returncode, None
    try:
        return cp.returncode, json.loads(cp.stdout) if cp.stdout.strip() else None
    except json.JSONDecodeError:
        return cp.returncode, None
