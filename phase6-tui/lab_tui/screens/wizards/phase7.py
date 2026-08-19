"""Phase 7 — Firecracker microVM create wizard.

Generates a [[microvm]] TOML for lab-fc.sh create --config <file>.

WHY THIS IS THE SIXTH SUBCLASS AND NOT A NEW SHAPE
--------------------------------------------------
MICRO_CLOUD_LAB_PLAN §8.2 lists "no `microvm` wizard" as one of two gaps, and calls both
"extension rather than invention" — the work is a subclass, after §5.2's schema is DERIVED
by the tool rather than guessed at. That happened in slice 4, so the fields below are not a
design: every one is a key `lab-fc.sh` already parses (its `KNOWN_KEYS`), and the wizard
adds nothing the CLI does not have. That is §0.2's invariant at the level of the schema —
a wizard offering a knob the tool lacks would be a parallel implementation with a form on it.

TWO FIELDS THIS WIZARD DELIBERATELY DOES NOT OFFER
--------------------------------------------------
`tap` is offered; **creating** one is not. Phase 7's own header is explicit that tap
lifecycle belongs to `fabric.sh` and that two owners for one resource is the stale-record
bug this repo keeps finding — so the wizard asks for the name of a tap you already made,
exactly as the tool does.

There is no field for the API socket or the pidfile. They are run-time state chosen at
`start`, not spec, and a wizard that wrote them into a spec would be inventing a key.
"""

from __future__ import annotations

from pathlib import Path

from textual.app import ComposeResult
from textual.widgets import Checkbox, Input, Label, Select

from lab_tui.screens.wizards.base import WizardModal, _toml_str

_MEMORY = [("128M", "128M"), ("256M", "256M"), ("512M", "512M"),
           ("1G", "1G"), ("2G", "2G")]
_VCPUS = [("1", "1"), ("2", "2"), ("4", "4")]


class MicroVMWizard(WizardModal):
    TITLE = "Phase 7 — New Firecracker microVM"

    def compose_form(self) -> ComposeResult:
        yield Label("Name *", classes="field-label")
        yield Input(placeholder="api1", id="f-name")

        yield Label("Kernel (uncompressed ELF vmlinux) *", classes="field-label")
        yield Input(placeholder="~/.local/state/lab-create/micro-cloud-s3/vmlinux",
                    id="f-kernel")

        yield Label("Root filesystem (ext4 image) *", classes="field-label")
        yield Input(placeholder="~/.local/state/lab-create/micro-cloud-s3/api1.ext4",
                    id="f-rootfs")

        yield Label("Memory", classes="field-label")
        yield Select(_MEMORY, id="f-memory", value="256M")

        yield Label("vCPUs", classes="field-label")
        yield Select(_VCPUS, id="f-vcpus", value="1")

        # Networking. The tap must already exist — see the module docstring.
        yield Label("Tap device (must already exist — fabric.sh tap <name>)",
                    classes="field-label")
        yield Input(placeholder="mc-api1", id="f-tap")

        yield Label("Guest IP", classes="field-label")
        yield Input(placeholder="10.71.0.11", id="f-ip")

        yield Label("Gateway", classes="field-label")
        yield Input(placeholder="10.71.0.1", id="f-gateway")

        yield Label("Netmask", classes="field-label")
        yield Input(placeholder="255.255.255.0", id="f-netmask")

        yield Label("Guest MAC (blank = derived from the name)", classes="field-label")
        yield Input(placeholder="06:00:ac:47:f1:f7", id="f-mac")

        yield Label("Lab name (optional)", classes="field-label")
        yield Input(placeholder="micro-cloud", id="f-lab")

        yield Label("Extra kernel cmdline (optional)", classes="field-label")
        yield Input(placeholder="quiet", id="f-append")

        yield Checkbox("MMDS v2 (a real 169.254.169.254 — needs a tap)", False, id="f-mmds")

    def _default_save_path(self) -> str:
        name = self._val("f-name", self) or "my-microvm"
        return f"examples/microvm-{name}.toml"

    def run_hint(self, path: Path) -> str:
        name = self._val("f-name", self) or "<name>"
        tap = self._val("f-tap", self)
        # The fabric step is shown ONLY when a tap was asked for, because `fabric.sh tap`
        # needs root and telling someone to run a privileged command they do not need is how
        # a guided path teaches a superstition.
        fabric = (
            f"# This spec names tap '{tap}', and lab-fc.sh validates taps but never creates\n"
            f"# them (two owners for one resource is how records go stale). Make it first —\n"
            f"# this one needs root:\n\n"
            f"sudo examples/micro-cloud/fabric.sh up\n"
            f"sudo examples/micro-cloud/fabric.sh tap {name}\n\n"
        ) if tap else ""
        return (
            f"# TOML saved to: {path}\n"
            f"#\n"
            f"{fabric}"
            f"# Step 1 — check every gate BEFORE anything is copied (same function create runs):\n\n"
            f"phase7-firecracker/lab-fc.sh preflight --config {path}\n\n"
            f"# Step 2 — see exactly what the tool would generate, and what it filled in for\n"
            f"#          you, without writing anything:\n\n"
            f"phase7-firecracker/lab-fc.sh create --config {path} --dry-run\n\n"
            f"# Step 3 — create it (copies the rootfs per instance, records digests):\n\n"
            f"phase7-firecracker/lab-fc.sh create --config {path}\n\n"
            f"# Step 4 — boot it:\n\n"
            f"phase7-firecracker/lab-fc.sh start {name}\n\n"
            f"# What it is doing, and whether the recorded artifacts still match:\n\n"
            f"phase7-firecracker/lab-fc.sh inspect {name}\n\n"
            f"# Stop it, and destroy it (the tap is left alone — the fabric owns it):\n\n"
            f"phase7-firecracker/lab-fc.sh stop {name}\n"
            f"phase7-firecracker/lab-fc.sh destroy {name}\n"
        )

    def generate_toml(self) -> str:
        name = self._val("f-name", self) or "<name>"
        kernel = self._val("f-kernel", self)
        rootfs = self._val("f-rootfs", self)
        memory = self._sel("f-memory", self) or "256M"
        vcpus = self._sel("f-vcpus", self) or "1"
        tap = self._val("f-tap", self)
        ip = self._val("f-ip", self)
        gateway = self._val("f-gateway", self)
        netmask = self._val("f-netmask", self)
        mac = self._val("f-mac", self)
        lab = self._val("f-lab", self)
        append = self._val("f-append", self)
        mmds = self._chk("f-mmds", self)

        # F-01: escape all free-text values. A wizard that wrote a broken spec while the
        # preview said "(invalid input)" is this repo's signature bug, already found and
        # fixed inside this framework once.
        lines = [
            "# Generated by lab-create TUI — Phase 7 microVM wizard",
            "# Usage: lab-fc.sh preflight --config <this-file>",
            "#        lab-fc.sh create    --config <this-file>",
            "#        lab-fc.sh start     <name>",
            "",
            "[[microvm]]",
            f'name    = "{_toml_str(name)}"',
        ]
        if kernel:
            lines.append(f'kernel  = "{_toml_str(kernel)}"')
        if rootfs:
            lines.append(f'rootfs  = "{_toml_str(rootfs)}"')
        lines.append(f'memory  = "{_toml_str(memory)}"')
        lines.append(f'vcpus   = {vcpus}')
        if tap:
            lines.append(f'tap     = "{_toml_str(tap)}"')
        if ip:
            lines.append(f'ip      = "{_toml_str(ip)}"')
        if gateway:
            lines.append(f'gateway = "{_toml_str(gateway)}"')
        if netmask:
            lines.append(f'netmask = "{_toml_str(netmask)}"')
        if mac:
            lines.append(f'mac     = "{_toml_str(mac)}"')
        if lab:
            lines.append(f'lab     = "{_toml_str(lab)}"')
        if append:
            lines.append(f'append  = "{_toml_str(append)}"')
        if mmds:
            lines.append("mmds    = true")
        return "\n".join(lines) + "\n"
