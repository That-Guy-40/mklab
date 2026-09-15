# pacme in the workbench — GNU poke's acme UI as a live inspector of the firmware, not a port into it

**The question.** Could pacme, GNU poke's acme-inspired C interface, run *under*
OpenBIOS the way this repo's [MicroEMACS client](examples/openbios-clib-hello-to-emacs/README.md)
does — a program the firmware `load`s and runs on the bare machine with no OS?
**Short answer: no, and you don't want that.** Two independent walls stop it. But
the framing that replaces it — pacme confined to the **Unix process that hosts the
workbench**, wired to the firmware's own bytes over a seam — is not just a
fallback. It is what pacme was built to be, and it is the interactive, live sibling
of the [`pe.pk` host oracle](UKI_WORKBENCH_LAB_PLAN.md#4a-the-pe-oracle-gnu-pokes-pepk)
this repo just adopted. Tracked in [`TODO.md`](TODO.md) §32.

Calls a lab into being — **`pacme-inspects-the-firmware`** (name reserved here,
built as a separate example) — and settles its one hard decision (the bridge) as a
Spike 0 before any UI is drawn.

## 1. Two framings, and why only one survives

**Framing A — pacme as a firmware client (no OS underneath): a no, twice over.**

The MicroEMACS lab is the honest precedent, so read what it actually did. It did
**not** port Daniel Lawrence's uEmacs verbatim; it says so in as many words — a
freestanding client has *no files, no termios, no signals, no termcap, no shell*,
so porting that tree "isn't a mechanical port, it's rewriting its entire bottom
half." It **reimplemented the editor core** in ~430 lines of gnu89 on a tiny
firmware-callback libc, and labelled it plainly as a reimplementation.

- **The core here is not 430 lines.** pacme's "core" is **libpoke**: a parser, the
  **Jitter** JIT/VM, a bignum library, a garbage collector, and a
  filesystem-loaded pickle system — all assuming POSIX. Doing the honest MicroEMACS
  move for pacme means reimplementing libpoke on the firmware, which is
  reimplementing GNU poke. That is the *wrong half*, and it is enormous.
- **The license wall from `pe.pk`'s note still stands.** libpoke is **GPLv3-or-later**;
  OpenBIOS is **GPLv2-only** (no "or later"). Linking it into the frozen image is a
  conflict no amount of effort removes — the same wall the
  [modern-filesystems note](DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md)
  found for GRUB 2 and the `pe.pk` note re-found for poke. Effort aside, that door
  is closed.

**Framing B — pacme in the workbench Unix process: the right shape.** Running poke
on the host beside the firmware is not a workaround; it is the [`pe.pk`
stance](UKI_WORKBENCH_LAB_PLAN.md#4a-the-pe-oracle-gnu-pokes-pepk) made
**interactive and live**. Aggregation across a socket is not linking, so the
license wall does not apply. And — the pivot that makes this a *lab* and not a
shell alias — the interesting part is **the bridge**, not the tool: point one of
poke's IO spaces at the running OpenBIOS session and pacme becomes a structured,
acme-style inspector of the firmware's own data, graded against the Forth toolkit's
read of the same bytes.

## 2. What pacme actually is (and why B is natural, not forced)

pacme is **not a monolithic TUI**. Per [its page](https://sourceware.org/pacme/)
it is a **screen manager** (tmux today) coordinating small C programs — *pokelets*
(`plet-repl`, a byte-dump view, a tree editor, `plet-cpu-disasm` over Capstone) —
each talking to the **`poked` daemon** over a **Unix-domain socket**
(`/tmp/poked.ipc`). It is already a distributed, host-Unix, IPC-driven architecture
that *wants* to live as several processes around one daemon. Framing B runs pacme
**as designed**; Framing A would have to dismantle that architecture to fit one
freestanding address space with no OS. The tool is telling us where it belongs.

### 2b. Why its own lab, not a section of the UKI/UEFI plans (LOCKED)

The workbenches ([UKI](UKI_WORKBENCH_LAB_PLAN.md), [UEFI](UEFI_WORKBENCH_LAB_PLAN.md))
grade the **Forth toolkit** reading a **static artifact** against a foreign oracle.
This lab is a different axis: an **interactive, live** view of a **running
firmware's** memory and stores, and its deliverable is a *bridge* plus a UI, not a
new `dsl/*.fth` reader. It **consumes** those readers as the grader; it does not
grow them. Folding it into either plan would blur "read a file, once" with "watch a
machine, live." Separate lab, cross-linked. §2b LOCKED.

## 3. Feasibility (to check before writing)

- pacme + `poked` build and run on the host — **✅ upstream** (autotools + a C
  compiler; Capstone only for the disasm pokelet, already a repo dependency for the
  x86 client work).
- poke reads through **pluggable IO spaces** — **✅** the shipped backends are
  **FILE, MEMORY, NBD, STREAM, PROC** ([IO Spaces](https://www.jemarch.net/poke-2.4-manual/html_node/Stream-IO-Spaces.html)),
  so a firmware artifact is opened, not special-cased.
- **NBD support is optional** — poke must be **built against `libnbd`** for
  `nbd://` ([nbd command](https://www.jemarch.net/poke-2.4-manual/html_node/nbd-command.html)).
  **To verify first:** whether the repo's poke build has it, or whether the
  zero-dependency FILE path (below) is the floor.
- QEMU can expose a session's state — **✅**, but **asymmetrically**, and that
  asymmetry is the honest core of Spike 0:
  - **Block artifacts** (a disk image, the OVMF `VARS` pflash, an NVRAM image) are
    block devices → QEMU's built-in **NBD server** (`nbd-server-start` via QMP, or
    `qemu-nbd` for an image) exports them **live**; poke opens `nbd://…`.
  - **Guest RAM** is *not* a block device → it is **snapshot-only** without extra
    work: `pmemsave` / `dump-guest-memory` (QMP) writes a file poke opens as a
    plain **FILE** IOS. **Live** RAM needs a custom IOD onto the **gdbstub** (a
    stretch goal, named — see §5 Spike 5).

## 4. Why this and not `poke somefile.rom`

Opening a captured ROM in stock poke is already possible and already useful; this
lab is the two things that are **not** a static file open:

1. **Live.** The subject is the firmware *as it runs* — the FDT while it is being
   built, `boot_params` in the seconds before the handoff, the `VARS` store a boot
   just wrote — not a corpse captured beforehand. This is the
   [record-that-outlives-its-subject](DESIGN-NOTES-modern-filesystems-for-a-frozen-firmware.md)
   hazard turned into a feature: you watch the value *change*, you do not trust a
   cache of it.
2. **Graded.** Every pacme view of a structure is checked against the **Forth
   toolkit's** read of the same bytes (`dsl/fdt.fth`, `dsl/cbfs.fth`, `dsl/pe.fth`).
   Two independent readers on one live buffer is the foreign-oracle rule, now with a
   UI.

## 5. The spikes

> **Spike 0 runs first and is a DECISION.**

### Spike 0 — THE BRIDGE (decision)
**Question.** How does poke reach the firmware's bytes? **(A) FILE** — a QMP
`pmemsave`/`dump-guest-memory` or an on-disk image/pflash, opened as a file: zero
new dependencies, works today, but a **snapshot** (stale the instant it is read).
**(B) NBD** — QEMU exports a **block** artifact (disk / `VARS` / NVRAM) over its
NBD server; poke opens `nbd://`: **live** and low-glue, but needs poke built with
`libnbd` and only reaches **block** devices. **(C) live RAM** — a custom IOD on the
**gdbstub**: live *and* reaches memory, but it is C against poke's IOD API, the most
work. **Criterion:** start at **A** (it makes every later spike runnable), promote
**block** subjects to **B** where the payoff is watching a live write land, and name
**C** as the stretch goal for live RAM rather than pretending A's snapshot is live.
**Honesty label chosen here:** `LIVE: block-only` until C exists; `SNAPSHOT` on
every FILE-backed RAM view.

### Spike 1 — open a firmware artifact, prove the seam
Bring up `poked` on the host; open one firmware block artifact (start with the OVMF
`VARS` pflash or a captured NVRAM) through the chosen bridge; a `plet` shows raw
bytes. **Control:** the bytes poke shows at offset *n* equal `xxd` of the same image
at *n* — the seam carries data faithfully before any pickle interprets it.

### Spike 2 — dissect with pickles, graded against the Forth toolkit
Point the shipped/`dsl`-mirrored pickles at the live buffer: `elf.pk`/`pe.pk` on a
loaded image, an `fdt` pickle on the device tree, a `cbfs` pickle on a coreboot ROM.
**The grade:** each field pacme decodes equals the Forth toolkit's read of the same
bytes. **Control:** a pickle pointed one byte off, or at a truncated buffer, is
**refused/among mismatches by name** — it does not quietly render garbage that
happens to look plausible.

### Spike 3 — the acme UI: navigate structure, not hexdump
Wire the tree/dump pokelets so a click on a struct field jumps the byte view to its
span and back — the thing a flat `objdump` cannot do. **Control:** the span pacme
highlights for a field equals that field's `offset..offset+size` from the pickle;
selecting the FDT's `/chosen/bootargs` lands exactly on the cmdline bytes.

### Spike 4 — edit live, and prove the firmware sees it
On a **block** artifact over NBD (Spike 0/B), edit a value in pacme — a `VARS`
entry, an NVRAM variable — and show the **firmware reads the new value** on its next
access (the store note's *survives-and-is-observed* test, here from the editor
side). **Control:** the pre-edit firmware read and the post-edit read differ by
exactly the edit, and a malformed edit is refused **before** it is written, not
after (the "refuse before the irreversible step" rule).

### Spike 5 — live RAM (the stretch goal, named not faked)
The custom IOD onto the gdbstub (Spike 0/C): watch `boot_params` or the in-progress
FDT **change** across the handoff, live. **Until it exists, this spike is
explicitly a SNAPSHOT** taken with `dump-guest-memory` and labelled so — a layer
named as not-yet-covered rather than a snapshot dressed up as live.

## 6. What this is NOT (scope guards)

- **Not poke inside the firmware.** libpoke stays a **host** process; nothing GPLv3
  is linked into the GPLv2 image. Framing A is closed on both effort and license.
- **Not a poke or pacme fork.** Stock `poked` + stock pokelets + (at most) **one**
  bespoke IOD for Spike 5. The pickles are ours; the engine is upstream's.
- **Confined to the workbench Unix process.** The seam reaches **owned** targets
  only — this lab's own QEMU session, its own images and sockets. No reaching into
  anything but the firmware the workbench is already running. Defensive, emulated,
  own bytes — the repo's standing posture for anything that touches a live machine.
- **Not a debugger replacement.** It reads/edits *structured firmware data*; it is
  not gdb for the firmware's *code* (the [`open-firmware-debugs-itself`](examples/open-firmware-debugs-itself/README.md)
  lab owns that axis).

## 7. Routing, success signature, open questions

A host lab (no in-firmware code), so it routes as a **workbench/tooling** member in
`learning-paths.toml` beside the UKI/UEFI plans and the `open-firmware-debugs-itself`
lab; its checkpoints are host-side `plet`/`xxd`/toolkit-diff commands under
`smoke-*.sh`.

| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | the bridge chosen; `LIVE: block-only` / `SNAPSHOT` label printed | a RAM view claimed "live" while FILE-backed is caught |
| 1 | poke's bytes at *n* == `xxd` at *n* | a seam that drops/rewrites a byte is caught |
| 2 | each pickle field == the Forth toolkit's read | a one-byte-off / truncated pickle is refused by name |
| 3 | the highlighted span == the field's `offset..size` | a field whose span != its bytes is a finding |
| 4 | the firmware reads the post-edit value; edit == the delta | a malformed edit refused **before** write |
| 5 | live RAM changes watched across handoff — **or** `SNAPSHOT`, named | a snapshot dressed as live is caught |

**Open questions.** (1) Is the repo's poke built with `libnbd` (Spike 0/B), or is
FILE the floor until it is rebuilt? (2) Does QEMU's NBD server reach the OVMF
`VARS` pflash directly, or must it be exported as a drive first? (3) Is the Spike 5
IOD worth building here, or cited to a future lab once the FILE/NBD tiers have
proven the UI? Likely **named here, built later**.
