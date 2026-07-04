# Hands-Off install — end-to-end boot-verify

Runbook for driving a full trixie install via Philip Hands' Hands-Off framework,
plus the real debugging story (this lab exposed two genuine
serve-it-under-a-subpath gotchas). Shares the boot-loop stage table with
[`../debian-pxe-lab/MANUAL_TESTING.md`](../debian-pxe-lab/MANUAL_TESTING.md) —
read that for preflight.

> Run from the repo root; replace `/home/sqs` in the TOML with your `$HOME`.

---

## Steps

```bash
# 1. Fetch + pin the framework:
examples/debian-hands-off-install/fetch-hands-off.sh

# 2. Stage + overlay + re-sign (default), and create the /files,/classes,/local aliases:
examples/debian-hands-off-install/setup-hands-off.sh

# 3. Installer kernel/initrd (once):
examples/debian-pxe-lab/fetch-debian-installer.sh --arch amd64

# 4. iPXE — SIGNED path (no checksigs=false), pick a partition class:
netboot/build-ipxe.sh --server http://10.0.2.2:8181 \
    --kernel-path /debian/linux --initrd-path /debian/initrd.gz \
    --append 'auto=true priority=critical preseed/url=http://10.0.2.2:8181/hands-off/trixie/preseed.cfg auto-install/classes=partition/atomic DEBIAN_FRONTEND=text console=ttyS0,115200n8 ---'

# 5. Serve + install:
phase4-podman/lab-podman.sh up --config examples/debian-hands-off-install/debian-hands-off-lab.toml
phase2-qemu-vm/lab-vm.sh create --config examples/debian-hands-off-install/debian-hands-off-lab.toml
phase2-qemu-vm/lab-vm.sh start  debian-hands-off-install
phase2-qemu-vm/lab-vm.sh console debian-hands-off-install
```

## Serving sanity (the #1 failure point for this lab)

The framework mixes relative and **host-absolute** fetch paths, so the aliases
must resolve at the docroot:

```bash
curl -sI http://localhost:8181/hands-off/trixie/preseed.cfg | head -1   # 200 (relative base)
curl -sI http://localhost:8181/files/lib/HO_fn.sh            | head -1   # 200 (start.sh: /files absolute)
curl -sI http://localhost:8181/classes/_/defaults/debian/preseed | head -1  # 200 (foreach_class: /classes absolute)
curl -sI http://localhost:8181/local/preseed                | head -1   # 200 (the lab overlay)
```

Any `404` here → `setup-hands-off.sh` didn't create the `~/netboot/{files,classes,local}`
symlinks (or they're absolute and dangle inside the nginx container — they must
be **relative**).

---

## The chain, verified from the installer's own syslog

Booted end-to-end on KVM (x86_64, 2026-07-03). The framework bootstrap, captured
live from `/var/log/syslog` via the d-i shell (main menu → *Execute a shell*):

```text
preseed: successfully loaded preseed file from …/hands-off/trixie/preseed.cfg
preseed/run: + db_get hands-off/checksigs        → (unset; signed path)
preseed/run: + gpgv --keyring …/trustedkeys.gpg …/MD5SUMS.sig …/MD5SUMS
preseed/run: gpgv: Good signature from "mklab hands-off lab (THROWAWAY) …"   ← trust bootstrapped
preseed/run: + /bin/preseed_lookup_checksum start.sh
preseed/run: + db_set preseed/run/checksum 15201801088bd98dbfd04da7cdf7378b  ← per-file checksum from the SIGNED manifest
preseed: successfully ran ".../checksigs.sh"
preseed/run: URL:…/files/lib/HO_fn.sh …/foreach_class …/populate_classes …     ← start.sh pulls the framework
preseed: successfully ran ".../start.sh"
preseed/run: URL:…/classes/_/core/filter …/classes/partition/atomic/filter …   ← class FILTERS decide what's active
foreach_class(preseed): about to grab [preseed] elements for class [_/defaults/debian]
foreach_class(preseed): … (assembles the preseed from each active class) …
```

then normal d-i: `Partitions formatting → Installing the base system → …/GRUB →
reboot`, landing at a `debian login:` on the serial console.

## Verify the installed system

```bash
ssh -o StrictHostKeyChecking=no -p 2222 debian@127.0.0.1     # debian / debian  (root / lab)
```

Verified output (KVM, 2026-07-03):

```text
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME                   SIZE TYPE FSTYPE      MOUNTPOINT
vda                     20G disk
├─vda1                 1.4G part ext4        /boot
└─vda2                18.6G part LVM2_member
  ├─debian--vg-swap_1 10.8G lvm  swap        [SWAP]
  └─debian--vg-root    7.7G lvm  ext4        /
# framework-default packages present: bash-completion molly-guard openssh-server pwgen
# 245 packages total — lean, no desktop
```

Note the `partition/atomic` class composes an **LVM** layout (a plain `/boot` +
an LVM VG with root and swap), not a single flat partition — that's the recipe
the framework's `partition/atomic` + `partition/_/lvm` classes assemble. The
tell-tale **`molly-guard`** and **`pwgen`** come straight from the framework's
`_/defaults/debian` class `pkgsel/include` — proof the class composition, not a
static file, drove the package set.

---

## Two findings this lab surfaced (worth knowing)

1. **`hands-off/checksigs=false` does not work on trixie d-i.** Trixie's
   `preseed_fetch` supports `-C` (checksum lookup), so `start.sh` fetches every
   component *with* `-C` — which needs `/bin/preseed_lookup_checksum`, created
   **only** by `checksigs.sh`'s signed/gpgv branch. Turn signing off and the
   first component fetch dies: *"-C specified, but there is no
   /bin/preseed_lookup_checksum executable."* → **signing is required**, the
   `--sign` path (default) is the one that works.

2. **The framework must be reachable at a docroot for its absolute fetches.**
   `start.sh` grabs `/files/…` and `foreach_class` grabs `/classes/…` (and
   `/local/…`) with a **leading slash** = the server root, while everything else
   is relative to `preseed.cfg`. Served under `/hands-off/trixie/`, the absolute
   ones 404 (`…:8181//files/lib/HO_fn.sh`). `setup-hands-off.sh` bridges this
   with **relative** `~/netboot/{files,classes,local}` symlinks (absolute targets
   would dangle inside the bind-mounted nginx container).

Both are consequences of operationalizing a framework that upstream serves at a
host root, under our shared multi-lab netboot dir — documented here so the next
person doesn't re-derive them from a 404.
