"""Phase 7 (Firecracker microVM) backend — slice 6's first increment.

Per-instance state at `$LAB_STATE_DIR/fc/<name>/`:
  manifest.toml  — name, lab, kernel, kernel_sha256, rootfs, rootfs_source,
                   rootfs_source_sha256, tap, created
  config.json    — the generated Firecracker config (also the identity marker below)
  fc.pid         — written by `lab-fc.sh start`
  fc.log         — the guest's console, appended per boot (tailable)
  rootfs.ext4    — the per-instance copy

WHY THIS READS THE STATE DIRECTORY RATHER THAN SHELLING OUT
-----------------------------------------------------------
Same shape as `vm.py`: an inventory that forks a shell per instance is slow and
turns a read into a write-capable surface.  `lab-fc.sh list --json` exists and is
fine, but it reports only `{name, state}` — the detail panel needs the manifest,
so the manifest is what we read.

LIVENESS IS NOT IDENTITY — the one place this backend deliberately differs from
`vm.py`.  `vm.py` asks `os.kill(pid, 0)`, which is true of *any* live process at
that pid.  REVIEW-phase7 P7-5 measured what that costs: with an unrelated
`sleep 600`'s pid in the pidfile, `list` said **running**, `start` refused as
"already running", and `stop` said "was not running" — one pidfile, three answers.
`lab-fc.sh` was fixed to bind the check to the instance's own config path, which is
unique per instance and appears in firecracker's argv.  This backend does the same
check rather than re-introducing the weaker one in Python, because a TUI that says
"running" about a recycled pid is the same defect wearing a different language.
"""

from __future__ import annotations

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


def fc_pid(inst_dir: Path) -> int | None:
    """The pid iff THIS instance's firecracker is alive there, else None.

    Mirrors `lab-fc.sh`'s `_running_pid`: numeric pid, live process, `firecracker`
    in its argv, AND this instance's `config.json` in its argv.  The last clause is
    what distinguishes *our* VMM from a recycled pid or from another instance's.
    """
    try:
        pid = int((inst_dir / "fc.pid").read_text().strip())
    except (OSError, ValueError):
        return None
    if pid <= 0:
        return None
    try:
        cmdline = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        # No such pid, or no /proc.  Either way we cannot claim it is ours.
        return None
    if b"firecracker" not in cmdline:
        return None
    if str(inst_dir / "config.json").encode() not in cmdline:
        return None
    return pid


class FCBackend(BackendRunner):
    name: ClassVar = "fc"
    script: ClassVar[Path] = phase_script("phase7-firecracker/lab-fc.sh")

    @classmethod
    def state_paths(cls) -> list[Path]:
        return [state_subdir("fc")]

    def list_resources(self, lab: str | None = None) -> list[Resource]:
        out: list[Resource] = []
        root = state_subdir("fc")
        for inst in sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []:
            mp = inst / "manifest.toml"
            if not mp.is_file():
                continue
            try:
                data = tomllib.loads(mp.read_text())
            except (OSError, tomllib.TOMLDecodeError):
                continue
            this_lab = (data.get("lab") or "") or None
            if lab is not None and this_lab != lab:
                continue
            pid = fc_pid(inst)
            log_path = inst / "fc.log"
            extra = {k: v for k, v in data.items() if k not in {"name", "lab"}}
            if pid is not None:
                extra["pid"] = pid
            out.append(Resource(
                backend="fc",
                name=data.get("name", inst.name),
                lab=this_lab,
                svc=None,
                type="microvm",
                status="running" if pid is not None else "stopped",
                extra=extra,
                spec_path=mp,
                log_command=(
                    ["tail", "-n", "200", "-F", str(log_path)]
                    if log_path.is_file() else []
                ),
                # NO console attach, and that is a property of the engine rather than
                # an omission: `lab-fc.sh` runs `firecracker --no-api`, whose guest
                # console is the redirected stdout already tailed above.  There is no
                # second socket to attach to, so offering an attach button would be a
                # knob that does nothing — the defect phase 7's own `--force` had.
                console_command=[],
            ))
        return out

    def inspect(self, resource: Resource) -> str:
        # `lab-fc.sh inspect` prints the manifest plus live rows the manifest cannot
        # carry: state, pid, and a THREE-OUTCOME digest check per artifact
        # (match / CHANGED since create / UNKNOWN).  That is worth a fork here —
        # unlike the inventory above, this is one instance, on demand, and the
        # digest comparison is the whole point of the detail view.
        cp = run_capture([str(self.script), "inspect", resource.name])
        if cp.returncode == 0 and cp.stdout.strip():
            return cp.stdout
        if resource.spec_path and resource.spec_path.is_file():
            return resource.spec_path.read_text()
        return f"# no manifest on disk for {resource.name}"

    def stop(self, resource: Resource):
        # Phase 7 has a real per-instance stop that asserts the outcome (it polls
        # until the process is gone rather than trusting kill(2)), so unlike the
        # container backends this one does not need to fall back to a lab-scoped down.
        return run_capture([str(self.script), "stop", resource.name, "--force"])

    def destroy_argv(self, resource: Resource, force: bool = False) -> list[str]:
        # No sudo: `lab-fc.sh` keeps its state under $XDG_STATE_HOME for non-root
        # callers and micro-cloud drives it unprivileged throughout.
        #
        # And NO `--` separator, deliberately — the opposite of `vm.py`.  Phase 7's
        # arg loop treats ANY `-`-leading token as a flag (`-*) die "unknown flag"`),
        # so a `--` would be rejected outright.  It is unnecessary anyway: the
        # positional is validated against `^[a-z][a-z0-9-]{0,30}$` before it is used
        # as a path component (REVIEW-phase7 P7-3), so a hostile name fails closed.
        argv = [str(self.script), "destroy", resource.name]
        if force:
            argv.append("--force")
        return argv
