# RUNBOOK — crafting boot environments (FreeBSD `bectl`, on Linux)

Once Debian is on root-on-ZFS with ZFSBootMenu ([RUNBOOK-install.md](RUNBOOK-install.md)),
you have what FreeBSD users call **boot environments**: bootable, copy-on-write
snapshots of the whole OS. This walk shows the lifecycle — snapshot, clone,
activate, boot, roll back — by hand and with the lab's [`be.sh`](be.sh) helper
(the Linux answer to FreeBSD's `bectl(8)`).

> **The lesson.** A boot environment is *one ZFS filesystem holding one coupled
> version of the OS*. Because ZFS clones are copy-on-write, making a new BE is
> instant and nearly free — so "try the risky upgrade in a throwaway clone, and
> if it breaks, reboot into the old one" becomes a 2-second operation instead of
> a restore-from-backup. ZFSBootMenu is what makes each of those clones
> *selectable at boot*.

Run everything here **inside the booted `zbm-debian` VM** (author-run under KVM —
the mklab host has no ZFS). The [`be.sh`](be.sh) *logic* is unit-tested on the
mklab host without a pool (see [`tests/test-be-logic.sh`](tests/test-be-logic.sh)
and [`MANUAL_TESTING.md`](MANUAL_TESTING.md)); the *effects* below need the real
pool.

---

## The two properties that make it all work

| Property | Set on | Meaning |
|---|---|---|
| `bootfs` (pool property) | the pool (`rpool`) | the **default** boot environment ZFSBootMenu boots |
| `org.zfsbootmenu:commandline` | the `rpool/ROOT` container (inherited by BEs) | the kernel command line — **without `root=`** (ZBM injects `root=zfs:<be>` itself) |
| `canmount=noauto` | each BE dataset | only the *booted* BE mounts `/` (never auto-mount) |
| `mountpoint=/` | each BE dataset | the dataset **is** a root filesystem when mounted |

The dataset layout (from the install):

```text
rpool/ROOT              canmount=off    mountpoint=/     ← the BE container (holds the cmdline)
rpool/ROOT/debian       canmount=noauto mountpoint=/     ← a boot environment
rpool/home              mountpoint=/home                 ← shared across all BEs
```

> **Why the command line lives on the container and carries no `root=`.** ZBM
> works out and injects `root=zfs:<the BE it boots>` on its own. Set the property
> on `rpool/ROOT` so every BE — including clones you make later — inherits the
> same extra args. Hard-code a `root=` and a clone would inherit it and boot the
> *original* dataset instead of itself. (You can still override the property on a
> single BE when you genuinely want that one to boot differently.)

`bectl` on FreeBSD hides these behind verbs; on Linux you set them directly (or
let [`be.sh`](be.sh) do it). Everything below shows *both*.

## 1. See what you have

```bash
./be.sh list
# name                       used  creation            org.zfsbootmenu:commandline
# rpool/ROOT/debian          1.2G  Sun Jul 13 ...       root=zfs:rpool/ROOT/debian quiet ...
# be.sh: default (bootfs): rpool/ROOT/debian
```

By hand:

```bash
zfs list -o name,used,creation,org.zfsbootmenu:commandline -r rpool/ROOT
zpool get -o value -H bootfs rpool          # which BE is the default
```

## 2. Snapshot the current system (a restore point)

Before you touch anything, mark a known-good point. This is the cheapest
insurance in the whole lab.

```bash
./be.sh snapshot debian known-good
#   ≡  zfs snapshot rpool/ROOT/debian@known-good
```

A snapshot is read-only and free until you diverge from it. You can boot *into*
a snapshot directly from the ZFSBootMenu menu (it clones on the fly), or roll
back to it in place (§5).

## 3. Clone a new boot environment to try a risky change

The FreeBSD move: `bectl create testupgrade`. Here:

```bash
./be.sh create testupgrade
#   ≡  zfs snapshot rpool/ROOT/debian@<timestamp>
#      zfs clone -o canmount=noauto -o mountpoint=/ \
#           rpool/ROOT/debian@<timestamp> rpool/ROOT/testupgrade
```

`testupgrade` is now a full, independent, bootable copy of your system that
shares all unchanged blocks with `debian` (so it cost almost no space). Clone
from a *different* source BE with `./be.sh create -e otherbe newbe`.

`testupgrade` already inherits the shared command line from `rpool/ROOT`. Only
override it if you want *this* BE to boot differently — e.g. verbosely, to debug
the upgrade (still **no `root=`** — ZBM adds it):

```bash
./be.sh cmdline testupgrade "loglevel=7 systemd.log_level=debug rw"
```

## 4. Activate it and boot in

Make `testupgrade` the default ZFSBootMenu will boot:

```bash
./be.sh activate testupgrade
#   ≡  zpool set bootfs=rpool/ROOT/testupgrade rpool
reboot
```

Now do the scary thing *inside `testupgrade`* — a `apt full-upgrade`, a kernel
swap, a config change you're unsure about. Your original `debian` BE is
untouched on disk.

### Driving the ZFSBootMenu menu

If you'd rather pick a BE interactively than pre-`activate`, hold a key during
ZBM's countdown to get the menu. Its keys (shown on screen):

- **↑/↓** select a boot environment, **Enter** boots it.
- **Ctrl-D** boot the selected BE **once** (without changing `bootfs`).
- **Ctrl-S** snapshots, **Ctrl-K** kernels, **Ctrl-R** a recovery shell.
- **Ctrl-E** edit this boot's kernel command line for one boot.

> **Automating the menu over a serial console — read this first.** If you script
> ZBM's menu via QEMU's `serial.sock` (the way [`root-password-reset/`](../root-password-reset/)
> drives GRUB), the **same char-drop trap applies**: a serial console has *no
> flow control*, so text typed faster than the menu consumes it is silently
> dropped and your selection "doesn't take" with no error. Send **one byte at a
> time with ~40 ms between them**, space out keystrokes, and **ground-truth the
> result with the booted kernel's `/proc/cmdline`**, not by screen-scraping the
> menu's redraws. One client on the socket at a time. For humans at a real
> console none of this matters — you just press the arrow keys.

## 5. If it broke — roll back in seconds

**Option A — reboot into the old BE.** From the ZBM menu, pick `debian` and
Ctrl-D (boot once), or re-activate it:

```bash
./be.sh activate debian && reboot
```

Then delete the failed experiment:

```bash
./be.sh destroy testupgrade
#   ≡  zfs destroy -r rpool/ROOT/testupgrade
# (be.sh refuses to destroy the *active* BE — activate another first.)
```

**Option B — roll the current BE back in place** to the restore point from §2
(discards everything since the snapshot — you must not be booted off exactly
that dataset with divergence you want to keep):

```bash
./be.sh rollback debian known-good
#   ≡  zfs rollback rpool/ROOT/debian@known-good
```

**Option C — promote a clone into the new mainline.** If the upgrade *worked*
and you want `testupgrade` to become the permanent system (so you can delete the
old `debian` and its origin snapshot), promote it so it no longer depends on the
origin, then activate:

```bash
zfs promote rpool/ROOT/testupgrade      # clone no longer needs debian's snapshot
./be.sh activate testupgrade
zfs destroy -r rpool/ROOT/debian        # optional: retire the old BE
```

`zfs promote` is the piece that turns a throwaway clone into a first-class BE —
it's the same "clone and promote" ZFSBootMenu offers from its own menu.

## FreeBSD `bectl` ⇄ Linux/ZBM cheat sheet

| FreeBSD | This lab (`be.sh`) | Raw ZFS |
|---|---|---|
| `bectl list` | `be.sh list` | `zfs list -r rpool/ROOT` + `zpool get bootfs` |
| `bectl create testupgrade` | `be.sh create testupgrade` | `zfs snapshot … && zfs clone -o canmount=noauto -o mountpoint=/ …` |
| `bectl create -e src new` | `be.sh create -e src new` | clone from `src`'s snapshot |
| `bectl activate testupgrade` | `be.sh activate testupgrade` | `zpool set bootfs=rpool/ROOT/testupgrade rpool` |
| `bectl destroy testupgrade` | `be.sh destroy testupgrade` | `zfs destroy -r rpool/ROOT/testupgrade` |
| `bectl rename old new` | `be.sh rename old new` | `zfs rename rpool/ROOT/old rpool/ROOT/new` |
| (snapshot) | `be.sh snapshot be tag` | `zfs snapshot rpool/ROOT/be@tag` |
| (rollback) | `be.sh rollback be tag` | `zfs rollback rpool/ROOT/be@tag` |

The one real difference: FreeBSD's loader reads BEs natively; on Linux,
**ZFSBootMenu is the loader** that gives you the same power — and, unlike GRUB,
it reads modern ZFS (encryption, recent feature flags) without fuss.

## Success signature

```text
# ./be.sh list                    → shows debian + testupgrade
# ./be.sh activate testupgrade && reboot
# (ZFSBootMenu boots testupgrade)
# cat /proc/cmdline                → root=zfs:rpool/ROOT/testupgrade ...
# findmnt -no SOURCE /             → rpool/ROOT/testupgrade
# ...break it, then:
# ./be.sh activate debian && reboot
# cat /proc/cmdline                → root=zfs:rpool/ROOT/debian ...   (recovered)
```

That round trip — boot a clone, break it, reboot the original untouched — is the
entire point of boot environments, and now you have it on Linux.
