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

Two dropin hooks are candidates, and the difference between them turned out to
matter. `ofw/core/banner.fth:141`, the first act of `banner()`:

```forth
: banner  ( -- )
   auto-banner?  if  " banner-" do-drop-in  then     ← option B — CHOSEN
```

and, nearer the boot, `ofw/core/bootparm.fth:345`:

```forth
: auto-boot  ( -- )
   reboot?  if  ...  safe-evaluate  exit  then       ← ⚠ early exit on a REBOOT
   " boot-" do-drop-in                               ← so this hook has a hole
   do-auto-boot
   " boot+" do-drop-in
```

`boot-` fires closest to the boot, but `auto-boot`'s `reboot?` branch returns
*before* reaching it, so a warm reboot slips past. `banner` is called from
`startup` before `auto-boot` on **every** path, so `banner-` has no such hole.

## Option A — `nvramrc` · dead on the **stock** ROM, since **REVIVED**

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
tried `setenv boot-device` and had to repair a `devalias` instead.

**Correction (was: "a missing peripheral in this firmware build").** That reading
was wrong, and source archaeology says so. Nothing is missing: it is a *disabled
config switch*, and the driver ships in-tree.

- The whole confvar stack **is compiled in** — `cpu/x86/basefw.bth:58` floads
  `ofw/confvar/loadcv.fth`, which pulls `conftype`, `nvramrcg`, `nvalias`,
  `nvcache` and `nameval`. Parser, cache, name=value encoder, persistent
  devaliases: all present.
- What is absent is only the **backing store**. `ofw/core/ofwcore.fth:236` declares
  `defer nv-c@` / `defer nv-c!`, and the emu flavor assigns neither — it floads
  neither `cpu/x86/pc/nullnv.fth` nor `cpu/x86/pc/biosload/filenv.fth`.
- **The two error messages are one cause.** `nvram-node` stays 0, so
  `" size" nvram-node $call-method` hits `no-proc` (`ofwcore.fth:2111`) →
  *Unimplemented package interface procedure*; and `config-size`/`config-mem`
  stay 0 (`nvcache.fth:18-19`), so `cv-area` is a **zero-length region** and
  `add-ge-var` returns −1 → *Out of NVRAM environment space*
  (`nameval.fth:158`). One unbound defer, reported by two layers.
- **The enablement already ships**, commented out. `cpu/x86/pc/emu/config.fth`
  carries `\ create pseudo-nvram`, and `cpu/x86/pc/emu/devices.fth:176` holds the
  complete `[ifdef] pseudo-nvram` block — `filenv.fth`, a `/file-nvram` node, and
  a `stand-init:` that opens it and calls `init-config-vars`.

It is a deliberate platform judgment, in the author's own prose in `config.fth`:
generic PCs *"have no good place to store those configuration variables, as the
CMOS RAM is too small for typical string-valued variables"* — unlike SPARC (a
dedicated NVRAM/TOD chip) or PPC (`/pci@80000000/mac-io@10/nvram@60000`). So
`use-null-nvram` is the shipped default and `pseudo-nvram` — a file on a writable
drive — is the emulator-only alternative.

This is the same structure as UEFI: OVMF splits into `OVMF_CODE.fd` +
**`OVMF_VARS.fd`** precisely so variables get a writable pflash store. EFI
variables work on x86 not for architectural reasons but because *someone attached
a writable device*. `pseudo-nvram` is the identical move.

On real OFW hardware (Sun, OLPC, PowerPC Macs) `nvramrc` is the correct answer and
needs no rebuild at all. See [`NVRAM-ON-X86.md`](NVRAM-ON-X86.md) for the
experiment that enables it here.

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
   " ${BP}/…/autotrace.fth"  " banner-"      $add-deflated-dropin   \ B2
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

### B2 — a `banner-` dropin (true autoboot tracing)

Ship a tiny `autotrace.fth` as `banner-`. It fires before `auto-boot` on every
path, so the autoboot itself is traced — the gap closes completely.

(It was originally written as `boot-`, which is nearer the boot and reads better,
until the `reboot?` early exit above showed that hook cannot see a warm reboot.
`banner-` arms slightly earlier, which is only more coverage.)

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
    80:   " ${BP}/labdsl/autotrace.fth" " banner-"     $add-deflated-dropin
==> /home/…/autotrace-emuofw.rom
==> guard OK: the sister lab's emuofw.rom is untouched
```

and, with nothing typed and no media attached:

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

Two things confirmed only by building it:

- **`execute-buffer` sniffs the first byte** (`0xf0-0xf3`/`0xfd` = FCode) and
  otherwise evaluates the buffer as **Forth text** — so a `.fth` source dropin is
  a first-class startup hook, which is why the flavor's own `probe-` hook can be
  `builton.fth`.
- **`boot-` has a hole; `banner-` does not.** `auto-boot`'s `reboot?` branch
  takes an early `exit` *before* `" boot-" do-drop-in`, so a warm reboot would
  slip past it. The dropin therefore hooks **`banner-`** (`banner.fth:141`), and
  `startup` calls `banner` before `auto-boot` on every path. Arming happens a
  little earlier — strictly more coverage, no downside.
- **The reboot path is unreachable on the stock build.** `reboot?` comes only
  from the NVRAM variable `reboot-command` (`ofw/core/reboot.fth`), and no NVRAM
  store is bound here (`$setenv` → *Unimplemented package interface procedure*).
  Closed by construction on the stock ROM — but *not* permanently: see
  [`NVRAM-ON-X86.md`](NVRAM-ON-X86.md), which enables the in-tree `pseudo-nvram`
  store and makes `reboot-command` settable.

The isolation turned out to be the whole job, exactly as predicted: a separate
tree clone, its own output ROM, and a sha-guard on the sister lab's artifact.

## Recommendation (as originally reasoned)

| | verdict | cost |
|---|---|---|
| **A** nvramrc | dead on the **stock** ROM; **revived** by `build-nvram-rom.sh` | 3 edits + a rebuild |
| **B1** named dropin | **do this** — media-free loading, zero behaviour change | 1 build line + a rebuild |
| **B2** `banner-` dropin | **do this second** — closes the gap properly, reboot path included | 1 build line + **isolated ROM output** |
| **C** bake into image | avoid | moves the audited dictionary |

**B1 then B2**, with B2's build isolated. The honest scope note is that neither is
free: both need the sister lab's build re-run, and B2 needs an isolation scheme so
a shared, already-verified ROM does not change underneath another lab.

## What is verified vs. designed

**Verified on this host:** NVRAM is unwritable **on the stock ROM** (`setenv`
fails, `use-nvramrc?` stays `false`) because no store is bound to `nv-c@`/`nv-c!`,
not because the machinery is absent — the confvar stack is fully compiled in
(`cpu/x86/basefw.bth:58`) and the `pseudo-nvram` store ships commented out
(`cpu/x86/pc/emu/config.fth`, `devices.fth:176`); `/dropin-fs` exists and lists
its contents; `memtest.fth` ships as
a Forth-source dropin; a `probe-` startup-hook dropin is present in the running
ROM; `" boot-" do-drop-in` sits immediately before `do-auto-boot` in
`bootparm.fth:345` (with a `reboot?` early exit ahead of it) while
`" banner-" do-drop-in` is the first act of `banner()` in `banner.fth:141`; the
build-time idiom is `$add-deflated-dropin` in the flavor's `.bth`.

**Since built and verified:** both dropin variants, the isolated build, and the
sha-guard. `smoke-dsl.sh dropin` and `smoke-dsl.sh autotrace` are the standing
proofs.

**Not demonstrable on the stock ROM:** the warm-reboot path itself. `banner-`
removes the blind spot *in the code*, but the stock ROM can never take that path —
`reboot?` is set only from the NVRAM variable `reboot-command`
(`ofw/core/reboot.fth`) and no NVRAM store is bound, so the write fails:

```
ok " testcmd" " reboot-command" $setenv
Unimplemented package interface procedure
ok " reboot-command" $getenv .
ffffffff                                  \ OFW's true == failure
```

**NOW DEMONSTRABLE — and the reason was not the one written above.**
[`NVRAM-ON-X86.md`](NVRAM-ON-X86.md) closed it, and in doing so corrected this
section twice over:

1. NVRAM is enable-able (three edits, `build-nvram-rom.sh`), so `reboot-command`
   persists across a cold power cycle.
2. **That alone did not close the gap.** The emu flavor defines its *own* `startup`
   (`cpu/x86/pc/emu/fw.bth:288`) which — unlike the generic
   `ofw/core/startup.fth:16` — never calls `copy-reboot-info`, the only writer of
   `reboot?`. So the branch was dead code here *independently of NVRAM*.

With both (`build-nvram-rom.sh --reboot-hook`):

```
Rebooting with command: .( WARM-REBOOT-TAKEN ) cr
WARM-REBOOT-TAKEN
```

and no countdown and no `Boot device:` — `auto-boot` took the early `exit` before
`" boot-" do-drop-in`, exactly as `bootparm.fth:330` reads. `smoke-nvram.sh reboot`
runs **both arms**, asserting the NVRAM-only ROM does *not* take the branch; that
control is what proves the two causes independent.

This retroactively confirms hooking **`banner-`** over `boot-`: the `reboot?` early
exit is real, reachable, and now observable rather than merely argued from source.
