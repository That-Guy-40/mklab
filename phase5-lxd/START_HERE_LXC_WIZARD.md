# Start here — Phase 5: LXD/Incus (`lab-lxd.sh`)

> **Note on naming:** this file is named `START_HERE_LXC_WIZARD.md` to match
> the project convention, but the tool drives **LXD or Incus** (the maintained
> fork). LXC is the underlying kernel technology; LXD/Incus is the management
> layer on top of it. The two binaries (`lxc` for LXD, `incus` for Incus) are
> detected automatically — the script prefers Incus if both are present.

Phase 5 is the only manager in this stack that drives **system containers AND
full hardware-virtualised VMs through a single CLI**. System containers share
the host kernel (fast, low overhead); VMs get their own kernel and hardware
emulation (stronger isolation, different OS kernel). Both live in the same
`[[instance]]` TOML table — `type = "container"` vs `type = "vm"` is the only
difference.

---

## Option A — use the wizard (recommended)

If you have the Phase 6 TUI running:

```bash
cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
python3 -m lab_tui          # or: python3 phase6-tui/main.py
```

Press **`n`** → select **Phase 5 — LXD instance** → fill in the form → press **Save**.
The wizard writes a TOML file to `examples/lxd-<lab>.toml`.
Then bring it up with the command in Option C.

---

## Option B — three-minute quickstart (no wizard needed)

### 1. Install and initialise (one-time)

```bash
# Incus (recommended — actively maintained fork):
sudo apt-get install -y incus jq yq
sudo usermod -aG incus-admin "$USER" && newgrp incus-admin
sudo incus admin init --auto   # creates default storage pool + bridge network

# OR LXD (Canonical's original):
# sudo snap install lxd
# sudo lxd init --auto
# sudo usermod -aG lxd "$USER" && newgrp lxd
```

### 2. Start a container

```bash
phase5-lxd/lab-lxd.sh up   --config examples/lxd-examples/lxd-plain-single.toml
phase5-lxd/lab-lxd.sh list --lab hello-lxd
```

### 3. Execute a command inside it

```bash
phase5-lxd/lab-lxd.sh exec hello-lxd/shell -- cat /etc/os-release   # one-off command
phase5-lxd/lab-lxd.sh exec hello-lxd/shell                          # interactive shell
```

> **Interactive `exec` and `TERM`.** When you drop into a shell (or run `less`,
> `vim`, `man`, `clear`), `exec` sets `TERM=xterm` in the guest. `lxc`/`incus`
> would otherwise propagate your *client's* `$TERM` — and modern emulators
> (Ghostty → `xterm-ghostty`, Kitty, Alacritty) ship terminfo entries the
> container's database doesn't have, so those programs error with "unknown
> terminal type". The classic `xterm` is near-universally present and keeps
> colour. Want 256 colours (or a stricter entry)? Override it:
> `LAB_TERM=xterm-256color phase5-lxd/lab-lxd.sh exec hello-lxd/shell`. This only
> affects interactive sessions (a TTY) — scripted `exec … -- cmd` is untouched.

### 4. Tear down

```bash
phase5-lxd/lab-lxd.sh down --lab hello-lxd
```

---

## Option C — use a TOML config (from the wizard or an example)

Ready-to-run examples in `examples/lxd-examples/`:

| File | What it builds |
|---|---|
| `lxd-plain-single.toml` | Single Alpine container — simplest possible topology |
| `lxd-vm-single.toml` | Single Alpine VM (needs a ZFS/btrfs/LVM storage pool) |
| `lxd-mixed-topology.toml` | Two containers + one VM side by side in one `up` |
| `lxd-profiles-projects.toml` | LXD projects + profiles — namespace isolation |
| `lxd-from-chroot.toml` | Import a Phase-1 chroot/tarball as an LXD instance |

```bash
phase5-lxd/lab-lxd.sh up   --config examples/lxd-examples/lxd-mixed-topology.toml
phase5-lxd/lab-lxd.sh list --lab demo-mixed
phase5-lxd/lab-lxd.sh down --lab demo-mixed
```

---

## Option D — imperative one-liners (no TOML)

For a quick one-off — no config file — use the imperative verbs `run` (launch a
single instance) and `build` (bake a reusable local image alias):

```bash
# launch one container straight from the CLI
phase5-lxd/lab-lxd.sh run --name a --image images:alpine/latest

# a VM, attached to an existing LXD network
phase5-lxd/lab-lxd.sh run --name v --image images:debian/bookworm --type vm --network lxdbr0

# bake a chroot into a reusable local image alias, then launch from it
phase5-lxd/lab-lxd.sh build --alias kali --backend from-chroot --chroot /var/chroots/kali
phase5-lxd/lab-lxd.sh run   --name k --image kali
```

`run` takes `--name`, `--image`/`--chroot`/`--tarball`/`--qcow2`, `--type`,
`--project`, `--storage`, and `--network`; `build` takes `--alias` (a.k.a.
`--tag`), `--backend`, and the matching source flag. See **`SHOWCASE.md` §
Imperative verbs** for the full flag reference — or `lab-lxd.sh help`.

---

## Anatomy of a config

```toml
[lab]
name = "my-lab"

# A system container (shares host kernel — fast, lightweight):
[[instance]]
name  = "shell"
type  = "container"           # container | vm
image = "images:alpine/latest"   # resolved to e.g. images:alpine/3.23 at launch

# A hardware-virtualised VM (its own kernel, stronger isolation):
[[instance]]
name    = "worker"
type    = "vm"
image   = "images:debian/bookworm"
config  = { "limits.memory" = "512MiB", "limits.cpu" = "2" }
```

### Other useful instance keys

| Key | Notes |
|---|---|
| `arch` | `x86_64`, `aarch64`, `armv7l`, `ppc64le`, `riscv64`, `s390x` |
| `storage` | Storage pool name (`default`, `vmpool`, …) |
| `profiles` | `["default", "webnode"]` — merged config+device templates |
| `project` | LXD project for namespace isolation |
| `from_chroot` | Path to a Phase-1 chroot tree |
| `from_tarball` | Path to a rootfs tarball (from Phase-1 `export-tarball`) |
| `from_qcow2` | Path to a Phase-2 qcow2 disk image (VM only) |

---

## What just happened — the "why" under the hood

**System containers vs VMs — two levels of isolation:**

A **system container** (`type = "container"`) runs a full OS userspace (init,
services, everything) but shares the host's kernel. The Linux kernel's namespace
system (PID, net, mount, UTS, IPC, user) makes the container appear to have its
own process tree, network interfaces, and hostname — but there's only one kernel.
This makes them very fast to start (< 1 s) and cheap on RAM.

A **VM** (`type = "vm"`) runs under QEMU: its own kernel, its own hardware
emulation, a real bootloader. The host kernel sees it as a QEMU process. Processes
inside can't affect each other at the kernel level at all. Slower to start (10–30 s),
more RAM, but you can run a completely different kernel (or a different OS) from the host.

LXD/Incus presents both through the same API — the `--vm` flag to `lxc launch` is
the only difference internally.

**Profiles — reusable config+device templates:** a profile is a named set of
`config` key-value pairs and `devices` (disk, NIC, GPU, …). An instance that sets
`profiles = ["default", "webnode"]` merges them in order — `default` provides the
root disk and default NIC; `webnode` adds CPU limits and a specific NIC config.
This is LXD's equivalent of Kubernetes' ConfigMaps + resource requests — define
once, apply to many instances.

**Projects — namespace isolation:** a project is a separate "view" of LXD.
Instances, images, networks, and storage volumes can all be scoped to a project so
two labs don't see each other's instances. Phase 5 creates projects with
`features.profiles=false features.storage.volumes=false` so they inherit the
default project's profiles and storage — you don't have to recreate `default`
in every project.

**`images:alpine/latest` resolution:** the `images:` simplestreams remote doesn't
publish a literal `latest` alias. Phase 5 intercepts `*/latest` at runtime, queries
the remote for the highest stable release, and rewrites the image ref before calling
`lxc launch`. You get the convenience of `latest` without the resolver error.

---

## Next steps

- **`SHOWCASE.md`** — live-verified demos: mixed topology, profiles/projects, from-chroot
- **`MANUAL_TESTING.md`** — step-by-step verification walkthrough (includes §0a first-run bootstrap)
- **`examples/`** — all TOML examples above
- **← Phase 1** (`START_HERE_CHROOT_WIZARD.md`) — build a rootfs for `from_chroot`
- **← Phase 2** (`START_HERE_VM_WIZARD.md`) — produce a qcow2 for `from_qcow2`
- **← Phase 4** (`START_HERE_PODMAN_WIZARD.md`) — rootless containers without LXD
- **Export to lxc-yaml:** `phase5-lxd/lab-lxd.sh export <lab> --format lxc-yaml`
- **Export to Compose:** `phase5-lxd/lab-lxd.sh export <lab> --format compose`
- **Inspect JSON:** `phase5-lxd/lab-lxd.sh inspect <lab>/<name> --json | jq`
