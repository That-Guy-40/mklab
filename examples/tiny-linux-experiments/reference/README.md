# Reference helper scripts

These standalone shell scripts predate the auto-build logic now folded into
`lab-vm.sh`.  They still work, and they document (in isolation) exactly what
happens when `lab-vm.sh create --config microvm-alpine.toml` runs with
`distro=alpine` + `backend=kernel+initrd`.

Read them if you want to see the build without the surrounding framework.
Run them if you want to inspect the intermediate artifacts.

| Script | What it builds |
|---|---|
| `build-alpine-microvm.sh` | Minirootfs → busybox-init initramfs (matches `init_flavour = "busybox"`) |
| `build-alpine-microvm-custom-init.sh` | Minirootfs with `/sbin/init` replaced by a static C binary (matches `init_flavour = "custom"`) |

For regular use, prefer `lab-vm.sh create` with a TOML spec — it auto-resolves
paths, caches downloads, and wires feature flags (`network`, `ssh`, `persist`).
