# POC-7 — loading a client from a hard disk, not a CD (x86)

**Goal:** prove the client `load` path is *device- and filesystem-agnostic* —
that the same C client that boots off an ISO9660 CD also boots off a **hard
disk**, exercising OpenBIOS's disk-label + filesystem plumbing directly.
**Result: DONE and green.** Both `hello` and `emacs` load from an **ext2 hard
disk** at `/ide@0/disk@0` and run on the revived OpenBIOS-x86 — no CD, no
firmware change, no sudo. `smoke-client.sh x86 {hello,emacs} disk` are two new
green verdicts.

## The thinking

The whole lab has loaded clients from one place: an ISO9660 CD at
`/ide@1/cdrom@0`. But nothing about a *client* cares where it came from — once
`go` runs, `emacs` is `emacs`. The CD is just a *staging* choice. The firmware's
`load` path is supposed to be indifferent to the medium, because it flows through
three layers that each only do one job:

```
device tree  →  disk-label (partition map)  →  filesystem package  →  read bytes
   /ide@…            whole-disk or part N          grubfs (ext2/iso9660)
```

So the question isn't "can it?" — it's "what does the plumbing actually expect,
and where does it bite?" POC-7 finds out by loading a client off a disk and, when
it *doesn't* work first try, instrumenting the exact layer that refused.

## The device node — `show-devs` settles it

Boot the firmware with a disk attached (`-hda`) and ask:

```
0 > show-devs
  …
  /ide@0            (ide)
  /ide@0/disk@0     (block)      ← primary-master IDE = qemu -hda
  /ide@1            (ide)
  /ide@1/cdrom@0    (block)      ← secondary-master = qemu -cdrom (the CD today)
```

| qemu flag | IDE position | device node |
|---|---|---|
| `-cdrom`  | secondary master | `/ide@1/cdrom@0` |
| `-hda`    | **primary master** | **`/ide@0/disk@0`** |

## Three gotchas, each traced to ground truth

Loading `hello` off a freshly-made FAT disk *silently failed* — `$load` printed
`ok` (that's just the Forth line finishing) but `go` said **"No valid state,"**
and `state-valid @ .` was `0`. No error, no clue. Enabling OpenBIOS's own
`DEBUG_DISK_LABEL` trace (POC-4's trick: the `DPRINTF`s use `printk`, which on
x86 goes to **VGA** — invisible on serial — so swap it to `forth_printf`) made
the plumbing narrate itself, and three distinct problems fell out.

### 1. FAT isn't compiled in — so it fails *silently*

The trace showed disk-label doing the right thing:

```
DISK-LABEL - dlabel_open: dlabel-open '\hello'
DISK-LABEL - dlabel_open: Unknown or missing partition map; trying whole disk
```

…and then going quiet. It called `find-filesystem` on the whole disk and got
**nothing** — no `Located filesystem`, no `INTERPOSE!`. The reason is in the
build config, not the code:

```
CONFIG_FSYS_ISO9660 = true      ← why the CD works
CONFIG_FSYS_EXT2FS  = true
CONFIG_FSYS_FAT     = false     ← FAT was never built into this grubfs
```

grubfs's `fsys_table` only lists the filesystems compiled in. FAT is absent, so a
FAT image mounts-probe-fails with no error and `state-valid` stays `0`. **On the
firmware as shipped, the disk filesystem is `ext2`** (or iso9660).

**FAT is now enabled too** — `build-firmware-x86.sh` flips `CONFIG_FSYS_FAT` to
`true` before the final `switch-arch` (which regenerates `autoconf.h` and pulls
`fsys_fat.c` into the build). After that rebuild, a FAT disk loads exactly like
ext2 — `stage-disk.sh <prog> fat` + `smoke-client.sh x86 <prog> disk-fat` are
green. The distinction that remains: **ext2 needs no firmware rebuild** (it was
already compiled in), while **FAT does** (the stock config ships it off). That's
the whole reason the silent-failure lesson above matters — a FAT image on a
stock-config firmware gives you *nothing but a `0`*.

### 2. Modern `mke2fs` defaults break GRUB's ancient ext2 driver

Switching to ext2, the trace got further — `Located filesystem`, `INTERPOSE!` —
then `File not found`. The filesystem *mounted* but the directory lookup failed.
Cause: grubfs's ext2 driver is **GRUB 0.97-era**, and today's `mke2fs -t ext2`
still enables 256-byte inodes plus `resize_inode` / `dir_index` / `ext_attr`,
which that driver can't parse. The fix is a classic layout:

```
mke2fs -b 1024 -I 128 -O ^resize_inode,^dir_index,^ext_attr,^sparse_super,^large_file
```

→ a filesystem whose only feature is `filetype`, which the old driver reads
cleanly. (This is the same "alive where it's used, fossil where it isn't" museum
lesson the rest of the lab keeps teaching — here the *filesystem format* is the
fossil.)

### 3. The path separator is a backslash — a forward slash gets eaten

`" /ide@0/disk@0:\hello" $load` works; `:/hello` does **not** —
disk-label sees `dlabel-open '<NULL>'`, because a leading `/` in the arguments is
swallowed by OpenBIOS's device-path parser. The backslash survives, and grubfs
converts `\`→`/` internally (`grubfs_files_open`: `if(*s=='\\') *s='/'`). So the
arg is always the **backslash** form.

## The win (clean firmware, no debug build)

With a classic-ext2 disk and the backslash path, on the **shipped** firmware:

```console
$ ./smoke-client.sh x86 hello disk
  - booting revived OpenBIOS-x86 + our hello on an ext2 hard disk, driving $load /ide@0/disk@0 + go → …
PASS: revived OpenBIOS-x86 loaded our C client 'hello' from an ext2 hard disk and it answered Hello world! over the IEEE 1275 client interface

$ ./smoke-client.sh x86 emacs disk
PASS: revived OpenBIOS-x86 loaded our C client 'emacs' from an ext2 hard disk and it ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited) over the IEEE 1275 client interface

$ ./build-firmware-x86.sh            # enables CONFIG_FSYS_FAT, then:
$ ./smoke-client.sh x86 hello disk-fat
PASS: revived OpenBIOS-x86 loaded our C client 'hello' from a FAT hard disk and it answered Hello world! over the IEEE 1275 client interface
```

The disk-label trace on the successful ext2 load, end to end:

```
dlabel-open '\hello'  →  Unknown or missing partition map; trying whole disk
                      →  Located filesystem  →  path: \hello length: 6  →  INTERPOSE!
0 > go  switching to new context:
Hello world!  --  an OpenBIOS client program, calling back into the firmware.
```

No partition table needed — a whole-disk ("superfloppy") ext2, found by
disk-label's *missing-partition-map* fallback. The instrumentation was reverted
and the clean firmware rebuilt before finishing; the CD smokes still pass, so the
trace left no residue.

## How the lab wires it

- **`stage-disk.sh [program] [ext2|fat]`** — builds the image and populates it
  without mounting (`debugfs` for ext2, `mcopy` for FAT — no loop, no root),
  baking gotchas #1–#3 into readable comments.
- **`build-firmware-x86.sh`** flips `CONFIG_FSYS_FAT=true` (idempotent + verified)
  so the rebuilt firmware carries the FAT driver.
- **`smoke-client.sh x86 <prog> {disk|disk-fat}`** — the CD and disk paths share
  one branch; only the device node (`/ide@0/disk@0` vs `/ide@1/cdrom@0`), the
  filesystem, and the QEMU media flag (`-hda` vs `-cdrom`) differ. All end at the
  same `$load`+`go`. `disk-fat` adds a hint to its failure line pointing at the
  firmware rebuild (the #1 silent-failure trap).
- **`run-client-qemu.sh x86 <prog> {disk|disk-fat}`** — the same, interactively.
- **ppc `disk`/`disk-fat` SKIP** with a pointer: mac99's tree is different
  (`/pci/mac-io/ata-…/disk@N`, `boot hd:…`) and its stock blob's filesystem set
  isn't ours to recompile — left as a future mini-spike.

## Pitfalls checklist

- **A silent `state-valid = 0`** is how a *missing filesystem driver* (FAT) and a
  *format the driver can't parse* (modern ext2) both present. Don't trust `$load`
  returning `ok` — check `state-valid @ .`, or just try `go`.
- **`DPRINTF` → `printk` → VGA** on x86 is invisible on serial; swap to
  `forth_printf` to see the disk-label trace (revert after — it's a debug build).
- **FAT is off in the stock config** (`CONFIG_FSYS_FAT=false`); ext2 and iso9660
  are on. `build-firmware-x86.sh` now flips FAT on — but a FAT image on a
  *stock-config* firmware still fails silently, so the `disk-fat` smoke hints at
  the rebuild when it can't reach the marker.
- **Classic ext2 only**: `-b 1024 -I 128` and strip `resize_inode`/`dir_index`/
  `ext_attr`, or the fs mounts but every lookup says `File not found`.
- **Backslash path** in the `$load` arg; a leading `/` is eaten by the device-path
  parser.
- **Stage sudo-free** with `debugfs -w -R "write <file> <name>"` — no mount, no
  root, exactly the house constraint.
