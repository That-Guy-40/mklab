# Hand-walk: build an AlmaLinux cloud image with upstream's own Packer factory

Walks [`AlmaLinux/cloud-images`](../upstream-repo/cloud-images/) by hand, in a disposable
container, using the **vendored, pinned** copy — so the steps are reproducible even after
upstream moves. The source of truth for the recipe is the archive's own
[`README.md`](../upstream-repo/cloud-images/README.md); this file adds the *why* and the
gotchas.

Contrast with the automated path: [`../fetch-cloud-images.sh`](../fetch-cloud-images.sh)
stages the factory and you drive `packer` yourself — there is deliberately **no**
`build-alma-image.sh` wrapper, because unlike the Kali sibling this repo has not verified a
build end to end and a wrapper would imply otherwise.

## ⚠️ What is verified, and what is yours to run

| step | who |
|---|---|
| stage + verify the pinned factory (563 files) | ✅ automated, CI-gated |
| build the container image below | ✅ **verified 2026-08-06** (`podman build`, clean) |
| `packer init` (downloads plugins) | ✅ **verified** — ansible, qemu, hyperv plugins install |
| `packer validate -only='qemu.almalinux-9-gencloud-x86_64'` | ✅ **verified — `The configuration is valid.`** |
| `packer build` (~1 GB ISO, Anaconda, needs `/dev/kvm`) | ✅ **verified 2026-08-06 — 5 min 55 s → a 567 MB qcow2** |
| booting the result | ✅ **verified — `localhost login:`** |

The agent sandbox cannot run the last three: `/dev/kvm` and a multi-GB fetch-and-execute are
author-only. They are marked rather than claimed, per
[`CLAUDE.md`](../../../CLAUDE.md)'s hand-walk convention.

## 1. Stage the pinned factory (offline)

```bash
examples/almalinux-packer-images/fetch-cloud-images.sh
# → $HOME/almalinux-cloud-images-build/cloud-images
```

It verifies all 563 files against `SHA256SUMS` first and **refuses** a mismatch. That is not
ceremony: the archive is a dated snapshot of an *actively maintained* repo, and an
unverified snapshot looks authoritative while being whatever someone last edited.

## 2. Build the sandbox

```bash
podman build -t alma-packer-handwalk examples/almalinux-packer-images/hand-walk
```

Reproduces the RHEL-9 environment upstream assumes: QEMU/KVM, Packer from HashiCorp's own
RPM repo, `ansible-core` for the provisioning half.

## 3. Enter it, with the factory mounted and KVM passed through

```bash
podman run --rm -it --device /dev/kvm \
  -v "$HOME/almalinux-cloud-images-build/cloud-images":/work:Z \
  -w /work localhost/alma-packer-handwalk
```

**`--device /dev/kvm` is not optional in practice.** Without it Packer silently falls back
to TCG and a full Anaconda install goes from tens of minutes to hours — the same lesson the
Kali sibling records for its `--accel` flag.

## 4. Look before you build

```bash
ls *.pkr.hcl | head -20        # 34 targets: ami, azure, gcp, oci, opennebula, vagrant, gencloud…
grep -n 'iso_url_9_x86_64\|iso_checksum_9_x86_64' variables.pkr.hcl
sed -n '1,40p' http/almalinux-9-gencloud-x86_64.ks
```

The `gencloud` targets are the qcow2 ones and the right first walk. Note the ISO URL **and
its checksum** are pinned in `variables.pkr.hcl` — the factory refuses an ISO that does not
match, which is the same discipline this repo applies to its own downloads (AUDIT F2).

### ⚠️ On RHEL-family, `packer` is ambiguous — and the WRONG one wins

`cracklib-dicts` ships **`/usr/sbin/packer`** (a symlink to `cracklib-packer`); HashiCorp's
lands at `/usr/bin/packer`. Root's PATH puts `/usr/sbin` **first**, so a plain
`packer version` runs cracklib's, which prints

```
0 0
```

and **exits 0**. Not an error — a different program, answering confidently, with a success
code. Measured here 2026-08-06: `packer validate` on the vendored templates "succeeded"
twice while validating nothing at all.

That is a false success, which this repo ranks above an honest failure as a thing to fix.
The `Containerfile` puts `/usr/bin` first **and** carries a build-time assertion that
`packer version` starts with `Packer v` — so the image cannot exist if the name resolves
wrongly. A PATH tweak is a mechanism; the assertion checks the outcome.

If you are on a RHEL-family host rather than this container, check first:

```bash
command -v packer && packer version | head -1     # must say "Packer v…"
```

## 5. Initialise and validate — cheap, and it catches most mistakes

```bash
packer init .
packer validate -only='qemu.almalinux-9-gencloud-x86_64' .
```

`packer init` downloads the plugins the templates declare (qemu, ansible, and the cloud
publishers). `validate` parses everything without booting anything.

## 6. Build one target

```bash
packer build -only='qemu.almalinux-9-gencloud-x86_64' -var qemu_binary=/usr/libexec/qemu-kvm .
```

### ⚠️ `-var qemu_binary=...` is REQUIRED here, and the reason is worth a minute

Upstream's `qemu_binary` variable defaults to `null`, so packer falls back to
`qemu-system-x86_64` — **a binary name RHEL, AlmaLinux and Rocky do not ship.** They ship
`/usr/libexec/qemu-kvm`. Without the override the build dies in under a millisecond:

```
Build errored after 819 microseconds: Failed creating Qemu driver:
  exec: "qemu-system-x86_64": executable file not found in $PATH
```

**Upstream's own default does not work on upstream's own distro** — their CI runs on
Debian-family runners, where that name exists. The variable exists precisely for this, so
passing it is the supported fix rather than a workaround. It is also a neat illustration of
why a hand-walk on *the author's distro* finds things a build on a convenient distro does
not.

Watch it: boot the netinstall ISO → type the `inst.ks=http://…` boot command → Anaconda
installs unattended from `http/*.ks` → Packer SSHes in → the `ansible/` roles run → a qcow2
drops out.

**Watch the install over VNC even when headless** — Packer logs
`connect via VNC without a password to vnc://127.0.0.1:59XX`. Use `xtightvncviewer
127.0.0.1::59XX` — note the **`::`**, a single colon is read as a display *number*, which
is the trap the Kali lab documents too.

## 7. Boot what you built

The output qcow2 can be booted straight through this repo's phase 2:

```bash
phase2-qemu-vm/lab-vm.sh create --name almapacker --backend disk-image \
    --image <path-to>/AlmaLinux-9-GenericCloud-9.8-*.x86_64.qcow2 --firmware uefi
phase2-qemu-vm/lab-vm.sh start almapacker
```

The image is **UEFI** (packer leaves an `efivars.fd` beside it), so `--firmware uefi`.

### ⚠️ And booting needs a v2-capable CPU

AlmaLinux 9 targets the **x86-64-v2** microarchitecture level; QEMU's default `qemu64` CPU
does not advertise it. The kernel boots normally and then init dies instantly:

```
Run /init as init process
Fatal glibc error: CPU does not support x86-64-v2
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

`0x7f00` is exit status **127** — glibc refusing before anything ran. Pass `-cpu host`
(or `-cpu Nehalem` / `x86-64-v2`). This is a *harness* mistake and not an image defect, but
it reads exactly like a failed build, which is why it is written down here.

## Where this differs from the sibling labs

- [`../../kali-packer-vagrant/`](../../kali-packer-vagrant/) — **the same mechanism, a
  different installer**: debian-installer + preseed, versus Anaconda + kickstart. Read the
  two `boot_command`s side by side; that one line is the whole difference.
- [`../../almalinux-kickstart-gallery/`](../../almalinux-kickstart-gallery/) — consumes
  **only** `http/*.ks` from this same upstream, unpinned. The catalog view; this is the
  factory view.
