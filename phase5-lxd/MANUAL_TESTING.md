# Phase 5 — Manual Testing Walkthrough

Copy-pasteable exercise of `lab-lxd.sh` against either LXD (via `lxc`) or
Incus (preferred). Phase 5 auto-detects which engine is on PATH. Run
top-to-bottom on a Linux host.

> **Set up a working dir:**
> ```bash
> cd /media/sqs/COLD_STORAGE/LAB_CREATE_V2
> alias ll='phase5-lxd/lab-lxd.sh'
> ```

## 0. Preflight

Pick one engine. Both share the subcommand surface Phase 5 uses, so either
works.

```bash
# Option A — Incus (preferred; actively maintained fork):
sudo apt-get install -y incus jq          # Debian/Ubuntu/Kali
sudo usermod -aG incus-admin $USER
newgrp incus-admin                        # or log out and back in

# Option B — LXD (older, still fine):
sudo snap install lxd
sudo usermod -aG lxd $USER
newgrp lxd
```

### 0a. First-run bootstrap (REQUIRED — tests fail without this)

Right after install, the daemon is running but has **no storage pool** and
the `default` profile carries **no root-disk device**. Every `launch`
fails with:

```
Failed instance creation: Failed initialising instance: Failed getting root disk: No root device could be found
```

Bootstrap once with the engine's non-interactive init:

```bash
# For Incus:
sudo incus admin init --auto

# For LXD:
sudo lxd init --auto
```

Either creates a `dir`-backed `default` storage pool, an `lxdbr0` bridge
network, and wires both into the `default` profile. The `dir` pool is
fine for containers; **VM tests** (`type = "vm"`) need a block-capable
pool (`zfs`/`btrfs`/`lvm`):

```bash
# Incus, ZFS via 20 GB loop file (good default for VMs):
sudo incus admin init --auto --storage-backend zfs --storage-create-loop 20

# LXD, same:
sudo lxd init --auto --storage-backend zfs --storage-create-loop 20
```

Verify:

```bash
incus profile show default 2>/dev/null || lxc profile show default
# → must contain a `root:` device under devices:
#     devices:
#       root:
#         path: /
#         pool: default
#         type: disk
```

Without a `root:` line in the default profile, the automated test suite
will skip the lifecycle tests with a pointer back to this section.

### 0b. Smoke-test

Confirm your engine is reachable:

```bash
incus list 2>/dev/null || lxc list
# → empty table, no errors
```

A TOML parser is required (Phase 3/4 inherit this too):

```bash
ll help >/dev/null || sudo apt-get install -y yq
```

Smoke-test the script:

```bash
ll version                                # → "lab-lxd.sh 0.1.0"
ll help | head -5                         # → usage block
ll list                                   # → empty table, "all labs (lab-lxd-managed only)"
ll status                                 # → engine info summary
```

## 1. Plain mode: single container

```bash
ll up --config examples/lxd-plain-single.toml
```

**Expect:**
- `[info] ── bringing up lab 'hello-lxd' from … ──`
- `[info] resolved images:alpine/latest → images:alpine/3.23` (or whatever the newest stable is)
- `[info] launching container 'shell' as lab-hello-lxd-shell (image=images:alpine/3.23)`
- `[info] ── lab 'hello-lxd' up (1 incus instance(s), 0 skipped) ──`

**Verify:**

```bash
ll list --lab hello-lxd
ll exec hello-lxd/shell -- cat /etc/os-release
ll exec hello-lxd/shell -- ip a            # has eth0 via default profile
ll status hello-lxd/shell
```

**Tear down:**

```bash
ll down --lab hello-lxd
ll list                                    # no hello-lxd rows
```

## 2. VM mode (requires KVM + a block-capable storage pool)

Prereqs:
- `/dev/kvm` readable by you (or your `incus-admin` / `lxd` group)
- A storage pool of type `zfs`, `btrfs`, `lvm`, or anything else with real
  block support. The `dir` pool does **not** support VMs. `lxc storage list`
  / `incus storage list` shows what you have.

```bash
ll up --config examples/lxd-vm-single.toml
```

**Expect:** `[info] launching vm 'alpine' as lab-hello-vm-alpine …`.

**Verify:**

```bash
ll list --lab hello-vm
# Give the lxd-agent 20-60s to come up after first boot:
for i in {1..30}; do ll exec hello-vm/alpine -- true 2>/dev/null && break; sleep 2; done
ll exec hello-vm/alpine -- uname -a
```

**Tear down:**

```bash
ll down --lab hello-vm
```

This is PLAN.md **exit criterion #1** — containers + VMs in a single lab
management surface.

## 3. Mixed topology (2 containers + 1 VM)

```bash
ll up --config examples/lxd-mixed-topology.toml
ll list --lab demo-mixed
ll status demo-mixed
ll down --lab demo-mixed
```

## 4. Profiles and projects

```bash
ll up --config examples/lxd-profiles-projects.toml
incus profile show webnode --project demo-pp      # or: lxc profile show …
incus project list
ll down --lab demo-pp
# Project + profile remain (multi-lab sharing); clean by hand if desired:
incus profile delete webnode --project demo-pp
incus project delete demo-pp
```

## 5. From-chroot import (cross-phase)

Prereq: a Phase 1 chroot with an export-tarball.

```bash
sudo phase1-chroot/lab-chroot.sh create \
    --backend debootstrap --distro kali --suite kali-rolling \
    --arch x86_64 --target /var/chroots/kali-amd64 --variant minbase \
    --name kali-amd64

sudo phase1-chroot/lab-chroot.sh export-tarball kali-amd64 \
                                               --output /tmp/kali-amd64.tar.gz

ll up --config examples/lxd-from-chroot.toml
ll exec lxd-kali/attacker -- cat /etc/os-release
# → PRETTY_NAME="Kali Linux Rolling"
ll exec lxd-kali/attacker -- apt --version
ll down --lab lxd-kali
rm -f /tmp/kali-amd64.tar.gz
```

**Rootful chroot without the tarball step?** The script runs a readability
preflight that fires a specific error pointing you at `export-tarball`.
This is deliberate — mode-600 files (`/etc/shadow`, `/root/*`) in root-
owned chroots break tar for unprivileged users, so the tarball path is the
rootless-clean route. Matches Phase 3/4's handling.

This is PLAN.md **exit criterion #2**.

## 5b. VM from a chroot / tarball (direct path — root required)

`from_chroot` and `from_tarball` now support `type = "vm"` directly.  Phase 5
builds a bootable disk image from the chroot tree (MBR + ext4 + extlinux,
x86_64 BIOS boot), converts it to qcow2, and imports it as an LXD VM image.

**Requirements:**
- Run with `sudo` — loop mounts, `mkfs.ext4`, and `extlinux --install` are
  root-only.
- `apt-get install -y qemu-utils parted extlinux syslinux-common rsync`
- A kernel must be installed inside the chroot (`/boot/vmlinuz-*`):
  ```bash
  sudo phase1-chroot/lab-chroot.sh enter kali-amd64 -- \
      apt-get install -y linux-image-amd64
  ```
- x86_64 BIOS only; aarch64 UEFI needs a different bootloader chain.
- A block-capable LXD storage pool (ZFS/btrfs/LVM — the `dir` pool does
  not host VMs; see §0a).

**Walk-through (from an existing chroot):**

```bash
cat > /tmp/vm-from-chroot.toml <<'EOF'
[lab]
name = "kali-vm"

[[instance]]
name       = "attacker"
type       = "vm"
from_chroot = "/var/chroots/kali-amd64"   # must have /boot/vmlinuz-*
EOF

sudo ll up --config /tmp/vm-from-chroot.toml
```

**Expect** (takes ~2–5 min — disk image creation, rsync, extlinux install,
qcow2 convert, LXD import):

```
[info] preflight: scanning /var/chroots/kali-amd64 for unreadable files
[info] creating 20G raw disk image for VM
[info] partitioning (MBR + single bootable ext4 partition)
[info] copying chroot → disk (rsync, preserving perms)
[info] converting raw → qcow2
[info] importing as LXD VM image alias 'lab-kali-vm-attacker-img'
[info] launching vm 'attacker' as lab-kali-vm-attacker …
```

**Verify:**

```bash
sudo ll list --lab kali-vm
# Give the lxd-agent 20-60s to come up:
for i in {1..30}; do sudo ll exec kali-vm/attacker -- true 2>/dev/null && break; sleep 2; done
sudo ll exec kali-vm/attacker -- uname -a     # amd64 Linux
sudo ll down --lab kali-vm --force
```

**Same workflow from a tarball** (rootless-clean prep; still needs sudo for
the VM disk build):

```bash
sudo phase1-chroot/lab-chroot.sh export-tarball kali-amd64 --output /tmp/kali.tar.gz
cat > /tmp/vm-from-tarball.toml <<'EOF'
[lab]
name = "kali-vm-t"
[[instance]]
name         = "attacker"
type         = "vm"
from_tarball = "/tmp/kali.tar.gz"
EOF
sudo ll up --config /tmp/vm-from-tarball.toml
sudo ll down --lab kali-vm-t --force
```

**Prefer the Phase 2 bridge for anything complex.** The direct path is
convenient for x86_64 BIOS VMs; for UEFI, aarch64, or anything that needs
grub-efi or a signed shim, build a qcow2 via Phase 2 and import with
`from_qcow2` (the original workaround, still fully valid):

```bash
sudo phase2-qemu-vm/lab-vm.sh create --backend from-chroot \
    --chroot /var/chroots/kali-amd64 --arch x86_64 --disk-size 20G --name kaliseed
sudo cp /var/lib/lab-create/vms/kaliseed/disk.qcow2 /tmp/kali.qcow2
sudo chown $USER:$USER /tmp/kali.qcow2
# then from_qcow2 = "/tmp/kali.qcow2" in TOML (rootless from here)
```

## 5c. Inspect profiles and projects

`inspect` resolves in order: **instance → profile → project**.  Both human
and `--json` modes work the same way.

```bash
# --- Profile inspect ---
ll inspect default                            # default profile (human form)
ll inspect default --json | jq .             # JSON: kind="profile"
ll inspect webnode --json | jq '.config, .devices'

# Expected JSON shape:
# {
#   "schema_version": 1, "kind": "profile",
#   "name": "default", "description": "",
#   "config": { "limits.cpu": "2" },
#   "devices": { "root": { "path": "/", "pool": "default", "type": "disk" } }
# }
```

```bash
# --- Project inspect (Incus/LXD ≥ 5.x) ---
ll inspect default --json | jq .             # "kind": "project"

# After bringing up examples/lxd-profiles-projects.toml:
ll up --config examples/lxd-profiles-projects.toml
ll inspect demo-pp --json | jq '.kind, .config'
# → "project"
# → { "features.profiles": "false", "features.storage.volumes": "false" }
ll inspect webnode --json | jq '.kind, .config'
# → "profile"
# → { "security.nesting": "true", "limits.cpu": "1" }
ll down --lab demo-pp
```

**Failure path** — target not found as instance, profile, or project:

```bash
ll inspect nonexistent-xyz 2>&1 | grep "no instance, profile"
# → [error] no instance, profile, or project matches 'nonexistent-xyz'
```

## 6. Export (`--format lxc-yaml` and `--format compose`)

Phase 5 supports two export formats.

### 6a. `--format lxc-yaml` (default — LXD native round-trip)

Dumps `lxc config show --expanded` per instance, concatenated with YAML
`---` separators.  Feedable straight back into `lxc launch --yaml` / `incus
launch --yaml` to recreate identical instances — same config, same devices,
same `user.lab-create.*` labels.

```bash
ll up --config examples/lxd-mixed-topology.toml
ll export demo-mixed --format lxc-yaml > /tmp/demo.yaml
head -40 /tmp/demo.yaml
grep '^# instance:' /tmp/demo.yaml         # → one line per instance
ll down --lab demo-mixed

# Round-trip:
#   incus launch --yaml < /tmp/demo.yaml
#   # re-creates instances with identical config, devices, labels
```

This is PLAN.md **exit criterion #3**.

### 6b. `--format compose` (Docker Compose YAML — cross-tool handoff)

Synthesises Compose v3.9 YAML from the stored `spec.toml`.  Containers
become services; VMs are skipped with a `# (skipped: type=vm)` comment
because Compose has no VM concept.  LXD-specific fields (profiles, project,
storage) are noted as omitted.

```bash
ll up --config examples/lxd-mixed-topology.toml

ll export demo-mixed --format compose > /tmp/demo-compose.yml
cat /tmp/demo-compose.yml
```

**Expect** (excerpt — containers only; VM row appears as a comment):

```yaml
version: "3.9"
# Generated by lab-lxd.sh export --format compose from lab demo-mixed
# Note: LXD-specific fields (profiles, project, storage) are not representable
# in compose YAML and are omitted.  VMs are skipped entirely.
services:
  web:
    image: images:alpine/3.23
    container_name: lab-demo-mixed-web
  cache:
    image: images:alpine/3.23
    container_name: lab-demo-mixed-cache
  # (skipped: worker-vm is type=vm, not representable in compose)
networks:
  default:
    driver: bridge
```

**Validate with `docker compose config` (if available):**

```bash
docker compose -f /tmp/demo-compose.yml config --quiet && echo "VALID"
```

**Verify that named volumes appear at top level** (bring up a lab that
uses volumes first):

```bash
# TOML with a named volume:
cat > /tmp/vol-test.toml <<'EOF'
[lab]
name = "voltest"
[[instance]]
name    = "db"
image   = "images:alpine/latest"
volumes = ["pgdata:/var/lib/data"]
EOF
ll up --config /tmp/vol-test.toml
ll export voltest --format compose | grep -A2 '^volumes:'
# → volumes:
# →   pgdata:
ll down --lab voltest
```

```bash
ll down --lab demo-mixed
rm /tmp/demo-compose.yml
```

## 7. Cross-phase unified TOML

The same `lab.toml` can carry docker, podman, and LXD services side by
side. Each phase tool only claims its own rows via the `engine` filter.

```bash
# Suppose you have examples/lab-unified-demo.toml with mixed engines:
phase3-docker/lab-docker.sh up --config examples/lab-unified-demo.toml  # docker rows
phase4-podman/lab-podman.sh up --config examples/lab-unified-demo.toml  # podman rows
phase5-lxd/lab-lxd.sh      up --config examples/lab-unified-demo.toml  # lxd rows

phase5-lxd/lab-lxd.sh list --lab demo-ctf      # shows ONLY LXD instances
```

This is PLAN.md **exit criterion #4**.

## 8. Validation guardrails

These should fail fast, before any daemon call. A good regression probe
after any CLI-parsing edit:

```bash
ll build                                   # → "usage: …"
ll build --alias foo --backend bogus       # → "unknown backend: bogus"
ll build --alias foo --backend upstream    # → "needs --image SRC"
ll up                                      # → "usage: … topology.toml"
ll export                                  # → "usage: … export <lab>"
ll export somelab --format kube            # → "unknown export format: kube (phase 5 supports: lxc-yaml|compose)"
ll inspect                                 # → "usage: … inspect <name|lab/service> [--json]"
ll inspect nonexistent-xyz 2>&1            # → "no instance, profile, or project matches"
```

All subcommand guards covered by `phase5-lxd/tests/test-validation.sh`.

## 9. Run the automated suite

```bash
phase5-lxd/tests/run-all.sh
```

Expect (on an LXD-equipped host):

- `test-validation.sh` — pass (~1 s, no daemon required)
- `test-engine-dispatch.sh` — pass (~2 s; exercises engine filter too)
- `test-naming.sh` — pass (~15 s)
- `test-container-lifecycle.sh` — pass (~20 s)
- `test-vm-lifecycle.sh` — pass or skip (depending on `/dev/kvm` + storage pool)
- `test-from-chroot-import.sh` — pass (~5 s; uses a scratch busybox tree)
- `test-profiles-projects.sh` — pass (~15 s)
- `test-export-lxc-yaml.sh` — pass (~15 s)
- `test-inspect-json.sh` — pass (~30 s); covers running + **stopped** container
  (B), **VM** (C — skips if no `/dev/kvm`), and failure paths (D)

Skips are exit 77 (LSB). Without LXD/Incus installed, every daemon-touching
test skips and you get `passed: 2, skipped: 7`.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `incus info failed — daemon not reachable` | service not running | `sudo systemctl start incus` (or `snap.lxd.daemon` for LXD) |
| `you are not in group 'incus-admin'` warning | unprivileged user not in the LXD/Incus control group | `sudo usermod -aG incus-admin $USER && newgrp incus-admin` |
| `Failed getting root disk: No root device could be found` | post-install state — engine is running but never bootstrapped (no storage pool, default profile has no root device) | `sudo incus admin init --auto` (Incus) or `sudo lxd init --auto` (LXD); see §0a |
| `image … is incompatible with secureboot. Please set security.secureboot=false` | community VM images (Alpine, etc.) aren't signed for UEFI Secure Boot | add `config = { "security.secureboot" = "false" }` to the `[[instance]]` block; see `examples/lxd-vm-single.toml` |
| `VM up failed (likely dir-pool without block support)` | default storage pool is `dir`, which can't host VMs | `incus storage create vmpool zfs` (or btrfs/lvm); reference via `[[instance]] storage = "vmpool"` |
| `image import failed` with a half-created alias | prior run died mid-import | Phase 5 now cleans these up on failure; if you hit one, `incus image delete <alias>` and retry |
| `chroot 'X' contains files unreadable by this user` | you pointed `from_chroot` at a root-owned chroot | for **containers**: use `sudo lab-chroot.sh export-tarball <name>` and switch to `from_tarball`. For **VMs**: run `sudo ll up …` (the VM path already requires root) |
| `from-chroot (VM): no /boot/vmlinuz-* found` | tried `type = "vm"` + `from_chroot` but the chroot has no kernel | `sudo ll enter <chroot> -- apt-get install -y linux-image-amd64` then retry |
| `from-chroot for VMs requires root` | ran VM from-chroot without sudo | `sudo ll up --config …` — the VM disk-image build needs root for loop mounts |
| `syslinux MBR binary not found` | `syslinux-common` not installed | `sudo apt-get install -y extlinux syslinux-common` |
| `no instance, profile, or project matches` | `inspect` target doesn't exist under any of the three types | double-check the name with `ll list` / `incus profile list` / `incus project list` |
| `lxd-agent` slow to come up in a VM | first boot runs cloud-init inside the guest | wait 30-60 s; `incus info <vm>` shows `Status: Running` well before `exec` works |

### Verbose logging

```bash
LAB_LOG_LEVEL=debug ll up --config …
```

Emits every internal step including the picked engine and the shell
commands issued against the daemon.
