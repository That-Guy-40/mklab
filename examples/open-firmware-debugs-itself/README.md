# open-firmware-debugs-itself — the firmware is the debugger

The sister lab, [`../open-firmware-forth-to-boot/`](../open-firmware-forth-to-boot/README.md),
proved that Open Firmware **answers back**, and fixed its era-gaps live at the
`ok` prompt — one clever incantation at a time, typed once and never named.

This lab does the other thing. It writes a **language** down: three Forth
vocabularies, loaded off a CD into a 2015 firmware, that turn "Can't open boot
device" into a per-entry diagnosis, walk PCI config space, diff RAM, and
reverse-engineer a driver off a card's option ROM — while the firmware
decompiles *itself* to show you how it works.

```text
ok fload <cd>:\ofdiag.fth
ok why-no-boot
OFDIAG: boot-device = disk net
OFDIAG target: disk
OFDIAG path:   /pci-ide/ide@0/disk@0
OFDIAG-2: no such node in the device tree          ← a 2015 ATA path QEMU hasn't got
OFDIAG target: net
OFDIAG path:   /pci/ethernet
OFDIAG-3: node exists but its open method FAILED   ← a different bug entirely
```

That is the failure the sister lab hits on **every single boot**, and the
firmware's own message for it is five words.

## The discovery: the toolbox was in the box

An audit of the OFW source tree found a complete reverse-engineering workbench
already compiled into the ROM. The sister lab's tour opens `words`, `dev`,
`.properties`, `dump`. Everything below was sitting there unopened:

| In-firmware tool | Source | What it is |
|---|---|---|
| `see` | `forth/lib/decomp.fth` | **decompiler** — recovers source for any word in the dictionary |
| `debug` · `stepping` · `resume` | `forth/lib/debug.fth` | **source-level single-step debugger**, on bare metal |
| `set-breakpoint` · `show-breakpoints` | `forth/lib/breakpt.fth` | real breakpoints (in the `hidden` vocabulary) |
| `ctrace` | `cpu/x86/ctrace.fth` | machine-code backtrace with frame/arg decoding |
| `.calls` | `forth/lib/callfind.fth` | dictionary **cross-reference** — "who calls this word?" |
| `config-l@` · `config-l!` | `dev/pci/` | raw **PCI config-space** access |
| `byte-load` · `detokenize` | `ofw/fcode/` | run FCode bytecode; turn it back into source |
| `code` · `assembler` · `end-code` | | the Forth **assembler**, in a 512 KiB ROM |

**22 of 23 audited words are reachable.** Most of the ones that look missing
aren't: `only forth also hidden also` reveals the breakpoint words, and
`load-fcode` lives in the PCI package's scope. Run
[`./probe-dictionary.sh`](probe-dictionary.sh) to reproduce the audit.

## The thesis

> In Forth, a DSL is not a parser — it is a **vocabulary**. You don't write a
> grammar; you define words, and the words *are* the language.

Which is why this lab is a few hundred lines of `.fth` rather than a compiler.
And the second lesson, the one that makes it a *forensics* lab: **the machine
under investigation is also the instrument.** No agent, no OS, no JTAG. `see`
decompiles the firmware you are standing inside, and `detokenize` recovers
source for driver bytecode that arrived on a card.

## Quick start

```console
$ ./stage-dsl.sh                            # put the vocabularies on media (~1 s)
$ ./smoke-dsl.sh all                        # three verdicts, headless
$ ./showcase-diagnose-a-broken-boot.sh      # diagnose → repair live → verify
$ ./run-ofw-debug.sh                        # interactive ok prompt (Ctrl-A X quits)
$ ./build-fcode-rom.sh && ./run-ofw-debug.sh --card    # plug in the FCode card
```

Prereqs: `qemu-system-x86_64`, `python3`, `genisoimage` (+ `mkfs.vfat`/`mcopy`
for the coreboot flavor's FAT16 media). The ROM comes from the sister lab —
run its `./build-ofw.sh` first. `toke`/`detok` for the FCode track come from
[`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/README.md)'s
`~/openbios-lab/fcode-utils` (plain `make`). No sudo anywhere.

## The three vocabularies

| | words | proves |
|---|---|---|
| **`ofdiag`** boot forensics | `why-no-boot` `diag-open` `trace-boot` `untrace` | four **distinct** fault classes, and tracers on the firmware's own hooks |
| **`ofscope`** memory & devices | `pci-map` `mem-map` `region-snap` `region-diff` | agreement with QEMU's own view — or an honest disagreement |
| **`fcode`** option-ROM RE | `dsl/fcode-card.fth` → `toke` → ROM → `detok` | a card's bytecode driver running on the bare machine |

**`ofdiag` doesn't just print — it discriminates.** The smoke asserts all four
of `OFDIAG-0/1/2/3` appear, because "a diagnostic that always says the same
thing" is exactly how this rots. It did rot that way once: the first version
misread `expand-alias`'s flag and reported `OFDIAG-1` for *every* input. The
fault matrix caught it on the first run; a single-case smoke would have passed.

**`ofscope` is checked against an oracle.** `pci-map`'s output is diffed against
QMP `query-pci` on the same running VM — 7 functions, IDs and classes, full
agreement. That cross-check found two bugs, both in *this lab's* code (a walker
that skipped multifunction devices; class decoding off by 8 bits). An explorer
that is never checked against ground truth is a very confident random-number
generator.

**`fcode` is the real mechanism, not a mock.** `dsl/fcode-card.fth` is tokenized
to 62 bytes of FCode, wrapped in a PCI expansion ROM, and handed to QEMU as a
card's option ROM. The firmware probes it, validates the PCI Data Structure,
`byte-load`s the bytecode, and the *card* names its own device-tree node. This
is what made Open Firmware architecture-independent in the 1990s.

## What we found in the firmware

Two findings are the lab's own, produced by its tools rather than read from docs:

| Finding | How |
|---|---|
| **`available` claims 32 MB past the end of RAM.** `/memory@0`'s big region starts at 32 MB but its size is the *full* installed RAM instead of `installed − start`. Identical at `-m 128`/`256`/`512`. | `mem-map`, first run |
| **OFW anchors its PCI window at ~`0x10000000` regardless of RAM.** So a card's option ROM is silently shadowed by DRAM whenever `-m > 256` — no error, just a device that quietly isn't there. | `pci-map` + `config-l@` |

That second one is why **every script here pins `-m 256`**, and why raising it
"to be generous" will break the FCode track in a way that looks like nothing at
all. It is the same family of era-gap the sister lab fought with `memmap=1023M@1M`.

## Honesty about what's verified

Everything in Quick start is **verified end-to-end on this host** (Ubuntu 24.04,
QEMU 8.2.2, KVM): three smoke verdicts plus the showcase, all headless, all
driven over serial with [`tools/drive-serial-repl.py`](../../tools/drive-serial-repl.py).

Not claimed:

- **The `debug` stepper is not smoked.** It is a full-screen ANSI application and
  paging resets inside it, so scripted keystrokes answer pager prompts instead of
  stepping. It is documented in [RUNBOOK.md](RUNBOOK.md) **for humans** — the same
  call the sister lab made about GRUB's `e` menu-edit.
- **The coreboot flavor's media is staged but its smokes are not run here.** The
  dictionaries are identical across flavors (proven), so the vocabularies port;
  only the media path differs.
- **`map?` is not recovered.** It needs the assembler *and* a `${BP}` dep, and it
  walks page tables that don't exist in the physical-mode boot this lab uses.
  Declined on purpose, not overlooked.
- A **full autoboot trace** (as opposed to tracing an interactive `load`) is
  still unproven; the hooks are the same ones `boot` uses.

Blow-by-blow spike results, with transcripts and the wrong turns, are in
[PLAN.md](PLAN.md). Exact commands and success signatures:
[MANUAL_TESTING.md](MANUAL_TESTING.md). The guided tour: [RUNBOOK.md](RUNBOOK.md).

## Security posture

Everything runs as your user under QEMU (KVM or TCG); no sudo, no host services,
no listening ports. The 2015 firmware is run for study, not trust — and the
`fcode-card` ROM is a lab artifact we built, not a vendor blob.
