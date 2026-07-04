# kali-packer-vagrant — build + boot runbook

End-to-end steps to build a Kali Vagrant box with Packer and boot it, plus what
was **verified here** vs. what is **author-run** (the long build).

> Run from the repo root. Artifacts go to `$KALI_PACKER_DIR`
> (default `$HOME/kali-packer-build`) — outside this repo.

## 0. Preflight

```bash
command -v qemu-system-x86_64 qemu-img git tar || echo "install: qemu-system-x86 qemu-utils git tar"
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM ok" || echo "no KVM — build falls back to slow tcg"
id -nG | tr ' ' '\n' | grep -qx kvm && echo "in kvm group" || echo "sudo adduser \$USER kvm; re-login"
command -v packer && packer version | head -1 || echo "no packer — use --install-packer or the apt repo (step 1b)"
```

## 1a. Fetch + pin the upstream scripts (verified here ✓)

```bash
examples/kali-packer-vagrant/fetch-kali-packer.sh
# → [fetch] ready: ~/kali-packer-build/kali-packer @ b8c9b34
```

The checkout must contain `config.pkr.hcl`, `http/preseed.cfg`, `scripts/*.sh`,
`Vagrantfile.tpl`. If HEAD drifts from the recorded pin you'll get a WARNING (not
a failure) — update `UPSTREAM.md` if upstream moved.

## 1b. Get packer (pick one)

```bash
# Easiest — let the lab fetch a pinned, SHA256-verified static binary into the workdir:
examples/kali-packer-vagrant/build-kali-box.sh --install-packer --validate-only

# …or HashiCorp's apt repo (Debian/Ubuntu/Kali):
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y packer
```

## 2. Validate the config (fast — no VM, no download)

```bash
examples/kali-packer-vagrant/build-kali-box.sh --validate-only
```

Expect `packer init` to install five plugins, then:

```text
[build] validate: OK — config + all builder/provisioner/post-processor schemas are valid
```

(`fmt -check` may report cosmetic diffs against upstream — informational, not a
failure.) This is the highest-value cheap check: it proves the pinned config
parses and every builder/provisioner/post-processor schema is satisfied on your
packer + plugin versions.

## 3. Build the box (author-run — long)

```bash
examples/kali-packer-vagrant/build-kali-box.sh                 # KVM, headless, QEMU only
# variations:
examples/kali-packer-vagrant/build-kali-box.sh --headless false   # watch the install in a window
examples/kali-packer-vagrant/build-kali-box.sh --accel tcg --ssh-timeout 180m   # no KVM (hours)
```

What you'll see (matches the upstream README transcript):

```text
==> qemu.kalirolling: Retrieving ISO
==> qemu.kalirolling: Starting HTTP server on port NNNNN
==> qemu.kalirolling: Starting VM, booting from CD-ROM
==> qemu.kalirolling: Typing the boot commands over VNC...
==> qemu.kalirolling: Waiting for SSH to become available...
==> qemu.kalirolling: Connected to SSH!
==> qemu.kalirolling: Provisioning with shell script: scripts/vagrant.sh
==> qemu.kalirolling: Provisioning with shell script: scripts/minimize.sh
==> qemu.kalirolling (vagrant): Creating Vagrant box for 'libvirt' provider
Build 'qemu.kalirolling' finished after NN minutes.
--> qemu.kalirolling: 'libvirt' provider box: packer_kalirolling_libvirt_amd64.box
```

Result: `~/kali-packer-build/kali-packer/packer_kalirolling_libvirt_amd64.box`
(~5–6 GB).

## 4. Boot it (extraction + QEMU boot verified here ✓)

```bash
examples/kali-packer-vagrant/run-graphical.sh          # gtk window; login vagrant / vagrant
# headless boot-check (no window):
examples/kali-packer-vagrant/run-graphical.sh --display none
```

It unpacks `box.img` (the QCOW2) from the `.box`, makes a COW overlay, and boots
under SeaBIOS + virtio-scsi. Then:

```bash
ssh -p 2222 vagrant@127.0.0.1        # password: vagrant  (passwordless sudo inside)
```

---

## What was verified here (2026-07-03)

- **Fetch + pin** — `fetch-kali-packer.sh` clones `kali-packer` and lands on
  `b8c9b34`; all expected upstream files present.
- **ISO resolver** — `curl …/base-images/current/SHA256SUMS` resolves
  `kali-linux-2026.2-installer-amd64.iso` + its sha256 (the URL/checksum the
  build hands to packer).
- **`packer init` + `packer validate`** — with `packer 1.13.1` + all five plugins
  (qemu/virtualbox/vmware/hyperv/vagrant), the pinned upstream config gives
  `fmt: OK` and `The configuration is valid.` — every builder/provisioner/
  post-processor schema checks out. (`--install-packer` fetched + SHA-verified
  the static binary first.)
- **Driver scripts** — `bash -n` clean on all three; `--help` renders; unknown-arg
  and packer-missing paths fail with clear messages.
- **`.box` → boot pipeline** — built a **synthetic** vagrant/libvirt box (a real
  8 MB qcow2 named `box.img` + `metadata.json` + `Vagrantfile`);
  `run-graphical.sh --extract-only` pulled the qcow2 out and `qemu-img` confirmed
  it; a timeout-boot then launched QEMU with the full virtio-scsi arg vector and
  created the COW overlay (exit 124 = ran until killed = args valid).

## What is author-run (not run here)

- **The full `packer build`** — downloads ~4 GB and runs a full Kali install
  (~20–40 min on KVM, hours on tcg). Same posture as `kali-vm-builder`: long,
  host-specific, and offensive-tooling — so it's yours to run.

## Gotchas

- **No packer, no build.** It isn't in the default distro repos — use
  `--install-packer` or the HashiCorp apt repo (step 1b).
- **tcg is slow.** Without `/dev/kvm` the install can take hours; raise
  `--ssh-timeout` (e.g. `180m`) or Packer aborts waiting for SSH.
- **`/dev/sda` in the preseed is correct here.** The QEMU builder uses
  `virtio-scsi` (SCSI naming → `/dev/sda`), so the upstream preseed's
  `grub-installer/bootdev /dev/sda` needs **no** rewrite — unlike the virtio-blk
  PXE labs that patch `/dev/sda`→`/dev/vda`. `run-graphical.sh` boots virtio-scsi
  to match.
- **`validate` needs a real ISO filename.** packer's `file:` checksum resolves by
  matching the ISO URL's *basename* against `SHA256SUMS`, so even a no-build
  `validate` fails ("no checksum found") with a placeholder name — that's why
  `build-kali-box.sh` resolves the current filename before validating, not just
  before building.
- **This is the retired path.** Kali no longer ships Vagrant boxes from these
  scripts (debos does the images now). You're building a historical artifact —
  which is the point.
