# PORTING.md — what travelled from the x86 lab, what didn't, and what turned out to be a stub

The sibling lab, [`open-firmware-debugs-itself`](../open-firmware-debugs-itself/README.md),
wrote three Forth vocabularies against **OFW** — Bradley's implementation,
frozen in 2015. This lab runs **OpenBIOS** — an independent reimplementation of
the same standard, C-hosted, still maintained. Same spec, different code.

The plan predicted the vocabularies would port *"as a design, not verbatim"*.
That held, and the split was sharper than expected: the **diagnosis ladder**
ported almost unchanged, and the **tracers** could not port at all.

## What ported unchanged

Four words carry contracts identical to OFW's, which is the whole reason a port
was viable:

| word | OpenBIOS source | contract |
|---|---|---|
| `expand-alias` | `forth/device/pathres.fs:14` | `( alias$ -- expansion$ expanded? )` |
| `find-package` | `forth/device/package.fs` | `( name$ -- phandle true \| false )` |
| `open-dev` | `forth/device/pathres.fs` | `( path$ -- ihandle \| 0 )` — returns 0, does **not** throw |
| `left-parse-string` | `forth/device/package.fs:211` | `( str$ char -- rest$ head$ )` |

Because `open-dev` returns 0 rather than throwing, the three-way discriminator
is free here too: **no `catch` anywhere in the ported ladder**, exactly as on
x86.

`expand-alias` even carries the *same trap*, and the x86 lab's comment about it
is reproduced verbatim in `dsl/ofdiag.fth` because it is still true: **the flag
means "an alias WAS expanded", not "success"**. A full pathname legitimately
comes back `false` with the string untouched, and treating that as failure makes
every input misreport as `OFDIAG-1`.

`boot-device` also ports: OpenBIOS exposes config variables as words pushing
`( -- str len )` (`forth/admin/nvram.fs`, `is-config-word`), the same shape OFW
gives them, so `why-no-boot`'s list walk is character-for-character the x86 one.

## What the habitats forced: a fifth rung

On x86 `boot-device` is `disk net` — bare names. In the native habitats **every
entry carries device arguments**:

```text
Sun     disk:a disk
Apple   hd:,\\:tbxi   hd:,\ppc\bootinfo.txt   hd:,%BOOT
```

Alias lookup must therefore see the **head only**, or every real-world entry
misdiagnoses as "no such devalias". Hence a new word:

```forth
: dev-head  ( dev$ -- head$ )
   ascii : left-parse-string  2swap 2drop
;
```

This relies on a detail of `forth/lib/split.fs`: when the delimiter is absent,
`left-split` hands back the **whole string** as the left part — which is exactly
what a bare `disk` needs, so the same word serves both cases.

One further adaptation: the ported `diag-open` calls `open-dev` on the **full
entry, arguments and all**, where the x86 version opened the resolved path. On
x86 those were the same string. Here `:a`, `,\ppc\bootinfo.txt` and `%BOOT` are
precisely what the open method acts on.

## What could not port — and was rebuilt instead: the tracers

The x86 `ofdiag` installs boot tracers by re-pointing hooks the firmware ships:

```forth
['] t-show-device to ?show-device      \ OFW: bootparm.fth declares these
['] t-load-started to load-started     \ as `defer` pass-throughs on the
['] t-load-done   to load-done         \ boot path
```

**OpenBIOS declares no `defer` anywhere on its boot path.** The complete list of
`defer`s in `forth/` is display/framebuffer primitives, `find-dev`,
`init-fcode-table`, `emit`/`key`, `reset-all`, `power-off`, `status`,
`outer-interpreter`, and the DMA hooks. Nothing in `$load`, nothing in `boot`,
nothing around `open-dev`. There is nothing to re-point.

That is a real divergence between two implementations of one standard, and it is
worth stating plainly: **OFW ships its tracepoints; OpenBIOS does not.**

The standard's own answer to this is `patch` (7.5.3.3) — which OpenBIOS also
ships empty, so [increment 2](PLAN.md) implemented it. See
**[PATCH.md](PATCH.md)**: `dsl/patch.fth` rewrites the *call site* rather than
re-pointing a hook, so `dsl/tracers.fth` can instrument **any** call in **any**
colon definition — including two the firmware's author never anticipated:

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

Arguably this ends up *stronger* than what it failed to port: OFW's tracers work
only where OFW's author placed a `defer`. These work anywhere.

## The debugging chapter is largely unimplemented

Spike 0 probed the dictionary with the x86 lab's tick idiom (`' <word> .` — look
up without executing) and reported **11 of 11 words present**. That was an
over-report. A tick proves a *name resolves*; it says nothing about behaviour.
`see` — which OpenBIOS *does* implement, properly — says the rest:

```text
0 > see patch
: patch
  ;
 ok
0 > see .calls
: .calls
  ;
 ok
0 > see dl
: dl
  ;
 ok
```

| word | 1275 section | OpenBIOS |
|---|---|---|
| `dl` | 7.5.2 serial download | **empty stub** — `forth/debugging/firmware.fs:23` |
| `.calls` | 7.5.3.1 cross-reference | **empty stub** |
| `$sift` · `sifting` | 7.5.3.1 | **empty stubs** |
| `patch` · `(patch)` | 7.5.3.3 | **empty stubs** |
| `nvedit` · `nvstore` · `nvquit` · `nvrecover` · `nvrun` | 7.4.4.2 the script editor | **empty stubs** — `forth/admin/script.fs` is nine no-ops |
| `see` · `(see)` | 7.5.3.2 decompiler | **implemented** (`forth/debugging/see.fs`) |
| `words` · `dump` · `debug` | | implemented |

The x86 lab's headline was *"the toolbox was in the box"* — 22 of 23 audited
words reachable, an assembler in a 512 KiB ROM. **Here the box has labelled
compartments and several are empty.** The two implementations made opposite
bets: OFW is a self-hosting Forth that grew every debugging convenience its
author wanted; OpenBIOS is a C kernel that implements what QEMU's boot paths
exercise daily, and 7.5's debugging chapter is not on that path.

This is why the sibling lab's `stepper` and `stepper-deep` smokes have no
counterpart here yet, and why the tracers are listed as future work in
[PLAN.md](PLAN.md) rather than shipped: **the mechanism they need would have to
be written first**, not merely adapted. `patch` is ~10 lines of Forth over a
dictionary OpenBIOS already knows how to decompile, so this is an opportunity
rather than a wall — but it is honest work, not a port.

## `see` works, but is rougher than OFW's

It decompiles; the control-flow reconstruction is approximate. The real
`expand-alias` (`forth/device/pathres.fs:14`) against what `see` recovers:

```forth
\ source                                    \ see
: expand-alias ( a$ -- e$ expanded? )       : expand-alias
  2dup                                        2dup " /aliases" find-dev 0= if
  " /aliases" find-dev 0= if 2drop            2drop false exit get-package-property if
    false exit then                             false then
  get-package-property if                       2swap 2drop dup if
    false                                       1- true
  else                                        ;
    2swap 2drop  dup if 1- then
    true
  then
;
```

Every token is there and in order; the `if`/`else`/`then` nesting and
indentation are not recoverable from the threaded code. Readable, and enough to
answer "what does this actually do" — which is what it is for.

## Portability summary

| from the x86 lab | status here |
|---|---|
| `ofdiag` diagnosis ladder | **ported**, + one rung for device arguments |
| `ofdiag` tracers | **cannot port** — no `defer` on the boot path; needs `patch` implemented first |
| `ofscope` `pci-map` | **not yet** — PPC has PCI, sun4m is SBus; and OpenBIOS has no `config-l@` |
| `ofscope` `mem-map` / `region-diff` | **likely** — `/memory` + `decode-int` + `alloc-mem` all exist |
| `nopage.fth` | **not needed** — no pager fights the driver here |
| the smoke harness *shape* | **ported fully** — one verdict, EXIT-trap net, SKIP=77, `--echo-gate` |
| the socket-driven `boot_and_drive` | **cannot port** — `-serial unix:` yields zero bytes; pty only |
