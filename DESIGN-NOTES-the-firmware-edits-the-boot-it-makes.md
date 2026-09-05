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
**The seams are the build list**: each of §2's four and §3 ends in a *Build:* line
naming its file, its words and its track, and §5 collects them in one table. §1a says
what the boot protocol can and cannot tell the firmware, §1b why the standard's own
configuration variables are the front end, and §1c why the fourth seam — NVRAM,
across boots — is the only event loop there is. §2.6 is the gate — every value
validated before `go`, or UNKNOWN by name — and §2.7 the inventory of everything
else at the prompt that can be read, validated or changed.

## 0a. In brief — what gets built, and what read, write and validate mean here

*The digest of the discussion that produced §1a, §2.6 and §2.7, kept up front so
[`TODO.md` §22](TODO.md#22-the-firmware-edits-the-boot-it-makes--two-compositions-of-the-toolkit-2026-09-05)
can point at one place. The sections named carry the detail and the controls.*

**Read, write and validate are explicit build items, not a display word with editing
alluded to.** Every field of the boot protocol's setup header is a typed field, so a
store through it *is* the write, and the fields fall into three classes that decide
what the other two verbs mean (§1a):

- **Declared by the kernel** — version, alignment, `init_size`, `setup_type_max` and
  their kin. *Read* from the file and from the zero page separately. *Write* is a lie,
  permitted only as a negative control, because the kernel's decompressor reads some of
  these back. *Validate* means the two copies are equal, field for field.
- **Written by the loader** — the command-line pointer, the initrd fields, e820,
  `setup_data`, `type_of_loader`. These are the edits, each through a word that refuses
  an out-of-range value by name. *Validate* means every constraint the declared class
  imposes on them.
- **Consumed by the kernel** — read back from `/sys/kernel/boot_params/` after boot.
  *Validate* means equal to the zero page at `go`, except the rewrites the kernel
  documents, so any other difference is a finding.

**The gate is `?bootparams`** (§2.6), the ELF gate's constraint vocabulary over the
whole handoff, run at `go` by default. It checks, in groups: that the image is what it
says it is (the magics, the size arithmetic, the compression named by its magic before
any decompressor runs, and the bzImage's own trailing CRC32, which no loader here has
ever checked); that the zero page agrees with the file; that every loader value sits
inside the declared limits; that the memory map is coherent **and agrees with the
firmware's own `/memory`** — two descriptions of one machine by one author must not
disagree; that the `setup_data` chain terminates with every type one the kernel
declared it understands; that the initrd is a well-formed archive; and the command
line structurally — with the questions only the kernel can answer, such as whether a
`sysctl.` name exists, said as **UNKNOWN by name** rather than passed quietly.

**"What else" is an inventory** (§2.7): everything at the prompt, with the verbs that
apply to each. Three items there are new enough to be seams-in-waiting:

- **PCI option ROM handoff.** The protocol has a record type that hands a card's ROM
  image to the kernel, which then serves it as the device's `rom` attribute in sysfs.
  Act III already read that ROM at the card's live BAR; handing it over closes the loop
  the showcase opened.
- **Entropy.** The loader can seed the kernel's random number generator through a
  record the kernel wipes after consuming. The smallest possible handoff, and the only
  one whose pass condition is the kernel *erasing* the evidence.
- **The tables the door handed on**, ACPI and SMBIOS. Patching them is a fifth seam
  with the cleanest oracles and the highest cost, listed as closed so the omission is
  a decision rather than a gap.

The build table in §5 has a row for the gate, the ROM handoff and the seed; §6 asks
whether the fifth seam is worth opening.

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

**And the split ships with its hooks.** OFW had `load-started`, `load-done` and
`linux-hook` — `defer`s on the boot path a user re-points from the prompt, which is
how the sister lab repaired its zero page. **OpenBIOS declares no `defer` anywhere on
its boot path** — measured by the habitats lab, which had to implement the standard's
empty `patch` word to get a tracer in
([`PATCH.md`](examples/open-firmware-native-habitats/PATCH.md)). So patch 69 declares
three, named for the step they follow, each a no-op until pointed at a word:

| defer | runs after | what a word pointed at it can see |
|---|---|---|
| `linux-header-hook` | the setup header is parsed, before placement | the kernel's **declaration** (§1a) — refuse or re-plan on it |
| `linux-params-hook` | the zero page, command line, e820 and initrd are complete | every structure of §2, in memory, before anything is copied down |
| `linux-go-hook` | the prompt says `go`, before the copy-down and the jump | the last look — the measured digest, the NVRAM counter (§2.5) |

**Build:** the three defers, in the same patch as the split; `' fix-cmdline to
linux-params-hook` at the prompt is the whole user interface. A hook that throws
aborts the load with the throw's name, which is how a policy word refuses.

### 1a. What the boot protocol is, and is not — the declaration half

The x86 boot protocol is **not a negotiation.** It is one-directional in each half:
the **kernel declares** what it is and needs, in the setup header inside the *file*,
and the **loader fills** the zero page according to that declaration. Nothing flows
back. "Capabilities" therefore means: read the declaration, honour it, fill the fields
the declared version has, zero the rest.

**What the loader honours today** (measured in
[patch 12](examples/openbios-the-rival-that-shipped/patches/12-amd64-spike3-boots-linux.patch)
and patch 01): `HdrS` and `protocol_version` (gating the 2.00 / 2.02 / 2.03 code
paths); `loadflags` bit 0, loaded-high; `kernel_alignment` and `init_size` for
placement and the decompressor's work area; `initrd_addr_max` for where the initrd
may go; and `xloadflags` bit 0 on amd64 — **the one real capability refusal already in
the tree**: a kernel that does not declare itself 64-bit capable is refused with the
protocol version and flags printed. The whole header is then copied into the zero
page verbatim (bug #7).

**What it ignores, and what a capability word would read:**

| field | what it declares | why it matters here |
|---|---|---|
| `kernel_info` (`0x268`, protocol 2.15 — this kernel's) → `setup_type_max` | the highest `setup_data` type the kernel understands | **decisive for Idea B**: read it, and a `SETUP_DTB` the kernel would skip silently becomes a refusal *by name, before `go`* (§3) |
| `relocatable_kernel`, `min_alignment`, `pref_address` | where the kernel would rather be | the loader places its own way and never asks — a placement it chose could disagree with one the kernel preferred, and today nothing says so |
| `xloadflags` bits 1–4 | loadable above 4 GiB, EFI handover, five-level paging | the amd64 door has 5 GB machines (patch 41) and honours only bit 0 |
| `type_of_loader` (`0x210`), `ext_loader_ver` | the loader identifies **itself** | the protocol's own "who are you"; what this loader writes is unmeasured (§6) |
| the **sentinel** (`0x1ef`) | a loader that did not zero the boot params | nonzero, and the kernel sanitises a set of fields itself — a silent fallback. The header copy starts at `0x1f1`, so it *should* be clear; nobody has looked (§6) |

**Build: `bootparams.fth`, three verbs per field — read, write, validate.** Not a
display word with editing "alluded to"; each field is a typed `le-field:` (so a store
through it *is* the write, the type layer's rule), and the fields fall into three
classes that decide what *write* and *validate* mean:

| class | fields | read | write | validate |
|---|---|---|---|---|
| **declared by the kernel** | `protocol_version`, `xloadflags`, `kernel_alignment`, `init_size`, `relocatable_kernel`, `min_alignment`, `pref_address`, `initrd_addr_max`, `cmdline_size`, `kernel_info` → `setup_type_max`, `syssize`, `payload_offset`/`payload_length` | from the **file** and from the **zero page**, separately | **a lie** — the zero-page copy can be edited, and the kernel's decompressor reads some of it (`kernel_alignment`, `init_size`), so a write here is a *negative control*, never a feature: declare a wrong alignment and watch the boot fail *by name* | the two copies are **equal**, field for field — the loader's `memcpy` is the mechanism, equality is the outcome; and each value is self-consistent (§2.6) |
| **written by the loader** | `type_of_loader`, `loadflags` (heap/quiet bits), `heap_end_ptr`, `cmd_line_ptr`, `ramdisk_image`/`ramdisk_size`, `setup_data`, `e820_entries`/table, `vid_mode`, `acpi_rsdp_addr`, the sentinel | from the zero page | **the edits of §2.1** — each through a word that refuses out-of-range by name | every constraint the declared class imposes on it: length ≤ `cmdline_size`, initrd ≤ `initrd_addr_max`, records ≤ `setup_type_max`, placement aligned to `kernel_alignment`, everything below 4 GiB unless `xloadflags` says otherwise |
| **consumed by the kernel** | all of the above, as received | `/sys/kernel/boot_params/data` after boot | — | equals the zero page at `go`, byte for byte, **except** the fields the kernel is documented to rewrite (a `SETUP_RNG_SEED` it wipes, §2.7) — so a difference is either a documented rewrite or a finding |

`.kernel-caps` is the *read* verb over the first class, printing the declaration by
name beside what the loader did with it. `?bootparams` (§2.6) is the *validate* verb
over all three. Ground truth: the same header read from the file on the host with the
type layer's own `struct-layer` shape; the kernel's `dmesg` for what it believed; and
the sysfs copy for what it received.

### 1b. The standard already designed the front end

This is not a boot loader to be built; OpenBIOS **is** the boot loader here, and IEEE
1275 already specifies its persistent user interface as configuration variables:
`boot-device`, `boot-file`, `boot-command`, `auto-boot?` and `nvramrc` (7.4.3.5), and
this lab already has **NVRAM backings on x86** (patches 04–07). So:

- the persistent command line is **`boot-file`**;
- the script that runs at power-on **before probing** is **`nvramrc`** — the habitats
  lab loaded a whole vocabulary off the chip that way, above the banner;
- the verb auto-boot evaluates is **`boot-command`**, which is where `load` + a hook +
  `go` goes once the split exists.

**Build: nothing new.** Use them; a lab-specific surface beside them would be
re-deriving the standard. The runbook form of every seam below is *"set `boot-file`,
put the hook word in `nvramrc`, `reset-all`"*, and that is the version that survives
a power cycle.

### 1c. There are no events after `go`

This is the constraint the whole idea sits inside. On x86 the firmware has **no
runtime presence** once the kernel starts — no client interface that persists, no
callback. "React to events in the environment" can mean only three things, and two of
them happen before the jump:

1. **React to what the kernel declares** — §1a's fields, in `linux-header-hook`.
   Refuse, re-place, or attach records accordingly.
2. **React to what the machine is** — the e820 map, the device tree, the option ROMs
   that ran, a digest of the image — in `linux-params-hook`. Policy at the gate, in
   Forth; B.4's Spikes 1 and 5 are exactly this shape.
3. **React across boots.** The running kernel cannot talk to the firmware, but it can
   write the NVRAM chip the firmware reads at the next power-on. That is the only
   genuine event loop available, and it is **seam 4** (§2.5).

## 2. Idea A — four seams, ordered by how much they can change

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

**Build: `bootparams.fth`** — the layout (every row above as a `le-field:`), a
`.zero-page` that prints it beside the kernel's `dmesg` reading, `cmdline!` (refuses
past `cmdline_size`), `e820-reserve` (refuses an overlap with the kernel's staging),
and a `setup-data+` that links a record into the chain. One track, `zero-page`,
graded by `/sys/kernel/boot_params/data` (§4).

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

**Build: `cpio.fth`** — the `newc` header as a cursor record with one new type (eight
hex digits as a number), `cpio-walk` (counts what `cpio -itv` counts), `cpio-find`
(edit 1), and `initrd-append` — copy, compose, `TRAILER!!!`, repoint (edit 2),
asserting `nlink = 1` and fresh inodes on every member it writes. One track,
`initrd-append`, graded by u-root's `ls`/`cat` and `cpio -itv` from `pmemsave`.

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

**Build: nothing in-firmware.** A host-side fixture builder in the `elf-gate` shape —
one bzImage whose setup header differs from the good one in one field — is what this
seam needs, and only when a §1a refusal wants a subject.

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

### 2.5 Seam 4 — NVRAM, across boots: the only event loop there is

§1c's third reaction. The kernel cannot reach the firmware while it runs, but the
NVRAM chip outlives the boot, the OS can write it (`/dev/nvram`, or the same words
at the next prompt), and the firmware reads it at power-on **before it decides what to
boot**. That is the **boot counter** every embedded loader has (U-Boot's `bootcount`,
the A/B slot of every phone), and this lab has every piece of it:

1. `nvramrc` runs at power-on (§1b) and reads a counter the firmware keeps in its own
   NVRAM (patches 04–07 back it on x86; the ppc chip is real).
2. `linux-go-hook` **increments** the counter before the jump — "a boot was
   attempted."
3. The booted OS **clears** it once it is up — u-root's `init`, or one `dd` into
   `/dev/nvram` at the offset the firmware published on the command line.
4. At the next power-on `nvramrc` finds the counter: **zero** means the last boot
   reached userspace, so boot `boot-file`; **nonzero** means it did not, so boot the
   *previous* kernel (`boot-file` and a `boot-file-prev`, swapped by the hook), and
   say so on the console.

**Ground truth:** two power cycles. First with a kernel whose `init=` points at
nothing — the counter stays set, the machine reboots into the fallback, and the
console names the reason. Then the good kernel — the counter clears, and the third
boot takes the primary. **Controls:** the counter is not cleared by a boot that
*panicked* (`panic=5` on the command line so it reboots itself); the fallback is not
taken when the OS cleared the counter; and the fallback is refused *by name* when
`boot-file-prev` is empty rather than looping. This is the seam that makes the lab
look like a boot loader instead of a demo, and it is the natural home of the
RAM-resident infra labs' "reboot = newest build" rule
([TODO §4](TODO.md#4-net-booted-ram-resident-infrastructure-images-immutable-infra-reboot--newest-build)):
newest build, **unless the newest build did not come up**.

**Build: `bootcount.fth`** — `bootcount@`/`bootcount!` over the NVRAM words, the
`nvramrc` script, and the `linux-go-hook` word; on the OS side one line in the
u-root `init` this lab already builds. One track, `boot-counter`, three power cycles,
driven the way the persist tracks already drive NVRAM across a restart.

### 2.6 Validate before `go` — `?bootparams`, the gate for the whole handoff

`?elf`/`?phdrs` refuse a malformed ELF on the gABI's word; the same `chk`/`chk<`/`chk?`
vocabulary from `dsl/elf.fth` (REVIEW E1's *constraints that refuse*) over
`bootparams.fth` gives the bzImage handoff its gate. It runs in `linux-go-hook` by
default, and the rule is the ELF gate's: **refuse by name, before the copy-down, or
say UNKNOWN by name.** Grouped by what the constraint is *about*:

- **The image is what it says it is.** `HdrS` at `0x202`; `boot_sector_magic`;
  file size = `(setup_sects+1)·512 + syssize·16` (rounded); `payload_offset`/
  `payload_length` inside the file, and the bytes at `payload_offset` beginning with
  a compression magic the kernel can unpack (gzip `1f 8b`, xz `fd 37 7a 58 5a`,
  zstd `28 b5 2f fd`, lz4, bzip2, lzma) — *which* compression, said by name, before
  any decompressor runs; and the **image's own CRC32**, which the kernel's build tool
  appends as the last four bytes and which no loader here has ever checked (the
  exact convention is measured against the file on the host first, then the check
  is written).
- **The zero page agrees with the file** — the declared class, field for field (§1a).
- **Every loader-written value is inside the declared limits** — the second row of
  §1a's table, one refusal per constraint, each named after its field.
- **The memory map is coherent.** e820 entries sorted, non-overlapping, `e820_entries`
  ≤ 128 (else `SETUP_E820_EXT` is required and the check says so); the kernel's
  placement `[load, load+init_size)`, the initrd, the command line and every
  `setup_data` record each lie **inside one RAM range** and **do not overlap each
  other**; and — the record-versus-record check this repo keeps finding — the map
  agrees with the firmware's **own** `/memory` `reg`/`available` (patches 40, 45):
  two descriptions of one machine, authored by the same firmware, that must not
  disagree.
- **The chain terminates.** `setup_data` walks to `next = 0` in bounded steps; each
  `len` is inside its range; each `type` ≤ `setup_type_max`.
- **The initrd is a well-formed archive** — `cpio-walk` reaches `TRAILER!!!` with
  every member's header magic present and every size landing on the next member
  (§2.2), and its digest matches a recorded one if one was recorded (Spike 5's shape).
- **The command line, structurally.** Length; `initrd=` names the initrd that was
  loaded; `console=` names a device the device tree has (`ttyS0` ↔ a serial node);
  no parameter given twice. **And what it cannot check, by name:** whether a
  `sysctl.` name exists, whether `root=` resolves, whether the kernel knows a
  parameter at all — those are the kernel's to answer, and the gate prints them as
  `UNKNOWN: <param> (the kernel decides)` rather than passing them quietly.
- **The machine can run it.** `xloadflags` bit 0 on the amd64 door (the existing
  refusal); five-level paging only if bit 4 allows; ACPI present when the door
  provides it (the multiboot door has none, the coreboot door has coreboot's —
  a row that differs *per door*, which is a control in itself). **UNKNOWN by name:**
  the x86-64 feature level a distro kernel requires — the header does not declare
  it, the kernel checks it itself at entry.

**Build: `?bootparams`** over `bootparams.fth` + `cpio.fth`; one track, `boot-gate`,
with **one fixture per constraint** authored by a builder in the `elf-gate` shape (a
bzImage that differs from the good one in exactly one field), each refused by name,
and the good image passing. The negative control for the "UNKNOWN" rows is a run
with a nonsense `sysctl.` name: the gate must say UNKNOWN, and the kernel's log must
then be the one that names it.

### 2.7 The pre-boot state space — everything that can be read, validated or changed before `go`

The four seams are the ones with a clear edit and a clear grade. This is the wider
inventory — what is *in* the machine at the prompt, and which of the three verbs
applies to each. It is the answer to "what else", and it is the list §5's build
table will grow from:

| object | read | validate | change | oracle after boot |
|---|---|---|---|---|
| the kernel's **declaration** (§1a) | `.kernel-caps` | equals the file; self-consistent | lie only (negative control) | `dmesg`'s protocol line |
| the kernel **payload** | compression by magic; size from `syssize` | the image CRC32; `payload_length` inside the file | on the medium only (§2.3) | `/proc/version` names the build |
| the **command line** | `cmdline@` | §2.6 | `cmdline!` — `sysctl.`, `init=`, `loglevel=`, `panic=` | `/proc/cmdline`, `/proc/sys/…` |
| the **memory map** | `.e820`, `/memory` | coherent; agrees with `/memory` | `e820-reserve` (hide); *adding* memory is a LIED-rung control, never a feature | `/proc/iomem`, `/sys/firmware/memmap/` |
| **`setup_data`: the tree** (§3) | `.setup-data` | ≤ `setup_type_max` | `setup-data+ SETUP_DTB` | `/sys/kernel/boot_params/setup_data/`, `/proc/device-tree` |
| **`setup_data`: PCI option ROMs** — `SETUP_PCI` (3) hands a card's ROM image to the kernel as `struct pci_setup_rom`, which attaches it as the device's `rom` | the ROM Act III already read at the card's live BAR | the `0x55AA`/`PCIR` header `optrom.fth` already parses | `setup-data+ SETUP_PCI` with the bytes from the BAR | `/sys/bus/pci/devices/…/rom` serves the firmware's copy — **Act III's card, handed to Linux** |
| **`setup_data`: entropy** — `SETUP_RNG_SEED` (9): the loader seeds the kernel's RNG, and the kernel **wipes the record after consuming it** | — | `len` sane | `setup-data+ SETUP_RNG_SEED` with bytes from the firmware's own sources | the sysfs record's `len` reads **0** — the kernel's documented rewrite, and the one case where "the copy differs" is the pass |
| the **initrd** (§2.2) | `cpio-walk` | well-formed; digest | `initrd-append`, replace | `ls`, `cat`, `cpio -itv` |
| **`/chosen`** — 1275's own place for `bootargs`, `bootpath`, `stdin`/`stdout` | `.properties` | **agrees with the zero page**: the standard's record of the boot and the protocol's record of the boot are two records of one boot | `setprop` | on ppc the kernel reads it; on x86 it is the firmware's own ledger |
| the **device tree** | the tree | — | `new-device`/`property` (Act VI), which the DTB then carries | via §3 |
| the **NVRAM variables** (§1b, §2.5) | `printenv` | — | `setenv boot-file`, `nvramrc`, the boot counter | the next power-on |
| the **tables the door handed on** — coreboot's `LB_TAG` table (Act II), ACPI (RSDP → RSDT/XSDT, each with a checksum byte), SMBIOS | `lb-walk`; an ACPI walk is one more TLV | every checksum sums to zero; the RSDP the kernel will find is the one coreboot wrote | patching them (an SSDT, an SMBIOS string) is **a fifth seam, not opened here** — the kernel scans for RSDP itself, so it is reachable, and `/sys/class/dmi` and `/sys/firmware/acpi/tables` are its oracles | `acpidump`, `dmidecode` in userspace |
| the **measured-boot record** | `evlog-replay` | the digest of kernel + initrd + command line matches a recorded policy | authored at the gate (B.4 Spike 1) | `tpm2_eventlog`; the quote stays UNKNOWN |
| the **firmware's own state** | `dict-used`, the active package | room left; `device-end` before any typed probe (the showcase's marker lesson) | `marker`, `forget` | — |

Three of these are new enough to name as seams-in-waiting: **`SETUP_PCI`** is the
one that closes a loop the showcase opened (a ROM read at a live BAR in Act III,
served by Linux from the bytes the firmware handed over); **`SETUP_RNG_SEED`** is
the smallest possible handoff and the only one whose oracle is the kernel *erasing*
the evidence; and the **ACPI/SMBIOS tables** are a fifth seam with a real oracle and
a real cost, listed so the omission is a decision.

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

**The refusal that comes before any of it:** `setup_type_max` from the image's
`kernel_info` (§1a). If `SETUP_DTB` is above what the kernel declares it understands,
the record is refused *by name at the prompt*, and Idea B's worst outcome — a blob the
kernel skips silently, indistinguishable from a broken one — cannot happen. That is
the capability half of the protocol doing work.

**The oracle that needs no device-tree support at all:** the kernel exposes the zero
page it received at `/sys/kernel/boot_params/data`, and every `setup_data` record it
walked under `/sys/kernel/boot_params/setup_data/<n>/`. The record is visible there
**whether or not the kernel understood it** — so "did the bytes arrive" and "did the
kernel read them" are two separate assertions, and only the second depends on
`CONFIG_OF`.

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
- **The kernel shows the zero page it received.** `/sys/kernel/boot_params/data` is
  the struct byte for byte, `…/setup_data/<n>/{type,data}` the chain. Every edit in
  §2.1 is graded there *and* by its effect (`/proc/cmdline`, `/proc/iomem`): the
  first proves the bytes arrived, the second that the kernel acted on them, and a
  row where the first holds and the second does not is a finding, not a pass.
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
| S0 | `load …\vmlinuz …` → `LOADED`, `go` → u-root; `boot` unchanged; the three hooks declared and no-ops | patch 69 (§1), on x86 and amd64 |
| S0a | `.kernel-caps` prints the loaded image's declaration; `setup_type_max` and `type_of_loader` named | `bootparams.fth` (§1a); S0 |
| S1 | `/proc/cmdline` shows a string typed at the prompt after `load` | `bootparams.fth`; S0 |
| S2 | `cat /proc/sys/kernel/<name>` shows the value from a `sysctl.` parameter S1 added | S1 |
| S3 | `/proc/iomem` lacks a range the firmware reserved; the kernel booted anyway | e820 layout; S1 |
| S4 | `ls /etc/sysctl.d` shows a member the firmware appended; `cpio -itv` on the host reads two archives | `cpio.fth`; S1 |
| S5 | `/proc/device-tree/…/fcode-card@3` exists, or the mailbox blob `dtc`-decompiles identically; the record is under `/sys/kernel/boot_params/setup_data/` either way | `CONFIG_OF` measured; S3 for the mailbox |
| S5a | `?bootparams` refuses each one-field fixture by name and passes the good image; a nonsense `sysctl.` name is UNKNOWN at the gate and named by the kernel's log | `boot-gate` (§2.6); S1, S4 |
| S5b | `/sys/bus/pci/devices/…/rom` serves the bytes Act III read at the BAR; the `SETUP_RNG_SEED` record reads `len 0` | S1; `optrom.fth` |
| S6 | a kernel that never reaches `init` is followed, at the next power-on, by the console naming the fallback and booting the previous kernel | `bootcount.fth` (§2.5); S0, the NVRAM tracks |

**What to build, by seam** — the deliverables, so the seams read as work and not as
description:

| seam | file / patch | words | track | graded by |
|---|---|---|---|---|
| the window (§1) | patch 69 | `load`/`go` for bzImages; `linux-header-hook`, `linux-params-hook`, `linux-go-hook` | `linux-ladder` | today's showcase verdict, unchanged; a hook that throws aborts by name |
| the declaration (§1a) | `dsl/bootparams.fth` | `.kernel-caps` | `kernel-caps` | the same header read on the host; the kernel's `dmesg` |
| 1 — the zero page (§2.1) | `dsl/bootparams.fth` | `.zero-page`, `cmdline!`, `e820-reserve`, `setup-data+` | `zero-page` | `/sys/kernel/boot_params/data`; `/proc/cmdline`; `/proc/iomem` |
| 2 — the initrd (§2.2) | `dsl/cpio.fth` | `cpio-walk`, `cpio-find`, `initrd-append` | `initrd-append` | u-root's `ls`/`cat`; `cpio -itv` from `pmemsave` |
| 3 — the medium (§2.3) | a fixture builder | — | (a subject for §1a's refusals) | `readelf`-style host reading of the same header |
| 4 — NVRAM (§2.5) | `dsl/bootcount.fth`, an `nvramrc` script, one line in u-root's `init` | `bootcount@`, `bootcount!`, the hook word | `boot-counter` | three power cycles; the console naming the fallback |
| the tree (§3) | `dsl/fdt.fth` (exists) + `setup-data+` | — | `dtb-handoff` | `/sys/kernel/boot_params/setup_data/`; `/proc/device-tree`; `dtc` |
| the gate (§2.6) | `dsl/bootparams.fth` + `dsl/cpio.fth`, a one-field-per-fixture builder | `?bootparams` | `boot-gate` | one refusal per fixture, by name; UNKNOWN rows named; the good image passes |
| PCI ROM handoff (§2.7) | `dsl/optrom.fth` (exists) + `setup-data+` | — | `pci-rom-handoff` | `/sys/bus/pci/devices/…/rom` equals the bytes read at the BAR |
| entropy (§2.7) | `setup-data+` | — | `rng-seed` | the sysfs record's `len` is 0 after boot; unwiped is a finding |

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
6. **What does the loader write as `type_of_loader`?** The protocol's "who are you"
   field; `0xFF` is *undefined*, and the registered values are a short list. Whether
   OpenBIOS should identify itself, and as what, is a decision — the measurement of
   what it writes today comes first.
7. **Is the sentinel clear?** One boot, one `/sys/kernel/boot_params/data` read, byte
   `0x1ef`. If it is not, the kernel has been sanitising fields behind every boot this
   lab has ever graded, and some assertion above is weaker than it reads.
8. **Is the ACPI/SMBIOS seam (§2.7) worth opening?** It has the cleanest oracle of
   all (`acpidump`, `dmidecode`) and the highest cost (checksum discipline, and the
   multiboot door has no tables at all, so it is a coreboot-door-only seam).
9. **Which of the ignored declarations (§1a) should become refusals?** `setup_type_max`
   clearly; `relocatable_kernel`/`pref_address` only if a placement the loader chose
   is ever shown to disagree with one the kernel preferred.
