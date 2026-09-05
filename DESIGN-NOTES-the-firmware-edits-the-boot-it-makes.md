# The Firmware Edits the Boot It Is About to Make — Design Notes

*Discussion draft, 2026-09-05. Not a lab plan yet: two ideas that compose the
building blocks [`examples/openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/README.md)
already has, written down so they can be argued with. Tracked as
[`TODO.md` §22](TODO.md#22-the-firmware-edits-the-boot-it-makes--two-compositions-of-the-toolkit-2026-09-05);
the successor of the B.3 toolkit and a sibling of
[`ELF_GATE_AND_BOOT_LADDER_LAB_PLAN.md`](ELF_GATE_AND_BOOT_LADDER_LAB_PLAN.md) (B.4),
whose Spike 4 — "poke it before boot" — this generalizes from a fixture to the
boot that matters.*

---

## 0. The two ideas in one paragraph each

**A — the boot-handoff edit.** When OpenBIOS boots a bzImage, its C loader
(`arch/x86/linux_load.c`, revived by patch 01, taken to long mode by patch 12)
*authors* three structures in memory and then jumps: the **zero page** (the boot
protocol's `struct boot_params`, at `0x90000`), the **command line** the zero page
points at, and the **initrd** it names. All three are bytes at addresses the
firmware knows, in formats the type layer can describe. So between "authored" and
"jumped" the prompt can **read them back, change them, and let the kernel be the
grade**: `/proc/cmdline`, `/proc/iomem`, `/proc/sys/…` and the initramfs the
kernel unpacks are ground truth the firmware cannot fake. It is the OFW lab's
`fix-zp` (poking the zero page from `linux-hook`,
[POC-3](examples/open-firmware-forth-to-boot/POC-3-COREBOOT-PAYLOAD.md)) done with a
typed layout instead of a hand-computed offset — and done to *edit* a correct
handoff rather than to repair a broken one.

**B — the device tree handed to Linux on x86.** `dsl/fdt.fth` already flattens the
live tree into a v17 DTB that `dtc` accepts (the showcase's Act V). The x86 boot
protocol has a place to put one: the `setup_data` chain, type `SETUP_DTB`, which a
kernel built with `CONFIG_OF` walks into `/proc/device-tree`. On ppc the kernel takes
the firmware's tree through the client interface as a matter of course; on x86
nothing ever hands it one. This is the firmware doing on x86 what it does natively
on ppc, carrying evidence the kernel cannot otherwise see (Act III's renamed card,
the `cfg-id` a card computed about itself, `/memory available`).

Both ideas share **one prerequisite**, and it is the first thing to build (§1).

## 1. The prerequisite: a window between "authored" and "jumped"

**Measured, not assumed:** on x86 and amd64 the `boot` word calls
`linux_load(&sys_info, path, param)` and that function builds the zero page, stages
the kernel high, copies it down "as its last act" and switches to it
([POC-4 bug #6](examples/openbios-the-rival-that-shipped/POC-4-BOOT-LINUX.md)). There
is **no prompt between the zero page being written and the kernel running**. ELF
images have that window — `load` runs `init-program` and leaves `state-valid` set,
and `go` jumps — and patch 68 put the ELF gate into exactly that gap. The bzImage
path has no such split.

Two ways to open it:

| | the split | the hook |
|---|---|---|
| shape | `load <bzImage> <args>` prepares everything and sets `state-valid`; `go` jumps. Mirrors `init-program`/`go`; `boot` stays `load` + `go` | a `defer` the loader calls after the zero page is complete and before the copy-down — OFW's `linux-hook`, which the sister lab used for `fix-zp` |
| what it gives | a **prompt** with the structures in memory: read, diff, edit, then `go` | a **scripted** edit, no prompt; the word must be defined before `boot` |
| cost | a patch in `linux_load.c` and `boot.c` on both x86 and amd64 (the amd64 handoff is its own routine, patch 12); the staged-high/copy-down dance means `go` must do the copy, so `load` must record where it staged | a few lines; but the kernel copy-down after the hook means an edit to the *kernel image* is overwritten, and nothing at the prompt can inspect what the hook saw |
| B.4 fit | the same `state-valid`/`go` vocabulary the ELF ladder grades — one door, two formats | none |

**Recommendation: the split.** It is the ELF path's shape, the ladder's rungs
(LOADED / REFUSED / RUN) then apply to bzImages for free, and the prompt is the point
of the whole family. The hook is the fallback if the copy-down cannot be deferred
cleanly on amd64. Either way this is **patch 69**, `PORT`/`FEATURE`, arch-local, and
it is the gate on everything below. **Negative control:** with the split in place,
`load` of a bzImage then `go` boots to u-root exactly as `boot` does today
(`showcase-rival-boots-linux.sh` is the regression test, unchanged).

## 2. Idea A — three seams, ordered by how much they can change

The zero page is a `struct boot_params`; the setup header inside it starts at
`0x1f1`. Patch 01 already extended the loader's copy of that header through protocol
2.15 and `memcpy`s the whole thing (bug #7), so every field below is *already
authored* by the firmware. A `bootparams.fth` layout over `struct.fth` — fixed
offsets, all little-endian, the static half of the type layer — names them. On x86
the address goes through `>virt` (the GDT rebase; a Forth address is not physical
there, the `flash-writer` lesson); on amd64 it is the physical address.

### 2.1 Seam 1 — the zero page: what the loader told the kernel

| field (offset) | what an edit does | ground truth inside Linux | control |
|---|---|---|---|
| `cmd_line_ptr` (`0x228`) → the string; `cmdline_size` (`0x238`) is the limit | **the command line.** Rewrite the string in place, or point at a longer one the firmware `alloc-mem`s | `cat /proc/cmdline` | the unedited boot prints the line `boot` was given; an edit past `cmdline_size` is **refused by name** before `go` |
| `ramdisk_image` / `ramdisk_size` (`0x218`/`0x21c`) | **which initrd, and how big.** Point at a second blob loaded off the CD; or grow the size after appending (§2.2) | the `RAMDISK: [mem …]` dmesg line; what `ls /` shows | swapping to a blob with a different `/init` boots a different shell |
| the e820 table (`e820_entries` at `0x1e8`, 128 × 20-byte entries at `0x2d0`) | **the memory map.** Carve a range out as *reserved*; the kernel never uses it. This is `memmap=` done to the structure instead of the string — the OFW lab needed the string because its map was e801 guesswork; here the map is real and the firmware wrote it (patches 39–41) | `/proc/iomem`, `/sys/firmware/memmap/` | the kernel still boots; the range is absent from `System RAM`; `free` drops by that amount |
| `setup_data` (`0x250`) | **a chain of typed extension records** — a TLV (`next u64, type u32, len u32, data[]`), the `vfield:` shape. Idea B lives here (§3) | per type | an unknown type is skipped silently by the kernel — so an *absent* effect is also the no-`CONFIG_OF` signature, and the control has to distinguish them (§3) |
| `vid_mode` (`0x1fa`), `loadflags` (`0x211`, `QUIET_FLAG`), `root_dev`/`root_flags` (`0x1fc`/`0x1f2`) | the old `rdev`-era knobs; `loadflags` bit 5 silences early output | console output present/absent; `/proc/cmdline` shows nothing, which is the point: **an edit the command line cannot express** | — |
| `acpi_rsdp_addr` (`0x270`, protocol 2.14) | where the kernel looks for ACPI first | `dmesg | grep RSDP` | pointing it at garbage must not crash the boot (the kernel falls back to the scan) |

**The edit that reads best is the first row**, because the grade is one `cat`. But
the **third row is the one the command line cannot do as honestly**: `memmap=` asks
the kernel to *ignore* memory the map says is there; editing e820 makes the map
*say* something else, and the kernel's view and the firmware's record agree — the
record-outlives-its-subject rule, applied to a memory map.

### 2.2 Seam 2 — the initrd in memory: a file inside the image the kernel unpacks

The u-root initrd this lab boots is a **plain `newc` cpio, uncompressed**
(`u-root -build=bb -o initramfs.cpio`; confirm with `file` — if it were gzipped, only
the *append* below works, not the in-place edits). `newc` is the friendliest format
in the whole toolkit: a 110-byte header of **ASCII hex fields** (`070701`, then
thirteen 8-digit numbers: `ino mode uid gid nlink mtime filesize …
namesize check`), the NUL-terminated name padded to 4, the data padded to 4, and a
`TRAILER!!!` member at the end. Length-prefixed, aligned, sequential — the Spike 0
cursor (`>rec`/`alignto`/`vbytes`) with one new type, "8 hex digits as a number".

Three edits, in order of how much they can change:

1. **In place, same length** — `cbfs-fill`'s shape. Find a member by name, overwrite
   its bytes without moving anything. Good for flipping a byte in a script the
   initramfs runs; useless for a config file that needs to grow.
2. **Append a second archive.** The kernel's unpacker takes **concatenated cpio
   archives**, skipping zero padding between them, and **a later member with the same
   path replaces the earlier one**. So the firmware composes a fresh `newc` archive
   *after* the loaded initrd — `etc/sysctl.d/99-firmware.conf`, or a replacement
   `/init` — and bumps `ramdisk_size` in the zero page (§2.1 row 2). No member of the
   original moves; a compressed original works too. **This is the edit that answers
   "change a config file in the image."**
3. **Replace the initrd wholesale** — load a second cpio off the CD and repoint
   `ramdisk_image`. Coarse, but the control for the other two: it proves the pointer
   is honoured before anything subtler is claimed.

Ground truth for all three is **what `ls` and `cat` show in u-root**, and for the
append the `TRAILER!!!`-after-`TRAILER!!!` structure `cpio -itv` reads on the host
from a `pmemsave` of the same range — the foreign oracle, the way `dtc` is Act V's.

**Two sharp edges, before any of it is built:**

- **The memory after the initrd is not free.** The loader places the initrd near the
  top of RAM (`RAMDISK: [mem 0x1f027000-0x1fb25fff]` on the 512 MiB machine in
  [POC-4](examples/openbios-the-rival-that-shipped/POC-4-BOOT-LINUX.md)), so an append
  *in place* runs past `initrd_addr_max` or into memory the kernel will not accept.
  The safe shape is **copy, append, repoint**: `alloc-mem` a range below the limit,
  copy the initrd there, compose the new archive after it, and point `ramdisk_image`
  and `ramdisk_size` at the copy — three primitives the toolkit already has. The
  in-place form is the negative control: the kernel must refuse or ignore it
  legibly, never unpack half an archive.
- **The unpacker resolves hard links by inode number.** A member with `nlink ≥ 2`
  is matched against earlier members by `(ino, devmajor, devminor)`. An appended
  member that reuses a number from the original archive can be taken for a link to
  a file it never meant to name. Every member the firmware composes carries
  `nlink = 1` and inode numbers the original archive does not use — and the
  layout asserts it, so the slip is refused by name rather than found in `ls -i`.

**The mental model, stated once:** the initrd is **a queue of archives the kernel
replays, in order, into one fresh filesystem** — not a stack of layers. It is
*not* an overlay:

| | an overlay | the initramfs unpacker |
|---|---|---|
| a same-path regular file | shadows the lower one | **truncated and rewritten** — the earlier contents are gone entirely, no merge |
| a same-path directory | union of both | reused, so the contents of both archives end up together — the one union-like behaviour |
| a type change (file where a directory was) | opaque marker | the earlier one is removed first, then the new one created |
| deleting a lower file | a whiteout | **impossible.** There is no whiteout; an archive can only add or replace. To neutralise a file, replace it with an empty one |

So *the last writer of any path wins*, and "make a filesystem-level change to the
initrd" always means one of: add a path, or wholly replace one. Anything that needs
a *diff* against the original member has to read the original first (edit 1's
walk) and write the whole result (edit 2's append).

### 2.3 Seam 3 — the image on the medium, before `load`

"The command line that resides in the image" needs a distinction:

- The **bzImage file** carries no command line unless the kernel was built with
  `CONFIG_CMDLINE`, and that string lives inside the *compressed* `vmlinux` — not
  editable without decompressing. What the file *does* carry, editable, is the setup
  header itself (`vid_mode`, `root_dev`, `ramdisk_max`, the `kernel_version` string
  offset): the fields `rdev` used to patch in 1993. Editing them in the file is the
  same layout as §2.1 at a different base.
- The **initrd file** is §2.2's subject at rest. The same cursor walks it; the same
  append works.

Where such an edit can *happen* is the real question. The CD is read-only; the
loader reads from the filesystem, not from a buffer the prompt could hand it. So a
file-side edit is either **host-side** (the `cbfs-write` shape — author a fixture,
boot it) or through the **pmem seam** (`pmem-writer`: the firmware writes bytes the
host finds in the NVDIMM image after QEMU exits — so the firmware can *author* a
modified initrd that the *next* boot loads). The memory-side edits of §2.1–2.2 need
neither, which is why they come first.

### 2.4 Kernel tunables specifically — three routes, ranked

The question was: *can we change kernel tunables by editing a config file in the
image?* Yes, and it is the **third**-best way to do it here:

1. **`sysctl.<name>=<value>` on the command line** — kernel 5.8+; this lab's kernel is
   6.3. Applied *"right before loading the init process, as if the value was written
   to the respective /proc/sys file"*; both `.` and `/` are accepted as separators;
   an unknown name is reported in the log, not fatal. **No image edit at all** —
   it is §2.1 row 1 with a specific payload, and the grade is
   `cat /proc/sys/kernel/<name>` in u-root. Any tunable that has a `/proc/sys` file,
   plus every ordinary boot parameter (`loglevel=`, `nr_cpus=`, `init=`).
2. **The e820 carve (§2.1 row 3)** for the one family of tunables that is not a
   sysctl: what memory the kernel may use. `mem=`/`memmap=` are the string form;
   the structure form is honest.
3. **A file appended into the initrd (§2.2 edit 2)** — `etc/sysctl.d/99-firmware.conf`
   or a `sysctl -w` line in a replacement `/init`. **Named UNKNOWN until measured:**
   this route needs a *consumer* in the initramfs. Whether u-root's `init` applies
   `sysctl.d` is not something to assume; if it does not, the appended member has to
   be the `init` itself (or a script `init=` names — which brings route 1 back).
   The route earns its place anyway, because it is the only one of the three that
   changes **userspace** state — a file u-root reads — and not just kernel state.

**What else lives at that seam, once the cursor walks a cpio:** replace u-root's
`init` with one that prints the DTB (§3); drop a `/boot/firmware.dtb` member for a
userspace that has no `CONFIG_OF`; carry the authored TCG event log
(`dsl/eventlog.fth`) into the initramfs so userspace can replay it with
`tpm2_eventlog` — the log's structure handed across the boundary in a *file*, since
the boot protocol has no `setup_data` type for it.

## 3. Idea B — the tree, handed over

Mechanism: one `setup_data` record — `next=0, type=SETUP_DTB (2), len=<dtb size>,
data=<the v17 blob dt>fdt wrote>` — in memory the kernel will not reclaim (the
loader's own zero-page neighbourhood, or a range carved *reserved* in e820, §2.1),
and `boot_params.setup_data` pointing at it. The kernel's setup walk hands the blob to
the OF core; `CONFIG_OF` and `CONFIG_OF_EARLY_FLATTREE` are the gates.

**Ground truth:** `/sys/firmware/fdt` (the raw blob the kernel accepted — `pmemsave`
is not needed; `cat` it out over serial and `dtc` it on the host, or compare its
sha256 in u-root against the firmware's `sha256` of what it wrote) and
`/proc/device-tree/pci8086,1237@0/fcode-card@3/` — Act III's rename, visible to a
kernel that never ran FCode.

**The measurement that comes first:** whether the cached 6.3 kernel has `CONFIG_OF`.
`extract-ikconfig` on the host, or `/proc/config.gz` in u-root if enabled. If it does
not, the kernel skips the unknown-to-it record **silently** — the same signature as
a broken record — so the control must separate the two: a blob with its magic
flipped must be *rejected by a kernel that has OF* (early FDT verification refuses
it and boots on) and *ignored identically by one that has not*. Only a kernel that
accepts the good blob and refuses the bad one has been shown to read it.

**If `CONFIG_OF` is off, two fallbacks, both with what they cost:**

- **Build the kernel.** The repo builds kernels ([`micro-linux/`](micro-linux/README.md));
  one config flip. Cost: a second cached kernel and the provenance note that says why.
- **The mailbox.** Carve a range reserved in e820 (§2.1 row 3), write the DTB there,
  name the address on the command line (`fw.dtb=0x…`, an unknown parameter the kernel
  ignores and userspace can read from `/proc/cmdline`), and have u-root read it
  through `/dev/mem`. **No kernel support at all** — which is the more interesting
  demonstration: the firmware hands a structure to userspace through a memory map it
  wrote and a string it wrote, and nothing in between had to understand either.
  `STRICT_DEVMEM` permits reserved, non-RAM ranges; still a measurement.

Why the tree is worth handing: it carries **what only the firmware knows**. The kernel
can enumerate PCI itself, but it cannot know that a card's FCode renamed a node, what
`cfg-id` a card computed about itself, what `/memory available` the firmware had
after its own allocations, or what the coreboot tables said before it converted
them. On ppc all of that flows through `prom_init`; on x86 it evaporates at the jump.

## 4. Grading, per this repo's rules

- **Outcome, not mechanism.** The assertion is `/proc/cmdline`, not "the string at
  `cmd_line_ptr` changed". A poke that changed the bytes and did not reach the
  kernel — the wrong address on x86, the copy-down overwriting it, the kernel
  copying the line before the edit — passes the mechanism check and fails the boot.
- **The unedited boot is the no-fault row.** Every seam's first assertion is that the
  split (§1) reproduces today's `showcase-rival-boots-linux.sh` verdict byte for byte.
- **Refuse before the irreversible step.** `go` is the `dd`. A command line longer than
  `cmdline_size`, a `ramdisk_size` past the end of memory, an e820 entry overlapping
  the kernel's own staging, a `setup_data` record in RAM the kernel will reclaim: each
  is refused *by name* at the prompt, and the negative control watches each refusal
  bite.
- **The foreign oracle for the structures**: `cpio -itv` on the appended initrd,
  `dtc` on the accepted DTB, both from `pmemsave` — the same shape as Acts V/VI.
- **Fixtures have effects that follow causes.** The DTB that lands in `/proc/device-tree`
  is flattened *after* Act III's rename in the same boot, never pre-written.

## 5. A sequence, if this becomes a plan

| step | the line that must print | needs |
|---|---|---|
| S0 | `load …\vmlinuz …` → `LOADED`, `go` → u-root; `boot` unchanged | patch 69 (§1), on x86 and amd64 |
| S1 | `/proc/cmdline` shows a string typed at the prompt after `load` | `bootparams.fth`; S0 |
| S2 | `cat /proc/sys/kernel/<name>` shows the value from a `sysctl.` parameter S1 added | S1 |
| S3 | `/proc/iomem` lacks a range the firmware reserved; the kernel booted anyway | e820 layout; S1 |
| S4 | `ls /etc/sysctl.d` shows a member the firmware appended; `cpio -itv` on the host reads two archives | `cpio.fth`; S1 |
| S5 | `/proc/device-tree/…/fcode-card@3` exists, or the mailbox blob `dtc`-decompiles identically | `CONFIG_OF` measured; S3 for the mailbox |

S1 is the showcase's natural Act X (Act IX being the ELF gate, per B.4 §8): the last
act is the one where the firmware, having dissected everything that arrived, **edits
what leaves**.

## 6. Open questions — the ones to discuss

1. **Split or hook** (§1)? The split is recommended; the amd64 copy-down is the part
   that might argue back.
2. **Where does the command line live** after the loader — a buffer the copy-down
   overwrites, or somewhere stable? The pointer says, and the first measurement is to
   follow it and `region-snap` it across a `go` that is interrupted.
3. **Does u-root's `init` consume `sysctl.d`?** Decides whether §2.4 route 3 is a
   file edit or an `init` replacement.
4. **`CONFIG_OF` in the cached kernel** — decides whether Idea B is a `setup_data`
   record or a mailbox, and the mailbox is arguably the better story.
5. **Is a bzImage `load` a rung of the ELF ladder?** If S0 shares `state-valid`, the
   `elf-ladder` track's vocabulary (LOADED / REFUSED / RUN) describes both formats,
   and a bzImage with a bad `HdrS` magic is a REFUSED row — the bzImage gate beside
   the ELF gate, which the first survey listed separately.
