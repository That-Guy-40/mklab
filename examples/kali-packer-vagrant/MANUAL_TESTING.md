# kali-packer-vagrant — build + boot runbook

End-to-end steps to build a Kali Vagrant box with Packer and boot it. The whole
flow — build → box → boot → login — was **verified here on KVM** (2026-07-03);
the transcript and findings (incl. two retired-script bitrots) are at the bottom.

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

## 3. Build the box (~11 min on KVM)

```bash
examples/kali-packer-vagrant/build-kali-box.sh                 # KVM, headless, QEMU only
# variations:
examples/kali-packer-vagrant/build-kali-box.sh --headless false   # watch the install in a window
examples/kali-packer-vagrant/build-kali-box.sh --accel tcg --ssh-timeout 180m   # no KVM (hours)
examples/kali-packer-vagrant/build-kali-box.sh --verbatim         # skip compat patches → see the bitrot fail
```

The build **auto-applies two compat patches** (log lines `[build] compat: …`) so
the *retired* upstream builds on current Kali — see
[README "Known issues"](README.md#known-issues-retired-script-bitrot). `--verbatim`
skips them, which reproduces the historical failures (a `Read-only file system`,
then a `File exists`, at the first provisioner).

> ### 👀 Eyeball the installer live (VNC) — even a headless build
>
> A **headless** build (the default) still exposes the guest's screen over VNC —
> Packer prints the address in its output:
>
> ```text
> ==> qemu.kalirolling: connect via VNC without a password to vnc://127.0.0.1:59XX
> ```
>
> Point a VNC client at that address to watch d-i partition, debootstrap, and
> install packages in real time. With `xtightvncviewer`
> (`sudo apt install -y xtightvncviewer`):
>
> ```bash
> xtightvncviewer 127.0.0.1::59XX      # e.g. 127.0.0.1::5979 for the line above
> ```
>
> **Mind the double colon.** In VNC address syntax a *single* colon means the
> *display number* (`127.0.0.1:5979` → display 5979 → TCP port 11879, which won't
> connect); a **`::`** forces the literal **TCP port** (`127.0.0.1::5979`). Packer
> picks the port fresh each build (it scans 5900–6000), so read `59XX` from the
> log — don't hardcode it. No password is set.

What you'll see (real transcript, KVM, 2026-07-03):

```text
[build] compat: config.pkr.hcl disk_cache → "writeback"  (KVM read-only-root fix)
[build] compat: scripts/vagrant.sh 'mkdir' → 'mkdir -p /home/vagrant/.ssh'
==> qemu.kalirolling: Retrieving ISO
==> qemu.kalirolling: Starting HTTP server on port 8938
==> qemu.kalirolling: Starting VM, booting from CD-ROM
==> qemu.kalirolling: Typing the boot commands over VNC...
==> qemu.kalirolling: Waiting for SSH to become available...
==> qemu.kalirolling: Connected to SSH!
==> qemu.kalirolling: Provisioning with shell script: scripts/vagrant.sh
==> qemu.kalirolling: Provisioning with shell script: scripts/minimize.sh
==> qemu.kalirolling: Gracefully halting virtual machine...
==> qemu.kalirolling: Converting hard drive...
==> qemu.kalirolling (vagrant): Compressing: box_0.img
Build 'qemu.kalirolling' finished after 10 minutes 58 seconds.
--> qemu.kalirolling: 'libvirt' provider box: packer_kalirolling_libvirt_amd64.box
[build] done: …/packer_kalirolling_libvirt_amd64.box (5.7G on disk)
```

Result: `~/kali-packer-build/kali-packer/packer_kalirolling_libvirt_amd64.box`
(**5.7 GB**). (Without the compat patches — `--verbatim` — it instead dies at
`Provisioning with shell script: scripts/vagrant.sh` with `Read-only file system`,
or `File exists` once the cache is fixed. See README "Known issues".)

## 4. Boot it (extraction + QEMU boot verified here ✓)

```bash
examples/kali-packer-vagrant/run-graphical.sh          # gtk window; login vagrant / vagrant
examples/kali-packer-vagrant/run-graphical.sh --memory 6G --cpus 4   # more muscle for the desktop
examples/kali-packer-vagrant/run-graphical.sh --display sdl          # if GTK/GL misbehaves
examples/kali-packer-vagrant/run-graphical.sh --display none         # headless boot-check (no window)
```

It auto-finds the newest `packer_kalirolling_*.box` (or pass `--box <path>` /
`--image <qcow2>`), unpacks `box.img` (the QCOW2) from the `.box` into
`<workdir>/images/`, makes a COW overlay (`--snapshot` throwaway / `--fresh`
reset), and boots under SeaBIOS + virtio-scsi. Then:

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
- **Full build, end-to-end** — with the compat patches, `build-kali-box.sh`
  produced a real **`packer_kalirolling_libvirt_amd64.box` (5.7 GB)** in 10m58s.
  `run-graphical.sh` unpacked its QCOW2 and booted it to a working **Kali GNU/Linux
  Rolling** (kernel 6.19, root ext4 rw, 0 failed units, 2877 pkgs incl. the XFCE
  desktop). Provisioning confirmed inside: **passwordless sudo** (`sudo -n` → root),
  `/etc/sudoers.d/vagrant`, and the HashiCorp **insecure key** in
  `~/.ssh/authorized_keys` — i.e. `scripts/vagrant.sh` ran clean.
- **The two bitrots + fixes** — getting there took 2 failed builds, root-caused
  from the aborted VM's journal (see README "Known issues"); `--verbatim`
  reproduces them.

## What is author-run (not run here)

- **The non-QEMU builders** — `virtualbox-iso` / `vmware-iso` / `hyperv-iso`
  (`--only …`) need that hypervisor installed; only the **QEMU** builder is
  verified here. `run-graphical.sh` boots only the QEMU/QCOW2 output anyway.

## Gotchas

- **Retired scripts need two compat patches on 2026 Kali** — applied by default;
  see README "Known issues (retired-script bitrot)". `--verbatim` to reproduce.
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
