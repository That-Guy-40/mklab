# RUNBOOK — a guided tour of the firmware that debugs itself

You have run [`./stage-dsl.sh`](stage-dsl.sh). Start the machine:

```console
$ ./run-ofw-debug.sh          # ok prompt on this terminal; Ctrl-A X quits
```

This tour uses the **emu** flavor. Everything here works on the coreboot payload
too (`./run-ofw-debug.sh coreboot`) — same vocabularies, different media path,
and one extra step before any `fload` works. The README's flavor table has the
details; the short version is that coreboot needs
`: my-dma h# 1000 mem-claim ;` / `' my-dma to allocate-dma` typed first, because
its `allocate-dma` defer is never re-pointed and the filesystem stack needs it.

Everything below is typed at the `ok` prompt. The prompt thinks in **hex** — see
the sister lab's [RUNBOOK §1](../open-firmware-forth-to-boot/RUNBOOK.md) if that
bites you.

## 0. The first word: `no-page`

```
ok fload /pci/pci-ide@1,1/ide@1/cdrom@0:\nopage.fth
nopage loaded: the pager can no longer interrupt a listing
```

Do this before anything else. `see`, `.calls`, `words` and `devalias` all page
their output and stop with:

```
 More [<space>,<cr>,q,c,p,i,d,h] ?
```

Fine for a human, fatal for a script — it hung this lab's first automated run
until it timed out. `c` at that prompt means "stop paging" and maps to a word
called `no-page`, which you can call directly. But `no-page` is **not enough**,
for two reasons, both in `forth/lib/suspend.fth`:

1. `lines/page` is a **defer** (default 24). [`dsl/nopage.fth`](dsl/nopage.fth)
   points it at 30000, so `#line` can never reach it — and unlike `no-page` that
   survives `(reset-page)`, which only clears `#line`. Measured: `' open-dev
   .calls` went from **4** pager prompts to **0**.
2. `(exit?)` ends with `key? if key ascii q = if … else suspend then` — **any key
   pressed while output is streaming is eaten by the pager.** Nothing you set can
   turn that off; you simply must not type into a running listing. It is the
   reason §7's stepper resists automation.

(Don't reach for `' false to interactive?`. It does disable paging at the root —
`(exit?)`'s first line — but `interactive?` means "is input coming from the
keyboard?", so it also **silences the `ok` prompt**, leaving a driver with
nothing to synchronise on. Verified the hard way.)

## 1. Load the language

```
ok fload /pci/pci-ide@1,1/ide@1/cdrom@0:\ofdiag.fth
ofdiag loaded: diag-open why-no-boot trace-boot untrace
ok fload /pci/pci-ide@1,1/ide@1/cdrom@0:\ofscope.fth
```

You just extended a running firmware's command set from a CD. That is the whole
delivery mechanism, and it is not a stylistic choice: a serial console has **no
flow control**, so a multi-line colon definition typed at this prompt arrives
silently mangled. Put the words in a file and load the file.

Two traps live here. The filenames are 8.3 (`ofdiag.fth`, not
`ofdiag-vocabulary.fth`) because OFW's ISO9660 reader has no Rock Ridge —
`dir <cd>:\` will show you `OFDIAG.FTH` in capitals. And if a fload prints a wall
of `... isn't unique`, that is a **redefinition warning, not an error**; the load
succeeded.

## 2. Why won't it boot?

Every boot of this firmware ends the same way:

```
Boot device: /pci/ethernet  Arguments:
Can't open boot device
```

Five words, one device named, no cause. Ask better:

```
ok why-no-boot
OFDIAG: boot-device = disk net
OFDIAG target: disk
OFDIAG path:   /pci-ide/ide@0/disk@0
OFDIAG-2: no such node in the device tree
OFDIAG target: net
OFDIAG path:   /pci/ethernet
OFDIAG-3: node exists but its open method FAILED
```

`boot-device` is a **list**, and the two entries fail for completely different
reasons. `disk` is a devalias that resolves fine — to a 2015-era ATA path this
QEMU machine does not have. `net` names a node that genuinely exists; it is the
*open* that fails. One is a stale name, the other is a live device with nothing
to serve it. The firmware's own message conflated them.

The ladder has four rungs, and they come from flags the firmware already returns
— `expand-alias`, `find-package`, `open-dev` — so `diag-open` needs no `catch`:

| | meaning |
|---|---|
| `OFDIAG-0` | opens fine; whatever failed, failed later (load/execute) |
| `OFDIAG-1` | not a pathname, and no such devalias |
| `OFDIAG-2` | the path resolves but no such node exists |
| `OFDIAG-3` | the node exists; its `open` method failed |

Try your own targets: `" /pci/nosuch@9" diag-open`, `" nosuchalias" diag-open`.

## 3. Fix it from inside

The diagnosis says the `disk` alias points somewhere that doesn't exist. So
repoint it — live, no reflash, no rebuild:

```
ok devalias disk /pci/pci-ide@1,1/ide@1/cdrom@0
ok why-no-boot
OFDIAG target: disk
OFDIAG path:   /pci/pci-ide@1,1/ide@1/cdrom@0
OFDIAG-0: opens OK - failure is later (load/execute)
```

Diagnose, repair, re-verify with the same word — the loop
[`./showcase-diagnose-a-broken-boot.sh`](showcase-diagnose-a-broken-boot.sh) runs
unattended.

(`setenv boot-device …` is the more obvious repair and it **does not work here**:
the emu build answers "Out of NVRAM environment space". The alias is both the
honest fix and the working one.)

## 4. strace for firmware

```
ok trace-boot
OFDIAG: tracing ON
ok boot
#T open disk                       ← the boot-device LIST being walked
Boot device: /pci/ethernet  Arguments:
#T open /pci/ethernet              ← the device about to be opened
Can't open boot device
ok load /pci/pci-ide@1,1/ide@1/cdrom@0:\ofdiag.fth
#T open /pci/pci-ide@1,1/ide@1/cdrom@0:\ofdiag.fth
#T load-begin
#T load-end
ok untrace
OFDIAG: tracing OFF
```

Read the `boot` trace again: the firmware tries `disk`, says nothing about it,
and moves on to `/pci/ethernet`. The failed entry is **silently discarded** — the
tracer is what makes that visible, and `why-no-boot` from §2 is what tells you
*why* it failed.

No call-site patching was needed, because **the firmware ships its own
tracepoints**: `bootparm.fth` declares `defer ?show-device ( adr len -- adr len )`,
a pass-through hook that receives the device path just before `open-dev`, plus
`load-started`/`load-done` around the load. `trace-boot` is three assignments.

Deferred words are firmware-sanctioned patch points — the sister lab used one by
hand (`' my-dma to allocate-dma`); here it is systematic. Run `untrace` and repeat
the `load`: **silence**. A tracer you cannot remove is a bug, so prove the removal.

The `#T` lines are machine-readable on purpose — they are milestone lines, the
same shape [`tools/control-pane`](../../tools/control-pane) renders for anything else.

## 5. Look at the hardware, then check yourself

```
ok dev /pci pci-map device-end
#P begin
#P dev=0 fn=0 id=12378086 class=6000002 bar0=0 bar1=0 rom=0
#P dev=1 fn=1 id=70108086 class=1010080 ...
#P end
ok mem-map
#M region start=2000000 size=10000000
#M total=11b9f000
#M end
```

Now the important part: **do not believe it.** From outside the VM, ask QEMU the
same question with QMP `query-pci` and diff. They agree — 7 functions, IDs and
classes ([MANUAL_TESTING.md](MANUAL_TESTING.md) has the command).

That check is not ceremony. It found two bugs in *this lab's* walker: it was
skipping multifunction devices (the firmware's own tree had `pci-ide@1,1` and
`pci8086,7113@1,3` right all along), and it decoded the class register 8 bits off.
Neither is visible from inside.

And `mem-map` disagrees with the machine in a way worth staring at. On `-m 256`,
the big region runs `0x2000000 + 0x10000000` — it **ends 32 MB past the end of
RAM**. The size is the full installed RAM instead of `installed − start`, and it
is wrong by exactly 32 MB at every machine size. A firmware handing that map to a
kernel is inviting it to write into nothing.

Snapshot and diff memory too:

```
ok load-base h# 400 region-snap
ok region-diff
#R total-diffs=0
ok load /pci/pci-ide@1,1/ide@1/cdrom@0:\ofscope.fth
ok region-diff
#R diff +0  was 0  now 5c
#R total-diffs=400
```

`5c 20 6f 66 73 63 6f 70` is `\ ofscope` — the file's own first line, appearing in
RAM. This is the primitive the sister lab needed *by hand* in POC-2 to prove an
initrd was intact and the corruption happened later.

## 6. The firmware decompiles itself

```
ok see open-dev
: open-dev
   0 package( current-device >r ['] (open-dev)
   catch if  2drop  then
   my-self r> push-device )package
;
```

That is not a copy of the source file — the firmware read it back out of its own
compiled dictionary. Now decompile the word *you* loaded ten minutes ago:

```
ok see diag-open
: diag-open
   ." OFDIAG target: " 2dup type cr 2dup
   expand-alias >r 2swap 2drop r> 0= if
      over c@ h# 2f <> if
   ...
```

Compare with [`dsl/ofdiag.fth`](dsl/ofdiag.fth) and find the difference: you wrote
`ascii /`, and it comes back **`h# 2f`**. Decompilation recovers *semantics*, not
*notation*. How a constant was spelled existed only in the source text, and that
text was never in the machine. Four characters that teach what reverse
engineering actually gets you.

Then ask who calls what:

```
ok ' open-dev .calls
                  Called from (boot-read)               at 1c3eed4
                  Called from default-device            at 1c3f058
                  Called from open-partition-map        at 1c57ee8
                  ... (13 callers)
```

`(boot-read)` and `default-device` are **exactly** the two words §4's tracer
hooks. The cross-referencer points straight at the instrumentation points — see
the exercises.

## 7. The single-stepper (bring your eyes)

```
ok debug diag-open
Stepper keys: <space> Down Up Continue Forth Go Help ? See $tring Quit
ok " disk" diag-open
```

The screen clears and you get a live view: `Callers:`, `Stack:`, and the
decompiled body with the current word marked. `<space>` steps, `D` descends into
a word, `U` returns, `G` runs to completion, `Q` abandons it.

A source-level debugger, on bare metal, with no OS and no debug port.

### …and under a script

This was the last thing in the lab claimed to be human-only. It isn't. `debug`
has a **second display mode**: set `true to scrolling-debug?` *before* entering it
and you get a line-oriented view instead of the full-screen one — a stable
`Inside <word>  ( <stack> )` frame per step, which a driver can synchronise on,
one key per settled display. `smoke-dsl.sh stepper` does exactly that and asserts
the stack duplicates across `2dup`.

Two traps if you try it yourself: load [`nopage.fth`](dsl/nopage.fth) first, and
do **not** use `--echo-gate` — the stepper reads raw keys and its echo of a space
is indistinguishable from the whitespace already streaming past.

## 8. A driver that arrives on the card

```console
$ ./build-fcode-rom.sh && ./run-ofw-debug.sh --card
```

```
ok dev /pci ls
95884 fcode-card              ← not "ethernet@4"
ok dev /pci/fcode-card .properties device-end
fcode-marker             FCODE-FROM-CARD-RAN
name                     fcode-card
fcode-rom-offset         00000000
```

[`dsl/fcode-card.fth`](dsl/fcode-card.fth) — four lines — was tokenized to 62
bytes of **FCode bytecode**, wrapped in a PCI expansion ROM, and handed to QEMU as
a card's option ROM. The firmware found it, validated the PCI Data Structure,
`byte-load`ed the bytecode, and *the card named its own node*.

This is the mechanism that made Open Firmware architecture-independent: a card
carried its driver as ISA-neutral bytecode and any OF machine could run it — SPARC,
PowerPC, x86, without the vendor shipping three binaries.

Recover the source from the bytes, the way you would with a ROM you didn't write:

```console
$ ~/openbios-lab/fcode-utils/detok/detok ~/ofw-lab/fcode-card.fc
b(") " fcode-card"  device-name
b(") " FCODE-FROM-CARD-RAN"  encode-string
b(") " fcode-marker"  property
end0
```

Source → bytecode → executed by firmware → bytecode → source.

⚠️ If the node comes back as `ethernet@4` instead, check `-m`. OFW anchors its
PCI window at ~`0x10000000` no matter how much RAM you gave it, so anything above
`-m 256` puts the ROM BAR **inside DRAM** — reads return zeros, the `0xaa55` check
fails, and there is no error of any kind. Every script here pins `-m 256`.

## Exercises

1. **Derive the hooks.** Without reading §4, use `' open-dev .calls` to work out
   where a tracer would have to attach to see every device open on the boot path.
   Compare with what `trace-boot` actually patches.
2. **Break it four ways.** Craft a device string for each of `OFDIAG-0/1/2/3`.
   Which rung is hardest to trigger deliberately, and why?
3. **Trust but verify.** `mem-map` says the machine has ~283 MB. `-m` said 256.
   Find the region that overruns, and predict what an OS would do if it believed it.
4. **Notation is not semantics.** `see diag-open` prints `h# 2f` where the source
   says `ascii /`. Find two more places where decompilation loses something the
   source had. (Hint: look for what is *absent* between the words.)
5. **Make the card lie.** Change `dsl/fcode-card.fth` to claim a `reg` property,
   rebuild the ROM, and watch `pci-map`'s BAR columns change. Why does the stock
   card show sizing masks (`fffe0000`) instead of assigned addresses?
6. **Cross-implementation.** The rival lab's OpenBIOS also implements IEEE 1275.
   Does it have `see`? `.calls`? Take `ofdiag.fth` to its `0 >` prompt and see how
   far it gets.
