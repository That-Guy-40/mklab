# PLAN — `examples/open-firmware-debugs-itself/`: a Forth DSL for boot forensics, memory, and FCode reverse engineering

> **Status: pre-assembly.** Spikes 0, 0c, 1, 2, 2b and 3 are GREEN — results are
> recorded inline below with the real transcripts. The vocabularies proven so far
> live in [`spikes/`](spikes/); they become the lab's `dsl/` at assembly.
>
> This directory deliberately has **no `README.md` yet**: `tools/paths.py` counts
> an `examples/` subdir as a routable lab unit only once it has one, and routing
> a lab whose checkpoint nobody can run yet would be dishonest. The 00-INDEX row
> and the `learning-paths.toml` step land together with the README, the smokes,
> and the POC write-ups.

## Context — why

Follow-on to [`examples/open-firmware-forth-to-boot/`](../open-firmware-forth-to-boot/README.md)
(the OFW lab). That lab proved the firmware *answers back* and fixed its era-gaps
live at the `ok` prompt — but it used maybe 5% of what the firmware actually
carries, and every fix was ad hoc: typed once, never named, never reusable.

A source-tree audit of `~/ofw-lab/openfirmware` (frozen Dec 2015) found a
**complete reverse-engineering workbench already inside the ROM**, untouched by
the parent lab:

| Word / file | Source | What it is |
|---|---|---|
| `see` | `forth/lib/decomp.fth` | **decompiler** — recovers Forth source for any dictionary word |
| `debug` · `stepping` · `resume` | `forth/lib/debug.fth` | **source-level single-step debugger** on bare metal |
| `set-breakpoint` · `show-breakpoints` · `repair-breakpoint` | `forth/lib/breakpt.fth` (369 ln) | real breakpoints |
| `ctrace` | `cpu/x86/ctrace.fth` (145 ln) | **machine-code backtrace** with frame/arg decoding, per-CPU |
| `.calls` | `forth/lib/callfind.fth` | dictionary **cross-reference** — "who calls this word?" |
| `map?` | `cpu/x86/mmu.fth` | **MMU page-table walker** |
| `random-test` | `forth/lib/lfsr-memtest.fth` | LFSR RAM tester |
| `config-b@` `config-l@` `config-l!` … | `dev/pci/` | raw **PCI config-space** access |
| `detokenize` · `load-fcode` · `byte-load` | `ofw/fcode/detokeni.fth`, `byteload.fth` | **FCode detokenizer** (bytecode → Forth) + bytecode loader |
| (FCode debugger) | `ofw/fcode/debugfc.fth` | step FCode *as it is being evaluated* |

The parent lab's RUNBOOK opens `words`, `dev`, `.properties`, `dump`. Everything
above is closed. **This lab opens the toolbox and builds a language on top of it.**

## Thesis

> In Forth, a DSL is not a parser — it is a **vocabulary**. You do not write a
> grammar; you define words, and the words *are* the language.

The parent lab already makes ad-hoc DSL moves (RUNBOOK §4: `: my-dma … ;
' my-dma to allocate-dma`) without ever naming them as such. This lab writes the
language down: three composable vocabularies, shipped as `.fth` source, `fload`ed
from staged media, each earning a headless verdict.

The second lesson, and the reason the lab is worth building at all: **the machine
under investigation is also the investigation tool.** No agent, no OS, no JTAG,
no external debugger — `see` decompiles the firmware you are standing in, and
`detokenize` recovers source for driver bytecode that arrived on a card.

## Decisions locked (user-confirmed)

- **New sibling lab**, not an in-place edit of the parent — precedent is
  [`openbios-clib-hello-to-emacs/`](../openbios-clib-hello-to-emacs/README.md),
  which reuses the family's build artifacts and cross-links rather than doubling
  the parent's size and blurring its single thesis.
- **All three vocabularies**, with the risky one (**C**) spiked **first**.
- Name candidate: `open-firmware-debugs-itself` (settle at assembly).

## Delivery mechanism (forced, not chosen)

The DSL arrives as **`.fth` files loaded from staged media**, invoked by one
short word. This is not a style preference — CLAUDE.md's serial doctrine
forbids the alternative:

> *"when diagnosing firmware over a lossy console, don't type long Forth
> colon-definitions at the prompt — compile the probe in and type one short word
> to invoke it."*

A multi-line colon definition typed at a flow-control-free serial console gets
silently mangled. `fload` sidesteps it entirely, and is also the historically
correct mechanism (`fload`, `dropin-fs`, `mkdropin.fth` are all in-tree).

Staging reuses the parent lab's proven idioms: FAT16 via `mkfs.vfat` + `mcopy`
(coreboot flavor, legacy ISA-IDE path) and ISO9660 via `genisoimage` (emu
flavor, ATAPI path) — the two flavors read different media, a parent-lab finding
this lab inherits rather than re-discovers.

Driving: `tools/drive-serial-repl.py --echo-gate` throughout. Self-clocking on
echo, no per-byte delay guessing, exit 125 on a dropped byte instead of a
silently mangled line.

## The three vocabularies

### A · `ofdiag` — boot forensics ("strace for firmware")

Wrap the firmware's own boot path using its sanctioned patch points: `patch`,
`defer`/`to`, and `debug`. Instrument `open`, `read`, `load`, `$call-method`.

Words to define:

| word | does |
|---|---|
| `trace-boot` | install tracers on the boot path; every step emits one structured line |
| `why-no-boot` | replay `boot-device` resolution and report the **exact failing step** |
| `boot-timeline` | emit `#T <ms> <phase> <detail>` marker lines for host-side rendering |
| `untrace` | restore every patched word (a tracer that cannot be removed is a bug) |

**What makes it a lab and not a toy: a fault-injection matrix.** Break the boot
path five distinct ways and require that each fault produce its own *specific*
one-line diagnosis — not a generic "boot failed". Candidate faults: a
`boot-device` naming a nonexistent node; a valid node whose `open` method fails;
a device that opens but whose `read` returns short; a present file that is not a
recognized executable; an empty `boot-device`. Each gets a `REGRESSION:`-guarded
assertion, because "the diagnosis regressed to generic" is exactly the failure
mode a diagnostic DSL rots into.

**Repo synergy:** the `#T` marker lines are milestone lines. `tools/control-pane`
already renders milestone streams — pointing it at firmware boot phases costs a
`milestones.toml` profile and gets a live boot timeline for free.

Risk: **LOW** — every primitive confirmed present in-tree.

### B · `ofscope` — memory and device exploration

Layer structure over the raw primitives (`dump`, `c@`/`l@`, `map?`,
`config-l@`, `.properties`):

| word | does |
|---|---|
| `struct:` … | declare a record layout once, then decode it at any address |
| `find-bytes` | signature scan over a region (find `55 AA`, `7F E L F`, an FCode header) |
| `region-diff` | snapshot RAM → do a thing → diff, and show only what moved |
| `pci-map` | walk bus/dev/fn, decode vendor / class / BARs into a table |
| `mem-map` | render `available` + `reg` into a visual memory map |
| `.pages` | `map?`-backed page-table view (which virtual maps where, with flags) |

**The honesty hook — cross-check against outside ground truth.** Whatever
`pci-map` reports from *inside* the machine must match QEMU's own view from
*outside* via QMP `query-pci`. Same for `mem-map` vs. the `-m` size and the e820
the parent lab fought. The lab either demonstrates the in-firmware tool agrees
with the emulator, or it says plainly where it does not. A memory explorer that
is never checked against ground truth is a very confident random-number
generator.

Risk: **LOW–MEDIUM** — `map?` behavior in physical mode (the parent lab runs OFW
in physical mode; `virtual-mode` triple-faults the 64-bit entry) needs
confirming; `.pages` may be a documented no-op on this track, which is itself a
fine result to write down.

### C · `fcode-forensics` — the option-ROM round trip (capstone, spiked FIRST)

The full loop:

```text
driver.fth ──toke──► FCode bytecode ──wrap──► PCI expansion ROM (code type 0x01)
     ▲                                              │
     │                                    qemu -device e1000,romfile=fake.rom
     │                                              ▼
  diff  ◄──detokenize (in-firmware)◄── OFW probes the card, evaluates the FCode,
                                        creates a live device node
```

Source → bytecode → **executed by the firmware** → bytecode recovered → source.
This is the actual historical mechanism that made Open Firmware
architecture-independent (a 1990s option card carrying its own ISA-neutral
driver), run as a forensics exercise. `debugfc.fth` additionally allows
single-stepping the FCode *while the firmware evaluates it*.

`toke` comes from `openbios/fcode-utils` — **already built** at
`~/openbios-lab/fcode-utils` by the rival lab. No new toolchain fetch.

**The unknown, stated plainly:** a source scan of `dev/pci/` found no obvious
expansion-ROM FCode evaluation path — `probe-self ( arg$ reg$ fcode$ -- )` in
`dev/pci/isa.fth` takes FCode as a *string*, which is a different mechanism.
Whether OFW-x86's PCI probe finds, validates (PCI Data Structure code type
`0x01`), and byte-loads a ROM image under QEMU 8.2 is genuinely undetermined.
Hence: **spike it before anything else is built.**

**Fallback ladder** (each rung still delivers a real round trip):
1. ROM on a PCI device, auto-probed — the full story.
2. ROM present but probe declines → `byte-load` the ROM image by hand from the
   prompt after locating it in the device's ROM BAR. Same bytecode, same
   detokenize, manual trigger.
3. No ROM path at all → `byte-load` the tokenized FCode straight off staged
   media (`ofw/fcode/byteload.fth` is in-tree). Loses the card, keeps
   tokenize → execute → detokenize → diff.

A clean documented negative on rung 1 with rung 2 or 3 green is an acceptable
outcome and a *better* teaching artifact than pretending it worked.

Risk: **MEDIUM–HIGH**, isolated to this vocabulary by construction.

## Phased spikes (out-of-tree, each → a `POC-N.md` with real transcripts)

| # | Spike | De-risks | Gate |
|---|---|---|---|
| **0** | **Word inventory on the running firmware.** `fload` a trivial file; confirm `see`, `debug`, `.calls`, `map?`, `config-l@`, `detokenize` are present *and callable* in **both** flavors (emu, coreboot). Dump `words` to a log and diff the two flavors. | the entire premise — a word in the source tree is not a word in *this build's* dictionary | any missing word is re-scoped or dropped **before** it reaches the DSL |
| **1** | **FCode option ROM** (capstone, early). `toke` a 10-line driver, wrap the PCI ROM header, attach via `romfile=`, observe. Walk the fallback ladder until a rung is green. | the one medium-high unknown | which rung the capstone stands on |
| **2** | **`ofdiag` core + fault injection.** Tracers on `open`/`read`/`load`; the five-fault matrix; `untrace` restores cleanly. | patch-point stability; whether tracing perturbs the boot it observes | the diagnosis lines become the smoke's expect anchors |
| **3** | **`ofscope` + ground truth.** `pci-map` vs. QMP `query-pci`; `mem-map` vs. `-m`; `region-diff` across a known-good `load`. | agreement between inside and outside views | any disagreement is documented, not hidden |
| **4** | **`see`-driven self-decompilation tour.** Decompile the firmware's own `boot`, `open`, `$call-method`; `.calls` the call graph. | nothing technical — this is the lab's *narrative* spine, and it needs real output to write against | RUNBOOK material |

Spike 0 runs first regardless. Spike 1 second (the scope-determining unknown).
2–4 are low-risk and can proceed in any order once 0 is green.

## Spike 0 — RESULT: **GREEN**, with two re-scopes (run 2026-07-25)

Method: `' <word> .` per candidate — tick *looks up* without *executing* (we must
not actually fire `debug` or `random-test`) — syncing on the `ok` prompt, which
returns either way, so a missing word cannot stall the drive. Verdict parsed from
the log afterward rather than asserted in the expect script. This also avoids
`words`, whose built-in pager would hang a scripted drive.
Script: `spike0-word-inventory.sh`; logs `~/ofw-lab/spike0-{emu,coreboot}.log`.

**18 of 23 present — and the two flavors are byte-identical in outcome.**

| Vocabulary | Verdict |
|---|---|
| **A · `ofdiag`** | **100% green.** `see` `patch` `debug` `resume` `stepping` `ctrace` `showstack` `.calls` all live. Zero blockers on the highest-value vocabulary. |
| **B · `ofscope`** | Green except **`map?` absent** → `.pages` drops from a working view to *documentation of why*. Anticipated: the lab runs physical-mode (the parent's `virtual-mode` triple-faults), so a page-table walker was always semi-moot. `config-l@` `config-b@` `mem-claim` `random-test` `dump` all live. |
| **C · `fcode-forensics`** | Split: **`byte-load` present** (the firmware CAN execute FCode bytecode) but **`detokenize` and `load-fcode` absent** from the ROM. |
| breakpoints (A stretch) | `set-breakpoint`/`show-breakpoints` absent. Non-fatal: `debug`/`stepping`/`resume` carry source-level stepping without them. |

### Re-scope 1 — the flavor-divergence risk is retired

Both flavors returned the *same* 18/23. The parent lab's emu-vs-coreboot split is
a **media/disk-path** divergence, not a dictionary one, so the DSL source is
flavor-portable and only the staging path forks. Budget one vocabulary, two
stagings — not two of each.

### Re-scope 2 — the capstone survives, via the delivery mechanism itself

`fload` is present **and works from media** (spike 0b, same session): an ISO
staged with a `.fth` file loaded silently, the defined word ran, and — the
thesis in miniature — `see` decompiled it straight back to source:

```text
ok fload /pci/pci-ide@1,1/ide@1/cdrom@0:\test.fth
ok dsl-live
<<DSL-VOCAB-LIVE>>
ok two-plus-two
4
ok see two-plus-two
: two-plus-two
   2 2 + .
;
```

So the ROM's missing words are **recoverable at runtime by the same mechanism the
DSL already uses to ship itself.** The lab's vehicle carries its own missing tools.

**But not by a straight `fload` of the upstream file.** `ofw/fcode/detokeni.fth`
lines 256–258 `fload` three siblings (`primlist.fth`, `sysprims.fth`,
`regcodes.fth`) through `${BP}` — a **build-path variable that does not exist at
the prompt**. Recovering the detokenizer therefore needs a **flatten step**:
concatenate the four sources in dependency order, strip the `${BP}` directives,
ship one loadable vocabulary. Tractable build work, not a blocker — and it
becomes `build-detok-vocab.sh` in the assembled lab.

### New gotchas for the lab's tooling (both cost real debugging time)

- **`see` colorizes its output with ANSI SGR sequences.** The transcript above is
  really `\e[35m: \e[34mtwo-plus-two \e[m`. A naive `--expect ": two-plus-two"`
  **fails** — the escape sequence sits between the colon and the name. Every
  expect anchor against decompiler output must match a *fragment that no escape
  splits*, or the smoke must strip SGR first.
- **`ok` is a substring hazard.** The inventory parser split replies on the bare
  string `ok` and truncated `detokenize`'s reply to `det` — right verdict, wrong
  reason, pure luck. Anchor to the line-leading prompt (`[\r\n]+ok\b`), never the
  bare token. Any word containing "ok" (`detokenize`, `lookup`, `book`) trips it.

## Spike 0c — "the ROM is a subset: what can media restore?" (**added**, static analysis done)

Generalizes re-scope 2 from "flatten the detokenizer" into a systematic question,
and turns the ROM's omissions into a teaching artifact rather than a list of
losses. **The ROM is not the toolbox — the source tree is. `fload` is the bridge.**

Static analysis of every missing word's source (line-anchored `^code`/`^label` for
*real* assembler definitions, vs. `${BP}` build-path floads):

| source | `code`/`label` | `${BP}` floads | tier |
|---|---|---|---|
| `forth/lib/breakpt.fth` (369 ln) | **0** | **0** | **1 — direct fload** |
| `forth/lib/callfind.fth` | 0 | 0 | 1 (already in ROM) |
| `ofw/fcode/detokeni.fth` | 0 | 5 | **2 — flatten, then fload** |
| `ofw/fcode/{primlist,sysprims,regcodes}.fth` | 0 | 0 | 2 (clean deps) |
| `cpu/x86/mmu.fth` (`map?`) | **2** | 1 | **3 — needs the assembler** |
| `forth/lib/lfsr-memtest.fth` | 3 | 0 | 3 (moot: `random-test` already in ROM) |

**The recovery tiers** (the taxonomy the lab teaches):

1. **Pure high-level Forth** → floads as-is. *Proven* by spike 0b.
2. **`${BP}`-chained source** → concatenate in dependency order, strip the
   directives, ship one vocabulary (`build-detok-vocab.sh`).
3. **Contains `code`/`label`** → needs the **Forth assembler** in the dictionary.
   The assembler is a build-time tool and is probably not in a 512 KiB ROM —
   **runtime probe required** (`' code .`, `' assembler .`), folded into the next
   available boot rather than spending one on it.
4. **Loadable but semantically inert on this track** — `map?` walks page tables,
   and this lab runs **physical-mode** (the parent's `virtual-mode` triple-faults
   the 64-bit entry), so even a successful load would report "Not mapped" for
   everything. Honest verdict: not worth recovering.

**Net effect: ~20 of 23 recoverable, and the one true loss (`map?`) is the one
that was already semantically moot.** Breakpoints — written off as a dropped
stretch goal an hour ago — come back to vocabulary A as tier 1.

### Spike 0c — RESULT: **22 of 23 available** (run 2026-07-25)

**The assembler is in the ROM.** `code` `assembler` `end-code` `label` all
resolve — so tier 3 was never a wall. OFW ships its own assembler, entirely in
character for a firmware that is also a development environment.

**And "missing" was mostly a search-order artifact.** `only forth also hidden
also` reveals what a root-prompt tick cannot see:

| originally "missing" | truth |
|---|---|
| `set-breakpoint`, `show-breakpoints` | **present in the `hidden` vocabulary** — no fload needed at all |
| `load-fcode` | present in the **PCI package scope** (via `dev /pci`) |
| `detokenize` | genuinely absent → **recovered** by the tier-2 flatten, `' detokenize .` → `1c991c4` |
| `map?` | genuinely absent, not in `hidden` either; recoverable in principle (the assembler is right there) but **inert in physical mode** → declined on purpose |

⚠️ **Methodology correction:** Spike 0's tick-probe **under-reports**, because the
OFW dictionary is not flat. Any inventory the lab ships must widen the search
order first and note that package-scoped words (`load-fcode`) need `dev <node>`
instead. Three of five "missing" words were false negatives.

### Two more delivery gotchas (both cost a boot)

- **OFW's ISO9660 reader is 8.3-only — no Rock Ridge long names.** `fload
  …\breakpt-flat.fth` failed with "cannot be opened"; `dir <cd>:\` showed the
  firmware sees `BPT.FTH` / `DETOK.FTH`. Every staged vocabulary file must use an
  8.3 name. (The parent lab's `uroot.img` / `vmlinuz` are 8.3 — it never hit this.)
- **`isn't unique` is a warning, not an error.** A fload that redefines existing
  words spews one line per word and still succeeds. A smoke that treats stderr
  chatter as failure will report a false negative.

### The detokenizer flatten is real work, not a concat

`detokeni.fth` needs **five** files spliced in dependency order: `common.fth` at
line 53, then the body, then `primlist`/`sysprims`/`regcodes` at lines 256–258,
then the tail. Naive concatenation gives undefined words. `build-detok-vocab.sh`
implements the splice; verified by `' detokenize .` resolving after fload.

### Gate decision

Vocabulary **A proceeds unchanged**. **B proceeds** with `.pages` demoted to a
documented negative. **C proceeds** with a flatten step prepended, and its real
unknown — whether the PCI expansion-ROM probe path exists — is untouched by this
spike and remains Spike 1's job.

## Spike 1 — RESULT: **RUNG 1 GREEN** (run 2026-07-25)

The scope-determining unknown is resolved in the best possible direction: **the
PCI expansion-ROM FCode path exists, is compiled into the emu flavor, and works.**

Found statically before spending a boot: `dev/pcibus.fth` carries the whole path
(`fcode-image?` 616, `locate-fcode` 657, `expansion-rom` 714, `find-fcode?` 756,
`load-fcode` 801 → `1 byte-load`, called from `populate-device-node` 964), and
`cpu/x86/pc/emu/devices.fth:10` floads it into the ROM.

**The verified round trip:**

```text
spike1-card.fth ──toke──► 61 B FCode ──wrap──► 2 KB PCI ROM (code type 0x01)
                                                      │
                                          qemu -device e1000,romfile=…
                                                      ▼
                    OFW probes → validates PCIR → byte-loads the bytecode
                                                      ▼
     ok dev /pci ls
     95884 spike1-card                    ← the CARD named its own node
     ok dev /pci/spike1-card .properties
     spike1-marker    SPIKE1-FCODE-RAN    ← property created by the bytecode
     name             spike1-card
     fcode-rom-offset 00000000            ← the FIRMWARE's own success marker
                                                      ▼
                    detok ──► " spike1-card" device-name … checksum (Ok)
```

### The killer gotcha: **guest RAM size decides whether this works at all**

First attempt (`-m 512`) silently produced `ethernet@4` — no FCode, no error, no
diagnostic. Hand-walking `find-fcode?`'s checks at the prompt found it: OFW's PCI
allocator assigns the ROM BAR at **`0x10020000`** (256 MB + 128 KB), but with
`-m 512` RAM spans `0`–`0x20000000`, so **the BAR lands inside DRAM** — reads
return zeros and the `0xaa55` signature check fails. `-m 256` puts the BAR above
RAM top and everything works.

⚠️ **The parent lab's showcase runs `-m 1024`.** This lab's FCode track therefore
*must* pin `-m 256` and say why, or it will fail exactly as mysteriously for the
next person. This is the same family of era-artifact as the parent's
`memmap=1023M@1M` fight — a 2015 demo firmware carrying small-machine assumptions.

### Format traps (both would fail silently)

- **ROM header offset `0x02` is the OFFSET TO THE FCODE IMAGE**, not the image
  size in 512-byte blocks as on an x86 option ROM. OFW adds it to the ROM base.
  Put a size there and the firmware jumps into garbage.
- **Vendor/device `0xffff` in the PCIR structure is "always accept"** in
  `fcode-image?`. One ROM artifact therefore rides any QEMU PCI device with no
  ID matching — a real simplification for the lab's build script.
- The command register reads `0` after probe (`populate-device-node` ends with
  `0 4 my-w!`, "disables all card response"), so anyone poking config space at
  the prompt must re-enable decode first.

### Corrections to Spike 0

`load-fcode` is **not absent** — it is defined inside the PCI package's scope, so
ticking it at the root prompt failed. Exactly the "present but outside the search
order" caveat Spike 0 flagged, now confirmed. `detokenize` *is* genuinely absent
(`detokeni.fth` is floaded by no emu build file), so tier 2's flatten still stands.

### Unplanned validation of vocabulary B

The bug was diagnosed **using the capability vocabulary B proposes** — `dev /pci`
+ `config-l@` to read the ROM BAR, `config-l!` to enable decode, `dump` to read
the mapped window — before vocabulary B exists. The explorer earned its place by
being the tool that debugged the capstone. That story belongs in the README.

### Scope decision (the gate the plan reserved)

Rung 1 landing does **not** trigger the split into a separate lab. The mechanism
proved out in one session and reduces to one build script, one FCode driver, and
one smoke; splitting would duplicate the build box and the staging path for
little gain. **C stays the capstone**, and earns its own POC doc.

Host tools `toke`, `detok`, `romheaders` all build clean from
`~/openbios-lab/fcode-utils` (`make`, no fetch). `romheaders` independently
validates a built ROM **before** booting it — a cheap host-side gate worth
keeping in `build-fcode-rom.sh`.

## Spike 2 — RESULT: **diagnosis half GREEN**, tracer half still open (run 2026-07-25)

`ofdiag.fth` floads off media and discriminates four fault classes correctly:

| input | diagnosis |
|---|---|
| `nosuchalias` | `OFDIAG-1: not a path, and no such devalias` |
| `/pci/nosuch@9` | `OFDIAG-2: no such node in the device tree` |
| `/pci/ethernet` | `OFDIAG-3: node exists but its open method FAILED` |
| `…/cdrom@0` | `OFDIAG-0: opens OK - failure is later (load/execute)` |
| `disk` | expands to `/pci-ide/ide@0/disk@0` → `OFDIAG-2` |

No `catch` needed anywhere: `expand-alias` returns a flag, `find-package` returns
a flag, `open-dev` returns 0 rather than throwing. The firmware hands over a
clean three-way discriminator for free.

**Two rows earn their keep immediately.** `/pci/ethernet` is the exact device the
boot banner dies on ("Can't open boot device"); `ofdiag` upgrades that to *the
node exists, its open method failed* — a different bug from "no such device".
And the `disk` row **independently reproduces the parent lab's POC-2 disk-path
finding** (the 2015 ATA alias points somewhere QEMU 8.2 doesn't have) as a
one-line diagnosis. That is the single strongest argument for the whole lab: a
finding that cost the sister lab real debugging falls out of a vocabulary loaded
off a CD.

### Two bugs found — both by the fault matrix, both teaching material

1. **`expand-alias`'s flag means "an alias WAS expanded", not "success".** A full
   path is legitimately not an alias and returns `false` with the string
   untouched. v0 read a status flag as an error flag → **every** input reported
   `OFDIAG-1`. The matrix caught it on its first run; a single-case smoke would
   have passed happily. This is the plan's "a diagnostic DSL rots into generic"
   failure mode, caught by the guard designed for it.
2. **A stack-effect comment outside the parens is live code.**
   `( dev$ path$ )   r: alias-expanded?` compiled `r:` and `alias-expanded?` as
   words → "Undefined word encountered" at runtime. In-tree style keeps the
   annotation *inside*: `( r: size virt offset )`. Same family as the house rule
   about sample data executing as a live command.

## Spike 2b — RESULT: **tracer GREEN**, no call-site patching required

**The firmware ships its own tracepoints.** `bootparm.fth` declares
`defer ?show-device ( adr len -- adr len )` — a pass-through hook receiving the
device path immediately before `open-dev` (line 109) *and* while iterating the
boot-device list (145) — plus `load-started` / `load-done` bracketing the load
(119/127), all inside `(boot-read)`. So `trace-boot` is three `to` assignments;
`patch` (which rewrites a compiled call site) is **not needed**. This is the
parent lab's `' my-dma to allocate-dma` trick, systematized.

Verified, with the negative control:

```text
ok trace-boot
OFDIAG: tracing ON
ok load …:\ofdiag.fth
#T open /pci/pci-ide@1,1/ide@1/cdrom@0:\ofdiag.fth
#T load-begin
#T load-end
ok untrace
OFDIAG: tracing OFF
ok load …:\ofdiag.fth            ← same command, ZERO #T lines
```

- **`untrace` restores cleanly** — proven by re-running the traced operation and
  getting silence, not asserted. A tracer you cannot remove is a bug.
- **Tracing did not perturb the operation** — the load still succeeded, partly
  retiring the "tracers change the boot they observe" risk for this path.
- The `#T` lines are real milestone output, so the `tools/control-pane` firmware
  boot-timeline profile is now a concrete deliverable rather than speculation.

**Honest caveat:** the trace was driven through an interactive `load`, not a full
autoboot. The hooks are the same ones `boot` uses (`(boot-read)` is on the boot
path; `?show-device` fires during boot-device iteration), so the risk is low —
but a full `boot` trace remains **unproven** and belongs in the lab's showcase.

### Still open for vocabulary A

`why-no-boot` v2: `boot-device` defaults to the **list** `"disk net"`, so it must
tokenize and diagnose each entry. `default-device` (bootparm.fth:139) shows the
idiom — `bl left-parse-string` in a loop.

## Spike 3 — RESULT: **FULL AGREEMENT** with QMP ground truth (run 2026-07-25)

`ofscope.fth`'s `pci-map` walks config space (`dev<<11 | fn<<8 | reg`) and emits
one machine-readable `#P` line per function; the host diffs those against
`query-pci` **on the same running VM**:

```text
  dev=0 fn=0  id=12378086 class=0x0600   MATCH
  dev=1 fn=0  id=70008086 class=0x0601   MATCH
  dev=1 fn=1  id=70108086 class=0x0101   MATCH
  dev=1 fn=3  id=71138086 class=0x0680   MATCH
  dev=2 fn=0  id=11111234 class=0x0300   MATCH
  dev=3 fn=0  id=100e8086 class=0x0200   MATCH
  dev=4 fn=0  id=100e8086 class=0x0200   MATCH
  7 functions inside, 7 outside — FULL AGREEMENT
```

**The cross-check earned its place by finding two defects — both in my code, none
in the firmware.** That is the whole argument for the methodology:

1. **v1 walked function 0 only**, collapsing the PIIX's three functions at dev 1
   into one line. The firmware's own device tree had them right all along
   (`pci-ide@1,1`, `pci8086,7113@1,3`) — the *walker* was wrong. Fixed by testing
   the multifunction bit (header type, reg `0x0c`, bits 16–23, mask `0x80`) and
   iterating fn 1–7.
2. **Class decoding was off by 8 bits.** The raw register is
   `class_code(24) << 8 | revision(8)`, so QEMU's 16-bit class/subclass is
   `raw >> 16`. The firmware's data was correct from the first run; the host-side
   arithmetic was not.

Neither bug is visible without an external oracle. A single-source explorer would
have reported both with total confidence.

### Bonus finding: an FCode driver must declare `reg`

dev 4 (the FCode card from spike 1) reports `bar0=fffe0000 bar1=ffffffc1` — the
**sizing masks**, not assigned addresses — while the natively-probed dev 3 has
real ones (`bar0=11020000`). Cause: our minimal FCode driver replaces the default
property-making, and it never declares a `reg` property, so OFW has nothing to
assign addresses to. The lab's FCode driver should either declare `reg` or the
RUNBOOK must explain why its BARs look unprogrammed — a real lesson about what a
driver owes the firmware.

Also reconfirmed independently: `dev=4 rom=10020000`, matching spike 1's BAR
address exactly.

### Vocabulary B completed — and `mem-map` found a firmware bug on its first run

`region-diff` verified with **both** controls: snapshot → do nothing → diff
reports `total-diffs=0`; snapshot → `load` a file → diff reports `total-diffs=400`
with the changed bytes reading `5c 20 6f 66 73 63 6f 70` = `\ ofscope` — the
loaded file's own first line, visible in RAM. This is the forensic primitive the
parent lab needed *by hand* in POC-2 to prove an initrd was intact.

`mem-map` decodes `/memory@0`'s `available` property — and it does not agree with
the machine:

| `-m` | region start | size | region ends | RAM ends | overshoot |
|---|---|---|---|---|---|
| 128 | `0x2000000` | `0x8000000` | `0xa000000` | `0x8000000` | **32 MB** |
| 256 | `0x2000000` | `0x10000000` | `0x12000000` | `0x10000000` | **32 MB** |
| 512 | `0x2000000` | `0x20000000` | `0x22000000` | `0x20000000` | **32 MB** |

The big region starts at 32 MB but its size is the **full installed RAM** rather
than `installed - start`, so `available` always claims exactly 32 MB past the end
of physical memory. Systematic, reproducible at every size, and precisely the
class of era-gap the parent lab fought with `memmap=1023M@1M` in POC-2.

### Spike 1's root cause, properly named

Combining spike 1 and spike 3 data: the ROM BAR sat at `0x10020000` at `-m 512`
**and** at `-m 256`, with other BARs at `0x11020000`/`0x11040000` in both. So
OFW's PCI memory window is **anchored at ~`0x10000000` (256 MB) regardless of
installed RAM**. The rule is not the vague "guest RAM size matters" — it is a
**hardcoded 256 MB window that only clears DRAM when `-m` <= 256**. That is the
sentence the lab should teach, and vocabulary B is what produced it.

`map?`/`.pages` remains the documented negative from spike 0c.

## Artifacts proven so far — [`spikes/`](spikes/)

Everything here has been **run on this host** (Ubuntu 24.04, QEMU 8.2.2, KVM) and
produced the transcripts quoted above. At assembly the three `.fth` vocabularies
become the lab's `dsl/`, and the two host tools become `build-fcode-rom.sh` +
the inventory step of the smoke suite.

| artifact | spike | what it does |
|---|---|---|
| [`spikes/spike0-word-inventory.sh`](spikes/spike0-word-inventory.sh) | 0 | tick-probes the dictionary over serial; `' <word> .` looks up **without executing**, syncs on the `ok` prompt so a missing word cannot stall the drive |
| [`spikes/ofdiag.fth`](spikes/ofdiag.fth) | 2 | the boot-forensics **diagnosis ladder** — four distinct fault classes, no `catch` needed |
| [`spikes/ofdiag2.fth`](spikes/ofdiag2.fth) | 2b | the **tracers** — `trace-boot`/`untrace` over the firmware's own `?show-device`/`load-started`/`load-done` defer hooks, emitting `#T` milestone lines |
| [`spikes/ofscope.fth`](spikes/ofscope.fth) | 3 | `pci-map`, the config-space walker whose `#P` lines matched QMP `query-pci` **7/7** |
| [`spikes/spike1-card.fth`](spikes/spike1-card.fth) | 1 | the minimal **FCode driver** carried on a PCI option ROM; names its own node and sets a marker property |
| [`spikes/build-fcode-rom.py`](spikes/build-fcode-rom.py) | 1 | wraps tokenized FCode in a PCI expansion ROM, built to the contract **read out of `dev/pcibus.fth`** rather than off a spec sheet |

## Lab assembly (after spikes)

`examples/open-firmware-debugs-itself/`:

- **`dsl/ofdiag.fth`**, **`dsl/ofscope.fth`**, **`dsl/fcode-forensics.fth`** — the
  vocabularies, heavily commented (they are the primary teaching artifact, so
  they read as prose with a stack effect on every word).
- **`stage-dsl.sh`** — build the FAT16 / ISO media carrying the `.fth` files
  (both flavors, parent-lab idioms).
- **`build-fcode-rom.sh`** — `toke` a driver + wrap the PCI expansion-ROM header.
- **`run-ofw-debug.sh [emu|coreboot]`** — interactive: boots, `fload`s all three
  vocabularies, drops you at `ok` with the language loaded.
- **`smoke-dsl.sh [ofdiag|ofscope|fcode]`** — one verdict per vocabulary
  (EXIT-trap net, SKIP=77, cloned from `smoke-ofw.sh`'s proven shape).
- **`showcase-diagnose-a-broken-boot.sh`** — the finale, unattended: inject a
  fault, `why-no-boot` names it exactly, fix from the prompt, boot succeeds.
  One verdict.
- Docs: `README.md` (the toolbox-was-in-the-box table; DSL-as-vocabulary thesis;
  verified-vs-author-run honesty; deviations), `RUNBOOK.md` (the guided tour —
  decompile the firmware with itself, single-step a boot, walk a card's
  bytecode), `MANUAL_TESTING.md` (real transcripts + signatures), `PLAN.md`
  (this file + spike outcomes), `POC-0…4.md`.
- **Routing (both catalogs, or CI fails):** a `00-INDEX.md` row in the Phase-2
  section directly after the OFW row; a `learning-paths.toml` step in
  `boot-and-crash` **between** `open-firmware-forth-to-boot/` and
  `openbios-the-rival-that-shipped/` (you must meet the prompt before you
  instrument it); add to the `close-to-the-metal` collection. Then
  `python3 tools/paths.py render && python3 tools/paths.py --check` and
  `python3 tools/link_check.py` — both green.
- **Cross-links both ways:** the parent's RUNBOOK §6 gains a "now go debug it →"
  pointer, mirroring how it already hands off to the rival lab.

## Provenance

**Cite, don't mirror.** The lab is driven by the in-tree sources listed in the
audit table (pinned by the parent lab's clone commit) plus the OFW user manual
pages the parent lab **already vendored** at
`open-firmware-forth-to-boot/upstream-tutorial/`. Two labs sharing one source
would each need their own byte-exact copy under the self-containment rule — but
here the second lab is a *sibling that links the first*, so it cites and links
rather than duplicating. README records repo URL + commit + retrieved date.
Consequence: joins `close-to-the-metal`, not `provenance-vendored`.

## Verification (end-to-end)

1. Every spike ends in a verdict + an archived log under `~/ofw-lab/`; POC docs
   carry the real transcripts, including the failures and the thinking.
2. Three smoke verdicts (one per vocabulary), each a single PASS/FAIL/SKIP line
   with an EXIT-trap safety net.
3. The fault-injection matrix: five faults, five *distinct* diagnosis lines, each
   assertion `REGRESSION:`-prefixed and naming the specific defect.
4. `ofscope` agrees with QMP ground truth, or the disagreement is documented.
5. The showcase ends `PASS: …` having diagnosed and repaired a broken boot
   unattended.
6. Both catalogs green; `link_check.py` reports 0 broken links.
7. Anything env-blocked is marked **author-run** with the exact command handed
   over — never silently claimed as verified.

## Open risks

- **A word in the tree ≠ a word in the build.** The x86 configs may exclude
  `debug`/`decomp`/`breakpt` from the dictionary to save ROM space. Spike 0 is
  the gate; mitigation is a config edit (the parent lab already does serial-console
  config surgery in `build-ofw.sh`, so the pattern exists) — at the cost of a
  documented deviation from the parent's ROM.
- **Tracing perturbs what it observes.** Patching `open`/`read` on the live boot
  path can change timing enough to alter the outcome. If it does, that is a
  finding worth writing up, not a bug to hide — and `untrace` must prove clean
  restoration either way.
- **PCI expansion-ROM FCode may simply not be wired** on this x86 build →
  fallback ladder above; capstone drops to rung 2 or 3.
- **`map?` in physical mode** may be a no-op → `.pages` becomes documentation of
  *why* rather than a working view.
- **Flavor divergence.** The parent lab found emu and coreboot read different
  media and have different disk paths; expect the same split here and budget for
  two staging paths from the start rather than discovering it at assembly.
- **Scope creep.** Three vocabularies is already a large lab. If spike 1 lands on
  rung 1 (full option-ROM story), C alone could justify splitting into its own
  lab — decide at the spike-1 gate, not later.

## Post-approval

New project memory for the lab: state dir reuse (`~/ofw-lab/`), spike status,
which fallback rung the capstone stands on, the parent-lab synergies, and the
word-inventory result from spike 0 (the single most reusable fact for anyone
touching this firmware again).
