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
| a real `packer build` producing a qcow2 | ⛔ **NOT RUN** — needs `/dev/kvm`, a ~1 GB ISO, tens of minutes |
| booting the produced image | ⛔ **NOT RUN** |

**Nothing here claims an image was built.** Unlike
[`../kali-packer-vagrant/`](../kali-packer-vagrant/MANUAL_TESTING.md), which was built and
booted end to end, this lab ships the *factory* verified and the *build* author-run. That is
why there is no `build-alma-image.sh`: a wrapper would imply a path somebody had walked.

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
