# AlmaLinux's official image factory, vendored and runnable offline

AlmaLinux builds its **published** cloud and VM images with a Packer + Ansible pipeline:
[`AlmaLinux/cloud-images`](https://github.com/AlmaLinux/cloud-images). This lab keeps that
factory **byte-exact and pinned** in [`upstream-repo/`](upstream-repo/) — 563 files at
commit `6d808bf7` — and stages it into a work dir **offline**, verified against its own
`SHA256SUMS` on every run.

It is the AlmaLinux counterpart to
[`../kali-packer-vagrant/`](../kali-packer-vagrant/), and the two make the same point from
opposite ends: **drive-the-installer** image factories, vendored so they still run when
upstream does not.

## What this is, next to the two labs that already touch this repo

| lab | takes | pinned? | offline? |
|---|---|---|---|
| [`../almalinux-kickstart-gallery/`](../almalinux-kickstart-gallery/) | **only** `http/*.ks` — the kickstarts, as a browsable catalog | ✗ clones `main` at run time | ✗ |
| **this lab** | **the whole builder** — 34 `*.pkr.hcl` targets, the Ansible roles, the test suite | ✓ `6d808bf7` | ✓ |
| [`../almalinux-pxe-lab/`](../almalinux-pxe-lab/) | the installer artifacts (`vmlinuz`/`initrd.img`/`install.img`) | n/a | ✗ |

They are deliberately not merged. The gallery is about *kickstarts as a catalog*; this is
about *the factory as a mechanism* — and the mechanism is the interesting half, because it
is the one a reader cannot see from a rendered kickstart.

## ⚠️ This upstream is ALIVE, which changes the argument

The Kali sibling vendors a **retired** repo, where a URL is a poor custodian of something
nobody maintains. `cloud-images` is actively developed — its last commit was a week before
this snapshot. So the archive here is a **dated snapshot, not a mirror**:

- it *will* diverge from upstream, and that is expected rather than a defect;
- the pin and the retrieved date are the deliverable — they say *which* AlmaLinux factory
  this lab operationalizes;
- for "what does AlmaLinux build **today**", go to the canonical URL, not to this copy.

`fetch-cloud-images.sh --upstream` clones live `main` and warns when `HEAD` differs from the
pin, so you can see exactly what moved. Full reasoning:
[`upstream-repo/README.md`](upstream-repo/README.md).

## The pipeline (what the gencloud builder actually does)

The `gencloud` targets are the qcow2 ones, and the closest to what this repo can drive:

```
AlmaLinux-9-<ver>-x86_64-boot.iso              (the real netinstall ISO, checksum-pinned
        │  Packer boots it in a throwaway QEMU VM     in variables.pkr.hcl)
        ▼
boot_command typed at the boot prompt ──►  "inst.ks=http://{{.HTTPIP}}:{{.HTTPPort}}/ks.cfg"
        │
        ▼
http/almalinux-9-gencloud-x86_64.ks  (served by Packer)  ──►  unattended Anaconda install
        │
        ▼
Packer SSHes in  ──►  ansible/ roles  (cloud-init, repos, cleanup, image-specific tuning)
        ▼
a qcow2 — the same shape AlmaLinux publishes
```

That is the **same mechanism** as the Kali/Packer lab (screen-scrape an installer, serve a
config over HTTP, provision over SSH) with a different installer: **Anaconda + kickstart**
instead of **debian-installer + preseed**. Reading the two side by side is the point.

## Quick start

```bash
# Stage the pinned factory offline (verifies 563 files, no network):
examples/almalinux-packer-images/fetch-cloud-images.sh

# See what upstream has done since the pin (needs network):
examples/almalinux-packer-images/fetch-cloud-images.sh --upstream --workdir /tmp/alma-live

# Explore it — every builder, and the kickstart each one serves:
ls "$HOME/almalinux-cloud-images-build/cloud-images"/*.pkr.hcl
```

## Running an actual build — author-run, and honestly marked

**This lab does not claim to have built an image.** A `gencloud` build downloads a ~1 GB
netinstall ISO, wants `/dev/kvm`, runs a full Anaconda install plus the Ansible roles, and
takes tens of minutes. That is a *you run this* step, exactly as
[`CLAUDE.md`](../../CLAUDE.md)'s hand-walk convention requires for anything the agent
sandbox cannot execute.

What **is** verified here, on every CI run and by
[`tests/test-offline-archive.sh`](tests/test-offline-archive.sh):

- the archive matches its `SHA256SUMS` (563/563)
- the offline path stages a byte-identical tree with **no `.git`** (i.e. it did not clone)
- a **tampered** archive is refused **by name**, with nothing staged

The hand-walk environment — Packer + QEMU + the AlmaLinux prereqs as code — is
[`hand-walk/Containerfile`](hand-walk/Containerfile); the step-by-step is
[`hand-walk/RUNBOOK.md`](hand-walk/RUNBOOK.md). See
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) for the full author-run procedure and what a
successful build looks like.

## Files

| File | Role |
|---|---|
| [`fetch-cloud-images.sh`](fetch-cloud-images.sh) | Stage the factory: vendored+verified by default, `--upstream` to clone live. |
| [`upstream-repo/`](upstream-repo/) | The byte-exact archive + provenance + `SHA256SUMS`. |
| [`hand-walk/`](hand-walk/) | A disposable container reproducing the build environment. |
| [`tests/`](tests/test-offline-archive.sh) | The offline/verification guard. |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | The author-run build procedure. |
