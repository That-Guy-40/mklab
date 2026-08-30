# Driving the type layer by hand — `0 >` on both arches

A **hands-on** walkthrough of [`dsl/struct.fth`](dsl/struct.fth): draw on the VGA
text buffer through a typed layout, parse a real ELF64 header, walk its
program-header table, and author a header the *host's* `readelf` can read.

This is not [`MANUAL_TESTING.md`](MANUAL_TESTING.md), which is the **record** of
what has been run, and it is not the `struct-*` smoke tracks, which run the same
ground automatically and grade it. This is the version you type yourself.

**Both arches, on purpose.** Part 2 is the one worth doing even if you skip the
rest: the identical VGA code that works on `amd64` **silently does nothing** on
x86, reads back a perfect answer anyway, and only an observer outside the
firmware can tell you so.

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
against `readelf` on this machine:

```bash
W=${OPENBIOS_WORKDIR:-$HOME/openbios-lab}
mkdir -p "$W/typelayer"
cp dsl/struct.fth                          "$W/typelayer/STRUCT.FTH"
cp "$W/openbios/obj-amd64/openbios.multiboot" "$W/typelayer/SUBJ.ELF"
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

At the prompt:

```forth
load /ide@1/cdrom@0:\struct.fth
load-base load-size evaluate
```

The first prints some `Probing for …` chatter and `Path=/struct.fth`; the second
just says ` ok`. You now have `field:`, `le-field:`, `dev-field:`, `array:`,
`t@`, `t!`, `t-adr`, and the ELF64 layouts.

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

## 5. Part 2 — the same code on x86, and why nothing happens

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

You can see the divergence directly. Ask the layer where a field lives:

```forth
load /ide@1/cdrom@0:\subj.elf
load-base e_machine t-adr u.
```

| arch | `e_machine`'s address |
|---|---|
| amd64 | `4000012` — `load-base` is `4000000`, and `e_machine` is at `+0x12` |
| x86 | `e0670be2` — nowhere near it |

**This is the single most useful thing in this document.** A type layer makes
field access convenient; it does **nothing whatsoever** to make an address
correct. A write to a device has to be graded by an observer that is not the
writer — which is why the `struct-device` smoke track asserts the x86 row
*positively*, as a false positive it expects, rather than skipping it.

*(If you are on `OPENBIOS_DISPLAY=none`, `screendump /tmp/vga.ppm` at the monitor
gives you the same evidence as a picture.)*

---

## 6. Part 3 — parse a real ELF64

Back on **amd64**. If you have not already:

```forth
load /ide@1/cdrom@0:\subj.elf
```

`load` reads the whole file to `load-base` and stops. Nothing has interpreted
it — the bytes are just sitting there, and `elf64-ehdr` is a layout over them:

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

## 9. Part 6 — author a header, and let the host read it

The other direction. Build an ELF64 header from nothing, in a buffer, using only
`t!` — then hand the bytes to `readelf`.

```forth
40 alloc-mem value hdr
: zap 40 0 do 0 hdr i + c! loop ;
zap hdr u.
```

Note the address it prints. Then fill in the fields **by name**:

```forth
464c457f hdr e_magic t!  2 hdr e_class t!
1 hdr e_data t!  1 hdr e_version1 t!
2 hdr e_type t!  3e hdr e_machine t!  1 hdr e_version t!
401000 hdr e_entry-lo t!
40 hdr e_ehsize t!  38 hdr e_phentsize t!  40 hdr e_shentsize t!
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
  Type:                              EXEC (Executable file)
  Machine:                           Advanced Micro Devices X86-64
  Entry point address:               0x401000
```

A structure authored at a firmware prompt, read back by the platform's own
binary-format tool. That is the "poke in the environment poke cannot reach" claim
with the loop closed at both ends.

---

## 10. Reference — what `struct.fth` gives you

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

Widths are 1, 2, 4 (and 8 in memory space, on a 64-bit cell). Anything else is
**refused by name** — `T-ERR-width=<n>`, `T-ERR-be64`, `T-ERR-devwidth=<n>`,
`T-ERR-narrow-cell` — rather than answered with a plausible wrong number.

Layouts that ship: `elf64-ehdr` (`/elf64-ehdr`), `elf64-phdr` (`/elf64-phdr`)
with `phdr[]`, and `elf64-entry` for the 8-byte `x-entry` view.

---

## 11. When something goes wrong

| symptom | cause |
|---|---|
| prompt reads `2 > ` or `5 > ` and nothing works | you left items on the stack. Type `clear` |
| a line "didn't take", or a word is undefined that you just typed | characters were dropped — the console has no flow control. **Retype it**, slower |
| `Stack Underflow.` | a word got fewer operands than it needs; check the `( … )` comment in §10 |
| your words vanished after loading a file | `load` overwrote `load-base`. Evaluate `struct.fth` **first**, then load the subject |
| numbers are wildly wrong | the base is **hex**. `10` is sixteen |
| prompt shows `5 > ` and the last line said ` compiled` | you are inside an unfinished `:` definition. Finish it — `clear` here throws it away |
| a store "works" but nothing happens | Part 2. On x86 a Forth address is not a physical one — check with `xp` from the monitor |
| `invalid char 'h' in expression` | quote the path you gave `pmemsave` |

---

## 12. Where this is checked automatically

Everything above is asserted, on both arches, by three smoke tracks — with
controls, which is the part a walkthrough cannot give you:

```bash
./smoke-openbios.sh struct-layer     # the two checkpoints, and the refusals
./smoke-openbios.sh struct-array     # the phdr walk, graded by a derived sum
./smoke-openbios.sh struct-device    # the device backend, and the x86 false positive
```

Background: [`README.md`](README.md) (§"And where the type layer starts"),
[`MANUAL_TESTING.md`](MANUAL_TESTING.md) for the measured record and the
injection tables, and
[`REVIEW-preboot-forth-as-a-poke-engine.md`](../../REVIEW-preboot-forth-as-a-poke-engine.md)
§G2 and §G8 for why any of it exists.
