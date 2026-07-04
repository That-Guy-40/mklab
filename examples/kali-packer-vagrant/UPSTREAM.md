# Upstream & provenance — kali-packer-vagrant

This lab is a **driver** around Kali's own (now-retired) Packer build scripts. It
follows the repo's *cite-don't-mirror* rule for upstream code: we **clone a
pinned checkout** at build time rather than vendoring a copy (the same posture as
[`../kali-vm-builder/`](../kali-vm-builder/) and
[`../debian-hands-off-install/`](../debian-hands-off-install/README.md)).

| | |
|---|---|
| **Project** | Kali-Packer — Kali's HashiCorp Packer configs for building Kali Vagrant base boxes |
| **Upstream** | https://gitlab.com/kalilinux/build-scripts/kali-packer |
| **Pinned commit** | `b8c9b34efc553a3744b39387d359b89ede04267b` (default branch `main`) |
| **Pinned commit subject** | `GitLab: issues -> work_items` (Ben Wilson, 2026-03-25) |
| **Retrieved** | 2026-07-03 |
| **Status upstream** | **Archived / "no longer in production"** — Kali moved to debos at the 2025.2 release; these scripts no longer produce the published Vagrant boxes |
| **License** | Repo `LICENSE` documents that `scripts/minimize.sh` derives from [chef/bento](https://github.com/chef/bento) (**Apache-2.0**); the rest is Kali's build tooling. Nothing is vendored here — `git rm` this lab to remove. |

## What we use from the checkout (as-is, bar two compat patches)

`fetch-kali-packer.sh` pins the checkout; `build-kali-box.sh` runs it essentially
as-is:

- **`config.pkr.hcl`** — the Packer template: four `source` builders
  (`qemu`, `virtualbox-iso`, `vmware-iso`, `hyperv-iso`), the `boot_command` that
  types the preseed URL at the installer, a `shell` provisioner, and the
  `vagrant` / `vagrant-cloud` post-processors.
- **`http/preseed.cfg`** — the d-i preseed Packer serves over HTTP (user
  `vagrant`/`vagrant`, atomic partitioning, `late_command` enables ssh).
- **`scripts/vagrant.sh`** — installs the Vagrant insecure key + passwordless
  sudo + DHCP on `eth0`.
- **`scripts/minimize.sh`** — zero-fills free space so the box compresses.
- **`Vagrantfile.tpl`** — the per-provider Vagrantfile baked into the `.box`.

We pass the ISO URL/checksum and QEMU knobs as `-var`s and build **only** the
QEMU source, with `-except vagrant-cloud` so nothing is ever uploaded.

**Two documented compat patches** (applied by default, `--verbatim` to skip) are
the *only* edits to upstream files — needed because the retired scripts no longer
build on 2026 Kali (see the README "Known issues" for the full why):

- `config.pkr.hcl`: `disk_cache = "unsafe"` → `"writeback"` — the "unsafe" cache
  ignores guest flushes, leaving root read-only after d-i's post-install reboot
  under KVM.
- `scripts/vagrant.sh`: `mkdir /home/vagrant/.ssh` → `mkdir -p …` — modern Kali's
  login session auto-creates `~/.ssh`, so the bare `mkdir` hits "File exists".

Other divergences are documented, **not** patched — e.g. `/dev/sda` is correct
for the builder's virtio-scsi disk, so no `→/dev/vda` rewrite is needed.

## Live data resolved at build time (dated, not vendored)

- **Kali installer ISO** — resolved from
  `https://kali.download/base-images/current/SHA256SUMS` (as of 2026-07-03:
  `kali-linux-2026.2-installer-amd64.iso`). `kali.download` is used because it
  serves the `SHA256SUMS` without the redirect that `cdimage.kali.org` issues.
- **packer** — with `--install-packer`, a pinned static binary
  (`packer 1.13.1`, SHA256-verified) from `releases.hashicorp.com`.
- **packer plugins** — `packer init` downloads the qemu/virtualbox/vmware/
  hyperv/vagrant plugins the config declares.

## Further reading (upstream)

- `README.packer.md` in the checkout — the full multi-hypervisor build guide.
- `README.vagrant.md` in the checkout — using the produced box with Vagrant.
- Kali's current factory: https://gitlab.com/kalilinux/build-scripts/kali-vm
  (debos) — operationalized in [`../kali-vm-builder/`](../kali-vm-builder/).
