# Hand-walk: build a Kali Vagrant box with Kali's own retired Packer scripts

Walks [`kali-packer`](../upstream-repo/kali-packer/) by hand in a disposable Kali container,
from the **vendored, pinned** copy — so the steps still work now that upstream is retired.
The recipe's source of truth is the archive's own
[`README.packer.md`](../upstream-repo/kali-packer/README.packer.md); this file adds the
*why* and the gotchas.

Contrast with the automated path: [`../build-kali-box.sh`](../build-kali-box.sh) does all of
this in one command. Walk it by hand once and that script stops being magic.

## ✅ What is verified here, and what is yours to run

| step | status |
|---|---|
| build this container | ✅ **verified 2026-08-06** (`podman build`, clean) |
| `packer init` — 5 plugins | ✅ **verified** |
| `build-kali-box.sh --validate-only` inside the box | ✅ **verified — `The configuration is valid.`** |
| `packer build` (a ~4 GB ISO, a full unattended install, ~30 min, needs `/dev/kvm`) | ⛔ **author-run** |

The validate run is not a formality: it is the first time the **vendored bytes** were proven
to be a valid Packer config — parsed by packer 1.16.0, with both compat patches applied and
every builder/provisioner/post-processor schema checked.

## 1. Stage the pinned scripts (offline)

```bash
examples/kali-packer-vagrant/fetch-kali-packer.sh
# [fetch] archive verified: 17 files match
```

Verifies all 17 files against `SHA256SUMS` and **refuses** a mismatch. Upstream is retired,
so this archive — not GitLab — is what the lab builds from.

## 2. Build the sandbox

```bash
podman build -t kali-packer-handwalk examples/kali-packer-vagrant/hand-walk
```

### ⚠️ The gotcha this file exists to record

The obvious way to add HashiCorp's apt repo — the one this lab's own README and most of the
internet give — is:

```sh
echo "deb [...] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
```

On **Kali**, `lsb_release -cs` is `kali-rolling`, and HashiCorp publishes no such suite:

```
Err:3 https://apt.releases.hashicorp.com kali-rolling Release
  404  Not Found
E: The repository '… kali-rolling Release' does not have a Release file.
```

Kali rolling tracks Debian testing/sid, so a Debian suite is the correct substitution; the
`Containerfile` pins `bookworm`. **This is what a hand-walk is for** — the environment as
code refuses to build until the instruction is true, where prose can be wrong for years.

## 3. Enter it, with the scripts mounted and KVM passed through

```bash
podman run --rm -it --device /dev/kvm \
  -v "$HOME/kali-packer-build/kali-packer":/work:Z \
  -w /work localhost/kali-packer-handwalk
```

**`--device /dev/kvm` is not optional in practice.** Without it Packer falls back to TCG and
the install goes from ~30 minutes to hours.

## 4. Read before you run

```bash
grep -n 'boot_command' -A6 config.pkr.hcl     # what Packer TYPES at the installer
sed -n '1,30p' http/preseed.cfg               # …an ordinary d-i preseed
cat scripts/vagrant.sh                        # the insecure key + passwordless sudo
```

The `boot_command` is the whole trick: Packer types a kernel command line over VNC pointing
d-i at `http://{{.HTTPIP}}:{{.HTTPPort}}/preseed.cfg`, which Packer itself serves. That one
line is the difference between this and the *assemble-a-rootfs* factories
([`../../kali-vm-builder/`](../../kali-vm-builder/)), and the bridge back to
[`../../kali-preseed-gallery/`](../../kali-preseed-gallery/) — same preseed, delivered
differently.

## 5. Initialise and validate

```bash
packer init .
```

Installs the qemu, virtualbox, vmware, hyperv and vagrant plugins. Bare `packer validate .`
will **fail** with *"One of iso_url or iso_urls must be specified"* — that is correct, not a
defect: the ISO URL and checksum are `-var`s the driver resolves from Kali's live
`SHA256SUMS`. To validate the way the lab does:

```bash
/repo/examples/kali-packer-vagrant/build-kali-box.sh --validate-only --workdir /tmp/kb
# → The configuration is valid.
```

(mount the repo with `-v "$PWD":/repo:Z` to have that path available.)

## 6. Build — author-run

```bash
packer build -only='qemu.kalirolling' -except=vagrant-cloud \
  -var "iso_url=<from kali.download>" -var "iso_checksum=sha256:<…>" .
```

or simply `build-kali-box.sh`, which resolves those for you. Watch it over VNC:
`xtightvncviewer 127.0.0.1::59XX` — the **double** colon is a TCP port; a single colon is a
display *number*.

**Two compat patches are applied by default** (`--verbatim` to reproduce the failures) —
`disk_cache=unsafe` → `writeback`, and `mkdir` → `mkdir -p`. See
[`../README.md`](../README.md#known-issues-retired-script-bitrot) for why a *retired* factory
stops building.

## 7. Boot the result

```bash
examples/kali-packer-vagrant/run-graphical.sh
```
