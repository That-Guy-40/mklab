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
