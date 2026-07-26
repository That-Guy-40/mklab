# RUNBOOK.md — a guided tour of two habitats

Two machines, one standard. Everything here runs against the stock OpenBIOS blob
QEMU ships; nothing needs building. Start each track with

```bash
./run-habitat.sh sparc32 --bare      # or: ppc
```

`--bare` boots with **no vocabulary loaded**, which is how you should meet the
machine first. `Ctrl-A X` quits.

## Part 0 — three things that will bite you in the first minute

| | |
|---|---|
| **the prompt is `0 >`** | it is the **stack depth**, not `ok`. A word that leaves junk prompts `1 >`. Free stack-balance checking, and the reason automation here syncs on `0 >` |
| **the base is hex** | `5 6 * .` → `1e`. The same trap the OFW lab teaches |
| **pty only** | `-serial unix:` yields *zero bytes* from these builds. `tools/drive-pty-repl.py` exists for this |

## Part 1 — meet the machine (SPARC)

```text
Probing SBus slot 0 offset 0
…
Probing SBus slot 4 offset 0
Invalid FCode start byte              ← SBus FCode probing is LIVE, every boot
CPUs: 1 x FMI,MB86904
Welcome to OpenBIOS v1.1
Trying disk:a...
Trying disk...
0 >
```

Two things are already interesting. The firmware **probes SBus slots for FCode
option ROMs on every boot** — the x86 lab had to build a PCI card to create that
situation. And it tried `disk:a`, then `disk`, and gave up.

```text
0 > printenv
```

The variable names are the real thing: `boot-device "disk:a disk"`,
`ttya-mode "9600,8,n,1,-"`, `output-device "ttya"`, `selftest-#megs`,
`tpe-link-test?`. This is a Sun environment, not a generic one.

```text
0 > dev / ls
0 > dev /aliases .properties device-end
```

Note `devalias` with no arguments prints nothing useful — use the second form.
The aliases are `cdrom`/`cd`/`cdrom0`/`cd0` all pointing at
`/iommu/sbus/espdma/esp/sd@2,0`, plus the wonderfully archaic
`sd(0,2,0)` — SunOS device-naming, preserved as a devalias.

There is **no PCI**. `/iommu/sbus/…` is the whole I/O story.

## Part 2 — meet the machine (Apple)

```bash
./run-habitat.sh ppc --bare
```

```text
>> CPU type PowerPC,750
milliseconds isn't unique.                  ← the firmware warns about its OWN boot
Trying hd:,\\:tbxi...
Trying hd:,\ppc\bootinfo.txt...
Trying hd:,%BOOT...
0 >
```

The boot policy *is* the `boot-device` list, and it reads like Apple history:
an HFS+ file blessed with type `tbxi`, then a CHRP boot script, then `%BOOT`.

```text
0 > dev /aliases .properties device-end
via-cuda      "/pci@80000000/mac-io@10/via-cuda"        ← power + ADB controller
adb-keyboard  "…/via-cuda/adb/keyboard"                 ← Apple Desktop Bus
nvram         "/pci@80000000/mac-io@10/nvram@60000"     ← a real device node
ttya          "/pci@80000000/mac-io@10/escc/ch-a"       ← Zilog ESCC
mac-io        "/pci@80000000/mac-io@10"                 ← the Heathrow ASIC
```

Compare the two trees side by side and the lab's thesis is visible in one
glance: same standard, same prompt, same words — **completely different
furniture**.

## Part 3 — why won't it boot?

Now load the vocabulary (drop `--bare`) and ask:

```text
0 > why-no-boot
```

On both machines it walks the `boot-device` **list** and gives a per-entry
verdict. That is the whole point: the firmware's own answer is five words, and
a list has more than one way to fail.

Try the ladder by hand — one target, one verdict:

```text
0 > " nosuchalias" diag-open                 → OFDIAG-1  no such alias, not a path
0 > " /obio/nosuch@9" diag-open              → OFDIAG-2  no such node
0 > " cdrom" diag-open                       → OFDIAG-0  opens fine, look further along
0 > " /obio/eeprom" diag-open                → OFDIAG-3  node exists, open method failed
```

**Exercise.** On PPC, run `" cd" diag-open` twice — once as launched, once with
`-cdrom ~/ofhabitat-lab/dsl.iso` added. The verdict moves from OFDIAG-3 to
OFDIAG-0. The ladder is reading the machine, not reciting a script.

## Part 4 — the firmware decompiles what you just taught it

```text
0 > see why-no-boot
0 > see diag-open
```

You wrote it, the firmware read it off a disc or out of NVRAM, and it can now
hand the source back. Then try:

```text
0 > see expand-alias        \ a word that shipped with the firmware
0 > see patch               \ …and one that did not
```

`patch` decompiles to `: patch ;`. So do `.calls`, `dl`, `nvedit`, `nvstore`.
**The debugging chapter of the standard is largely unimplemented here**, which
is the sharpest single contrast with the OFW lab — where the same audit found
an assembler and a source-level single-step debugger sitting in the ROM. See
[PORTING.md](PORTING.md).

This is also the exercise that teaches the tick trap: `' patch .` resolves
happily. `'` proves a *name*. `see` proves a *behaviour*.

## Part 5 — put the vocabulary in the chip (Apple only)

```text
0 > setenv nvramrc device-end : q ." HELLO-FROM-NVRAM" cr ; q
0 > setenv use-nvramrc? true
0 > " update-nvram" " nvram" open-dev $call-method
0 > reset-all
```

Watch `HELLO-FROM-NVRAM` appear on the next power-on, *before* the banner. Three
things to notice:

1. **`setenv` alone would not have been enough.** Without the flush the write
   lives only in the in-memory `/options` node. Try it and see.
2. **`update-nvram` is a package method, not a word.** `' update-nvram .` says
   `undefined word` — a negative that looks like "missing feature" and is really
   "wrong calling convention".
3. **`device-end` is load-bearing.** Drop it and the definition becomes a method
   of whatever node is active when nvramrc runs. It will print. Its words will
   be gone.

**Now do the same on SPARC** and watch it *not* work. That asymmetry —
`drivers/obio.c` builds the NVRAM node but never binds the package that could
write it — is the single most useful thing this lab found, and it is a genuine
upstream gap, not a lab limitation. [DELIVERY.md](DELIVERY.md) has the code
references.

## Part 5b — the firmware ships no hook, so rewrite the call site

`patch` is section 7.5.3.3 of the standard, and here it is `: patch ;`. The lab
implements it (see [PATCH.md](PATCH.md)), and the tracers are built on top:

```text
0 > trace-boot
#T tracing ON, 2 call site(s) rewritten
0 > boot cdrom:\OFDIAG.FTH
#T load-begin
#T open cdrom:\OFDIAG.FTH
#T load-end
0 > untrace
#T tracing OFF, 2 call site(s) restored
```

**Exercise — prove it is not a memory scanner.** Build a word containing a
literal whose value *is* the xt you are about to replace, and count:

```text
0 > : zap ." ZAP" cr ;
0 > : zip ." ZIP" cr ;
0 > : t4 zap 12345 drop zap ;
0 > ' zap true 12345 true ' t4 (patch)      \ set the literal to ' zap
0 > patch zip zap t4
patch: 2 occurrence(s) replaced             \ 2, not 3 — the literal is untouched
```

⚠️ **Do not name your test words `aa` and `bb`.** The base is hex: those are 170
and 187, and `patch` will correctly hunt for literals instead. Same for `dead`,
`beef`, `face`, `cafe`.

**Then the payoff.** Boot with the combined script in NVRAM and type nothing:

```bash
./run-habitat.sh ppc --autotrace     # or sparc32
```

`#T tracing ON` appears *above* the banner, and `#T load-begin` before the first
prompt — the power-on autoboot tracing itself on a firmware that provides no
tracepoint at all.

## Part 6 — compare the rivals, side by side

Open two terminals:

```bash
./run-habitat.sh ppc                                   # OpenBIOS, Apple habitat
../open-firmware-debugs-itself/run-ofw-debug.sh emu    # OFW, x86
```

Run `why-no-boot` in both. Same word name, same four fault classes, two
different implementations, two completely different machines — and one of them
had to be taught what a device argument is.

| ask both | OFW / x86 | OpenBIOS / native |
|---|---|---|
| `boot-device` | `disk net` | `disk:a disk` · `hd:,\\:tbxi …` |
| the prompt | `ok` | `0 >` (stack depth) |
| `see patch` | a real cross-referencer | `: patch ;` |
| where NVRAM lives | a file on a floppy, after 3 source edits | a chip, at power-on |
| how the vocabulary arrives | `fload <cd>:\ofdiag.fth` | one door per habitat, and they differ |

That last row is the lab. The x86 sibling had to *build* four delivery
mechanisms because the platform gave it none; here each habitat hands you
exactly one, for free — and no single one works on both.
