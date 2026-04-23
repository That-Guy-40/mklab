from lab_tui.backends.base import BackendRunner, Resource
from lab_tui.backends.chroot import ChrootBackend
from lab_tui.backends.docker import DockerBackend
from lab_tui.backends.lxd import LXDBackend
from lab_tui.backends.podman import PodmanBackend
from lab_tui.backends.vm import VMBackend

ALL_BACKENDS: list[type[BackendRunner]] = [
    ChrootBackend,
    VMBackend,
    DockerBackend,
    PodmanBackend,
    LXDBackend,
]

__all__ = [
    "ALL_BACKENDS",
    "BackendRunner",
    "ChrootBackend",
    "DockerBackend",
    "LXDBackend",
    "PodmanBackend",
    "Resource",
    "VMBackend",
]
