"""Phase 7 (Firecracker) backend — slice 6's first increment.

The load-bearing test here is the identity one. `vm.py` asks `os.kill(pid, 0)`, which
is true of ANY live process at that pid; this backend additionally requires
`firecracker` and THIS instance's `config.json` in the process's argv, because
REVIEW-phase7 P7-5 measured what the weaker check costs — one pidfile, three answers.
A backend that reported "running" about a recycled pid would be the same defect in a
different language, so it is asserted rather than assumed.

RUNNING THE NEGATIVE CONTROL ON THIS FILE — read before trusting a green result.
Reverting `fc_pid` to bare liveness in a COPY of the tree and running pytest from that
copy reported **12 passed**, because the venv's editable install still resolved
`lab_tui` to the original repo: the control had exercised the unreverted code and said
so with a clean tick.  Force the copy onto the path —

    PYTHONPATH=<copy>/phase6-tui pytest tests/test_backends_fc.py

— and it fails exactly twice, on `test_running_requires_our_own_firecracker` and
`test_another_instances_firecracker_is_not_ours`, which is the result that means
something.  Same class as the seam answering for the wrong instance that this repo has
been caught by before; here it was the import system doing the answering.
"""

from __future__ import annotations

import os
from pathlib import Path

from typing import get_args

from lab_tui.backends import ALL_BACKENDS
from lab_tui.backends.fc import FCBackend, fc_pid
from lab_tui.state import BackendName, state_subdir

MANIFEST = """\
name = "api1"
lab = "micro-cloud"
kernel = "/srv/vmlinux"
kernel_sha256 = "{k}"
rootfs = "{d}/rootfs.ext4"
rootfs_source = "/srv/api1.ext4"
rootfs_source_sha256 = "{r}"
tap = "mc-api1"
created = "2026-08-16T12:00:00Z"
"""


def _seed(state: Path, name: str = "api1", lab: str = "micro-cloud") -> Path:
    d = state / "fc" / name
    d.mkdir(parents=True)
    (d / "manifest.toml").write_text(
        MANIFEST.format(k="a" * 64, r="b" * 64, d=d).replace(
            'name = "api1"', f'name = "{name}"'
        ).replace('lab = "micro-cloud"', f'lab = "{lab}"')
    )
    (d / "config.json").write_text('{"boot-source": {}}\n')
    return d


# ── the inventory ────────────────────────────────────────────────────────────

def test_backend_is_registered() -> None:
    assert "fc" in [b.name for b in ALL_BACKENDS]


def test_every_registered_backend_name_is_a_declared_one() -> None:
    """Registration and the type both come from ONE list, and this keeps it that way.

    `BackendName` used to be declared independently in `state.py` AND `backends/base.py`
    — two enumerations of the same set, where adding a backend to one and forgetting the
    other type-checks fine and diverges silently.  "fc" would have been the first entry to
    land in one copy only.  base.py now imports the single definition; this asserts the
    OUTCOME (every registered backend is a declared one, and every declared one that keeps
    state has a directory) rather than the mechanism of where the literal lives.
    """
    declared = set(get_args(BackendName))
    registered = {b.name for b in ALL_BACKENDS}
    assert registered <= declared, f"registered but undeclared: {registered - declared}"
    assert "fc" in registered and "fc" in declared
    # A backend that keeps on-disk state must have a resolvable directory; state_subdir
    # raises for an unknown name, so this fails loudly rather than returning a wrong path.
    assert state_subdir("fc").name == "fc"


def test_lists_a_stopped_instance(fake_state_dir: Path) -> None:
    _seed(fake_state_dir)
    rs = FCBackend().list_resources()
    assert len(rs) == 1
    r = rs[0]
    assert (r.backend, r.name, r.lab, r.type, r.status) == (
        "fc", "api1", "micro-cloud", "microvm", "stopped",
    )
    assert r.extra["tap"] == "mc-api1"
    assert r.extra["kernel_sha256"] == "a" * 64
    assert r.spec_path is not None and r.spec_path.name == "manifest.toml"
    # No console attach: `firecracker --no-api` has no second socket, so offering
    # one would be a knob that does nothing.
    assert r.console_command == []


def test_log_command_only_when_a_console_log_exists(fake_state_dir: Path) -> None:
    d = _seed(fake_state_dir)
    assert FCBackend().list_resources()[0].log_command == []
    (d / "fc.log").write_text("[    0.000000] Linux version …\n")
    cmd = FCBackend().list_resources()[0].log_command
    assert cmd[0] == "tail" and cmd[-1].endswith("fc.log")


def test_lab_filter(fake_state_dir: Path) -> None:
    _seed(fake_state_dir, "api1", "micro-cloud")
    _seed(fake_state_dir, "other", "different-lab")
    assert [r.name for r in FCBackend().list_resources(lab="micro-cloud")] == ["api1"]
    assert len(FCBackend().list_resources()) == 2


def test_a_directory_without_a_manifest_is_skipped(fake_state_dir: Path) -> None:
    (fake_state_dir / "fc" / "half-made").mkdir(parents=True)
    assert FCBackend().list_resources() == []


def test_unparseable_manifest_is_skipped_not_raised(fake_state_dir: Path) -> None:
    d = fake_state_dir / "fc" / "broken"
    d.mkdir(parents=True)
    (d / "manifest.toml").write_text("name = \"unterminated\n")
    assert FCBackend().list_resources() == []


def test_missing_state_dir_is_empty_not_an_error(fake_state_dir: Path) -> None:
    assert FCBackend().list_resources() == []


# ── liveness is not identity (REVIEW-phase7 P7-5) ────────────────────────────

def test_running_requires_our_own_firecracker(fake_state_dir: Path) -> None:
    """A live pid that is NOT this instance's VMM must read as stopped.

    This is the exact fixture P5-7's shell counterpart uses: the test process
    itself is alive, and its argv contains neither `firecracker` nor the config
    path — so a bare `os.kill(pid, 0)` check would call it running.
    """
    d = _seed(fake_state_dir)
    (d / "fc.pid").write_text(str(os.getpid()))
    assert fc_pid(d) is None
    assert FCBackend().list_resources()[0].status == "stopped"


def test_running_is_reported_when_the_argv_matches(
    fake_state_dir: Path, monkeypatch,
) -> None:
    """...and the control: with a matching argv it MUST report running.

    Without this, `fc_pid` returning None unconditionally would satisfy every
    assertion above — a check that can only ever say 'stopped' is not a check.
    The argv is faked by pointing the reader at a file we control, which is the
    same seam /proc exposes (a NUL-separated byte blob).
    """
    d = _seed(fake_state_dir)
    (d / "fc.pid").write_text("4242")
    argv = d / "fake-cmdline"
    argv.write_bytes(
        b"firecracker\x00--no-api\x00--config-file\x00" + str(d / "config.json").encode() + b"\x00"
    )
    real_read_bytes = Path.read_bytes

    def fake_read_bytes(self: Path) -> bytes:
        if str(self) == "/proc/4242/cmdline":
            return real_read_bytes(argv)
        return real_read_bytes(self)

    monkeypatch.setattr(Path, "read_bytes", fake_read_bytes)
    assert fc_pid(d) == 4242
    r = FCBackend().list_resources()[0]
    assert r.status == "running"
    assert r.extra["pid"] == 4242


def test_another_instances_firecracker_is_not_ours(
    fake_state_dir: Path, monkeypatch,
) -> None:
    """`grep firecracker` alone cannot tell two instances apart; the config path can.

    This is the second half of P7-5 — a pid running SOME firecracker, recycled onto
    or recorded against the wrong instance.
    """
    mine = _seed(fake_state_dir, "api1")
    theirs = _seed(fake_state_dir, "api2")
    (mine / "fc.pid").write_text("4242")
    argv = fake_state_dir / "other-cmdline"
    argv.write_bytes(
        b"firecracker\x00--no-api\x00--config-file\x00"
        + str(theirs / "config.json").encode() + b"\x00"
    )
    real_read_bytes = Path.read_bytes

    def fake_read_bytes(self: Path) -> bytes:
        if str(self) == "/proc/4242/cmdline":
            return real_read_bytes(argv)
        return real_read_bytes(self)

    monkeypatch.setattr(Path, "read_bytes", fake_read_bytes)
    assert fc_pid(mine) is None


def test_garbage_pidfile_is_not_running(fake_state_dir: Path) -> None:
    d = _seed(fake_state_dir)
    for junk in ("", "not-a-pid", "-1", "0"):
        (d / "fc.pid").write_text(junk)
        assert fc_pid(d) is None, f"pidfile {junk!r} was treated as a live pid"


# ── argv the confirm modal shows the user ────────────────────────────────────

def test_destroy_argv_has_no_double_dash(fake_state_dir: Path) -> None:
    """The opposite of vm.py, and deliberately so.

    Phase 7's arg loop rejects ANY `-`-leading token (`-*) die "unknown flag"`), so a
    `--` separator would be refused outright. It is unnecessary because the positional
    is validated against `^[a-z][a-z0-9-]{0,30}$` before becoming a path component
    (REVIEW-phase7 P7-3), so a hostile name fails closed at the driver.
    """
    _seed(fake_state_dir)
    r = FCBackend().list_resources()[0]
    argv = FCBackend().destroy_argv(r)
    assert "--" not in argv
    assert argv[-2:] == ["destroy", "api1"]
    assert "sudo" not in argv          # phase 7 is unprivileged by design
    assert FCBackend().destroy_argv(r, force=True)[-1] == "--force"
