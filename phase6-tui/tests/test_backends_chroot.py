from __future__ import annotations

import shutil
from pathlib import Path

from lab_tui.backends.chroot import ChrootBackend


def test_list_resources_built_status(fake_state_dir: Path, fixtures_dir: Path) -> None:
    """A chroot whose `target` exists shows status='built'."""
    # Copy the "real" manifest in, then ensure its target exists.
    shutil.copy(fixtures_dir / "chroot-debian-bookworm.toml",
                fake_state_dir / "chroots" / "debian-bookworm.toml")
    (fake_state_dir / "fake-chroot-target").mkdir()
    # Patch the target path inside the manifest to point at the temp dir.
    manifest = fake_state_dir / "chroots" / "debian-bookworm.toml"
    text = manifest.read_text().replace(
        "/var/chroots/debian-bookworm",
        str(fake_state_dir / "fake-chroot-target"),
    )
    manifest.write_text(text)

    rs = ChrootBackend().list_resources()
    assert len(rs) == 1
    r = rs[0]
    assert r.backend == "chroot"
    assert r.name == "debian-bookworm"
    assert r.lab == "demo"
    assert r.status == "built"
    assert r.type == "chroot"
    assert r.extra["distro"] == "debian"
    assert r.extra["manager"] == "schroot"


def test_list_resources_missing_status(fake_state_dir: Path, fixtures_dir: Path) -> None:
    """A chroot whose `target` does NOT exist shows status='missing'."""
    shutil.copy(fixtures_dir / "chroot-orphan.toml",
                fake_state_dir / "chroots" / "kali-amd64.toml")
    rs = ChrootBackend().list_resources()
    assert len(rs) == 1
    assert rs[0].name == "kali-amd64"
    assert rs[0].status == "missing"
    assert rs[0].lab is None  # empty string in manifest → None on the model


def test_list_resources_lab_filter(fake_state_dir: Path, fixtures_dir: Path) -> None:
    shutil.copy(fixtures_dir / "chroot-debian-bookworm.toml",
                fake_state_dir / "chroots" / "demo-c.toml")
    shutil.copy(fixtures_dir / "chroot-orphan.toml",
                fake_state_dir / "chroots" / "orphan.toml")
    assert len(ChrootBackend().list_resources(lab="demo")) == 1
    assert len(ChrootBackend().list_resources(lab="nonexistent")) == 0
    assert len(ChrootBackend().list_resources()) == 2  # no filter


def test_destroy_argv_uses_phase_script() -> None:
    b = ChrootBackend()
    argv = b.destroy_argv(  # type: ignore[arg-type]
        type("R", (), {"name": "foo"})()  # noqa: SLF001
    )
    # sudo may or may not be present depending on the host.
    assert argv[-3:] == [str(b.script), "destroy", "foo"]


def test_inspect_prefers_inspect_json_when_available(
    fake_state_dir: Path,
    fixtures_dir: Path,
    monkeypatch,
) -> None:
    """When Phase 1's `inspect --json` returns valid JSON, the backend
    should pretty-print it instead of falling back to the raw manifest."""
    import subprocess
    import lab_tui.backends.chroot as chroot_mod

    shutil.copy(fixtures_dir / "chroot-debian-bookworm.toml",
                fake_state_dir / "chroots" / "debian-bookworm.toml")
    rs = ChrootBackend().list_resources()
    assert len(rs) == 1
    target = rs[0]

    fake_doc = {
        "schema_version": 1,
        "name": target.name,
        "manifest": {"name": target.name, "manager": "schroot"},
        "target": {"path": "/x", "exists": True, "size_bytes": 4096},
    }

    def fake_run_capture(argv, *, env=None):
        if argv[1:3] == ["inspect", target.name] and "--json" in argv:
            import json as _j
            return subprocess.CompletedProcess(argv, 0, _j.dumps(fake_doc), "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected")

    monkeypatch.setattr(chroot_mod, "run_capture", fake_run_capture)
    out = ChrootBackend().inspect(target)
    # Pretty-printed JSON, two-space indent.
    assert '"schema_version": 1' in out
    assert '"size_bytes": 4096' in out


def test_inspect_falls_back_to_manifest_when_inspect_fails(
    fake_state_dir: Path,
    fixtures_dir: Path,
    monkeypatch,
) -> None:
    """If `inspect --json` exits non-zero or returns garbage, the
    backend gracefully falls back to the raw manifest TOML."""
    import subprocess
    import lab_tui.backends.chroot as chroot_mod

    shutil.copy(fixtures_dir / "chroot-debian-bookworm.toml",
                fake_state_dir / "chroots" / "debian-bookworm.toml")
    rs = ChrootBackend().list_resources()
    target = rs[0]

    monkeypatch.setattr(
        chroot_mod, "run_capture",
        lambda argv, *, env=None: subprocess.CompletedProcess(argv, 1, "",
                                                              "no such verb"),
    )
    out = ChrootBackend().inspect(target)
    # Manifest fallback contains the literal field names.
    assert "backend    = \"debootstrap\"" in out
    assert "distro     = \"debian\"" in out
