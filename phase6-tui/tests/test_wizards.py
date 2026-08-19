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


# ── Phase 7: MicroVMWizard ───────────────────────────────────────────────────

class TestMicroVMWizard:
    """MICRO_CLOUD_LAB_PLAN §8.2's second gap: 'no microvm wizard'.

    Every field here is a key `lab-fc.sh` already parses. That is the point rather than a
    coincidence — §0.2's invariant says the guided path is a VIEW of the raw path, so a
    wizard offering a knob the tool does not have would be a parallel implementation with a
    form on it. `test_every_field_is_a_key_the_tool_parses` asserts it against the tool's
    own KNOWN_KEYS rather than against a list copied into this file.
    """

    def _wiz(self, vals=None, sels=None, chks=None):
        from lab_tui.screens.wizards.phase7 import MicroVMWizard
        return _make_wizard(MicroVMWizard, vals or {}, sels or {}, chks or {})

    def test_minimal_toml_has_the_required_keys(self) -> None:
        toml = (self._wiz(
            vals={"f-name": "api1", "f-kernel": "/k/vmlinux", "f-rootfs": "/r/api1.ext4"},
            sels={"f-memory": "256M", "f-vcpus": "1"}))
        assert "[[microvm]]" in toml
        assert 'name    = "api1"' in toml
        assert 'kernel  = "/k/vmlinux"' in toml
        assert 'rootfs  = "/r/api1.ext4"' in toml
        assert 'memory  = "256M"' in toml
        assert "vcpus   = 1" in toml

    def test_optional_keys_are_omitted_when_blank(self) -> None:
        """An empty field must not become an empty VALUE.

        `tap = ""` is not "no tap" to lab-fc.sh — it is a tap named the empty string, and
        the config generator emits a network block iff a tap is set. A wizard that wrote
        blank keys would be handing the tool a spec that says something the operator did
        not.
        """
        toml = (self._wiz(vals={"f-name": "api1"}))
        for key in ("tap", "ip", "gateway", "netmask", "mac", "lab", "append"):
            assert f"{key} " not in toml, f"blank field '{key}' was written into the spec"
        assert "mmds" not in toml

    def test_mmds_is_written_only_when_checked(self) -> None:
        assert "mmds    = true" in (self._wiz(
            vals={"f-name": "api1", "f-tap": "mc-api1"}, chks={"f-mmds": True}))
        assert "mmds" not in (self._wiz(vals={"f-name": "api1"}))

    def test_free_text_is_escaped(self) -> None:
        """F-01, the framework's own signature bug: a value that breaks the TOML.

        `_toml_str` exists because a multi-line paste once wrote a broken spec to disk
        while the preview said "(invalid input)" — the record disagreeing with reality,
        inside the wizard code.
        """
        toml = (self._wiz(vals={"f-name": 'a"b', "f-append": "x\ny"}))
        assert 'a\\"b' in toml
        assert "\\n" in toml
        # The generated spec must still be one key per line.
        for line in toml.splitlines():
            assert line.count("=") == 0 or not line.strip().startswith('"')

    def test_run_hint_walks_preflight_dryrun_create_start(self) -> None:
        """The hint is a teaching ladder, and the order is the lesson.

        preflight and --dry-run come BEFORE create on purpose: phase 7's own design refuses
        before the irreversible step, and a hint that opened with `create` would teach the
        opposite of what the tool is built around.
        """
        hint = _make_hint(_cls7(), {"f-name": "api1"}, {})
        for verb in ("preflight", "create --config", "--dry-run", "start api1",
                     "inspect api1", "stop api1", "destroy api1"):
            assert verb in hint, f"the hint never mentions '{verb}'"
        assert hint.index("preflight") < hint.index("--dry-run") < hint.index("start api1")

    def test_the_fabric_step_appears_only_when_a_tap_was_named(self) -> None:
        """`fabric.sh tap` needs root. Telling someone to run a privileged command they do
        not need is how a guided path teaches a superstition — so the step is conditional."""
        with_tap = _make_hint(_cls7(), {"f-name": "api1", "f-tap": "mc-api1"}, {})
        assert "fabric.sh tap" in with_tap
        assert "sudo" in with_tap
        without = _make_hint(_cls7(), {"f-name": "api1"}, {})
        assert "fabric.sh" not in without

    def test_every_field_is_a_key_the_tool_parses(self) -> None:
        """§0.2: the guided path is a VIEW. A field the tool has no key for is an invention.

        Read from lab-fc.sh's KNOWN_KEYS, not from a list duplicated here — a copy would go
        stale exactly when the schema changed, which is the moment this test matters.
        """
        import re
        from pathlib import Path as _P
        tool = _P(__file__).resolve().parents[2] / "phase7-firecracker" / "lab-fc.sh"
        m = re.search(r'^readonly KNOWN_KEYS="([^"]*)"', tool.read_text(), re.M)
        assert m, "could not read KNOWN_KEYS out of lab-fc.sh — the tool's schema moved"
        known = set(m.group(1).split())

        toml = (self._wiz(
            vals={"f-name": "a", "f-kernel": "k", "f-rootfs": "r", "f-tap": "t",
                  "f-ip": "1.2.3.4", "f-gateway": "1.2.3.1", "f-netmask": "255.255.255.0",
                  "f-mac": "06:00:ac:47:00:01", "f-lab": "l", "f-append": "quiet"},
            sels={"f-memory": "256M", "f-vcpus": "2"}, chks={"f-mmds": True}))
        emitted = {ln.split("=")[0].strip() for ln in toml.splitlines()
                   if "=" in ln and not ln.strip().startswith("#")}
        unknown = emitted - known
        assert not unknown, (
            f"the wizard writes key(s) lab-fc.sh does not parse: {sorted(unknown)} — "
            "a guided path that can express something the CLI cannot is a parallel "
            "implementation, which is exactly what §0.2 forbids")


def _cls7():
    from lab_tui.screens.wizards.phase7 import MicroVMWizard
    return MicroVMWizard


# ── the three registries must agree ──────────────────────────────────────────

def test_every_wizard_in_the_package_is_reachable_from_the_ui() -> None:
    """A wizard is registered in THREE places, and a wizard in only some of them is a
    guided surface that either cannot be opened or is not offered.

    tools/check-guided-path-is-a-view.sh discovers wizards from the PACKAGE, so one that is
    exported but absent from the picker would pass that checker while being unreachable —
    the checker would be verifying commands nobody can get to. This closes that gap from
    the other side.
    """
    import importlib
    from pathlib import Path as _P
    import lab_tui.screens.wizards as pkg
    from lab_tui.screens.wizards.base import WizardModal
    from lab_tui.screens.wizard_select import _OPTIONS

    in_package = set()
    for mod_path in sorted(_P(pkg.__file__).parent.glob("*.py")):
        if mod_path.stem in ("__init__", "base"):
            continue
        mod = importlib.import_module(f"lab_tui.screens.wizards.{mod_path.stem}")
        for attr in dir(mod):
            cls = getattr(mod, attr)
            if (isinstance(cls, type) and issubclass(cls, WizardModal)
                    and cls is not WizardModal and cls.__module__ == mod.__name__):
                in_package.add(mod_path.stem)

    in_picker = {o.id for o in _OPTIONS}

    # The dispatch map is read out of browser.py: importing the screen drags in a Textual
    # app context, and the question here is about the mapping, not about the widget.
    src = (_P(pkg.__file__).parent.parent / "browser.py").read_text()
    import re
    block = re.search(r"_WIZARDS = \{(.*?)\}", src, re.S)
    assert block, "could not find the _WIZARDS dispatch map in browser.py"
    in_dispatch = set(re.findall(r'"(phase\d+)":', block.group(1)))

    assert in_package == in_picker == in_dispatch, (
        f"the three wizard registries disagree — package={sorted(in_package)} "
        f"picker={sorted(in_picker)} dispatch={sorted(in_dispatch)}. A wizard missing from "
        "the picker cannot be opened; one missing from the dispatch map opens nothing; one "
        "missing from the package is offered and then fails to import."
    )
