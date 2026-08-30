# Every patch, sorted — and why none of them goes upstream

`patches/` holds one annotated diff per change against the pinned commit
`6e563ee`. [`TESTED-TREE.patch`](TESTED-TREE.patch) is the cumulative version
that [`build-openbios.sh`](../build-openbios.sh) actually applies; the numbered
patches are **the record** — read, not run.
[`tools/check-patch-hygiene.sh`](../../../tools/check-patch-hygiene.sh) binds
the two together so the record cannot quietly outlive what is built.

This file is the fourth thing about them: **a decision, and a sorted index.**

## The decision (2026-08-28): all 41 are ours

**Nothing here is sent to `openbios/openbios`.** Every patch is carried as
deliberate local divergence, indefinitely.

The reason is a judgement about *review burden*, not about the code:

> "We won't be upstreaming anything… I don't want to bother the maintainers of
> this project. This repo is very low activity. It seems to be in maintenance
> mode."

**And upstream is not dead — that is the part worth writing down, because the
comfortable version of this reason would be false.** Measured 2026-08-28:
`openbios/openbios` carries commits dated **2026-06-29**, including a
`.github/workflows` update. It is a maintained project with CI, moving slowly.
So this is a choice about *our* posture toward a small volunteer project, not a
claim that patches would have nowhere to land. Recording it the other way round
would be exactly the failure this lab keeps finding in everything else it
touches: a record that outlives its subject, comfortable and wrong.

**What the decision costs.** Every bump of `OPENBIOS_PIN` re-applies all 41. The
`shared` rows below are where a conflict will actually land — **22 of 41** touch
a path that some *other* architecture's build also compiles. The 19 `arch-local`
rows touch only `arch/x86`, `arch/amd64`, their headers, or their own
`*_config.xml`, and are nearly free to carry.

**What would reverse it.** The `UPSTREAM-BUG` rows are the candidate set, already
one-per-defect with PR-shaped `Subject:` lines and (from patch 20 onward) an
`Arch-tested:` line. Nothing about carrying them locally forecloses sending them
later.

## How to read the table

**`kind` — why the patch exists.** A closed vocabulary; the checker rejects
anything else.

| kind | meaning |
|---|---|
| `UPSTREAM-BUG` | a defect in code upstream ships, fixed here. Would apply to upstream as-is. |
| `PORT` | capability in `arch/amd64`, which upstream ships but has not built since 2003. |
| `FEATURE` | a capability this lab wanted and upstream never claimed to have. |
| `DIVERGENCE` | deliberately **different from upstream's intent** — behaviour we do not want to match. |
| `FIXTURE` | a test or diagnostic surface compiled into the firmware for this lab's tracks. |
| `RECORD` | bookkeeping inside `patches/` itself; no behaviour change. |

**`scope` — where a future rebase will hurt.** Derived from the files each patch
touches, not asserted: `arch-local` when every touched path is under `arch/`,
`include/arch/`, or `config/examples/<arch>_config.xml`; `shared` otherwise.
`check-patch-hygiene.sh` **A7** recomputes this column from the patch on every
run and fails if the table disagrees — a hand-maintained scope column would be a
cached fact about a file that changes.

Rows link to the diff. The narrative for patches 12–34 lives in the
[README's “What's here” table](../README.md#whats-here); this index does not repeat it.

## The series

| patch | kind | scope | what it is |
|---|---|---|---|
| [`01-x86-revival.patch`](01-x86-revival.patch) | `UPSTREAM-BUG` | shared | the eight fixes that make the x86 path boot at all — the lab's founding diff |
| [`02-amd64-spike0-build-on.patch`](02-amd64-spike0-build-on.patch) | `PORT` | arch-local | **superseded by 08.** Spike 0: a real amd64 `build.xml` + 64-bit ldscript |
| [`03-amd64-spike0-drift-fixes.patch`](03-amd64-spike0-drift-fixes.patch) | `PORT` | arch-local | **superseded by 08.** The drift-only pass over `arch/amd64`'s 2003 sources |
| [`04-x86-nvram-p0.patch`](04-x86-nvram-p0.patch) | `FEATURE` | arch-local | persistence ladder P0: an `nvram` node that *exists*, backed by a static buffer that persists nothing — deliberately, as P2's control |
| [`05-x86-nvram-p1-ide-backing.patch`](05-x86-nvram-p1-ide-backing.patch) | `FEATURE` | shared | P1: a real backing. Adds `WIN_WRITE` (upstream `ide.h` defined only reads), PIO data-out, LBA28 write, and refuses a non-blank drive **before** the write |
| [`06-x86-nvram-cfi-flash-backing.patch`](06-x86-nvram-cfi-flash-backing.patch) | `FEATURE` | arch-local | a second, deliberately unlike backing: memory-mapped CFI flash, selected by a **runtime probe** rather than a build option |
| [`07-x86-floppy-backing.patch`](07-x86-floppy-backing.patch) | `FEATURE` | shared | a third backing, honestly half-done: read works (and fixes an upstream `read_ok()` bug hidden behind a disabled `CONFIG_DRIVER_FLOPPY`), write is known-blocked against QEMU's S82078B and fails by name |
| [`08-amd64-spike1-trampoline.patch`](08-amd64-spike1-trampoline.patch) | `PORT` | shared | **Spike 1: the firmware runs in long mode.** A new trampoline, SSE enabled, the multiboot handoff saved before paging destroys it |
| [`09-amd64-spike2-exceptions.patch`](09-amd64-spike2-exceptions.patch) | `PORT` | arch-local | Spike 2: a 64-bit IDT (`arch/amd64` had none — the first fault was a triple fault) and a working context switch |
| [`10-amd64-p3-pmem-store.patch`](10-amd64-p3-pmem-store.patch) | `FEATURE` | arch-local | the one backing that **needed** the port: an NVRAM store in persistent memory at `0x100000000`, the first address a 32-bit firmware cannot form |
| [`11-config-defaults-and-fault-recovery.patch`](11-config-defaults-and-fault-recovery.patch) | `UPSTREAM-BUG` | arch-local | two defects a green suite could not see: `set-defaults` registered in the wrong initializer list overwrote every boot's NVRAM read, and a fault recovery that never re-entered the interpreter |
| [`12-amd64-spike3-boots-linux.patch`](12-amd64-spike3-boots-linux.patch) | `PORT` | shared | **Spike 3: the 64-bit firmware boots Linux.** Five silent defects, three of them the same assumption — `arch/amd64` does not relocate, so it *is* sitting at the 1 MiB a bzImage runs at |
| [`13-amd64-loader-forth.patch`](13-amd64-loader-forth.patch) | `PORT` | arch-local | compiles the Forth loader into amd64 (x86 parity); inert until 14 |
| [`14-amd64-openbios-init-after-device-end.patch`](14-amd64-openbios-init-after-device-end.patch) | `PORT` | arch-local | **every `bind_func` before `device_end()` is invisible to `$find`** — so `(init-program)` and `(go)` were unreachable |
| [`15-forth-loader-divergence.patch`](15-forth-loader-divergence.patch) | `DIVERGENCE` | shared | **the one we carry on purpose.** `ls.file-size` is never set on the `load` path and `eval2` is defined nowhere in the tree, so upstream's Forth-source loader has never run a byte on any arch. Our goals differ from theirs |
| [`16-x86-openbios-init-after-device-end.patch`](16-x86-openbios-init-after-device-end.patch) | `UPSTREAM-BUG` | arch-local | 14's fix for x86, where `CONFIG_LOADER_FORTH` has been `true` all along over a dead path |
| [`17-amd64-enumerate-pci.patch`](17-amd64-enumerate-pci.patch) | `PORT` | arch-local | amd64 had `CONFIG_DRIVER_PCI` on and **never called `ob_pci_init()`** — compiled, linked, never run |
| [`18-vga-fcode-defined-into-the-root-node.patch`](18-vga-fcode-defined-into-the-root-node.patch) | `UPSTREAM-BUG` | arch-local | an unbalanced `find-device` put `vga-driver-fcode` in root's method list; the VGA FCode driver had never been evaluated on x86 either |
| [`19-amd64-preopen-leaves-chosen-active.patch`](19-amd64-preopen-leaves-chosen-active.patch) | `PORT` | arch-local | the second unbalanced site in the same file — `arch/x86/init.fs:52` has had the missing line all along |
| [`20-bindings-report-their-own-failures.patch`](20-bindings-report-their-own-failures.patch) | `UPSTREAM-BUG` | shared | the silence patches 14–19 hid behind: `feval()` returns the throw code and **146 of 147 call sites discard it** (`fword()`: 969 of 969) |
| [`21-vsprintf-precision-is-a-maximum.patch`](21-vsprintf-precision-is-a-maximum.patch) | `UPSTREAM-BUG` | shared | `%s` precision treated as a **minimum**, so `%.10s` of a 3-byte string produced ten bytes. The correct `strnlen` sat one line above under `#if 0` |
| [`22-printf-number-and-truncation-fixtures.patch`](22-printf-number-and-truncation-fixtures.patch) | `FIXTURE` | shared | closes the two paths 21 named and did not test, with one C99 divergence asserted **as itself** rather than fixed or hidden |
| [`23-load-state-is-never-zeroed.patch`](23-load-state-is-never-zeroed.patch) | `UPSTREAM-BUG` | shared | `create … allot` never zeroes, so the `0`-means-unset test read dictionary garbage and handed `evaluate` **768 MB** |
| [`24-forth-trampoline-runs-in-firmware-segments.patch`](24-forth-trampoline-runs-in-firmware-segments.patch) | `UPSTREAM-BUG` | shared | the Forth/FCode trampolines are firmware, not client programs, and were entered in the **client's** segments |
| [`25-decode-bytes-robbed-the-return-stack.patch`](25-decode-bytes-robbed-the-return-stack.patch) | `UPSTREAM-BUG` | shared | **one transposed character**: two bare `r>` and no `>r`, returning cleanly with six items where 1275 documents four |
| [`26-encode-int-refuses-what-four-bytes-cannot-hold.patch`](26-encode-int-refuses-what-four-bytes-cannot-hold.patch) | `UPSTREAM-BUG` | shared | `l!-be` wrote the low four bytes of a wider value and dropped the rest — and the tree encodes **ihandles** that way |
| [`27-encode-plus-concatenates.patch`](27-encode-plus-concatenates.patch) | `UPSTREAM-BUG` | shared | `encode+` was `nip +` — adjacency by assumption. The length was never the part it got wrong |
| [`28-pci-property-cells-are-big-endian.patch`](28-pci-property-cells-are-big-endian.patch) | `UPSTREAM-BUG` | shared | `drivers/pci.c` handed `set_property()` **host-order** cells while the tree reads them big-endian, so every child of the bridge encoded as `@0` |
| [`29-ppc32-had-no-fno-builtin.patch`](29-ppc32-had-no-fno-builtin.patch) | `UPSTREAM-BUG` | shared | ppc32 was the only arch built without `-fno-builtin`, so GCC computed `snprintf`'s C99 return value while our libc wrote the buffer |
| [`30-eword-and-printf-surface-fixtures.patch`](30-eword-and-printf-surface-fixtures.patch) | `FIXTURE` | shared | two "unverified by construction" rows that were verified by **nobody**; 12/12 becomes 14/14 |
| [`31-encode-writers-take-a-destination.patch`](31-encode-writers-take-a-destination.patch) | `FEATURE` | shared | splits SIZE from WRITE so an encoder can be aimed at flash, MMIO or a handoff page; the 1275 words are redefined on top, unchanged |
| [`32-the-cursor.patch`](32-the-cursor.patch) | `FEATURE` | shared | `int!+` `string!+` `bytes!+` compose successive fields at a caller-chosen address, with the cursor as a **stack value** |
| [`33-first-memory-bar-got-address-zero.patch`](33-first-memory-bar-got-address-zero.patch) | `UPSTREAM-BUG` | arch-local | `mem_base` seeded from a struct field x86 and amd64 never set, so the first memory BAR was programmed at **0** — QEMU's framebuffer |
| [`34-pci-bus-cell-counts.patch`](34-pci-bus-cell-counts.patch) | `UPSTREAM-BUG` | shared | a PCI bus declared no `#address-cells`, so `my-#acells` defaulted to 2 while every C encoder wrote 3 — the Forth *decode* read one cell short |
| [`35-record-amd64-boot-h.patch`](35-record-amd64-boot-h.patch) | `RECORD` | arch-local | records `arch/amd64/boot.h`, which the port needed and the record did not have — found by A6 on the day the record/applied split was introduced |
| [`36-amd64-embedded-image-set.patch`](36-amd64-embedded-image-set.patch) | `UPSTREAM-BUG` | arch-local | `switch-arch builtin-amd64` is in upstream's **own usage text** and built nothing, exiting 0 |
| [`37-amd64-builtin-never-declared-its-array.patch`](37-amd64-builtin-never-declared-its-array.patch) | `UPSTREAM-BUG` | arch-local | `arch/amd64/builtin.c` never declared the array its own comment describes — it has not compiled since 2003 |
| [`38-amd64-embedded-dictionary-branch.patch`](38-amd64-embedded-dictionary-branch.patch) | `PORT` | arch-local | amd64 knew only one kind of dictionary, so an embedded one panicked |
| [`39-coreboot-table-is-a-wire-format.patch`](39-coreboot-table-is-a-wire-format.patch) | `UPSTREAM-BUG` | shared | coreboot's own header says why it forces 4-byte alignment on its `uint64_t`; OpenBIOS's copy dropped it, so any 64-bit reader misreads the table |
| [`40-publish-the-memory-map.patch`](40-publish-the-memory-map.patch) | `UPSTREAM-BUG` | shared | nothing published the memory map — `/memory` carried only its name, so no client could ask this firmware what memory exists |
| [`41-multiboot-union-was-still-lp64.patch`](41-multiboot-union-was-still-lp64.patch) | `UPSTREAM-BUG` | arch-local | 39's wire-format fix stopped one struct short: a union of four `unsigned long` is 16 bytes on i386 and 32 on LP64, shifting `mmap_length` from offset 44 to 64 |
| [`42-ide-reg-follows-its-parents-cells.patch`](42-ide-reg-follows-its-parents-cells.patch) | `UPSTREAM-BUG` | shared | a `reg` is decoded with the PARENT's cells and ide wrote a fixed three, so `/ide@1` resolved by luck — ppc/sparc64 keep the old bytes, where the parent is a PCI bus and deriving would rename every node |
| [`43-amd64-root-two-address-cells.patch`](43-amd64-root-two-address-cells.patch) | `FEATURE` | arch-local | **TODO 17.1**: the amd64 root declares `#address-cells 2 / #size-cells 2`, so `/memory` can finally describe the range at `0x100000000`. x86 stays at one cell, where one cell is *accurate*. The root's unit words had to move with the count |
| [`44-amd64-had-no-claim.patch`](44-amd64-had-no-claim.patch) | `PORT` | arch-local | `arch/amd64` bound **no** `cif-claim` or `cif-release`, so the 1275 claim service fell through `ciface.fs`'s `else 3drop -1` and every client allocation on the 64-bit firmware returned -1. x86's window formula could not be copied: it sizes itself with `virt_offset`, and amd64 does not relocate |
| [`45-memory-available.patch`](45-memory-available.patch) | `FEATURE` | shared | **TODO 17.3**: `/memory` carries an `available` beside its `reg`, **republished on every claim and release** rather than snapshotted — it describes a cursor, and a boot-time snapshot is stale from the first allocation. Deliberately narrower than "all unallocated RAM": advertising memory `claim` will refuse would be the lie |
| [`46-number-agrees-with-c99.patch`](46-number-agrees-with-c99.patch) | `UPSTREAM-BUG` | shared | **TODO 17.4**: `%.0d` of 0 produced `"0"` where C99 produces nothing, and the `0` flag survived a precision — GCC refuses the literal for the second. Plus `num = -num` at `LLONG_MIN`, which was undefined behaviour. Closing them removes a latent "two printfs answering one call" (§13.3(C)), not just a formatting difference |
| [`47-source-date-epoch.patch`](47-source-date-epoch.patch) | `FEATURE` | shared | **TODO 17.5**: the build honours `SOURCE_DATE_EPOCH`, so a tree can be rebuilt byte-identically **on request**. The date is not deleted — the ppc track proves the running firmware is ours by comparing exactly that banner — and unset, behaviour is bit-for-bit what it was |
| [`48-scrub-host-arena-pointers.patch`](48-scrub-host-arena-pointers.patch) | `UPSTREAM-BUG` | shared | **TODO 17.5 cause 2**: the bootstrap stored pointers into the HOST's Forth arena in ordinary dictionary cells — not relocatable, so written out raw and moving with ASLR. Dead data (re-initialised at boot), now scrubbed from both writers. x86 never showed it because `pointer2cell` subtracts `base_address` at narrower widths |
| [`49-device-register-words-were-empty.patch`](49-device-register-words-were-empty.patch) | `UPSTREAM-BUG` | shared | IEEE 1275 **5.3.7.2**'s six device-register words — `rb@ rw@ rl@ rb! rw! rl!` — had bodies containing **no words at all**, so a register read returned the ADDRESS and a register write stored nothing while leaking two cells. `table.fs:390-395` binds FCode tokens `0x230-0x235` to them, so the presenting symptom is a **stack shift inside an FCode driver**, not a wrong value. `feval.fs:72`'s FIXME ("uses `c@` rather than `rb@` for now") shows the gap was known and worked around at one call site |

## What the sort says

| kind | count | |
|---|---|---|
| `UPSTREAM-BUG` | 24 | defects any user of `openbios/openbios` would hit. The candidate set, if the decision above is ever revisited |
| `PORT` | 11 | `arch/amd64`, which upstream ships and has not built since 2003 |
| `FEATURE` | 10 | capabilities upstream never claimed — three NVRAM backings, a pmem store, the encoder work, a root that can describe memory above 4 GiB, a `/memory` that says what is free, and a build that can be made reproducible on request |
| `FIXTURE` | 2 | test surface compiled into the firmware |
| `DIVERGENCE` | 1 | patch 15, and only patch 15 |
| `RECORD` | 1 | bookkeeping |

And by where a future rebase will hurt:

| scope | count | |
|---|---|---|
| shared | 28 | touches a path some *other* architecture's build also compiles — this is where a pin bump conflicts |
| arch-local | 21 | only `arch/`, `include/arch/`, or its own `*_config.xml` — nearly free to carry |

**Only one patch is a divergence in the sense of "we want different behaviour."**
The other 48 are things upstream would arguably want and is not going to be
asked for. That asymmetry is the honest summary of what "all 41 are ours" means
here: it is a decision about traffic, not about taste.

**Two of the six kinds have exactly one member**, which is a thin taxonomy and
is left thin on purpose — `RECORD` and `DIVERGENCE` each name a genuinely
different reason for a patch to exist, and collapsing them into the others would
hide the only deliberate behavioural divergence in the series behind 23 bug
fixes.
