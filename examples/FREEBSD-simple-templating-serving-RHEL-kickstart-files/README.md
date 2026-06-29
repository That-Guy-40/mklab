# FREEBSD-simple-templating-serving-RHEL-kickstart-files — a FreeBSD box that kickstart-installs AlmaLinux

A **FreeBSD VM** that serves an **AlmaLinux** install over HTTP and hands Anaconda
a per-host kickstart on a tiny **`OEMDRV`** ISO — operationalizing **vermaden's**
**["Automated Kickstart Install of RHEL/Clones"](upstream-tutorial/2022/04/11/automated-kickstart-install-of-rhel-clones/index.html)**,
retargeted from RHEL 8.5 to **AlmaLinux 9**. The genuinely reusable idea is a
**rudimentary `sed` templating system** for kickstart files: a skeleton + a
per-host config → a rendered `ks.cfg` → an `OEMDRV`-labelled ISO that Anaconda
auto-loads (no PXE, no `inst.ks=` required).

Unlike the other Phase-5 examples, this is a **multi-VM infrastructure lab** driven
by **custom QEMU** (the repo's `phase2-qemu-vm/lab-vm.sh` has no FreeBSD backend),
with the FreeBSD server and the AlmaLinux client sharing a rootless qemu **socket
LAN** — mirroring vermaden's two-interface host.

> **Want the story, not just the steps?** [WALKTHROUGH.md](WALKTHROUGH.md) is an
> ultra-detailed, first-person "how I did it" with a verification command at every
> checkpoint — including the cloud-init-that-wasn't (**nuageinit**) detour.

## What is verified vs. ready-to-run

Everything novel about this lab is **machine-verified on real FreeBSD 14.3 (KVM)**
in this build session ([proof in MANUAL_TESTING](MANUAL_TESTING.md)):

| Piece | Status |
|---|---|
| FreeBSD VM boots + is driveable (cloud image, nuageinit) | ✅ verified |
| FreeBSD `pkg install` nginx + cdrtools(`mkisofs`) + sudo | ✅ verified |
| nginx serves the AlmaLinux tree over HTTP (autoindex) | ✅ verified (real upstream `repodata`) |
| `sed` templating engine → rendered `ks.cfg` + `OEMDRV` ISO | ✅ verified on **FreeBSD and Linux** |
| rendered kickstart is valid AlmaLinux 9 (`ksvalidator`) | ✅ verified |
| AlmaLinux **client Anaconda install** from the FreeBSD repo | 📝 **ready-to-run + documented (author-run)** |

The final Anaconda install is shipped wired and ready
([`run-kickme-client.sh`](run-kickme-client.sh)) but was **not** run in the build
session — it is a multi-GB DVD fetch + a minutes-long install, and the
Anaconda-kickstart mechanics are already proven by
[`../almalinux-pxe-lab/`](../almalinux-pxe-lab/README.md) and
[`../rocky-pxe-lab/`](../rocky-pxe-lab/README.md). This split is stated honestly
throughout, per the repo's hand-walk convention.

## Quick start

```bash
cd examples/FREEBSD-simple-templating-serving-RHEL-kickstart-files

# 1) Build the per-host kickstart + OEMDRV ISO (pure sed + mkisofs; runs anywhere)
( cd templating && sh kickstart.sh )            # -> files/kickme.cfg, iso/kickme.oemdrv.iso

# 2) Launch the FreeBSD server VM (fetches the image once; two NICs: slirp + socket LAN)
./run-freebsd-server.sh up                       # ssh -p 2222 -i ~/freebsd-kickstart-lab/id_lab freebsd@127.0.0.1

# 3) Provision it (as root on the VM): nginx + cdrtools + sudo + the lab-LAN IP
#    scp freebsd-server/setup-freebsd.sh over, su -, then: sh setup-freebsd.sh
#    populate the AlmaLinux tree:  ./fetch-almalinux.sh serve-dvd   (on the VM, as root)

# 4) Author-run: boot the AlmaLinux client; it installs unattended from the FreeBSD box
./fetch-almalinux.sh boot-iso                    # AlmaLinux boot ISO (host)
OEMDRV_ISO=templating/iso/kickme.oemdrv.iso ./run-kickme-client.sh

# teardown
./run-freebsd-server.sh stop
```

The clean by-hand walk with the *why* at each step is [RUNBOOK.md](RUNBOOK.md);
the full narrated build is [WALKTHROUGH.md](WALKTHROUGH.md).

## How the templating works (the "neat thing")

[`templating/kickstart.sh`](templating/kickstart.sh) sources
[`kickstart.config`](templating/kickstart.config) (so every `NAME=value` becomes a
shell variable), then runs **one `sed`** with a `-e s@TOKEN@${TOKEN}@g` per
variable over [`kickstart.skel`](templating/kickstart.skel), and `mkisofs`-wraps the
result as `/ks.cfg` on an ISO **labelled `OEMDRV`**:

```sh
. ./kickstart.config
sed -e s@REPO_SERVER_IP@${REPO_SERVER_IP}@g  -e s@IP_ADDRESS1@${IP_ADDRESS1}@g ... \
    kickstart.skel > files/${SYSTEM_NAME}.cfg
mkisofs -V "OEMDRV" -o iso/${SYSTEM_NAME}.oemdrv.iso  ks.cfg=files/${SYSTEM_NAME}.cfg ksfloppy
```

Anaconda auto-mounts any volume labelled `OEMDRV` and reads `/ks.cfg` — so the
kickstart is delivered with **no PXE and no `inst.ks=`**. The `@` delimiter avoids
escaping the `/` in URLs/paths.

### Delivery: OEMDRV (faithful) + the `inst.ks=` alternative

vermaden's method is the **OEMDRV ISO** as a second CD-ROM, reproduced faithfully
here. The same rendered `ks.cfg` also works the way the repo's other netboot labs
deliver it — as an HTTP URL on the kernel command line:

```
inst.ks=http://10.0.10.210/kickme.cfg  inst.repo=http://10.0.10.210/almalinux/9/BaseOS/x86_64/os
```

Serve `files/kickme.cfg` from the same FreeBSD nginx and point the installer at it
(see [RUNBOOK.md](RUNBOOK.md#alternative-instks-over-http)); useful for PXE/iPXE
flows like [`../almalinux-pxe-lab/`](../almalinux-pxe-lab/README.md).

## Files

| File | Purpose |
|---|---|
| [`templating/`](templating/) | The engine: `kickstart.config` + `kickstart.skel` + `kickstart.sh` |
| [`run-freebsd-server.sh`](run-freebsd-server.sh) | Launch the FreeBSD server VM (QEMU; slirp + socket LAN) |
| [`run-kickme-client.sh`](run-kickme-client.sh) | Launch the AlmaLinux client (boot ISO + OEMDRV) — author-run |
| [`fetch-almalinux.sh`](fetch-almalinux.sh) | Get the AlmaLinux boot ISO (host) / mount + serve the DVD (FreeBSD) |
| [`freebsd-server/`](freebsd-server/) | `cloud-init/` seed, `setup-freebsd.sh`, `nginx.conf` |
| [`WALKTHROUGH.md`](WALKTHROUGH.md) | First-person, ultra-detailed build with verification checkpoints |
| [`RUNBOOK.md`](RUNBOOK.md) | The clean by-hand operational walk |
| [`MANUAL_TESTING.md`](MANUAL_TESTING.md) | Real captured transcripts (verified vs author-run) |
| [`upstream-tutorial/`](upstream-tutorial/README.md) | Byte-exact vermaden article + provenance |

## Scope & caveats

- **Throwaway lab.** VMs are disposable overlays; credentials (`freebsd`/`freebsd`,
  kickstart `rootpw alma`) are lab-only — change them for anything real.
- **FreeBSD ≠ container.** It can't be an LXD/Incus system container, and
  `lab-vm.sh` has no FreeBSD backend, so this lab drives QEMU directly. That is the
  documented exception to "drive it through the existing phases."
- **The cloud image runs nuageinit, not cloud-init** — only ssh keys + hostname +
  `chpasswd` are honoured from cloud-config; provisioning is done post-boot. See
  [WALKTHROUGH.md Part 3](WALKTHROUGH.md#part-3--the-cloud-init-that-isnt-meeting-nuageinit).
- **The client install is author-run** (multi-GB, minutes), shipped ready-to-run.
- **AlmaLinux, not RHEL.** Retargeted from vermaden's RHEL 8.5 (which needs a
  subscription) to free AlmaLinux 9; the kickstart syntax is adapted 8→9.

## Prerequisites

- A Linux host with **QEMU/KVM** (`qemu-system-x86_64`, `/dev/kvm`), `qemu-img`,
  `genisoimage`/`mkisofs`, `xz`, `curl`; **OVMF** for the UEFI client; `pykickstart`
  (`ksvalidator`) to validate. ~15 GB free for the FreeBSD image + overlays (much
  more if you mirror the full AlmaLinux DVD).

## Sources

The tutorial is © **vermaden** and carries no explicit license; it is vendored
byte-exact for **offline educational reference** under
[`upstream-tutorial/`](upstream-tutorial/README.md) (provenance + `sha256`).

- Tutorial: <https://vermaden.wordpress.com/2022/04/11/automated-kickstart-install-of-rhel-clones/>

See [`../00-INDEX.md`](../00-INDEX.md) for the full example catalog.
