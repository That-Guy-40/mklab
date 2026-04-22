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
sudo incus admin init                     # interactive first-run setup
sudo usermod -aG incus-admin $USER
newgrp incus-admin                        # or log out and back in

# Option B — LXD (older, still fine):
sudo snap install lxd
sudo lxd init                             # interactive first-run setup
sudo usermod -aG lxd $USER
newgrp lxd
```

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
- `[info] launching container 'shell' as lab-hello-lxd-shell (image=images:alpine/3.19)`
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

## 5b. VM from a chroot (workaround — container-only in v0.1)

`from_chroot` only produces container images in v0.1. For a VM built from
the same chroot, bridge via Phase 2:

```bash
# 1) Build a bootable qcow2 from the Phase 1 chroot (root; x86_64 BIOS):
sudo phase2-qemu-vm/lab-vm.sh create --backend from-chroot \
    --chroot /var/chroots/kali-amd64 --arch x86_64 \
    --memory 2G --disk-size 8G --name kaliseed

# 2) Copy the qcow2 somewhere user-readable:
sudo cp /var/lib/lab-create/vms/kaliseed/disk.qcow2 /tmp/kali.qcow2
sudo chown $USER:$USER /tmp/kali.qcow2

# 3) Import as an LXD VM image and launch:
cat > /tmp/vm-from-chroot.toml <<EOF
[lab]
name = "kali-vm"
[[instance]]
name       = "attacker"
type       = "vm"
from_qcow2 = "/tmp/kali.qcow2"
EOF
ll up --config /tmp/vm-from-chroot.toml
```

See `examples/lxd-from-chroot.toml` for the full workflow comment.

## 6. Export (`--format lxc-yaml`)

Dumps `lxc config show --expanded` per instance, concatenated with YAML
document separators. The output is feedable to `lxc launch --yaml`
(or `incus launch --yaml`) to recreate identical instance config — the
LXD equivalent of Phase 4's `podman kube play` handoff.

```bash
ll up --config examples/lxd-mixed-topology.toml
ll export demo-mixed --format lxc-yaml > /tmp/demo.yaml
head -40 /tmp/demo.yaml
grep '^# instance:' /tmp/demo.yaml         # → one line per instance
ll down --lab demo-mixed

# Round-trip (needs --yaml support; available in recent LXD/Incus):
#   incus launch --yaml < /tmp/demo.yaml
#   # re-creates instances with identical config, devices, labels
```

This is PLAN.md **exit criterion #3**.

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
ll export somelab --format kube            # → "unknown export format: kube"
```

All handled by `phase5-lxd/tests/test-validation.sh`.

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

Skips are exit 77 (LSB). Without LXD/Incus installed, every daemon-touching
test skips and you get `passed: 2, skipped: 6`.

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `incus info failed — daemon not reachable` | service not running | `sudo systemctl start incus` (or `snap.lxd.daemon` for LXD) |
| `you are not in group 'incus-admin'` warning | unprivileged user not in the LXD/Incus control group | `sudo usermod -aG incus-admin $USER && newgrp incus-admin` |
| `VM up failed (likely dir-pool without block support)` | default storage pool is `dir`, which can't host VMs | `incus storage create vmpool zfs` (or btrfs/lvm); reference via `[[instance]] storage = "vmpool"` |
| `image import failed` with a half-created alias | prior run died mid-import | Phase 5 now cleans these up on failure; if you hit one, `incus image delete <alias>` and retry |
| `chroot 'X' contains files unreadable by this user` | you pointed `from_chroot` at a root-owned chroot | use `sudo phase1-chroot/lab-chroot.sh export-tarball <name>` and switch to `from_tarball` in your TOML |
| `from_chroot is container-only in v0.1` | tried `type = "vm"` + `from_chroot` | see §5b — bridge via Phase 2 to produce a qcow2, then use `from_qcow2` |
| `lxd-agent` slow to come up in a VM | first boot runs cloud-init inside the guest | wait 30-60 s; `incus info <vm>` shows `Status: Running` well before `exec` works |

### Verbose logging

```bash
LAB_LOG_LEVEL=debug ll up --config …
```

Emits every internal step including the picked engine and the shell
commands issued against the daemon.
