"""Tests for the five phase create-wizards.

All tests exercise generate_toml() directly — no Textual pilot needed
because generate_toml() is pure logic.  We mock the widget-query helpers
(_val, _sel, _chk) by monkey-patching them on the wizard instance so the
method can be called without a running Textual app.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

# ── helpers ──────────────────────────────────────────────────────────────────

def _make_wizard(cls, vals: dict[str, str], sels: dict[str, str],
                 chks: dict[str, bool] | None = None):
    """Instantiate *cls* without a Textual app and patch the query helpers."""
    chks = chks or {}
    obj = object.__new__(cls)

    def _val(wid, _self):
        return vals.get(wid, "")

    def _sel(wid, _self):
        return sels.get(wid, "")

    def _chk(wid, _self):
        return chks.get(wid, False)

    with patch.object(cls, "_val", staticmethod(_val)), \
         patch.object(cls, "_sel", staticmethod(_sel)), \
         patch.object(cls, "_chk", staticmethod(_chk)):
        toml = obj.generate_toml()

    return toml


def _make_hint(cls, vals: dict[str, str], sels: dict[str, str],
               chks: dict[str, bool] | None = None,
               path: str = "examples/test.toml") -> str:
    """Call run_hint() on *cls* with patched query helpers, return the hint string."""
    from pathlib import Path as _Path
    chks = chks or {}
    obj = object.__new__(cls)

    def _val(wid, _self):
        return vals.get(wid, "")

    def _sel(wid, _self):
        return sels.get(wid, "")

    def _chk(wid, _self):
        return chks.get(wid, False)

    with patch.object(cls, "_val", staticmethod(_val)), \
         patch.object(cls, "_sel", staticmethod(_sel)), \
         patch.object(cls, "_chk", staticmethod(_chk)):
        return obj.run_hint(_Path(path))


# ── Phase 1: ChrootWizard ────────────────────────────────────────────────────

class TestChrootWizard:
    from lab_tui.screens.wizards.phase1 import ChrootWizard as _cls

    def _toml(self, vals=None, sels=None, chks=None) -> str:
        from lab_tui.screens.wizards.phase1 import ChrootWizard
        return _make_wizard(ChrootWizard, vals or {}, sels or {}, chks)

    def test_minimal_generates_chroot_table(self) -> None:
        toml = self._toml(
            vals={"f-name": "my-chroot", "f-suite": "bookworm"},
            sels={"f-backend": "debootstrap", "f-arch": "x86_64",
                  "f-distro": "debian", "f-manager": "none"},
        )
        assert '[[chroot]]' in toml
        assert 'name    = "my-chroot"' in toml
        assert 'backend = "debootstrap"' in toml
        assert 'distro  = "debian"' in toml
        assert 'suite   = "bookworm"' in toml
        assert 'arch    = "x86_64"' in toml
        assert 'manager = "none"' in toml

    def test_packages_emitted_as_include_array(self) -> None:
        toml = self._toml(
            vals={"f-name": "k", "f-pkgs": "curl,vim"},
            sels={"f-backend": "debootstrap"},
        )
        assert 'include = ["curl", "vim"]' in toml

    def test_init_script_emitted(self) -> None:
        toml = self._toml(
            vals={"f-name": "x"},
            sels={"f-backend": "debootstrap", "f-init": "busybox"},
        )
        assert 'init_script = "busybox"' in toml

    def test_missing_name_uses_placeholder(self) -> None:
        toml = self._toml(sels={"f-backend": "debootstrap"})
        assert '"<name>"' in toml

    def test_run_hint_contains_create_command(self) -> None:
        from lab_tui.screens.wizards.phase1 import ChrootWizard
        hint = _make_hint(ChrootWizard, {"f-name": "mychroot"}, {})
        assert "lab-chroot.sh" in hint
        assert "create" in hint
        assert "mychroot" in hint


# ── Phase 2: VMWizard ─────────────────────────────────────────────────────────

class TestVMWizard:

    def _toml(self, vals=None, sels=None, chks=None) -> str:
        from lab_tui.screens.wizards.phase2 import VMWizard
        return _make_wizard(VMWizard, vals or {}, sels or {}, chks)

    def test_minimal_generates_vm_table(self) -> None:
        toml = self._toml(
            vals={"f-name": "my-vm"},
            sels={"f-backend": "disk-image", "f-distro": "debian",
                  "f-arch": "x86_64", "f-memory": "2G", "f-cpus": "2"},
        )
        assert '[[vm]]' in toml
        assert 'name    = "my-vm"' in toml
        assert 'backend = "disk-image"' in toml
        assert 'distro  = "debian"' in toml
        assert 'memory  = "2G"' in toml
        assert 'cpus    = 2' in toml

    def test_microvm_flag_emitted_when_checked(self) -> None:
        toml = self._toml(
            vals={"f-name": "tiny"},
            sels={"f-backend": "kernel+initrd", "f-arch": "x86_64",
                  "f-memory": "256M", "f-cpus": "1"},
            chks={"f-microvm": True},
        )
        assert "microvm = true" in toml

    def test_cloud_init_disabled_flag(self) -> None:
        toml = self._toml(
            vals={"f-name": "pxe"},
            sels={"f-backend": "pxe-install", "f-arch": "x86_64",
                  "f-memory": "2G", "f-cpus": "2"},
            chks={"f-nocloudinit": True},
        )
        assert "cloud_init = false" in toml

    def test_lab_field_emitted_when_set(self) -> None:
        toml = self._toml(
            vals={"f-name": "vm1", "f-lab": "mylab"},
            sels={"f-backend": "disk-image", "f-arch": "x86_64",
                  "f-memory": "1G", "f-cpus": "1"},
        )
        assert 'lab     = "mylab"' in toml

    def test_run_hint_contains_create_and_start(self) -> None:
        from lab_tui.screens.wizards.phase2 import VMWizard
        hint = _make_hint(VMWizard, {"f-name": "myvm"}, {})
        assert "lab-vm.sh" in hint
        assert "create" in hint
        assert "start" in hint
        assert "myvm" in hint


# ── Phase 3: DockerServiceWizard ──────────────────────────────────────────────

class TestDockerServiceWizard:

    def _toml(self, vals=None) -> str:
        from lab_tui.screens.wizards.phase3 import DockerServiceWizard
        return _make_wizard(DockerServiceWizard, vals or {}, {})

    def test_minimal_has_all_sections(self) -> None:
        toml = self._toml({"f-lab": "demo", "f-svc": "web", "f-image": "nginx:alpine"})
        assert '[lab]' in toml
        assert 'name = "demo"' in toml
        assert '[network.' in toml
        assert '[[service]]' in toml
        assert 'name     = "web"' in toml
        assert 'image    = "nginx:alpine"' in toml

    def test_ports_emitted_as_array(self) -> None:
        toml = self._toml({
            "f-lab": "x", "f-svc": "web", "f-image": "nginx",
            "f-ports": "8080:80, 8443:443",
        })
        assert '"8080:80"' in toml
        assert '"8443:443"' in toml

    def test_env_vars_as_table(self) -> None:
        toml = self._toml({
            "f-lab": "x", "f-svc": "db", "f-image": "postgres",
            "f-env": "POSTGRES_PASSWORD=lab",
        })
        assert "POSTGRES_PASSWORD" in toml
        assert '"lab"' in toml

    def test_second_service_optional(self) -> None:
        toml = self._toml({
            "f-lab": "demo", "f-svc": "web", "f-image": "nginx",
            "f-svc2": "db:postgres:16-alpine",
        })
        assert toml.count("[[service]]") == 2
        assert '"db"' in toml
        assert '"postgres:16-alpine"' in toml

    def test_second_service_absent_when_empty(self) -> None:
        toml = self._toml({"f-lab": "demo", "f-svc": "web", "f-image": "nginx"})
        assert toml.count("[[service]]") == 1

    def test_run_hint_contains_up_and_down(self) -> None:
        from lab_tui.screens.wizards.phase3 import DockerServiceWizard
        hint = _make_hint(DockerServiceWizard, {"f-lab": "mylab"}, {})
        assert "lab-docker.sh" in hint
        assert "up" in hint
        assert "down" in hint
        assert "mylab" in hint


# ── Phase 4: PodmanServiceWizard ─────────────────────────────────────────────

class TestPodmanServiceWizard:

    def _toml(self, vals=None, sels=None, chks=None) -> str:
        from lab_tui.screens.wizards.phase4 import PodmanServiceWizard
        return _make_wizard(PodmanServiceWizard, vals or {}, sels or {}, chks)

    def test_plain_manager(self) -> None:
        toml = self._toml(
            vals={"f-lab": "srv", "f-svc": "http", "f-image": "nginx:alpine"},
            sels={"f-manager": "plain"},
        )
        assert '[lab]' in toml
        assert 'name = "srv"' in toml
        assert '[[service]]' in toml
        assert 'engine = "podman"' in toml
        assert 'image  = "nginx:alpine"' in toml

    def test_pod_manager_emits_pod_block(self) -> None:
        toml = self._toml(
            vals={"f-lab": "p", "f-svc": "app", "f-image": "alpine",
                  "f-pod": "mypod"},
            sels={"f-manager": "pod"},
        )
        assert "[[pod]]" in toml
        assert 'name = "mypod"' in toml
        assert 'pod    = "mypod"' in toml

    def test_quadlet_note_in_header_comment(self) -> None:
        toml = self._toml(
            vals={"f-lab": "q", "f-svc": "svc", "f-image": "img"},
            sels={"f-manager": "quadlet"},
        )
        assert "generate" in toml.lower()

    def test_ports_and_volumes(self) -> None:
        toml = self._toml(
            vals={"f-lab": "x", "f-svc": "s", "f-image": "i",
                  "f-ports": "8080:80", "f-vols": "/data:/data:ro"},
            sels={"f-manager": "plain"},
        )
        assert '"8080:80"' in toml
        assert '"/data:/data:ro"' in toml

    def test_run_hint_contains_up_and_down(self) -> None:
        from lab_tui.screens.wizards.phase4 import PodmanServiceWizard
        hint = _make_hint(PodmanServiceWizard, {"f-lab": "mylab"}, {"f-manager": "plain"})
        assert "lab-podman.sh" in hint
        assert "up" in hint
        assert "down" in hint
        assert "mylab" in hint


# ── Phase 5: LXDInstanceWizard ────────────────────────────────────────────────

class TestLXDInstanceWizard:

    def _toml(self, vals=None, sels=None) -> str:
        from lab_tui.screens.wizards.phase5 import LXDInstanceWizard
        return _make_wizard(LXDInstanceWizard, vals or {}, sels or {})

    def test_minimal_container(self) -> None:
        toml = self._toml(
            vals={"f-lab": "mylab", "f-name": "shell"},
            sels={"f-type": "container",
                  "f-image-sel": "images:alpine/latest"},
        )
        assert '[lab]' in toml
        assert 'name = "mylab"' in toml
        assert '[[instance]]' in toml
        assert 'name  = "shell"' in toml
        assert 'type  = "container"' in toml
        assert 'image = "images:alpine/latest"' in toml

    def test_vm_type(self) -> None:
        toml = self._toml(
            vals={"f-lab": "x", "f-name": "worker"},
            sels={"f-type": "vm", "f-image-sel": "images:debian/bookworm"},
        )
        assert 'type  = "vm"' in toml

    def test_custom_image_overrides_quick_select(self) -> None:
        toml = self._toml(
            vals={"f-lab": "x", "f-name": "a", "f-image-custom": "images:kali/rolling"},
            sels={"f-type": "container", "f-image-sel": "images:alpine/latest"},
        )
        assert 'images:kali/rolling' in toml
        assert 'images:alpine/latest' not in toml

    def test_profiles_as_array(self) -> None:
        toml = self._toml(
            vals={"f-lab": "x", "f-name": "a", "f-profiles": "default,webnode"},
            sels={"f-type": "container"},
        )
        assert '"default"' in toml and '"webnode"' in toml

    def test_config_key_value_pairs(self) -> None:
        toml = self._toml(
            vals={"f-lab": "x", "f-name": "a",
                  "f-config": "security.secureboot=false,limits.cpu=2"},
            sels={"f-type": "vm"},
        )
        assert "security.secureboot" in toml
        assert '"false"' in toml
        assert "limits.cpu" in toml

    def test_storage_and_project(self) -> None:
        toml = self._toml(
            vals={"f-lab": "x", "f-name": "a",
                  "f-storage": "vmpool", "f-project": "demo"},
            sels={"f-type": "container"},
        )
        assert 'storage = "vmpool"' in toml
        assert 'project = "demo"' in toml

    def test_run_hint_contains_up_and_down(self) -> None:
        from lab_tui.screens.wizards.phase5 import LXDInstanceWizard
        hint = _make_hint(LXDInstanceWizard, {"f-lab": "mylab"}, {"f-type": "container"})
        assert "lab-lxd.sh" in hint
        assert "up" in hint
        assert "down" in hint
        assert "mylab" in hint
