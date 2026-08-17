from lab_tui.backends.base import BackendRunner, Resource
from lab_tui.backends.chroot import ChrootBackend
from lab_tui.backends.control_pane import ControlPaneBackend
from lab_tui.backends.docker import DockerBackend
from lab_tui.backends.fc import FCBackend
from lab_tui.backends.lxd import LXDBackend
from lab_tui.backends.podman import PodmanBackend
from lab_tui.backends.vm import VMBackend

ALL_BACKENDS: list[type[BackendRunner]] = [
    ChrootBackend,
    VMBackend,
    DockerBackend,
    PodmanBackend,
    LXDBackend,
    ControlPaneBackend,
    FCBackend,
]

__all__ = [
    "ALL_BACKENDS",
    "BackendRunner",
    "ChrootBackend",
    "ControlPaneBackend",
    "DockerBackend",
    "FCBackend",
    "LXDBackend",
    "PodmanBackend",
    "Resource",
    "VMBackend",
]
