# Driving the type layer by hand — `0 >` on both arches

A **hands-on** walkthrough of [`dsl/struct.fth`](dsl/struct.fth): draw on the VGA
text buffer through a typed layout, parse a real ELF64 header (or an ELF32), walk
its program-header table, author a header the *host's* `readelf` can read — and
then reach for the device-register end of the DSL: set and clear individual bits
without disturbing their neighbours (Part 8), and hide the whole read-modify-write
behind a named control that reads as English (Part 9).

This is not [`MANUAL_TESTING.md`](MANUAL_TESTING.md), which is the **record** of
what has been run, and it is not the `struct-*` / `elf-methods` / `rmw-fields`
smoke tracks, which run the same ground automatically and grade it. This is the
version you type yourself.

Parts 1–2 are the VGA and the arch trap; Parts 3–7 are ELF inspection and
authoring; §10a adds the second ELF class; **Parts 8 and 9** are the
register-write end — mudge's `light-on` idiom (Phrack 53:9, 1998; see
[`upstream-tutorial/`](upstream-tutorial/)) generalised into `t-set`/`t-clr`/`t-tog`
and then into named `control:` verbs.

**Both arches, on purpose.** Part 2 is the one worth doing even if you skip the
rest: the identical VGA code that works on `amd64` **silently does nothing** on
x86, reads back a perfect answer anyway, and only an observer outside the
firmware can tell you so. **Then you fix it** — the translation is derivable at
the prompt, and x86 paints exactly as amd64 does.

Every output below was measured on 2026-08-30. Where the two arches differ, both
are shown.

---

## 1. Before you start

Build both firmwares — a few seconds each once the container is warm:

```bash
cd examples/openbios-the-rival-that-shipped
./build-openbios.sh amd64
./build-openbios.sh x86
```

Stage a CD carrying the type layer and something to parse. The ELF you'll parse
is **the amd64 firmware's own boot image** — a real ELF64, and one you can check
against `readelf` on this machine. §10a also parses an **ELF32**, which has to be
padded first (a bare ELF32 cannot be `load`ed — §10a says why), so stage that
here too:

```bash
W=${OPENBIOS_WORKDIR:-$HOME/openbios-lab}
mkdir -p "$W/typelayer"
cp dsl/struct.fth                          "$W/typelayer/STRUCT.FTH"
cp dsl/elf.fth                             "$W/typelayer/ELF.FTH"
cp dsl/elf32.fth                           "$W/typelayer/ELF32.FTH"
cp "$W/openbios/obj-amd64/openbios.multiboot" "$W/typelayer/SUBJ.ELF"
python3 - "$W/openbios/obj-amd64/openbios-builtin.elf32" \
          "$W/typelayer/EMBED32.BIN" <<'PY'
import sys
open(sys.argv[2], 'wb').write(b'\0' * 512 + open(sys.argv[1], 'rb').read())
PY
genisoimage -quiet -o "$W/typelayer.iso" -V TYPELAYER -r -J "$W/typelayer"
```

Keep a second terminal open for host-side ground truth:

```bash
readelf -h "$W/openbios/obj-amd64/openbios.multiboot"
```

---

## 2. Four rules for this prompt

Read these once. Three of them have cost this lab real time.

1. **The number base is HEX.** `40` is 64. `7d0` is 2000. No `0x` prefix.
2. **The prompt prints the STACK DEPTH, not a version.** `0 > ` means the stack
   is empty. If you see `2 > `, you left two things behind — type `clear`.
   **One exception:** part-way through a colon definition the line ends in
   ` compiled` instead of ` ok` and the digit reflects the *compiler's* state,
   not yours. `5 > ` there is normal — finish the definition; do **not** type
   `clear`, which would abandon it.
3. **The serial console has NO flow control.** A pasted line loses its tail
   *silently*. **Type the lines, or paste them one at a time and slowly.** Every
   line below is kept under 80 characters for this reason.
4. **`load` always lands at `load-base`.** Loading the parser and then the
   subject overwrites the parser. Always `evaluate` `struct.fth` **before**
   loading an ELF.

---

## 3. Boot, and load the layer

```bash
OPENBIOS_CDROM=$W/typelayer.iso OPENBIOS_DISPLAY=gtk ./run-openbios-qemu.sh amd64
```

`OPENBIOS_DISPLAY=gtk` opens a QEMU window — you need it to *see* Part 1. On a
headless box use `OPENBIOS_DISPLAY=none` and take a screenshot from the monitor
instead (Part 2 explains how). The `0 >` prompt stays on your terminal either
way.

- **Ctrl-A C** switches between the Forth prompt and the QEMU monitor.
- **Ctrl-A X** quits.

At the prompt — **two files, in this order**:

```forth
load /ide@1/cdrom@0:\struct.fth
load-base load-size evaluate
load /ide@1/cdrom@0:\elf.fth
load-base load-size evaluate
load /ide@1/cdrom@0:\elf32.fth
load-base load-size evaluate
```

The `load`s print some `Probing for …` chatter and a `Path=`; the `evaluate`s
just say ` ok`.

**Why three files.** `struct.fth` is the **engine** — `field:`, `t@`, `t!`,
`array:`, `>virt`, `chk`, `dump` — and mentions no format at all. `elf.fth` is
**one format** on top of it: the ELF64 layouts, the constraints and the methods.
`elf32.fth` is **the other ELF class**, and it is **optional** — without it
everything still works on an ELF64 and refuses an ELF32 *by name* rather than
misreading it. That is GNU poke's own split (`elf-64.pk` is not part of
`libpoke`), and it means a different format is a different file, not a fork of
the engine.

With `elf32.fth` loaded, the generic words — `?elf`, `.elf`, `.phdrs`,
`.sections`, `elf-load-base`, `vaddr>off`, `sh-name` — **read `e_class` and pick
the right half**. You do not choose; the file does.

---

## 4. Part 1 — draw on the VGA text buffer (amd64)

The legacy text buffer is at `b8000`: 80×25 cells, **two bytes each** — a
character and an attribute. That is a structure, so declare it as one. The
fields are `dev-field:`, which reaches the bytes through IEEE 1275's
device-register words rather than plain memory ones:

```forth
struct 1 dev-field: vc-ch 1 dev-field: vc-attr constant /vga-cell
/vga-cell array: vcell[]
: cell-at ( i -- adr ) b8000 swap vcell[] ;
: putc ( ch attr i -- ) cell-at dup >r vc-attr t! r> vc-ch t! ;
: fill-screen ( ch attr -- ) 7d0 0 do 2dup i putc loop 2drop ;
```

Now paint. `41` is `A`; `1f` is white-on-blue (high nibble = background, low
nibble = foreground):

```forth
41 1f fill-screen
```

**The QEMU window turns blue and fills with `A`.** Some things to try:

```forth
20 4e fill-screen                          \ solid red screen (space on red)
48 1f 0 putc                               \ 'H' in the top-left cell
: abc 1a 0 do 41 i + 1f i putc loop ;      \ A..Z along the first row
abc
```

Read a cell back — through a *different* declaration, one 2-byte little-endian
device field over the same two bytes:

```forth
b8000 rw@ u.
```

```
1f41  ok
```

`41` in the low byte, `1f` in the high byte. The character and attribute you
wrote, in memory, in that order.

---

## 5. Part 2 — the same code on x86, why nothing happens, and how to fix it

Quit (**Ctrl-A X**) and boot the 32-bit firmware instead — `multiboot` is the
x86 flavour:

```bash
OPENBIOS_CDROM=$W/typelayer.iso OPENBIOS_DISPLAY=gtk ./run-openbios-qemu.sh multiboot
```

Type **exactly** the same five definitions from Part 1, then:

```forth
41 1f fill-screen
b8000 rw@ u.
```

```
1f41  ok
```

**The read-back is identical. The screen does not change.**

Now ask something that is not the firmware. **Ctrl-A C** for the QEMU monitor:

```
(qemu) xp /8xb 0xb8000
```

| arch | physical `0xb8000` |
|---|---|
| **amd64** | `0x41 0x1f 0x41 0x1f 0x41 0x1f 0x41 0x1f` — your pattern |
| **x86** | `0x20 0x07 0x38 0x07 0x30 0x07 0x38 0x07` — grey-on-black text, the console's own output |

**Ctrl-A C** goes back to Forth.

### What just happened

`arch/x86` relocates itself by rebasing the GDT, so **a Forth address is not a
physical address there**. `b8000` in the firmware's world is some other place in
RAM. The store landed there, and `rw@` read it back through the *same*
translation — so it agreed with itself perfectly and told you nothing.

`arch/amd64` does not relocate: the firmware sits at the 1 MiB a bzImage runs
at, so `b8000` really is the aperture.

**A type layer makes field access convenient. It does nothing whatsoever to make
an address correct.** That is the lesson, and it is why a write to a device has
to be graded by an observer that is not the writer.

### Now fix it

The offset is not a mystery, and you do not need to look it up. `arch/x86`
defines its `load-base` constant as `phys_to_virt(LOAD_BASE_PHYS)`, and
`phys_to_virt(P)` is `P - virt_offset`. Rearrange:

```
virt_offset = LOAD_BASE_PHYS - load-base
```

`struct.fth` ships that as `>virt` / `>phys` (and `load-base-phys`, the one
constant it has to know). Ask:

```forth
load-base u.
load-base-phys load-base - u.
b8000 >virt u.
b8000 >virt >phys u.
```

| | amd64 | x86 |
|---|---|---|
| `load-base` | `4000000` | `e0670bd0` |
| `virt_offset` | `0` | `1fd8f430` |
| `b8000 >virt` | `b8000` — the **identity** | `e0328bd0` |
| round trip | `b8000` | `b8000` |

On amd64 `>virt` is the identity, exactly as it must be for an arch that does
not relocate. On x86 it is a real translation. Only one word needs to change —
the array's base — but you have to **retype the two words that call it as well**:

```forth
: cell-at ( i -- adr ) b8000 >virt swap vcell[] ;
: putc ( ch attr i -- ) cell-at dup >r vc-attr t! r> vc-ch t! ;
: fill-screen ( ch attr -- ) 7d0 0 do 2dup i putc loop 2drop ;
41 1f fill-screen
```

> **Redefining `cell-at` on its own does nothing, and says nothing.** `:`
> resolves each called word **at compile time**, so the `putc` you already
> defined still calls the *old* `cell-at`, and `fill-screen` still calls the old
> `putc`. Retype only the first line and the screen stays exactly as it was —
> no error, no warning, `41 1f fill-screen` still answers ` ok`. Measured on
> x86: `xp /4xb 0xb8000` reads `0x30 0x07 0x20 0x07` (console text) after
> redefining `cell-at` alone, and `0x41 0x1f 0x41 0x1f` once all three are
> retyped. Forth redefinition is **not** retroactive — a caller keeps the
> callee it was compiled against.

**The x86 screen turns blue.** Check it from outside too — **Ctrl-A C**,
`xp /8xb 0xb8000`, and the pattern is there:

```
0x41 0x1f 0x41 0x1f 0x41 0x1f 0x41 0x1f
```

Measured: **201,285 blue pixels on both arches**, identical.

`virt_offset` is *derived every time*, never written down — it scales with the
image, and `arch/x86/context.c:189` still records `1fd8fe50` from a measurement
in August 2026 that this tree no longer matches. A cached address is a wrong
address waiting to happen.

You can see the same divergence in any field address:

```forth
load /ide@1/cdrom@0:\subj.elf
load-base e_machine t-adr u.
```

| arch | `e_machine`'s address |
|---|---|
| amd64 | `4000012` — `load-base` is `4000000`, and `e_machine` is at `+0x12` |
| x86 | `e0670be2` — a *virtual* address, and correct as one |

*(If you are on `OPENBIOS_DISPLAY=none`, `screendump /tmp/vga.ppm` at the monitor
gives you the same evidence as a picture.)*

---

## 6. Part 3 — parse a real ELF64

Back on **amd64**. If you have not already:

```forth
load /ide@1/cdrom@0:\subj.elf
```

`load` reads the whole file to `load-base` and stops. Nothing has interpreted
it — the bytes are just sitting there.

**Bind it once, then stop passing it around.** poke says
`var f = Elf64_File @ 0#B`; here it is a value:

```forth
load-base elf-at
```

**Now make it prove it is an ELF.** `?elf64` is GNU poke's field constraints
(§E1 of the review) as a Forth predicate — it *refuses* rather than describing
a file wrongly:

```forth
?elf64
```

Silence and ` ok` means every constraint held. You will see it bite in §9.

**Look at it.** Three words, the three views `readelf` is usually run for:

```forth
.elf
.phdrs
.sections
```

```
ELF64  entry=101d70  phnum=3  shnum=a  ehsize=40
idx type     flg offset   vaddr    filesz   memsz
  0 LOAD    RWX     1000  100000   20830   a17b0
  1 NOTE    R--     1020  100020      50      50
  2 t6474e551 RW-        0       0       0       0
idx name                 type      addr     offset   size
  0                     NULL            0       0       0
  1 .hdr                PROGBITS   100000    1000      20
  2 .note               NOTE       100020    1020      50
  3 .text               PROGBITS   100070    1070   1235f
  4 .rodata             PROGBITS   1123e0   133e0    5a7b
  5 .eh_frame           PROGBITS   117e60   18e60    4af4
  6 .data               PROGBITS   11c960   1d960    3e28
  7 .initctx            PROGBITS   1207a0   217a0      90
  8 .bss                NOBITS     121000   21830   807b0
  9 .shstrtab           STRTAB          0   21830      42
```

Those **names are read out of the file's own string table** — `.shstrtab` at
offset `0x21830` — not a list compiled into the firmware. `t6474e551` is
`PT_GNU_STACK`, a type the small name table does not carry; unknown values print
as `t<hex>` rather than being guessed at.

Compare any of it with `readelf -hlS` in your other terminal.

### The fields underneath

`elf64-ehdr` is a layout over the same bytes, and every field is still there
by name:

```forth
load-base e_magic t@ u.
load-base e_class t@ u.
load-base e_type t@ u.
load-base e_machine t@ u.
load-base e_entry-lo t@ u.
load-size u.
```

```
464c457f  ok        \ 7f 'E' 'L' 'F' read as a little-endian quad
2  ok               \ ELF64
2  ok               \ EXEC
3e  ok              \ x86-64
101d70  ok          \ entry point
21af8  ok           \ 137976 bytes
```

Compare with `readelf -h` in your other terminal. Every one matches.

**The header describes its own size, so the layout can check itself:**

```forth
load-base e_ehsize t@ u. /elf64-ehdr u.
```

```
40 40  ok
```

The left number is read out of the file; the right is what `struct.fth`
declared. If an offset in the layout ever drifts, the field that would catch it
moves too — so this equality is worth more than any constant.

**A refusal, on purpose.** `e_entry` is 8 bytes. Declared as a single 8-byte
field it works on amd64 and is *refused by name* on x86, because a 32-bit cell
cannot hold it and truncating would be a lie:

```forth
load-base x-entry t@ u.
```

| arch | result |
|---|---|
| amd64 | `101d70  ok` |
| x86 | `T-ERR-narrow-cell` then ` Aborted.` |

---

## 7. Part 4 — write a field

A field yields the **address** of its bytes, so a store through it *is* the
write. There is no "commit" step:

```forth
3f load-base e_machine t!
load-base e_machine t@ u.
```

```
3f  ok
```

You just edited an ELF header in memory. Prove it from outside — `t-adr` tells
you where to look (amd64 only, for the reason in Part 2):

```forth
load-base e_machine t-adr u.
```

then **Ctrl-A C** and `xp /2xb 0x4000012` (use whatever address it printed).

---

## 8. Part 5 — walk the program-header table

A table is an **array of a type**. The header says where it starts, how big each
entry is, and how many there are — so nothing here is a constant:

```forth
load-base load-base e_phoff-lo t@ + value phtab
load-base e_phnum t@ u. load-base e_phentsize t@ u.
```

```
3 38  ok
```

Three headers, `0x38` bytes each — and `0x38` is exactly what `/elf64-phdr`
declares. Now index into it:

```forth
phtab 0 phdr[] p_type t@ u. phtab 0 phdr[] p_filesz-lo t@ u.
phtab 1 phdr[] p_type t@ u. phtab 1 phdr[] p_offset-lo t@ u.
```

```
1 20830  ok         \ PT_LOAD, 0x20830 bytes in the file
4 1020  ok          \ PT_NOTE at offset 0x1020
```

`readelf -lW` on the host prints the same table.

### The methods — questions about meaning, not layout

Walking a table by hand is the *mechanism*. What you usually want is an answer,
and `elf.fth` carries GNU poke's two most useful ones (§E4):

```forth
elf-load-base u.        \ the lowest vaddr any PT_LOAD segment loads at
101d70 vaddr>off u.     \ which byte of the FILE becomes that address
```

```
100000 2d70  ok
```

The entry point `0x101d70` lives at file offset `0x2d70`. That second question —
*which bytes become that address* — is exactly what boot forensics asks, and it
is why the review rates these above everything else in `poke-elf`.

An address in no segment answers `-1`, not a plausible number:

```forth
7fff0000 vaddr>off u.       \ ffffffffffffffff
```

And the string table by index:

```forth
3 sh-name .cstr             \ .text
```

### Doing it by hand anyway

Something a table makes possible that a single field does not — a **derived**
answer over the whole traversal:

```forth
: loadsum 0 3 0 do phtab i phdr[] dup p_type t@ 1 = if
p_filesz-lo t@ + else drop then loop ;
loadsum u.
```

```
: loadsum 0 3 0 do phtab i phdr[] dup p_type t@ 1 = if  compiled
5 > p_filesz-lo t@ + else drop then loop ;  ok
0 > loadsum u. 20830  ok
```

Two things to notice in that transcript. The first line ends in **` compiled`**,
not ` ok` — the definition is unfinished. And the prompt then reads **`5 > `**,
which is rule 2's exception: that digit is the *compiler's* bookkeeping, not
stack you left behind. Finish the definition; do not `clear`.

Splitting a definition across lines is how you keep every line inside what the
console can survive. Forth does not care where the newlines fall.

---

## 9. Part 6 — make it refuse

A layout that only *describes* will describe a broken file just as confidently
as a good one. Break the header and watch `?elf64` stop:

```forth
0 @elf e_class t!
?elf64
```

```
CONSTRAINT: not ELF64 (e_class) -- want=2  got=0
 Aborted.
```

**Both values, and the operation did not complete.** "Constraint failed" on its
own would send you back to the prompt to work out which; and a message followed
by a return would be worse than no message at all — the review calls that the
LIED rung.

Others to try (each needs a fresh `load /ide@1/cdrom@0:\subj.elf` first, since
you just corrupted the copy in memory):

```forth
0 @elf e_magic t!       ?elf64      \ bad ELF magic
99 @elf e_ehsize t!     ?elf64      \ e_ehsize disagrees with the layout
2 @elf e_data t!        ?elf64      \ big-endian
```

That last one is worth reading. `elf.fth` declares byte order **per field**,
where GNU poke takes it from `ei_data` *at map time* — so a big-endian ELF64
would be silently misread here. Rather than let it through, the constraint says
so. **A limit you can see is a different thing from a bug.**

Write your own constraint the same way — the message is an ordinary string:

```forth
: ?x86-64  @elf e_machine t@ 3e s" not x86-64" chk ;
?x86-64
```

`chk` compares, `chk<` bounds, `chk?` takes any flag. poke's implication
`a => b` is just `a 0= b or` handed to `chk?`.

---

## 10. Part 7 — author a header, and let the host read it

The other direction. Build an ELF64 header from nothing, in a buffer, using only
`t!` — then hand the bytes to `readelf`.

```forth
40 alloc-mem value hdr
hdr elf64-new
?elf64
hdr u.
```

`elf64-new` zeroes `0x40` bytes and fills the fields **by name** with `t!` — and
then **the same `?elf64` that rejected the corrupted file in §9 accepts what you
just built.** One predicate, two subjects: that is the whole argument for having
a constraint rather than a comment.

Note the address `hdr u.` prints. Look at the bytes:

```forth
hdr 40 dump
```

```
   14c68: 7f 45 4c 46 02 01 01 00  00 00 00 00 00 00 00 00  |.ELF............|
   14c78: 02 00 3e 00 01 00 00 00  00 00 00 00 00 00 00 00  |..>.............|
   14c88: 00 00 00 00 00 00 00 00  00 00 00 00 00 00 00 00  |................|
   14c98: 00 00 00 00 40 00 38 00  00 00 40 00 00 00 00 00  |....@.8...@.....|
```

Change anything you like before saving it — every field is addressable:

```forth
401000 @elf e_entry-lo t!
3 @elf e_type t!            \ DYN instead of EXEC
```

**Ctrl-A C**, then save those 64 bytes — substituting the address `hdr` printed:

```
(qemu) pmemsave 0x14c68 0x40 "/tmp/authored.elf"
```

> **Quote the filename.** HMP parses that argument as an *expression*: unquoted,
> a path beginning with `/home` fails with `invalid char 'h' in expression` and
> writes nothing. (`screendump` takes a bare path; `pmemsave` does not.)

Back on the host:

```bash
readelf -h /tmp/authored.elf
```

```
ELF Header:
  Magic:   7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00
  Class:                             ELF64
  Data:                              2's complement, little endian
  Version:                           1 (current)
  Type:                              DYN (Shared object file)
  Machine:                           Advanced Micro Devices X86-64
  Entry point address:               0x401000
```

A structure authored at a firmware prompt, read back by the platform's own
binary-format tool. That is the "poke in the environment poke cannot reach" claim
with the loop closed at both ends.

Both of the edits you made after `elf64-new` are visible here: `readelf` reports
the entry point as `0x401000` and the type as **`DYN`**, because `3 @elf e_type
t!` is what you typed. `elf64-new` itself writes `2` (`EXEC`) — skip that one
line and this reads `EXEC (Executable file)` instead. Two `t!`s at a firmware
prompt, and the host's ELF reader changes its mind about what the file is.

---

## 10a. Both ELF classes, through the same words

`elf32.fth` adds ELF32. Nothing about how you drive it changes — the generic
words dispatch on `e_class`:

```forth
load /ide@1/cdrom@0:\embed32.bin
load-base 200 + elf-at
?elf
.elf
```

```
ELF32  entry=101bf0  phnum=3  shnum=a  ehsize=34
```

`ehsize=34` where ELF64 said `40`. `.phdrs`, `.sections`, `elf-load-base`,
`vaddr>off` and `sh-name` all work exactly as before.

**Two things worth knowing.**

**You cannot `load` a bare ELF32.** It never returns — the firmware's *own*
loader recognises ELF32 and takes over. (An ELF64 is not recognised, which is
the only reason this lab's usual subject is loadable as data at all.) The
workaround is to embed it: pad the file so offset 0 is not an ELF, then bind at
the offset — `load-base 200 + elf-at`. That is poke's `Elf32_File @ 512#B`, and
inspecting a payload inside a container is the realistic case anyway.

**ELF32 is not ELF64 with narrower fields.** The program header **reorders**:

```
ELF64  p_type p_flags p_offset p_vaddr p_paddr p_filesz p_memsz p_align
ELF32  p_type p_offset p_vaddr p_paddr p_filesz p_memsz p_flags p_align
```

`p_flags` is **second** in one and **seventh** in the other. A port that only
narrowed the widths would read permissions out of `p_offset` and never fault —
it would just print the wrong `RWX`, confidently. That is why `smoke-openbios.sh
elf-methods` asserts `p32-flags` per segment against the host.

And each validator refuses the other class:

```forth
?elf64      \ on an ELF32 → CONSTRAINT: not ELF64 (e_class) -- want=2  got=1
?elf32      \ on an ELF64 → CONSTRAINT: not ELF32 (e_class) -- want=1  got=2
```

---

## 10b. Part 8 — set a bit without disturbing its neighbours

This one comes straight from the article that started the lab — mudge,
*FORTH Hacking on Sparc Hardware*, Phrack 53:9 (1998), archived in
[`upstream-tutorial/`](upstream-tutorial/). His first example turns an LED on:

```forth
:light-on   1 aux@ or aux!  ;      \ Sun OpenBoot: set bit 0 of the aux register
:light-off  1 invert aux@ and aux! ;
```

That is a **read-modify-write**: read the register, OR in one bit, write it
back. He does it that way — rather than `1 aux!` — because a bare store would
zero every *other* bit in the register, and those bits belong to other
functions.

The DSL generalises this to `t-set` / `t-clr` / `t-tog` over a **typed field**,
so it is not named for an LED and it carries the width, byte order and address
space of the field:

```forth
struct  1 field: st  constant /reg
40 alloc-mem value r

80 r st t!        \ pretend bit 7 belongs to something else
1 r st t-set      \ set bit 0
r st t@ .         \ 81  — bit 7 SURVIVED
1 r st t-clr
r st t@ .         \ 80  — and back
```

Now the same thing a careless hand would write, so you can see why RMW exists:

```forth
80 r st t!
1 r st t!         \ a plain store
r st t@ .         \ 1   — bit 7 is GONE
```

**On a device register that difference is not tidiness, it is correctness.**
Point a `dev-field:` at the VGA attribute byte (`bg<<4 | fg`) and set an `fg`
bit: `t-set` keeps the blue background, a bare `t!` turns it black. The
`rmw-fields` smoke track proves exactly that from *outside* the firmware, by
reading physical `0xb8000` back through QEMU's monitor — the Forth read-back
can't show it, because it goes through the same accessor the store did.

`t-tog` is `xor` — mudge uses it in the same article's cisco decryptor — and two
toggles of a bit return it to where it started.

---

## 10c. Part 9 — name a control, hide the plumbing

`t-set` still wants a mask, a field and a base every time you call it. mudge's
`light-on` didn't — it *was* "bit 0 of the aux register," baked in behind a
name. `control:` does the same for any typed field:

```forth
struct  1 dev-field: d-ch  1 dev-field: d-at  constant /dc
/dc array: dcell[]
b8000 >virt 800 dcell[] value spare      \ cell 0x800 — see the box below
0 spare d-at t!
spare d-at  10  control: backlight       \ address + field + mask, behind a name
```

Two things about that address, both of which bite if you skip them.

`d-ch` is there so `d-at` lands at **+1** — the attribute byte Part 8 was
setting, not the character at +0. Declare `d-at` as the only field and
`backlight enable` flips a bit in the *letter* instead: `A` becomes `Q`, which
looks like the control worked and isn't the byte you meant.

> **And cell `0x800` is deliberate: it is past the end of the screen.** The
> console owns cells `0`–`0x7cf` (80×25 = `0x7d0`) and **scrolls them on every
> `cr`** — so after a scroll, row 0 is whatever old row 1 held. Aim a control at
> cell 0 and the sequence below reads back **`0` every time**: `backlight
> enable` really does set the bit, the newline scrolls it away, and `backlight
> enabled?` then honestly reports the byte that replaced it. Nothing is broken
> and nothing says so. Cell `0x800` is the same aperture reached the same way
> through `rb@`/`rb!`, just outside the region the console rewrites. (This is
> the trap Part 1 met from the other side, and why `smoke-openbios.sh
> rmw-fields` fills the *whole* screen instead of one cell.)

Now the verbs read as English, and the mask, the byte order, the address and the
read-modify-write are all hidden:

```forth
backlight enabled?      \ 0   — nothing set yet
backlight enable        \ set the bit(s), preserving the rest
backlight enabled?      \ -1  — and spare d-at t@ u. now reads 10
backlight disable
backlight enabled?      \ 0
backlight toggle
backlight enabled?      \ -1
```

**It is still a read-modify-write underneath**, which you can see by giving the
byte some neighbours first:

```forth
81 spare d-at t!
backlight enable
spare d-at t@ u.        \ 91 — bit 4 set, and 0x81 untouched
```

From the monitor, **Ctrl-A C**, `xp /2xb 0xb9000` reads `0x20 0x91` — the same
answer from outside the firmware, which is the only witness that counts for a
device write.

They are **not** called `on` / `off` — those are the firmware's own flag setters
(`variable x  x on`), and shadowing them is the `elf isn't unique.` mistake.
`enable` / `disable` / `toggle` / `enabled?` are the names that are free *and*
the ones that say what they do.

**Two controls on one register don't fight**, which is the whole point — each
`enable` preserves the other's bits:

```forth
r st 80 control: guard
r st 01 control: led
guard enable   led enable   r st t@ .    \ 81 — neither clobbered the other
```

And mudge's own words come back, now as one-liners over the abstraction rather
than raw register pokes:

```forth
: light-on   led enable ;
: light-off  led disable ;
```

That is the arc of the whole lab in three lines: his hardware-specific
`1 aux@ or aux!`, generalised into a typed read-modify-write, and then given back
its friendly name — but this time backed by a field that knows its width, its
byte order, and whether it lives in memory or on a device.

---

## 11. Reference — the two files

| word | stack | what it does |
|---|---|---|
| `struct` | `( -- 0 )` | start a layout (it is just `0`) |
| `<n> field:` `<name>` | `( off n -- off' )` | big-endian field, 1275's native order |
| `<n> le-field:` `<name>` | `( off n -- off' )` | little-endian field |
| `<n> dev-field:` `<name>` | `( off n -- off' )` | big-endian **device register** (`rb@`/`rb!`) |
| `<n> le-dev-field:` `<name>` | `( off n -- off' )` | little-endian device register |
| `<name>` | `( base -- adr tid )` | the field's **address**, and its type |
| `t@` | `( adr tid -- u )` | typed fetch |
| `t!` | `( u adr tid -- )` | typed store — this **is** the write |
| `t-adr` | `( adr tid -- adr )` | drop the type, keep the address |
| `<stride> array:` `<name>` | `( stride -- )` | `<name>` is then `( base i -- elem )` |
| `>virt` | `( phys -- adr )` | physical → Forth address (identity on amd64) |
| `>phys` | `( adr -- phys )` | the inverse |
| `load-base-phys` | `( -- p )` | `400000` on x86, `4000000` on amd64 |
| `chk` | `( actual expected c-addr u -- )` | equal, or print both and **abort** |
| `chk<` | `( n limit c-addr u -- )` | unsigned `n < limit`, or abort |
| `chk?` | `( flag c-addr u -- )` | any predicate; `a => b` is `a 0= b or` |
| `bits@` | `( value lsb width -- field )` | bit-field extract |
| `bit?` | `( value n -- flag )` | one bit |
| `t-set` | `( mask adr tid -- )` | set bits, **preserving** the rest (mudge's `aux@ or aux!`) |
| `t-clr` | `( mask adr tid -- )` | clear bits, preserving the rest |
| `t-tog` | `( mask adr tid -- )` | toggle bits (`xor`) |
| `control:` | `( adr tid mask "name" -- )` | bake address+field+mask behind a name |
| `enable` / `disable` / `toggle` | `( mask adr tid -- )` | on a control: set / clear / flip |
| `enabled?` | `( mask adr tid -- flag )` | is any masked bit set |
| `cstr` / `.cstr` / `cstr-len` | `( adr -- … )` | NUL-terminated strings |
| `dump` | `( adr len -- )` | hex + ASCII, 16 to a line |

### `elf.fth` — one format on top of it

| word | stack | what it does |
|---|---|---|
| `elf-at` | `( adr -- )` | bind the ELF everything else works on |
| `@elf` | `( -- adr )` | that base |
| `?elf64` | `( -- )` | §E1 constraints — **refuses** a file it cannot describe |
| `?phdrs` | `( filesize -- )` | no `PT_LOAD` may run past the end of the file |
| `.elf` `.phdrs` `.sections` | `( -- )` | the three `readelf` views |
| `elf-load-base` | `( -- vaddr )` | poke's `get_load_base` |
| `vaddr>off` | `( vaddr -- off \| -1 )` | poke's `vaddr_to_file_offset` |
| `sh-name` | `( i -- adr )` | a section's name in the string table |
| `elf-ph` / `elf-sh` | `( i -- adr )` | one program / section header |
| `elf-phnum` / `elf-shnum` | `( -- n )` | how many |
| `elf64-new` / `elf32-new` | `( adr -- )` | author a valid header of that class |
| `elf-class` / `elf64?` | `( -- n \| flag )` | which class is bound |
| `.p-type` `.sh-type` `.p-flags` | `( n -- )` | names and `RWX`, not numbers |

Widths are 1, 2, 4 (and 8 in memory space, on a 64-bit cell). Anything else is
**refused by name** — `T-ERR-width=<n>`, `T-ERR-be64`, `T-ERR-devwidth=<n>`,
`T-ERR-narrow-cell` — rather than answered with a plausible wrong number.

Layouts that ship in `elf.fth`: `/elf64-ehdr`, `/elf64-phdr` with `phdr[]`,
`/elf64-shdr` with `shdr[]`, and `/elf64-entry` for the 8-byte `x-entry` view.

**Adding a format is a new file, not a fork.** Declare the layouts with
`field:`/`le-field:`, a `?`-word with `chk`, and whatever methods answer the
questions you actually ask. That is the whole shape.

---

## 12. When something goes wrong

| symptom | cause |
|---|---|
| prompt reads `2 > ` or `5 > ` and nothing works | you left items on the stack. Type `clear` |
| a line "didn't take", or a word is undefined that you just typed | characters were dropped — the console has no flow control. **Retype it**, slower |
| `Stack Underflow.` | a word got fewer operands than it needs; check the `( … )` comment in §10 |
| your words vanished after loading a file | `load` overwrote `load-base`. Evaluate `struct.fth` **first**, then load the subject |
| numbers are wildly wrong | the base is **hex**. `10` is sixteen |
| prompt shows `5 > ` and the last line said ` compiled` | you are inside an unfinished `:` definition. Finish it — `clear` here throws it away |
| a store "works" but nothing happens | Part 2. On x86 a Forth address is not a physical one — aim at `<phys> >virt`, and check with `xp` from the monitor |
| `invalid char 'h' in expression` | quote the path you gave `pmemsave` |
| `CONSTRAINT: …` then ` Aborted.` | working as intended — `?elf64` refused. The line says what it wanted and what it got |
| a constraint fires on a field you did not touch | you corrupted the header earlier and never reloaded it. `load … subj.elf` again |
| `CONSTRAINT: not ELF64 (e_class)` on a file you believe is fine | it is an **ELF32**. This layer is ELF64-only and says so rather than misreading it — the first 24 bytes of the two formats are identical, so a layer without that check would look right and then produce nonsense |
| `load` of an ELF32 never comes back | the firmware's **own** loader recognises ELF32 and takes over. An ELF64 is not recognised, which is why this lab's subject is loadable as data at all |
| `t-set` seems to wipe other bits | you used a bare `t!` somewhere, or the field's width is wrong. `t-set`/`t-clr`/`t-tog` read-modify-write; a plain `t!` replaces the whole field |
| you redefined a word and nothing changed | `:` resolves callees **at compile time**, so redefinition is not retroactive — every word already compiled still calls the old one. Retype the callers too. This is Part 2's `cell-at` → `putc` → `fill-screen` chain |
| `enabled?` reads `0` right after `enable` | your control points into cells `0`–`0x7cf`, which the console **scrolls on every `cr`**. Nothing is broken — it is reporting the byte that replaced yours. Aim past the screen (§10c's cell `0x800`) or fill every row first |

---

## 13. Where this is checked automatically

Everything above is asserted, on both arches, by the smoke tracks below — with
controls, which is the part a walkthrough cannot give you:

```bash
./smoke-openbios.sh struct-layer     # the two checkpoints, and the refusals
./smoke-openbios.sh struct-array     # the phdr walk, graded by a derived sum
./smoke-openbios.sh struct-device    # the device backend, and the x86 false positive
./smoke-openbios.sh elf-methods      # the constraints and the methods — four
                                     # corruptions must each be refused BY NAME
./smoke-openbios.sh rmw-fields       # Parts 8 and 9 — every RMW row paired with
                                     # a bare `t!` that destroys the neighbour
```

Each has a `tests/test-smoke-<track>.sh` wrapper, so
[`tests/run-all.sh`](tests/run-all.sh) runs all of them and
`tests/test-every-track-has-a-wrapper.sh` fails if a track ever ships without
one. That guard is why this list is not a hand-maintained count.

Background: [`README.md`](README.md) (§"And where the type layer starts"),
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) for the measured record and the
injection tables, and
[`REVIEW-preboot-forth-as-a-poke-engine.md`](../../REVIEW-preboot-forth-as-a-poke-engine.md)
§G2 and §G8 for why any of it exists.
