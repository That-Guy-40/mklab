"""LAB_STATE_DIR resolution + a watchfiles-backed state watcher.

Phase 1/2/4/5 write to `$LAB_STATE_DIR/{chroots,vms,podman,lxd}/`; Phase 3
is label-only (no filesystem signal). The watcher subscribes to the
filesystem-backed paths and tops up Phase 3 with a low-frequency timer,
yielding the *backend name* whose surface changed so the UI re-runs only
that backend's `list_resources()`.

Mirrors how the bash phase scripts resolve LAB_STATE_DIR — XDG-style for
unprivileged invocations, /var/lib/lab-create when running as root.
"""

from __future__ import annotations

import asyncio
import os
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Literal

from watchfiles import Change, awatch

BackendName = Literal["chroot", "vm", "docker", "podman", "lxd"]

# Which backends we tick on the timer (no filesystem trigger).
_POLLED_BACKENDS: frozenset[BackendName] = frozenset({"docker"})

# How often to fire the polling tick.  Matches the spec's 5-second cadence.
POLL_INTERVAL_S: float = 5.0


def lab_state_dir() -> Path:
    """Resolve $LAB_STATE_DIR identically to the bash phase scripts.

    Order of precedence:
      1. $LAB_STATE_DIR (explicit override)
      2. /var/lib/lab-create when running as root
      3. $XDG_STATE_HOME/lab-create (or $HOME/.local/state/lab-create)
    """
    explicit = os.environ.get("LAB_STATE_DIR")
    if explicit:
        return Path(explicit)
    if os.geteuid() == 0:
        return Path("/var/lib/lab-create")
    xdg = os.environ.get("XDG_STATE_HOME")
    base = Path(xdg) if xdg else Path.home() / ".local" / "state"
    return base / "lab-create"


def state_subdir(backend: BackendName) -> Path:
    """Per-backend subdirectory under LAB_STATE_DIR."""
    root = lab_state_dir()
    match backend:
        case "chroot": return root / "chroots"
        case "vm":     return root / "vms"
        case "podman": return root / "podman"
        case "lxd":    return root / "lxd"
        case "docker": return root  # docker has no on-disk state; placeholder
    raise ValueError(f"unknown backend: {backend}")


# Map of backend → directory whose changes mean "this backend's inventory
# may have shifted".  Docker is intentionally absent (label-only).
_FS_BACKENDS: dict[BackendName, Path] = {
    b: state_subdir(b) for b in ("chroot", "vm", "podman", "lxd")
}


async def watch_state() -> AsyncIterator[BackendName]:
    """Yield the BackendName of any backend whose surface just changed.

    Combines two sources:
      * watchfiles.awatch over the four file-backed state subdirs.
      * an asyncio timer that yields each polled backend on a fixed cadence.

    Yields are coalesced naturally — if 50 files appear in `lxd/` at once,
    one `"lxd"` lands per `awatch` notification, which is fine because the
    consumer just re-lists for that backend.
    """
    # Make sure target dirs exist so watchfiles doesn't error out on a
    # fresh host that's never run a phase script.  We create them as
    # 0o700 so we don't accidentally widen permissions for shared dirs.
    # F-11: mkdir(mode=0o700) only applies the mode to the *leaf* directory;
    # intermediate parents get the process umask.  Walk the path and chmod
    # each component that we create so the full tree is owner-only.
    for path in _FS_BACKENDS.values():
        parts: list[Path] = []
        p = path
        while not p.exists():
            parts.append(p)
            p = p.parent
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        for created in reversed(parts):
            try:
                created.chmod(0o700)
            except OSError:
                pass

    # We need to match a Change back to a backend.  Build a (path → name)
    # lookup that resolves the longest matching prefix.
    prefix_lookup: list[tuple[Path, BackendName]] = sorted(
        _FS_BACKENDS.items(), key=lambda kv: -len(str(kv[1])),
    )  # type: ignore[assignment]

    def classify(change_path: str) -> BackendName | None:
        cp = Path(change_path)
        for backend, root in prefix_lookup:
            try:
                cp.relative_to(root)
                return backend
            except ValueError:
                continue
        return None

    queue: asyncio.Queue[BackendName] = asyncio.Queue()

    async def _fs_pump() -> None:
        async for changes in awatch(*_FS_BACKENDS.values(), recursive=True):
            seen: set[BackendName] = set()
            for _change, path in changes:
                backend = classify(path)
                if backend and backend not in seen:
                    seen.add(backend)
                    await queue.put(backend)

    async def _tick_pump() -> None:
        while True:
            await asyncio.sleep(POLL_INTERVAL_S)
            for backend in _POLLED_BACKENDS:
                await queue.put(backend)

    fs_task = asyncio.create_task(_fs_pump(), name="state-fs-watcher")
    tick_task = asyncio.create_task(_tick_pump(), name="state-tick")

    try:
        while True:
            yield await queue.get()
    finally:
        fs_task.cancel()
        tick_task.cancel()
        # Swallow cancellations cleanly.
        for t in (fs_task, tick_task):
            try:
                await t
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass


# Re-export for tests that want to drive the classifier directly.
__all__ = [
    "BackendName",
    "POLL_INTERVAL_S",
    "lab_state_dir",
    "state_subdir",
    "watch_state",
]
