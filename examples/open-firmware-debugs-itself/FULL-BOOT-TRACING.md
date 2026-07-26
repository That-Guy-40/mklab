# Full boot traceability — dropin vs. NVRAM vs. baking it into the ROM

`trace-boot` covers a real `boot` (verified — both `?show-device` sites). What it
**cannot** catch is the **power-on autoboot**, because the tracers have to be
`fload`ed first and that happens after the machine has already tried to boot.

> **RESOLVED.** This started as a research note; both options are now **built and
> verified** by [`./build-dropin-rom.sh`](build-dropin-rom.sh), with
> `smoke-dsl.sh dropin` and `smoke-dsl.sh autotrace` as the verdicts. The
> reasoning below is kept because *why* the other two routes lose is the useful
> part.

## The startup sequence, and where a hook could go

`ofw/core/startup.fth`:

```forth
: startup  ( -- )
   ...
   " nvramrc" ?type
   use-nvramrc?  if  nvramrc safe-evaluate  then      ← option A
   install-alarm
   auto-banner?  if  probe-all  install-console  banner  then
   ...
   secondary-diagnostics                              ← a defer, but unreachable from outside
   kbd-extras
   auto-boot                                          ← the thing we want to trace
   user-interface
;
```

and inside the boot path itself, `ofw/core/bootparm.fth:345`:

```forth
   " boot-" do-drop-in        ← option B — fires IMMEDIATELY before the autoboot
   do-auto-boot
   " boot+" do-drop-in
```

## Option A — `nvramrc` · **DEAD ON THIS BUILD** (verified)

The canonical Open Firmware answer: NVRAM holds a Forth script that `startup`
evaluates before `auto-boot`. Per-machine, no rebuild, exactly what the mechanism
is for.

It does not work here:

```
ok printenv use-nvramrc?
use-nvramrc? =        false
ok setenv use-nvramrc? true
Out of NVRAM environment space
<buffer@1c3ebb8>:0: Unimplemented package interface procedure
ok printenv use-nvramrc?
use-nvramrc? =        false          ← unchanged
```

The emu demo build has no working NVRAM — the same wall the showcase hit when it
tried `setenv boot-device` and had to repair a `devalias` instead. **Not a design
flaw in the approach; a missing peripheral in this firmware build.** On real
OFW hardware (Sun, OLPC, PowerPC Macs) this is the correct answer and needs no
rebuild at all. Worth teaching for that reason, then discarding here.

## Option B — a **dropin** · CHOSEN, BUILT, VERIFIED

OFW keeps a small read-only filesystem *inside the ROM* and exposes it as
`/dropin-fs`. It is real and browsable on the ROM we already have:

```
ok dir /dropin-fs:\
----r--r--r--      1267  ...  pmreset
----r--r--r--       296  ...  paging
----r--r--r--      6472  ...  inflate
----r--r--r--    577908  ...  firmware
----r--r--r--      2828  ...  class060400
----r--r--r--       203  ...  probe-              ← a startup hook, already shipping
----r--r--r--     13922  ...  memtest.fth         ← a Forth SOURCE file in the ROM
```

Two things in that listing matter enormously:

1. **`memtest.fth`** — the ROM already ships a `.fth` *source* file as a dropin
   (`cpu/x86/pc/biosload/ofw.bth:151`). Our vocabularies are the same kind of
   thing, so this is a precedent, not an experiment.
2. **`probe-`** — a *startup-hook* dropin is already present and firing, which
   proves the hook machinery is live in this build rather than merely present in
   the source.

`ofw/core/ofwcore.fth:4614` documents the full hook set — `cpu-devices±`,
`nvramrc±`, `probe±`, `banner±`, `test±`, `boot±` — with a defined execution
order, and `do-drop-in` executes them.

Adding one is **a single line** in the flavor's build script, next to the
existing manifest (`cpu/x86/pc/emu/emuofw.bth:49-72`):

```forth
   " ${BP}/…/ofdiag.fth"     " ofdiag.fth"   $add-deflated-dropin   \ B1
   " ${BP}/…/autotrace.fth"  " boot-"        $add-deflated-dropin   \ B2
```

### B1 — a *named* dropin (safe, no behaviour change)

Ship `ofdiag.fth` as `ofdiag.fth`. It does not auto-run; you load it with
`fload /dropin-fs:\ofdiag.fth` — **the vocabulary lives in the ROM and needs no
CD, no floppy, no staged media at all.** Nothing about the firmware's behaviour
changes for anyone who doesn't ask for it.

This is worth doing on its own merits, independent of autoboot tracing: it would
delete the entire media-staging step for the emu flavor, and on the coreboot
flavor it would sidestep the `allocate-dma` bootstrap problem entirely, because
`/dropin-fs` is not a disk and needs no `deblocker`.

### B2 — a `boot-` dropin (true autoboot tracing)

Ship a tiny `autotrace.fth` as `boot-`. It fires immediately before
`do-auto-boot`, so the autoboot itself is traced — the gap closes completely.

⚠️ **This changes the ROM's behaviour for every consumer**, including the sister
lab, whose smokes and showcase are verified against the current boot output.
Extra `#T` lines on every boot would be a silent, cross-lab regression. So B2
must build to an **isolated output**, the way the coreboot track already isolates
itself with `DOTCONFIG=`/`obj=`, rather than overwriting the shared
`emuofw.rom`. That isolation — not the dropin — is the real work.

## Option C — bake the words into the firmware image

`fload` the vocabulary from `config.fth` at build time, so the words are in the
dictionary from power-on. The sister lab already patches `config.fth` for this
flavor (`create resident-packages`), so the pattern is proven.

Rejected as the primary route: it changes the **dictionary itself**, which is the
thing [`probe-dictionary.sh`](probe-dictionary.sh) measures and the README
reports as 22-of-23. A lab whose audit is one of its teaching artifacts should
not quietly move the baseline it audits. B1 gets the same media-free convenience
without touching the dictionary.

## Outcome

```console
$ ./build-dropin-rom.sh --boot-hook
==> dropin manifest now carries:
    76:   " ${BP}/labdsl/ofdiag.fth"    " ofdiag.fth"  $add-deflated-dropin
    77:   " ${BP}/labdsl/ofscope.fth"   " ofscope.fth" $add-deflated-dropin
    79:   " ${BP}/labdsl/autotrace.fth" " boot-"       $add-deflated-dropin
==> /home/…/autotrace-emuofw.rom
==> guard OK: the sister lab's emuofw.rom is untouched
```

and, with nothing typed and no media attached:

```
Install console
#T autotrace armed (boot- dropin)
Type any key to interrupt automatic startup
6 5 4 3 2 1
#T open disk
Boot device: /pci/ethernet  Arguments:
#T open /pci/ethernet
Can't open boot device
```

Two things confirmed only by building it:

- **`execute-buffer` sniffs the first byte** (`0xf0-0xf3`/`0xfd` = FCode) and
  otherwise evaluates the buffer as **Forth text** — so a `.fth` source dropin is
  a first-class startup hook, which is why the flavor's own `probe-` hook can be
  `builton.fth`.
- **A warm reboot is not traced.** `auto-boot`'s `reboot?` branch takes an early
  `exit` *before* `" boot-" do-drop-in`, so the hook covers the **cold** autoboot
  only. Noted in `dsl/autotrace.fth` where it will actually be read.

The isolation turned out to be the whole job, exactly as predicted: a separate
tree clone, its own output ROM, and a sha-guard on the sister lab's artifact.

## Recommendation (as originally reasoned)

| | verdict | cost |
|---|---|---|
| **A** nvramrc | **dead here** (no NVRAM), correct on real hardware | — |
| **B1** named dropin | **do this** — media-free loading, zero behaviour change | 1 build line + a rebuild |
| **B2** `boot-` dropin | **do this second** — closes the gap properly | 1 build line + **isolated ROM output** |
| **C** bake into image | avoid | moves the audited dictionary |

**B1 then B2**, with B2's build isolated. The honest scope note is that neither is
free: both need the sister lab's build re-run, and B2 needs an isolation scheme so
a shared, already-verified ROM does not change underneath another lab.

## What is verified vs. designed

**Verified on this host:** NVRAM is unwritable (`setenv` fails, `use-nvramrc?`
stays `false`); `/dropin-fs` exists and lists its contents; `memtest.fth` ships as
a Forth-source dropin; a `probe-` startup-hook dropin is present in the running
ROM; `" boot-" do-drop-in` sits immediately before `do-auto-boot` in
`bootparm.fth:345`; the build-time idiom is `$add-deflated-dropin` in the
flavor's `.bth`.

**Since built and verified:** both dropin variants, the isolated build, and the
sha-guard. `smoke-dsl.sh dropin` and `smoke-dsl.sh autotrace` are the standing
proofs. The remaining honest limit is the warm-reboot path above.
