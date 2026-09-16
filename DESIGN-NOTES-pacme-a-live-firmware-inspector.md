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

> **Re-measured 2026-09-16, against the host's packages, QEMU 8.2.2's QMP, upstream
> pacme's page, and `libpoke.h`.** The framing decision holds. Four facts sharpen the
> spikes: **(1) there is no "repo's poke build"** — poke is not installed, and the
> question of whether it has NBD is answered by the distro: Ubuntu's `poke 4.0+dfsg-1`
> ships `/usr/bin/poke`, **`/usr/bin/poked`**, and **`/usr/share/poke/pickles/pe.pk`**, and
> its `libpoke1` depends on **`libnbd0`** — so Spike 0's option (B) is on the floor with (A),
> one `apt install poke` away, no source build; **(2) pacme itself is not packaged** —
> source from sourceware git, autotools, and `tmux` (present); **(3) Capstone is *not* "already
> a repo dependency"** — the two READMEs that say "capstone" mean the *metaphor* (the
> x86 revival as the arc's capstone), no `libcapstone` is installed, and it is a new optional
> dependency for one pokelet only; **(4) `libpoke.h` really has `pk_register_iod`** for
> Spike 5's foreign IO device — with the documented limit of **one** registered device,
> which is exactly the note's "at most one bespoke IOD". QEMU's QMP has every command the
> bridge needs (`nbd-server-start`, `nbd-server-add`, `block-export-add`, `pmemsave`,
> `dump-guest-memory` — measured on 8.2.2). One hazard named for Spike 4: a **writable**
> export of a node a guest device holds meets QEMU's block-permission system, which is
> to be measured before "edit live" is promised. §3 carries the rows.

## 1. Two framings, and why only one survives

**Framing A — pacme as a firmware client (no OS underneath): a no, twice over.**

The MicroEMACS lab is the honest precedent, so read what it actually did. It did
**not** port Daniel Lawrence's uEmacs verbatim; it says so in as many words
([`POC-6-MICROEMACS.md`](examples/openbios-clib-hello-to-emacs/POC-6-MICROEMACS.md)) — a
freestanding client has *no files, no termios, no signals, no termcap, no shell*,
so porting that tree "isn't a mechanical port, it's rewriting its entire bottom
half." It **reimplemented the editor core** in ~430 lines of gnu89 (`clib/emacs.c`
is 398 today) on a tiny firmware-callback libc, and labelled it plainly as a
reimplementation.

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

## 3. Feasibility (measured 2026-09-16)

- **poke and `poked` — one `apt install poke` away, not a source build.** poke is
  **not installed** on the host today (nor invoked by any script — the `pe.pk`
  "host oracle" is adopted in plans, not yet in code). Ubuntu noble's
  `poke 4.0+dfsg-1` ships `/usr/bin/poke`, **`/usr/bin/poked`**, `pokefmt`, and
  **`/usr/share/poke/pickles/pe.pk`** (so the UKI plan's "does the package ship
  `pe.pk`" is answered: yes). Its `libpoke1` depends on `libgc1` (the GC the note
  names) **and `libnbd0`** — the distro build has NBD.
- **pacme is not packaged.** It is source from
  [sourceware.org/pacme](https://sourceware.org/pacme/) — a *screen manager* (tmux,
  present on the host) over small C *pokelets* (`plet-repl`, a byte-dump view, a
  tree editor, `plet-cpu-disasm`) talking to `poked` on `/tmp/poked.ipc`, as the page
  says. Autotools + a C compiler.
- **Capstone: a correction.** The first draft said Capstone was "already a repo
  dependency for the x86 client work". It is not: the two READMEs that contain the
  word use it as the *metaphor* — "the x86 revival is the arc's **capstone**" — and no
  `libcapstone` package is installed. Capstone is a **new, optional** dependency, needed
  by `plet-cpu-disasm` only; every other pokelet runs without it.
- poke reads through **pluggable IO spaces** — **✅** the shipped backends are
  **FILE, MEMORY, NBD, STREAM, PROC** ([IO Spaces](https://www.jemarch.net/poke-2.4-manual/html_node/Stream-IO-Spaces.html);
  the [4.0 manual](https://www.jemarch.net/poke-4.0-manual/html_node/IO-Spaces.html) is
  the one that matches the installable version), so a firmware artifact is opened,
  not special-cased.
- ~~**NBD support is optional — to verify first**~~ **Answered:** `libpoke1 → libnbd0`,
  so `nbd://` ([nbd command](https://www.jemarch.net/poke-2.4-manual/html_node/nbd-command.html))
  works in the distro build. Spike 0's (A) and (B) are **both on the floor**; the
  question left is only what to point them at.
- QEMU can expose a session's state — **✅ measured on QEMU 8.2.2** (`query-commands`
  over QMP lists `nbd-server-start`, `nbd-server-add`, `block-export-add`, `pmemsave`,
  `dump-guest-memory`; `qemu-nbd 8.2.2` is on the host), and **asymmetrically**, which
  is the honest core of Spike 0:
  - **Block artifacts** (a disk image, the OVMF `VARS` pflash, the OpenBIOS NVRAM
    pflash the `persist-flash` tracks write) are block **nodes** in the running QEMU →
    `block-export-add type=nbd node-name=…` exports the very node the guest device
    holds; poke opens `nbd://…` and sees the bytes the guest just wrote. This answers
    §7's open question (2): the `VARS` pflash *is* a `-drive`, so it needs no
    re-export — it has a node name already.
  - **One hazard, named for Spike 4:** exporting that node **writable** while the
    guest's pflash device holds it meets QEMU's block-permission system (a device
    that does not share `BLK_PERM_WRITE` refuses a second writer). Whether an
    in-use pflash node accepts a writable export, needs the guest paused, or needs
    the edit routed through the guest instead is **UNMEASURED** — Spike 0 measures
    it before Spike 4 promises "edit live".
  - **Guest RAM** is *not* a block node → **snapshot-only** without extra work:
    `pmemsave` / `dump-guest-memory` (QMP — HMP `pmemsave` parses the filename as an
    expression, a trap this repo has already paid for) writes a file poke opens as
    a plain **FILE** IOS. **Live** RAM needs a custom IOD onto the **gdbstub**
    (Spike 5) — and `libpoke.h` **has the hook**: `struct pk_iod_if` +
    `pk_register_iod()`, documented as supporting **exactly one** registered foreign
    IO device, which is the note's "at most one bespoke IOD" stated by the library
    rather than by us.

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

**What is already known (2026-09-16), so the decision starts further along:** (A) and
(B) are *both* on the floor — the distro's poke has NBD (`libpoke1 → libnbd0`), so
there is no "FILE until rebuilt" phase. The decision Spike 0 still owns is narrower and
sharper: **can the block node a running guest device holds be exported writable?**
Read-only NBD of a live node is the documented case; a writable export contends with
the pflash device's write permission, and the outcome (accepted / needs the guest
paused / refused → edit through the guest) is the fact Spike 4 stands on. Measure it
with the OpenBIOS NVRAM pflash the `persist-flash` track already boots — a store the
firmware provably reads back after a power cycle — before the OVMF `VARS`.

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
side). **Gated on Spike 0's writable-export measurement** (§3): if QEMU refuses a
second writer on the in-use node, this spike's honest shape is *pause the guest →
export writable → edit → resume*, or *edit through the guest's own store words*, and
the label says which — never a silent fall-back to editing the file behind QEMU's
back, which would be the record-outlives-its-subject hazard from the editor side.
**Control:** the pre-edit firmware read and the post-edit read differ by
exactly the edit, and a malformed edit is refused **before** it is written, not
after (the "refuse before the irreversible step" rule).

### Spike 5 — live RAM (the stretch goal, named not faked)
The custom IOD onto the gdbstub (Spike 0/C): watch `boot_params` or the in-progress
FDT **change** across the handoff, live. **The hook exists** (measured 2026-09-16 in
`libpoke.h`): `struct pk_iod_if` — open/close/pread/pwrite/size over a handler
string — registered with `pk_register_iod()`, which the header documents as
supporting **one** foreign IO device at a time; a `gdb://host:port` handler speaking
the remote protocol's `m`/`M` packets to QEMU's `-gdb` stub is that one device. **Until
it exists, this spike is explicitly a SNAPSHOT** taken with `dump-guest-memory` and
labelled so — a layer named as not-yet-covered rather than a snapshot dressed up as
live.

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

**Open questions.** (1) ~~Is the repo's poke built with `libnbd`?~~ **Answered
2026-09-16:** there is no repo build; the distro's `poke 4.0` has NBD (`libpoke1 →
libnbd0`), `poked`, and `pe.pk` — `apt install poke` is the whole install. (2) ~~Does
QEMU's NBD server reach the OVMF `VARS` pflash directly?~~ **Answered by mechanism:**
the pflash is a `-drive`, hence a block node with a name, and `block-export-add`
(measured present on 8.2.2) exports a node directly — read-only is the documented
case. **New (2b):** does a *writable* export of a node the guest's pflash device holds
get accepted, need the guest paused, or get refused? UNMEASURED; Spike 0 measures it
and Spike 4 is shaped by the answer. (3) Is the Spike 5 IOD worth building here, or
cited to a future lab once the FILE/NBD tiers have proven the UI? The API is real and
limited to one device (`pk_register_iod`), so the cost is one C file; still likely
**named here, built later**. (4) **New:** pacme is unpackaged and Capstone is a new
optional dependency (not, as the first draft said, an existing repo one) — the lab's
`deps.sh` states both.
