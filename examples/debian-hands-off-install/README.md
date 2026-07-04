# Debian install via Philip Hands' **Hands-Off** framework

Operationalizes a Debian Developer's canonical d-i preseed *framework* — Philip
Hands' **[Hands-Off](https://hands.com/d-i/)** — so a blank VM installs Debian
hands-off, driven not by one static preseed but by a **chained, GPG-verified,
class-composed** preseed assembled live inside the installer.

This is the sophisticated sibling of [`debian-pxe-lab/`](../debian-pxe-lab/) and
[`debian-preseed-gallery/`](../debian-preseed-gallery/). Those serve a *file*;
this serves a *framework*. It is the d-i-side analog of the
[`kali-vm-builder/`](../kali-vm-builder/) "operationalize an upstream builder"
pattern — fetch the real upstream, drive it from this repo, add a thin lab layer.

> **Provenance:** Hands-Off is live, maintained code, so it's **fetched + pinned**
> (not vendored) — see [`UPSTREAM.md`](UPSTREAM.md). Pinned commit `ec6e817`
> (2026-05-18), GPL-2+, © Philip Hands.

---

## What makes Hands-Off different (the whole point of this lab)

A plain preseed (our other Debian labs) is **one file** d-i reads top to bottom.
Hands-Off is a **framework**. The entry `preseed.cfg` is nearly empty:

```
d-i preseed/run        string checksigs.sh
d-i preseed/run/checksum string 4fba7ccee0ba66490f9b9c53dbb53c2d
```

From there a chain unfolds — **this is the lesson**:

1. **`preseed/run` → `checksigs.sh`.** d-i's `preseed/run` runs a *script*, not
   just settings. `checksigs.sh` **bootstraps trust**: it fetches `MD5SUMS`,
   `MD5SUMS.sig`, `trustedkeys.gpg` and runs **`gpgv`** — so every fragment
   fetched afterward is checksum-verified against a **GPG-signed** manifest. This
   is Hands-Off's answer to *"preseeding over HTTP is insecure."*
2. **→ `start.sh`.** Downloads the framework's helper binaries (`populate_classes`,
   `foreach_class`, `filter_classes`, the `DC_fn.sh`/`HO_fn.sh` libs), wires up
   `preseed/early_command` + `preseed/late_command`, and detects the release
   **codename** from d-i itself.
3. **→ `assemble_preseed.sh`.** Runs **`populate_classes`** (which *classes* are
   active?) then **`foreach_class preseed`** — concatenating the `preseed`
   fragment from every active class into one assembled file, then
   `db_set preseed/include` feeds it back to d-i.
4. **The class tree** (`classes/`) is the model: `partition/atomic`,
   `partition/multi`, `desktop`, `loc/gb`, `net`, `setup/users`, … Each class is
   a dir with a `filter` (is it active?), a `preseed` fragment, and optional
   `script`/`recipe`. You **select classes on the boot line**:
   `auto-install/classes=partition/atomic;desktop;loc/gb`.

So an install is **composed** from reusable, individually-signed pieces —
modular, verifiable, and reusable across a fleet — versus copy-pasting a monolith
preseed per machine. That is the idea worth learning here.

---

## What this lab adds

Just a thin operationalization — the framework does the work:

| File | Role |
|---|---|
| `fetch-hands-off.sh` | Clone + pin Phil's `hands-off.git` into `~/hands-off-src` (nothing committed here). |
| `setup-hands-off.sh` | Stage its `trixie/` tree into `~/netboot/hands-off/trixie/`, apply the lab `local/` overlay, **re-sign** with a throwaway lab key (default), and symlink `~/netboot/files` → the framework's `files/` (see the `/files` note below). |
| `lab-overlay/local/` | The framework's **intended site hook** (`preseed/local/`): makes the minimal default install unattended (lab accounts, `/dev/vda` pin, serial console). |
| `debian-hands-off-lab.toml` | Unified Phase-4 nginx + Phase-2 installer VM. |
| [`UPSTREAM.md`](UPSTREAM.md) | Provenance + pinned commit + attribution. |
| `MANUAL_TESTING.md` | End-to-end runbook + the real captured transcript. |
| `ADDING-PACKAGES.md` | Add a package/desktop the Hands-Off way (a class, not an edit). |

Reuses the shared `netboot/build-ipxe.sh` and the `debian-pxe-lab` installer
fetcher.

---

## Quick start (QEMU zero-touch)

Run from the repo root; replace `/home/sqs` in the TOML with your `$HOME`.

```bash
# 1. Fetch + pin the framework:
examples/debian-hands-off-install/fetch-hands-off.sh

# 2. Stage it + the lab overlay, re-signed with a throwaway lab key (default):
examples/debian-hands-off-install/setup-hands-off.sh
#    (or: setup-hands-off.sh --no-sign   → adds `hands-off/checksigs=false` below)

# 3. Fetch the trixie d-i kernel + initrd (reuses the pxe-lab helper):
examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64

# 4. Build iPXE pointed at the Hands-Off entry preseed + a class selection:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /debian/linux --initrd-path /debian/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/hands-off/trixie/preseed.cfg auto-install/classes=partition/atomic DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'
#    --no-sign staging: insert `hands-off/checksigs=false ` before DEBIAN_FRONTEND.

# 5. Serve (Phase 4) + install (Phase 2):
phase4-podman/lab-podman.sh up --config examples/debian-hands-off-install/debian-hands-off-lab.toml
phase2-qemu-vm/lab-vm.sh create --config examples/debian-hands-off-install/debian-hands-off-lab.toml
phase2-qemu-vm/lab-vm.sh start  debian-hands-off-install
phase2-qemu-vm/lab-vm.sh console debian-hands-off-install     # watch the chain assemble
phase2-qemu-vm/lab-vm.sh ssh    debian-hands-off-install      # login: debian / debian  (root / lab)
```

### Choosing classes

The `auto-install/classes=` boot parameter picks what gets composed. Some to try
(semicolon-separated):

| Classes | Effect |
|---|---|
| `partition/atomic` | this lab's default — composes a `/boot` + an LVM VG (root + swap) |
| `partition/multi` | separate `/home`, `/var`, `/tmp` |
| `partition/atomic;desktop` | + a desktop task |
| *(blank)* | the framework's minimal default (but our overlay still needs a partition class to stay unattended) |

Change the class list in the iPXE `--append`, rebuild iPXE, then destroy +
recreate the VM.

### Tear down

```bash
phase4-podman/lab-podman.sh down    --lab debian-hands-off
phase2-qemu-vm/lab-vm.sh    destroy debian-hands-off-install --force
```

---

## Signing is load-bearing on modern d-i (a real finding)

`setup-hands-off.sh` **signs by default** — it regenerates `MD5SUMS` over the
staged tree (including our `local/` overlay), signs it with a **freshly-generated
throwaway lab key**, and replaces `trustedkeys.gpg` with a keyring holding only
that key. This is precisely how you deploy Hands-Off at a real site: *mirror it,
add your site config, re-sign with your key.* Booting **without**
`hands-off/checksigs=false`, `checksigs.sh`'s `gpgv` verifies the manifest
against the lab key, creates `/bin/preseed_lookup_checksum`, and the whole chain
runs verified.

**On trixie d-i, this is not optional** — it's required, and here's why (verified
from the installer's own syslog). Trixie's `/bin/preseed_fetch` supports the
`-C` (checksum-lookup) flag, so `start.sh` fetches every framework component
*with* `-C`. That flag needs `/bin/preseed_lookup_checksum` — which **only
`checksigs.sh` creates, and only in its signed/gpgv branch.** So if you boot
`hands-off/checksigs=false`, that branch is skipped, the lookup script is never
created, and the very first component fetch dies:

```
preseed: error fetching "/files/lib/HO_fn.sh": -C specified,
         but there is no /bin/preseed_lookup_checksum executable
preseed: error running ".../start.sh"
```

So `--no-sign` (which strips `preseed/run/checksum` and boots `checksigs=false`)
**does not complete on trixie** — it's kept only for older d-i whose
`preseed_fetch` lacks `-C`. The signed path is the one that works, which is a
neat lesson in itself: Hands-Off's GPG layer isn't security theater bolted on
top — on a modern installer the checksum machinery is *structurally* required
for the framework to run at all. (The throwaway lab key is a *demonstration* of
the mechanism, not a real trust anchor — never treat it as one.)

> **Security posture.** Throwaway plaintext lab creds (`root:lab`,
> `debian:debian`). Never serve on an untrusted network. Hands-Off's *real*
> value here is that its signing makes HTTP-served preseeding **tamper-evident** —
> but that only holds with a *real* key you control, not this lab's throwaway one.

---

## The `/files` serving gotcha (another verified finding)

`start.sh` fetches its helper binaries with a **host-absolute** path
(`preseed_fetch /files/lib/HO_fn.sh …`), which d-i resolves against the **server
root**, *not* the preseed's directory. Everything else — `preseed.cfg`,
`checksigs.sh`, `start.sh`, `MD5SUMS`, `classes/*`, `local/*` — is fetched
**relative** to `preseed.cfg`, so it works fine under `…/hands-off/trixie/`. Only
`/files` needs to resolve at the docroot. `setup-hands-off.sh` handles this by
symlinking `~/netboot/files` → `hands-off/trixie/files` (a **relative** symlink,
because the docroot is bind-mounted into the nginx container at a different path,
so an absolute target would dangle). Without it, the installer syslog shows
`http://…:8181//files/lib/HO_fn.sh → 404` and `start.sh` aborts. (Phil serves the
framework at a host root where `/files` naturally resolves; we serve it under a
subpath alongside the other labs, hence the alias.)

## Why this is separate from the other Debian preseed labs

| Lab | Preseed shape | Teaches |
|---|---|---|
| `debian-pxe-lab` | one static file | the d-i + preseed basics |
| `debian-preseed-gallery` | six generated files | partitioning variants from the official example |
| **this** | a live-assembled **framework** | chained `preseed/run`, GPG-verified fragments, class composition |

All three drive the same iPXE + nginx + QEMU `pxe-install` machinery — only the
*preseed* differs. Start with `debian-pxe-lab`; come here to see how far d-i
preseeding can be pushed.
