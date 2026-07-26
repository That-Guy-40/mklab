# MANUAL_TESTING — exact commands and real success signatures

Host used for every transcript here: Ubuntu 24.04, QEMU 8.2.2, KVM, rootless.
No sudo, no host services, no listening ports.

## 0. Prerequisites

The firmware ROM comes from the sister lab; the FCode tools from the rival lab.

```console
$ cd ../open-firmware-forth-to-boot && ./build-ofw.sh     # -> ~/ofw-lab/.../emuofw.rom
$ cd ../open-firmware-forth-to-boot && ./build-coreboot-ofw.sh   # -> coreboot flavor (optional)
$ make -C ~/openbios-lab/fcode-utils                      # -> toke, detok, romheaders
```

Override the defaults with `OFW_WORKDIR=`, `OFW_ROM=`, `FCODE_UTILS=` if your
trees live elsewhere.

## 1. Stage the vocabularies

```console
$ ./build-detok-vocab.sh
wrote .../dsl/detok.fth (1495 lines spliced from 5 sources)

$ ./stage-dsl.sh
staged detok.fth nopage.fth ofdiag.fth ofscope.fth -> /home/sqs/ofw-lab/dsl.iso
staged -> /home/sqs/ofw-lab/dsl.img (FAT16, for the coreboot flavor)
```

**Signature:** both media created, and every staged name is 8.3. Two guards live
here, both added after they failed: the FAT16 step is fully checked (it once
reported success on an image `mkfs.vfat` had rejected, so `mdir` now gates it),
and ROM-only vocabularies are excluded — `autotrace.fth` is 9 characters and the
8.3 check rightly refused it, which broke this script until `smoke-dsl.sh stage`
started running it as a guard. **A build step with no verdict attached is an
untested step.**

## 2. The smoke verdicts

```console
$ ./smoke-dsl.sh ofdiag
  - four distinct fault classes reported (OFDIAG-0/1/2/3)
  - why-no-boot walked the boot-device list
  - tracer covers a real `boot` (list walk + device open) and a load; untrace restores cleanly
PASS: ofdiag: 4 distinct fault diagnoses + boot tracer installed and cleanly removed

$ ./smoke-dsl.sh ofscope
  - pci-map walked config space including multifunction devices
  - mem-map decoded /memory@0 available regions
  - region-diff: clean on a no-op, detects a load (both controls)
PASS: ofscope: pci-map + mem-map + region-diff verified, both region-diff controls hold

$ ./smoke-dsl.sh fcode
  - the firmware probed, validated and byte-loaded the card's FCode
PASS: fcode: a PCI card's bytecode driver ran on the bare machine and named its own node

$ ./smoke-dsl.sh all        # every mode on this flavor, then a summary line
```

The full mode list is
`stage | ofdiag | ofscope | fcode | stepper | stepper-deep | dropin | autotrace | all`,
and the second argument picks the flavor (`emu`, default, or `coreboot`).

### The coreboot flavor

The three vocabulary verdicts again on the second flavor — the ROM-resident and
debugger modes are emu-only, since they need the ROM this lab builds:

```console
$ ./smoke-dsl.sh all coreboot
PASS: ofdiag (coreboot): 4 distinct fault diagnoses + boot tracer installed and cleanly removed
PASS: ofscope (coreboot): pci-map + mem-map + region-diff verified, both region-diff controls hold
PASS: fcode (coreboot): a PCI card's bytecode driver ran on the bare machine and named its own node
PASS: all vocabularies verified (coreboot)
```

It needs the sister lab's `./build-coreboot-ofw.sh` (ROM at
`~/linuxboot-lab/coreboot/build-ofw/coreboot.rom`) and reads `dsl.img` (FAT16) on
the legacy ISA-IDE path instead of the ISO on ATAPI. The smoke injects the
`allocate-dma` repair automatically; by hand it is:

```
ok dir /isa/ide@i1f0/disk@0:\
Can't open deblocker package                      ← before
Can't open directory
ok : my-dma h# 1000 mem-claim ;
ok ' my-dma to allocate-dma
ok dir /isa/ide@i1f0/disk@0:\
fat-file-system                                   ← after
--A-rwxrwxrwx      4959  ...  OFDIAG.FTH
```

**Signature: the same `dir` fails, then succeeds, across two typed lines.**

`why-no-boot` reports a *different* failure here — the coreboot payload's default
`boot-device` is `a:\vmlinuz`, a DOS-style floppy alias:

```
OFDIAG: boot-device = a:\vmlinuz
OFDIAG path:   /isa/fdc/disk@0:\vmlinuz
OFDIAG-2: no such node in the device tree
```

Exit codes are the house convention: 0 PASS / 1 FAIL / 77 SKIP, one verdict line
each, with an `EXIT`-trap net so an early death still prints a verdict.

**What the assertions actually guard.** `ofdiag` requires **all four** of
`OFDIAG-0/1/2/3` to appear. That is not thoroughness for its own sake: v0 of the
ladder misread `expand-alias`'s flag and answered `OFDIAG-1` for every input, and
a single-case smoke would have passed it. `ofscope` requires an `fn=1` line
(multifunction walking) and **both** `region-diff` controls — clean on a no-op,
dirty after a load — because a differ that always says "changed" is as useless as
one that always says "clean".

## 2b. The DSL inside the ROM

```console
$ ./build-dropin-rom.sh                 # ~2 min incl. the container build box
==> guard OK: the sister lab's emuofw.rom is untouched
$ ./smoke-dsl.sh dropin
  - the vocabularies are inside the ROM, listed by /dropin-fs
  - loaded and ran with NO cdrom, NO floppy, NO staged media
PASS: dropin: the DSL ships inside the ROM and loads with no media at all

$ ./build-dropin-rom.sh --boot-hook     # also ships autotrace.fth as `banner-`
$ ./smoke-dsl.sh autotrace
  - the banner- dropin armed the tracers before auto-boot
  - the POWER-ON autoboot traced itself — nothing typed, no media
PASS: autotrace: the autoboot traces itself from a banner- dropin inside the ROM
```

**Signature for `autotrace`:** `#T` lines appear *before the first `ok` prompt*,
with no media attached and nothing sent to the console:

```
Install console
#T autotrace armed (banner- dropin)
Type any key to interrupt automatic startup
6 5 4 3 2 1
#T open disk
Boot device: /pci/ethernet  Arguments:
#T open /pci/ethernet
Can't open boot device
```

⚠️ Do not send a keystroke before that prompt — **any key cancels the autoboot
countdown**, and the autoboot is the whole point. The smoke's first drive step
only *waits*.

⚠️ These builds are isolated by construction (own tree clone, own output) and the
script **fails** if the sister lab's `emuofw.rom` sha changes.

## 2c. The single-step debugger

```console
$ ./smoke-dsl.sh stepper
  - stepped 5 times, one key per settled display
  - the displayed stack duplicates across 2dup, and steps follow the source
  - stepping 'type' emitted the argument — execution, not just display
  - 'G' ran it to completion and the diagnosis came out
PASS: stepper: single-stepped a live word on bare metal, one key per settled display, and ran it out
```

**Signature:** `Inside diag-open  ( … )` frames, one per keystroke, with the stack
visibly duplicating across `2dup`. Requires `true to scrolling-debug?` before
`debug` (line-oriented mode), `nopage.fth` loaded, and **no `--echo-gate`**.

And the same debugger driven harder — introspection, navigation, and the abandon
path:

```console
$ ./smoke-dsl.sh stepper-deep
  - the 'string' key displayed the stack argument before any of it executed
  - 'D' descended into expand-alias and stepped its actual first token
  - 'U' returned to the caller
  - 'Q' abandoned execution — no diagnosis followed, as it must not
PASS: stepper-deep: string/Down/Up/Quit all drive the live debugger, including the abandon path
```

```
." OFDIAG target: "     $ nosuchalias          ← $ prints the stack's string
...
expand-alias            D
: expand-alias            ( 1fff79c b 1fff79c b )   ← descended
switch-alias-buf                                     ← its REAL first token
Inside expand-alias       ( 1fff79c b 1fff79c b )
2dup                    U
[ Up to diag-open ]                                  ← the firmware announces it
Inside diag-open          ( 1fff79c b 1fff79c b 0 )
>r                      Q
unbug                                                ← abandoned, no diagnosis
```

⚠️ **The frame shapes are the synchronisation contract.** `": <word>"` means the
ip is at the first token **and** is repainted after any key that does not advance
(`$`, `S`, `R`, `H`); `"Inside <word>"` means the ip moved. Expect the wrong one
and the driver waits forever for a frame that never comes.

## 3. The showcase

```console
$ ./showcase-diagnose-a-broken-boot.sh
  - booting, diagnosing the default boot failure, repairing it at the prompt
  - diagnosed both boot-device entries, with DIFFERENT causes (OFDIAG-2 and OFDIAG-3)
  - repointed the broken 'disk' alias at the prompt; the same word now reports OFDIAG-0
PASS: diagnosed a boot failure the firmware only called "Can't open boot device",
      repaired the broken alias live, and verified the repair
```

The transcript it drives, in full:

```
ok why-no-boot
OFDIAG: boot-device = disk net
OFDIAG target: disk
OFDIAG path:   /pci-ide/ide@0/disk@0
OFDIAG-2: no such node in the device tree
OFDIAG target: net
OFDIAG path:   /pci/ethernet
OFDIAG-3: node exists but its open method FAILED
ok devalias disk /pci/pci-ide@1,1/ide@1/cdrom@0
ok why-no-boot
OFDIAG target: disk
OFDIAG path:   /pci/pci-ide@1,1/ide@1/cdrom@0
OFDIAG-0: opens OK - failure is later (load/execute)
```

## 4. The dictionary audit

```console
$ ./probe-dictionary.sh emu
  - booting emu ROM (accel=kvm); probing 23 words -> ~/ofw-lab/spike0-emu.log
--- emu: 18 found / 5 missing ---
FOUND  : words dev devalias dump see patch debug resume stepping ctrace showstack
         .calls config-l@ config-b@ mem-claim random-test byte-load fload
MISSING: map? detokenize load-fcode set-breakpoint show-breakpoints
PASS: spike 0 (emu): dictionary probed, inventory at ~/ofw-lab/spike0-emu.log.inventory
```

⚠️ **This probe deliberately under-reports, and the lab keeps it that way** as a
teaching artifact. Three of those five are false negatives — the dictionary is
not flat. Reproduce the correction by hand:

```
ok only forth also hidden also
ok ' set-breakpoint .
1c27688                      ← present all along, in the `hidden` vocabulary
ok ' show-breakpoints .
1c2771c
```

and `load-fcode` is package-scoped (`dev /pci`, then look). Only `detokenize` and
`map?` are genuinely absent. `detokenize` is recovered by
[`./build-detok-vocab.sh`](build-detok-vocab.sh); `map?` is declined on purpose
(it needs the assembler *and* walks page tables that do not exist in this
physical-mode boot).

`./probe-dictionary.sh coreboot` returns an **identical** 18/23 — the flavors
differ in media paths, not dictionaries.

## 5. Cross-checking `pci-map` against QEMU (the oracle)

Boot with a QMP socket alongside the serial one, run `pci-map` inside, then ask
QEMU the same question from outside:

```console
$ qemu-system-x86_64 -machine pc,accel=kvm -m 256 -bios "$ROM" -cdrom ~/ofw-lab/dsl.iso \
    -device e1000,romfile=$HOME/ofw-lab/fcode-card.rom \
    -display none -serial unix:/tmp/s.sock,server=on \
    -qmp unix:/tmp/q.sock,server=on,wait=off -no-reboot &
$ python3 ../../tools/drive-serial-repl.py /tmp/s.sock /tmp/pci.log --timeout 200 --echo-gate \
    --expect ok --send '\r' --expect ok \
    --send 'fload /pci/pci-ide@1,1/ide@1/cdrom@0:\ofscope.fth\r' --expect ok \
    --send 'dev /pci pci-map device-end\r' --expect '#P end'
```

Then diff the `#P` lines against QMP `query-pci`. Verified result:

```
  dev=0 fn=0  id=12378086 class=0x0600   MATCH
  dev=1 fn=0  id=70008086 class=0x0601   MATCH
  dev=1 fn=1  id=70108086 class=0x0101   MATCH
  dev=1 fn=3  id=71138086 class=0x0680   MATCH
  dev=2 fn=0  id=11111234 class=0x0300   MATCH
  dev=3 fn=0  id=100e8086 class=0x0200   MATCH
  dev=4 fn=0  id=100e8086 class=0x0200   MATCH
  7 functions inside, 7 outside — FULL AGREEMENT
```

Two decoding notes, both learned by getting them wrong: the firmware prints the
**raw** class register (`class_code(24) << 8 | revision(8)`), so QEMU's 16-bit
class is `raw >> 16`; and the multifunction bit is bit 7 of the header-type byte
at reg `0x0c`, bits 16–23.

## 6. Known-good `mem-map` output (and the bug in it)

```console
$ # -m 128 / 256 / 512, same firmware
#M region start=2000000 size=8000000     ends 0xa000000   RAM ends 0x8000000
#M region start=2000000 size=10000000    ends 0x12000000  RAM ends 0x10000000
#M region start=2000000 size=20000000    ends 0x22000000  RAM ends 0x20000000
```

**Signature: it is wrong by exactly 32 MB every time.** The region starts at
32 MB but its size is the full installed RAM rather than `installed − start`.
This is a finding, not a defect in the tool — `mem-map` is reporting faithfully
what the firmware believes.

## 7. Failure signatures worth recognising

| Symptom | Cause | Fix |
|---|---|---|
| `dev /pci ls` shows `ethernet@4`, not `fcode-card` | `-m` above 256; OFW's PCI window is anchored at ~`0x10000000`, so the ROM BAR is shadowed by DRAM. **No error is printed.** | keep `-m 256` |
| `fload` → "cannot be opened" | filename is not 8.3; OFW's ISO9660 reader has no Rock Ridge | rename; check with `dir <cd>:\` |
| a driven session hangs to a timeout | a listing hit the pager (` More [<space>,<cr>,q,c,p,i,d,h] ? `) | `fload …\nopage.fth` first — `no-page` alone is not enough |
| keys vanish instead of reaching a full-screen app | `(exit?)` ends `key? if key ascii q = if … else suspend then` — **any key pressed while output streams is eaten by the pager** | send one key per *settled* display |
| the debugger clears the screen and resists driving | `scrolling-debug?` is false → the 2D full-screen mode | `true to scrolling-debug?` **before** `debug` |
| a driven stepper stalls with `--echo-gate` | the stepper reads **raw** keys; a space's echo is indistinguishable from streaming whitespace | drop `--echo-gate` for raw-key readers |
| every `diag-open` answers `OFDIAG-1` | `expand-alias`'s flag misread — it means "an alias *was* expanded", not "success" | see the comment block in [`dsl/ofdiag.fth`](dsl/ofdiag.fth) |
| driver exits 125 | the console dropped input despite `--echo-gate` | not expected here; check for a second client on the serial socket |
| `setenv boot-device …` → "Out of NVRAM environment space" | the emu build has no working NVRAM | repair the **devalias** instead |
| coreboot: `Can't open deblocker package` on any fload | `allocate-dma` is a defer nothing re-points on this flavor | type the two-line `my-dma` repair first |
| a wall of `… isn't unique` during fload | redefinition **warnings**, not errors | ignore; the load succeeded |

## 8. Interactive

```console
$ ./run-ofw-debug.sh            # prints a cheat-sheet, then the ok prompt
$ ./run-ofw-debug.sh coreboot   # ...the coreboot payload (cheat-sheet includes the repair)
$ ./run-ofw-debug.sh --card     # ...with the FCode option ROM plugged in
```

Ctrl-A X quits QEMU. Follow [RUNBOOK.md](RUNBOOK.md) from there. §7's single-step
debugger is worth meeting by hand — but it is **no longer human-only**:
`smoke-dsl.sh stepper` and `stepper-deep` drive it headlessly, once you put it in
line-oriented mode.
