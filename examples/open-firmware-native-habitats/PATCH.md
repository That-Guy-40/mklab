# PATCH.md — implementing 7.5.3.3, and getting boot tracing out of it

Increment 1 ended with a wall. The x86 sibling's boot tracers install themselves
by re-pointing hooks OFW *ships* — `defer ?show-device`, `load-started`,
`load-done`. OpenBIOS declares **no `defer` anywhere on its boot path**, so
there was nothing to re-point, and the tracers were listed as unportable.

The standard has a second answer, and OpenBIOS ships it empty:

```text
0 > see patch
: patch
  ;
 ok
```

So this increment wrote it. **`dsl/patch.fth`, ~90 lines of Forth, no C, no
firmware build** — and because OpenBIOS's dictionary format is identical across
its targets, the same file runs unmodified on the SPARC and PowerPC tracks.

## What a colon definition actually looks like

Learned from the firmware's own decompiler (`forth/debugging/see.fs`), which is
the authoritative walker — if `patch` and `see` disagree, `patch` is wrong:

```text
xt - cell   link field       lfa2name turns this into the word's name
xt          TYPE CODE        1 colon · 3 constant · 4 variable · 5 defer · else primitive
xt + cell   the body         a run of cells, each an xt, ending at ['] (semis)
```

Verified directly, rather than taken on faith. `: target zap zap ;` dumps as:

```text
0 > ' target rawdump
ffd3a19c ffd3a19c ffd1d010 ...
   zap      zap    (semis)
0 > ' zap u. cr
ffd3a19c
```

## The part that makes it more than a memory scan

Some xts carry **inline data** in the cells that follow them, and stepping over
it is the whole correctness problem:

| xt | inline cells | what they hold |
|---|---|---|
| `do?branch` · `dobranch` | 1 | a branch target |
| `(lit)` | 1 | the literal |
| `(while)` · `(repeat)` | 2 | loop bookkeeping |
| `(")` | data-dependent | a count cell, then the string, then padding to alignment |

A naive "scan every cell for old-xt and replace it" would happily overwrite a
branch offset, or a literal that merely happens to hold the same bit pattern —
and the damage would not surface until the patched word ran.

`/body-item` therefore steps item-by-item, mirroring `see.fs` arm for arm. The
`(")` arithmetic is the fiddly one: the next item begins at
`aligned(adr + len) + 2 cells`.

### The negative control

`smoke-habitat.sh patch` builds that booby trap deliberately. It creates a word
holding **a literal whose value is exactly the xt being replaced**:

```text
0 > : t4 zap 12345 drop zap ;
0 > ' zap true 12345 true ' t4 (patch)     ← literal mode: set the literal to ' zap
0 > see t4
: t4
  zap ( lit ) h# ffd3a788  drop zap
  ;
0 > patch zip zap t4
patch: 2 occurrence(s) replaced             ← 2, not 3
0 > see t4
: t4
  zip ( lit ) h# ffd3a788  drop zip         ← the literal survived untouched
  ;
0 > ' zap u. cr
ffd3a788                                    ← it really is the same bit pattern
```

**2, not 3.** A memory scanner reports 3 and corrupts the literal. That number is
the assertion the smoke makes, and its failure message says exactly what a 3
would mean.

## The trap that cost a debugging session

The first functional test patched `bb` for `aa` inside a word visibly built from
`aa`, and reported:

```text
0 > patch bb aa target
patch: 0 occurrence(s) replaced
```

`patch` was right and the test was wrong. **The base here is hex**, so `aa` and
`bb` are perfectly good numbers — 170 and 187 — and `patch-parse` tried
`$number` before `$find`. It had gone looking for the *literal* 170.

Plenty of plausible Forth names are hex: `aa`, `bb`, `dead`, `beef`, `face`,
`add`, `cafe`. So `patch-parse` now **looks the word up first** and falls back to
a number only when no such word exists. The reverse order means you can never
patch a word whose name happens to be hex-ish, which is far more surprising than
the alternative.

A second, smaller version of the same lesson: `1` is **not** a literal here.

```text
0 > : t  1 drop ;      0 > ' t rawdump
ffd1d630 ...           ← one cell, and ' 1 resolves to it
0 > : t3  12345 drop ; 0 > ' t3 rawdump
ffd1d020 12345 ...     ← (lit) followed by the value
```

OpenBIOS predefines small integers as **words**. An early "literal" test was
therefore not testing a literal at all, which is why the real negative control
above uses `12345`.

## The tracers

With `patch` in hand, `dsl/tracers.fth` instruments two call sites at different
depths — neither of which the firmware's author provided a hook for:

```forth
: t-open-dev  ( path$ -- ihandle )  ." #T open " 2dup type cr  open-dev ;
: t-load      ( path$ -- )          ." #T load-begin" cr  $load  ." #T load-end" cr ;

: trace-boot
   ['] t-open-dev false  ['] open-dev false  ['] $load  (patch)   \ inside $load
   ['] t-load     false  ['] $load    false  ['] boot   (patch)   \ inside boot
;
```

No recursion hazard: `patch` rewrites call sites inside *one named word*, so
`t-open-dev`'s own reference to `open-dev` is untouched.

**`untrace` is the same patch with the arguments exchanged.** That is not
tidiness — a tracer you cannot remove is a bug, and proving the firmware returns
to silence is how you know you *measured* the boot rather than *changed* it. The
smoke asserts both directions.

## The payoff: the power-on autoboot traces itself

`nvramrc` is evaluated **before `probe-all`**, so a script that installs the
tracers there has rewritten the call sites before the firmware has probed a
single device. `stage-dsl.sh` builds exactly that — patch + tracers + `trace-boot`
as one 2232-byte NVRAM line — and then, with **nothing typed and no hook in the
firmware**:

```text
>> CPU type PowerPC,750
(patch) isn't unique.                       ← the firmware notices us shadowing its stubs
patch isn't unique.
patch loaded: patch (patch) patch-count inline-cells /body-item
tracers loaded: trace-boot untrace t-open-dev t-load
#T tracing ON, 2 call site(s) rewritten     ← armed, pre-probe
Welcome to OpenBIOS v1.1 built on Apr 22 2026 09:24
Trying hd:,\\:tbxi...
Trying hd:,\ppc\bootinfo.txt...
Trying hd:,%BOOT...
#T load-begin                               ← the POWER-ON autoboot, traced
#T open
#T load-end
```

Byte-for-byte the same on sparc32, from the same staged script. This is the
direct counterpart of the x86 lab's `banner-` dropin autotrace — reached there
by rebuilding the ROM, reached here by writing a config variable.

`#T open` has an empty path, incidentally, and that is honest: `(find-bootdevice)`
on a machine with no disk hands `$load` an empty string.

## Honest limits

- **This shadows the stubs; it does not replace them.** Our `patch` is a new
  dictionary entry that wins by search order — the firmware says so itself with
  `patch isn't unique.` Anything already compiled against the stub still calls
  the stub. Nothing on the boot path does, so the tracers work; but a real fix
  belongs in `forth/debugging/firmware.fs`, which is where an upstream patch
  would put it.
- **`patch` refuses to exchange a word for a literal** (or the reverse). Those
  occupy different numbers of cells, so it cannot be done in place without
  rewriting the whole body. It reports and declines rather than corrupting.
- **`.calls` is still a stub.** The dictionary walk `patch` now has is most of
  what a cross-referencer needs — "which words' bodies mention this xt" is the
  same scan run over every word instead of one. That is the obvious next thing
  this file makes cheap.
- **Not sent upstream.** It is written to be sendable — no lab-specific
  assumptions, no arch conditionals — but nobody has filed it.
