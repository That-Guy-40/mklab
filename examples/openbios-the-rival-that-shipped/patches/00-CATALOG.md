# Every patch, sorted — and why none of them goes upstream

`patches/` holds one annotated diff per change against the pinned commit
`e5ac46d`. [`TESTED-TREE.patch`](TESTED-TREE.patch) is the cumulative version
that [`build-openbios.sh`](../build-openbios.sh) actually applies; the numbered
patches are **the record** — read, not run.
[`tools/check-patch-hygiene.sh`](../../../tools/check-patch-hygiene.sh) binds
the two together so the record cannot quietly outlive what is built.

This file is the fourth thing about them: **a decision, and a sorted index.**

## The decision (2026-08-28): all of them are ours

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

**What the decision costs.** Every bump of `OPENBIOS_PIN` re-applies the whole
series. The `shared` rows below are where a conflict will actually land — they
touch a path that some *other* architecture's build also compiles. The
`arch-local` rows touch only `arch/x86`, `arch/amd64`, their headers, or their
own `*_config.xml`, and are nearly free to carry. **How many of each is in the
scope summary below**, and nowhere else on this page: `check-patch-hygiene.sh`
**A8** fails the run if a count reappears in the prose, because every count that
was written here drifted while the machine-checked table stayed right.

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
| [`50-unix-arena-below-4g.patch`](50-unix-arena-below-4g.patch) | `DIVERGENCE` | arch-local | **`openbios-unix` had not reached its prompt since patch 26**, and nothing noticed for four days because MANUAL_TESTING.md §5 documented it and no track drove it. 1275 encodes an integer into **four bytes** (5.3.5.1); `/chosen`'s `stdin`/`stdout` are ihandles; and at run time `pointer2cell` is a plain cast, so on this target an ihandle **is** a host pointer — glibc put the arena above 4 GiB and `encode-int` rightly refused. **Patch 26's gate is untouched**: measured, all five trips come through `int!`, so narrowing it would have changed nothing and weakening it would only restore the silent truncation. `arch/unix/unix.c` now maps the arena and the dictionary below 4 GiB — where the QEMU firmwares (0x400000, 0x4000000) have always been — and refuses by name if it cannot. Covered by `smoke-openbios.sh unix`; see TODO §18 |
| [`51-unix-exit-status-reports-the-forth.patch`](51-unix-exit-status-reports-the-forth.patch) | `DIVERGENCE` | shared | **main() returned 0 whatever the Forth had done**, so a firmware that aborted during initialisation reported SUCCESS to the shell — the LIED rung. Three obvious signals cannot discriminate (`enterforth()`'s return, `interruptforth`'s STOP bit, `exception()`), and the reason is that `bye` and an uncaught `throw` unwind **identically** — `0 rdepth!` either way. So the flag sits on the DELIBERATE path: `bye` sets `of-left-cleanly` and `arch/unix` reads it through `feval()`. A missing flag is **UNKNOWN**, not a failure. Shared Forth, so all three arches rebuilt and driven; see TODO §18(b) |
| [`52-unix-missing-dict-eof-spin-and-a-false-alarm.patch`](52-unix-missing-dict-eof-spin-and-a-false-alarm.patch) | `UPSTREAM-BUG` | shared | **Three defects out of one user session that just tried to get a prompt.** A **missing dictionary** was neither named nor fatal — `read_dictionary()` returns 0 on `stat()` failure and the caller ignored it, so an empty dictionary produced two baffling `fword:` lines and **exit 0**. **End of input spun a core at 100% forever** — `key()` was `while (!availchar());`, a busy-wait nothing could interrupt; it took BOTH halves (the console says `FORTH_INTSTAT_STOP`, the waiter listens), and EOF now reads as end-of-LINE rather than a `0xff` byte to echo. And **every clean exit printed `feval: … threw -4`** because `cmdline.c` reset only the return stack before its `feval`, where its own comment says "Reset stack". Covered by `smoke-openbios.sh unix` |
| [`53-unix-ctrl-d-is-not-eof-on-a-raw-tty.patch`](53-unix-ctrl-d-is-not-eof-on-a-raw-tty.patch) | `UPSTREAM-BUG` | arch-local | **Patch 52 finished.** 52 stopped the end-of-input spin — for **pipes only**, so the case a person hits stayed broken. `init_terminal()` clears `ICANON`, so a tty never turns `^D` into EOF; it arrives as the byte `0x04` and was silently swallowed, reading as input that will not flush. **Ctrl-D is one keystroke and means leave now**; **pipe EOF latches**, so there the first finishes a trailing line and the second leaves. A green suite could not see it because every unix test drives a pipe — the track now drives a **real pty** and the assertion was watched to bite. TODO §19(d) |
| [`54-unix-write-file-authors-a-host-file.patch`](54-unix-write-file-authors-a-host-file.patch) | `FEATURE` | arch-local | **The hosted firmware could READ from a host file and never WRITE to one** — `write_dictionary()` is `#if 0`, `blk` has no `write-blocks`, `arch/unix` has no NVRAM backend — so a structure the Forth built in the arena evaporated at exit. This binds `write-file ( data-adr data-len fname-adr fname-len -- actual-len )`, hosted-only (in `arch_init`, not the common `init.c`), closing REVIEW §G6's "the reader is still ahead of the writer". It names every failure and returns the bytes actually written; it cannot carry `strerror(errno)` because `config.h` `#define`s `errno` to a shim host syscalls never touch. `dsl/elf-write.fth` authors a 132-byte static x86-64 ELF and the `file-writer` track has the **kernel run it** — the exit status must equal the authored code. TODO §20 |
| [`55-pci-expansion-rom-published-and-config-space-bound.patch`](55-pci-expansion-rom-published-and-config-space-bound.patch) | `FEATURE` | shared | **B.3 Spike 3's UNCOVERED row, uncovered.** The PCI allocator already mapped AND enabled every device's expansion ROM (`ob_pci_configure_bar`, `reg == 6`) and never said where — `reg`/`assigned-addresses` stopped at the BARs. Publishes the ROM base register (0x30 / 0x38) as the 1275 PCI binding lists it, and binds the binding's `config-{b,w,l}@`/`!` as global words (bound after `device_end()`, per 14/16). `dsl/optrom.fth` + the `optrom` track read a real option ROM's header at the live BAR on x86 and amd64, byte-load its FCode from there, and flip its enable bit through `config-l!`
| [`56-pci-config-space-is-a-bus-node-method.patch`](56-pci-config-space-is-a-bus-node-method.patch) | `FEATURE` | shared | **A card cannot see a global word.** 55 bound `config-{b,w,l}@`/`!` globally; the 1275 PCI binding puts them on the **bus node**, because an FCode driver reaches config space as `my-space " config-l@" $call-parent`. Measured: `config-l@` has **no FCode number at all** (neither `toke` nor `detok` knows it), so there is no table entry to add and the method is the only route — before this, that route threw `-21` with the globals sitting right there |
| [`57-every-probed-node-gets-its-probe-addr.patch`](57-every-probed-node-gets-its-probe-addr.patch) | `UPSTREAM-BUG` | shared | **`my-space` answered 0 for every PCI node**, so a card driver asking who it is read **bus 0, device 0 — the host bridge (8086:1237)** while believing it read itself. `set-args` writes `probe-addr` through the *current instance*, and the enumerator has none for the node it is building. **ppc does not have the defect** (its nodes come out with `probe-addr` set), which is what made the arch matrix find it |
| [`58-the-firmwares-own-walk-re-run-and-watched.patch`](58-the-firmwares-own-walk-re-run-and-watched.patch) | `FEATURE` | shared | **B.3's last success-signature line, and the review's premise retracted.** Plan §9 wanted *"a region diff shows a firmware-caused change"*, so the change had to come from a code path already in the tree: `lb-walk` re-runs `libopenbios/linuxbios_info.c`'s coreboot-table parser (this lab's patches 01 and 39) into a **scratch** `sys_info`, `lb-table` names the region it reads and `heap-cursor` the allocator's next block. F5/F6 said the diff would show in the table; measured, `read_lbtable()` is a **reader**, so that region is the NEGATIVE control and the write is one level down, in `convert_memmap()`'s `malloc`. Addresses out are **physical** so a caller cannot skip `>virt` — the `region-diff` track counts **0** without it on x86 and the same as the `>virt` path on amd64, where `virt_offset` is 0
| [`59-config-space-through-a-pci-bridge.patch`](59-config-space-through-a-pci-bridge.patch) | `FEATURE` | shared | **Patch 56 stopped one bus level short.** A card behind a PCI-PCI bridge has the *bridge* node as its parent, and `ob_pci_bridge_node` had none of the config methods — measured on amd64 with QEMU's `pci-bridge`: `probe-addr` right (`0x10800`), ROM header fine, the *global* `config-l@` reads `100e8086`, and the card's own `$call-parent` route returns **`cfg-id=none`**, the `-21` patch 56 removed. Six one-line methods chain to the parent the way the bridge already chained `pci-map-in`. Found by the 2026-09-03 audit; the `optrom` track keeps a bridged card on x86 and amd64 |
| [`60-pci-map-out-the-other-half-of-map-in.patch`](60-pci-map-out-the-other-half-of-map-in.patch) | `UPSTREAM-BUG` | shared | **The binding's `map-in`/`map-out` are a pair; upstream bound only the first.** On ppc `ob_pci_map()` *claims* the physical and virtual ranges through ofmem, so with nothing to release them a second `map-in` of the same region fails its claim and answers `ffffffff` — which #388 had written up as *"call-once-and-keep, not a getter"*. A leak with a nicer name, retracted by the audit. `pci-map-out ( virt size -- )` is `ofmem_release()` (6.3.2.4: unmap, release virt, release phys) — the exact inverse of what `map-in` did; a no-op on x86/amd64, which never claimed. `dsl/optrom.fth` gains `optrom-unmap`, `optrom-run-mapped` gives its mapping back on every path, and the ppc row measures both directions. Also: `lb-table` searches once, not twice |
| [`61-ob-pci-unmap-gives-back-the-claims.patch`](61-ob-pci-unmap-gives-back-the-claims.patch) | `UPSTREAM-BUG` | shared | **The same leak as patch 60, one caller further in.** The config callbacks that map a BAR at *probe* (`sungem_config_cb`, 0x8000 bytes to read the MAC) gave it back with `ob_pci_unmap()`, which called `ofmem_unmap()` — the translation returned, both ofmem claims stayed, and every later `pci-map-in` of that BAR failed its claim and answered `ffffffff`. Measured on mac99 with `-device sungem` before the fix (twice `ffffffff`; an un-claimed e1000 BAR maps, releases and maps again as the control). `ob_pci_unmap()` is now `ofmem_release()`, and `pci-map-out` calls *it*, so there is one implementation of "give it back". `dsl/optrom.fth` gains `bar-map ( reg -- virt \| 0 )`; the `optrom` track's ppc row adds a sungem and maps its BAR0 after boot |
| [`62-call-method-refuses-ihandle-0.patch`](62-call-method-refuses-ihandle-0.patch) | `UPSTREAM-BUG` | shared | **An ihandle of 0 read as an instance.** `$call-method` did `0 >in.device-node @` — on amd64 that is the real-mode IVT, the "phandle" is `f000ff54f000ff7b`, and `find-method` takes a general protection fault; on x86 the same read walked to `-21` by luck. Met by the 2026-09-03 audit as *"`$call-parent` from a parentless instance GPFs rather than throwing"* (a bridge chaining patch 59's `$call-parent` into a one-level instance). Two `abort"`s in the shape `?my-self` already had: `$call-method: ihandle is 0 (no instance).` and `no parent instance.` — a caller's `catch` gets `-2` on every arch. The `optrom` track types both shapes on x86, amd64 and ppc and asserts the throw by name and no exception line |
| [`63-dict-limit-and-dict-used.patch`](63-dict-limit-and-dict-used.patch) | `FEATURE` | shared | **The two cells `here!` compares, readable from Forth.** Plan §6 had left the dictionary budget *"unmeasured, and no claim is made"*; measuring it needs `dictlimit` and `dicthead`, and the only way to reach the limit from Forth was to allot *past* it and read the `Dictionary space overflow` line — which was also the kernel's whole protection until patch 66: `herewrite()` printed and **continued**, into whatever follows the array. Two kernel primitives, `dict-limit` / `dict-used`, appended to `words[]`/`wordnames[]` (kernel, so every arch has them from bootstrap on; no arch file touched). The `dict-budget` track measures the toolkit's cost per file per arch and guards every evaluate with 1.5× source size against the room left; its controls: allot 10 past the room → the overflow line naming the same limit, 10 short → silence |
| [`64-amd64-dictionary-1mib.patch`](64-amd64-dictionary-1mib.patch) | `PORT` | arch-local | **The port's 256 KiB dictionary did not hold the toolkit.** Patch 63's `dict-budget` measured 205 of 256 KiB spent at the prompt (33 KiB of it compiled at init, 3× the hosted target's) and `eventlog.fth` refused for room. arch/x86's multiboot door has had 1 MiB for years and this arch's own coreboot-payload door (`builtin.c`) already carries 1 MiB, so the two amd64 doors disagreed by 4×. One constant; `.bss`, so the image does not grow. Measured after: the whole toolkit compiles on amd64 and the overflow control names `dictlimit=100000` |
| [`65-unix-dictionary-1mib.patch`](65-unix-dictionary-1mib.patch) | `DIVERGENCE` | arch-local | **The workbench was one file from the edge.** `dict-budget` measured the hosted target at 95% with the toolkit loaded (183 KiB spent at the prompt, +60 KiB, 13 KiB of 256 KiB left) — and `here!` only *prints* on overflow. Every other door now has 1 MiB (or ppc's 384 KiB); the target every `dsl/*.fth` edit is tried on first should not be the tightest. One constant, one mmap below 4 GiB at 0x30000000, clear of the arena. After: 781 KiB left (76%) — the whole toolkit compiles, and the overflow control names `dictlimit=100000` |
| [`66-here-refuses-a-dictionary-overflow.patch`](66-here-refuses-a-dictionary-overflow.patch) | `UPSTREAM-BUG` | shared | **`here!` printed `Dictionary space overflow` and CONTINUED**, the pointer already past the end — the `dict-budget` track's OVER control showed it on every arch, and the byte after the dictionary is somebody else's: an unmapped page on unix (the next `.` segfaulted the firmware — its pad is at `here`), `console_ops` on ppc (one `,` rewrote two console function pointers behind an `ok`), `x86_nvram_backend` on x86, `last_key` on amd64. Now the pointer stays and -8 (ANS *dictionary overflow*) is thrown from C through `enterforth`, as ppc's `methods.c` has thrown -13 all along; `print-status` names it. Measured after on unix and ppc: -8 to the `catch`, `dict-used` unchanged, the neighbour bytes identical, the prompt intact. One consequence: `[DEFINE]` at a *running* prompt (its buffer is outside the dictionary) is refused where it used to be flagged and carried on |
| [`67-marker-with-the-two-refusals-this-dictionary-needs.patch`](67-marker-with-the-two-refusals-this-dictionary-needs.patch) | `FEATURE` | shared | **`marker`, which OpenBIOS never had — with the two refusals THIS dictionary needs.** The marks are captured before the marker's own header (a draft that captured `here` under it segfaulted at `ffffffff` on the next `:`), and because the device tree is `allot`ed from the same dictionary — nodes, wordlist heads, property structs, names and values — a marker walks the tree and **refuses by name** when any of them lies above the mark, or when the active package differs. Byte-exact reclaim measured on all four arches; the three tree refusals each isolate one sub-check; nested markers forget LIFO. Track: `marker` |

## What the sort says

| kind | count | |
|---|---|---|
| `UPSTREAM-BUG` | 31 | defects any user of `openbios/openbios` would hit. The candidate set, if the decision above is ever revisited |
| `PORT` | 12 | `arch/amd64`, which upstream ships and has not built since 2003 |
| `FEATURE` | 17 | capabilities upstream never claimed — three NVRAM backings, a pmem store, the encoder work, a root that can describe memory above 4 GiB, a `/memory` that says what is free, a build that can be made reproducible on request, and a `write-file` that lets the hosted firmware author a real host file |
| `FIXTURE` | 2 | test surface compiled into the firmware |
| `DIVERGENCE` | 4 | patch 15 (the Forth loader), patch 50 (the unix arena below 4 GiB), patch 51 (the unix exit status), and patch 65 (the unix dictionary at 1 MiB) |
| `RECORD` | 1 | bookkeeping |

And by where a future rebase will hurt:

| scope | count | |
|---|---|---|
| shared | 41 | touches a path some *other* architecture's build also compiles — this is where a pin bump conflicts |
| arch-local | 26 | only `arch/`, `include/arch/`, or its own `*_config.xml` — nearly free to carry |

**Only the `DIVERGENCE` rows are divergences in the sense of "we want different
behaviour."** Everything else is something upstream would arguably want and is
not going to be asked for. That asymmetry is the honest summary of what "all of
them are ours" means here: it is a decision about traffic, not about taste.

**`RECORD` is a taxonomy of one**, which is thin and is left thin on purpose: it
names a genuinely different reason for a patch to exist — bookkeeping inside
`patches/` itself, no behaviour change — and folding it into the others would
file a non-change beside the fixes. `DIVERGENCE` began the same way and has
since grown (patch 15's Forth loader, then the two unix patches), which is the
argument for keeping a thin kind rather than against it.
