# MANUAL_TESTING — almalinux-packer-images

## Status, stated plainly

| what | status |
|---|---|
| the archive matches its 563-file `SHA256SUMS` | ✅ **verified**, and re-verified on every stage |
| offline staging: byte-identical tree, no clone | ✅ **verified** ([`tests/test-offline-archive.sh`](tests/test-offline-archive.sh)) |
| a tampered archive is refused by name, nothing staged | ✅ **verified** (negative control run) |
| the `.gitignore` trap is not hiding a file | ✅ **verified** (563 on disk == in manifest == tracked) |
| the hand-walk container builds | ✅ **verified 2026-08-06** |
| `packer init` (ansible/qemu/hyperv plugins) | ✅ **verified** |
| `packer validate -only='qemu.almalinux-9-gencloud-x86_64'` | ✅ **verified — `The configuration is valid.`** — the vendored 563 files parse as a valid Packer config at packer 1.16.0 |
| a real `packer build` producing a qcow2 | ✅ **VERIFIED 2026-08-06** — `AlmaLinux-9-GenericCloud-9.8-20260806.x86_64.qcow2`, 567 MB, **5 min 55 s** |
| booting the produced image | ✅ **VERIFIED** — boots to `localhost login:` (AlmaLinux 9.8 "Olive Jaguar") |

**An image was built and booted 2026-08-06**, from the vendored archive, in the hand-walk
container. There is still no `build-alma-image.sh`: the build is two commands and a wrapper
would hide the two host-specific `-var`s below, which are the interesting part.

## The automated part (runs anywhere, no root, no network)

```bash
bash examples/almalinux-packer-images/tests/test-offline-archive.sh
```

Expected:

```
  - archive matches SHA256SUMS
  - 563 files: on disk == in SHA256SUMS == tracked by git (the .gitignore trap is not biting)
  - default stage: offline, verified, byte-identical, no .git
  - tampered archive: refused by name, naming the file, nothing staged
  - the committed archive still verifies — this test modified nothing in the repo
PASS: the AlmaLinux factory stages offline from a verified 563-file archive …
```

### Negative controls, and how to re-run them

Both were run when the test was written; re-run either to confirm the assertions still bite.

1. **The verification actually verifies.** Append a byte to a file in a *copy* of the lab
   and stage from it — the fetch must exit non-zero, name `SHA256SUMS`, name the file, and
   stage nothing.
2. **The `.gitignore` trap.** `git rm --cached
   upstream-repo/cloud-images/tests/test-values.pkrvars.hcl`, re-run the test: it must fail
   with *"git tracks 562 of the 563 archived files"*. Restore with `git add -f` on the same
   path. This is the real trap — upstream's `.gitignore` lists `*.pkrvars.hcl` **and**
   upstream tracks that file, so vendoring verbatim drops it silently.

## The author-run part

Full procedure: [`hand-walk/RUNBOOK.md`](hand-walk/RUNBOOK.md). Short form:

```bash
examples/almalinux-packer-images/fetch-cloud-images.sh
podman build -t alma-packer-handwalk examples/almalinux-packer-images/hand-walk
podman run --rm -it --device /dev/kvm \
  -v "$HOME/almalinux-cloud-images-build/cloud-images":/work:Z \
  -w /work localhost/alma-packer-handwalk
# inside:
packer init .
packer validate -only='qemu.almalinux-9-gencloud-x86_64' .
packer build   -only='qemu.almalinux-9-gencloud-x86_64' .
```

### What success looks like

- `packer validate` exits 0 with no output.
- `packer build` logs a VNC address, then Anaconda progress, then `Provisioning with
  Ansible`, then an artifact path ending in `.qcow2`.
- The qcow2 boots via `phase2-qemu-vm/lab-vm.sh --backend disk-image --firmware bios` to a
  login prompt, with `cloud-init` having run.

### Known cost and gotchas

- **`/dev/kvm` or hours.** Without it Packer falls back to TCG; a full Anaconda install goes
  from tens of minutes to hours.
- **Disk:** the ISO (~1 GB) plus the output qcow2 plus Packer's cache — allow ~15 GB.
- **VNC:** `xtightvncviewer 127.0.0.1::59XX` — the **double** colon is a TCP port; a single
  colon is a display number.
- **Upstream is alive.** If `--upstream` reports a HEAD different from the pin, that is
  expected, not a failure. The pin says which factory this lab documents.

## Checking the archive against live upstream

```bash
examples/almalinux-packer-images/fetch-cloud-images.sh --upstream --workdir /tmp/alma-live
diff -r examples/almalinux-packer-images/upstream-repo/cloud-images /tmp/alma-live/cloud-images
```

A non-empty diff is the honest answer to *"how stale is the snapshot?"* — record the date
and the delta rather than silently re-pinning.

## The verified build — 2026-08-06

```bash
examples/almalinux-packer-images/fetch-cloud-images.sh
podman build -t alma-packer-handwalk examples/almalinux-packer-images/hand-walk
podman run --rm --device /dev/kvm \
  -v "$HOME/almalinux-cloud-images-build/cloud-images":/work:Z -w /work \
  localhost/alma-packer-handwalk \
  bash -c 'packer init . && packer build -only="qemu.almalinux-9-gencloud-x86_64" \
                                          -var qemu_binary=/usr/libexec/qemu-kvm .'
```

| | |
|---|---|
| source | the **vendored archive**, offline (`archive verified: 563 files match`) |
| ISO | `AlmaLinux-9.8-x86_64-boot.iso`, checksum-verified by packer |
| Anaconda | installed unattended from `http/*.ks`, SSH came up |
| Ansible | `ok=36 changed=23 unreachable=0 **failed=0** skipped=24` |
| wall clock | **5 min 55 s** |
| artifact | `AlmaLinux-9-GenericCloud-9.8-20260806.x86_64.qcow2`, **567 MB**, 10 GiB virtual, UEFI |

### ⚠️ Two host-specific knobs, both found by running it

**1. `-var qemu_binary=/usr/libexec/qemu-kvm` is REQUIRED on RHEL-family.** Upstream's
`qemu_binary` variable defaults to `null`, so packer falls back to `qemu-system-x86_64` —
a name **RHEL, AlmaLinux and Rocky do not ship**. The build dies in under a millisecond:

```
Build errored after 819 microseconds: Failed creating Qemu driver:
  exec: "qemu-system-x86_64": executable file not found in $PATH
```

The irony is worth noting: **upstream's own default does not work on upstream's own
distro.** Their CI runs on Debian-family runners, where the name exists. The variable is
there precisely for this, so passing it is the supported fix, not a workaround.

**2. Booting the result needs a v2-capable CPU model.** AlmaLinux 9 is built for the
**x86-64-v2** microarchitecture level, and QEMU's default `qemu64` CPU does not advertise
it. The kernel boots fine and then init dies instantly:

```
Run /init as init process
Fatal glibc error: CPU does not support x86-64-v2
Kernel panic - not syncing: Attempted to kill init! exitcode=0x00007f00
```

`exitcode=0x7f00` is exit status **127** — glibc refusing before anything ran. Use
`-cpu host` (or `-cpu Nehalem`/`x86-64-v2`). This is a *harness* mistake, not an image
defect, and it is easy to misread as a broken build.

### The boot proof

```bash
qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 2048 -smp 2 -nographic \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive if=pflash,format=raw,file=<a copy of>/OVMF_VARS_4M.fd \
  -drive file=<the>.qcow2,format=qcow2,if=virtio,snapshot=on \
  -serial mon:stdio -display none
```

`snapshot=on` so the built image is never written to. Reaches:

```
AlmaLinux 9.8 (Olive Jaguar)
Kernel 5.14.0-687.34.1.el9_8.x86_64 on an x86_64

localhost login:
```
