"""Create wizards — one modal TOML generator per phase."""

from lab_tui.screens.wizards.base import WizardModal
from lab_tui.screens.wizards.phase1 import ChrootWizard
from lab_tui.screens.wizards.phase2 import VMWizard
from lab_tui.screens.wizards.phase3 import DockerServiceWizard
from lab_tui.screens.wizards.phase4 import PodmanServiceWizard
from lab_tui.screens.wizards.phase5 import LXDInstanceWizard
from lab_tui.screens.wizards.phase7 import MicroVMWizard

__all__ = [
    "WizardModal",
    "ChrootWizard",
    "VMWizard",
    "DockerServiceWizard",
    "PodmanServiceWizard",
    "LXDInstanceWizard",
    "MicroVMWizard",
]
