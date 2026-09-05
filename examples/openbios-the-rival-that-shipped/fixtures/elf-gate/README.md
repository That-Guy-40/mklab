# `fixtures/elf-gate/` — four ELFs that differ only in their `p_type` words, and a hash oracle

The subjects for `smoke-openbios.sh elf-gate` (B.3, the gleanings' *loose gold*, 2026-09-03).
Nothing here is vendored; [`build-elf-gate-fixtures.py`](build-elf-gate-fixtures.py) **authors**
the fixtures at run time, so the track never depends on a checked-in binary.

| file it writes | phdr types | why |
|---|---|---|
| `good.elf` | `PHDR INTERP LOAD LOAD` | the gABI order; `readelf -l` is silent on it |
| `badord.elf` | `LOAD PHDR INTERP LOAD` | PHDR after a LOAD — `readelf` says *"the PHDR segment must occur before any LOAD segment"* |
| `baddup.elf` | `PHDR INTERP INTERP LOAD` | INTERP twice — the gABI forbids it; **`readelf` does not check it**; `eu-elflint` does (*"more than one INTERP entry in program header"*), and is the track's second oracle for this row since 2026-09-04 |
| `badint.elf` | `PHDR LOAD INTERP LOAD` | INTERP after a LOAD, PHDR in place — added 2026-09-05 because `badord.elf` moves both and the firmware's refusal fires on PHDR first, so **the INTERP branch of `?ph-order` had never been exercised**. Measured: `readelf` is silent (its order message names PHDR only), `eu-elflint` says *No errors* (it checks no order), the kernel's loader reads `PT_INTERP` wherever it sits — **no tool we have enforces this sentence**; the firmware refuses it on the gABI's word alone, and the track says so per run |

The four are byte-identical outside the program-header table — same header, same body — and
the track asserts exactly that (every differing byte lies in offsets 64..288). *Inside* the table
more than the type word moves, because a segment's offset and size follow its type (a LOAD covers
the file, a PHDR points at the table, an INTERP at 8 body bytes); the first draft claimed "only
the `p_type` words differ" and the track's own guard refused it. Every `PT_LOAD` fits inside the
file, so `?phdrs`'s older check (a segment past EOF) is satisfied by all four: whatever it
refuses, it refuses for the ordering rule.

The script also prints `NAME HASH` for the names the track types at the firmware, computed by a
transliteration of the SysV gABI's `elf_hash` (Figure 5-13) — and, when a C compiler is present,
checks *that* transliteration against the **linker**: it builds a shared object with
`ld --hash-style=sysv` and requires every symbol to be reachable from
`bucket[elf_hash(name) % nbucket]` of the `.hash` section ld wrote. The first line of its output
is `LINKER OK …` or `LINKER UNKNOWN …`; the track carries it into its note verbatim.

elflint's missing ordering check is written up for upstream in
[`UPSTREAM-elflint-no-phdr-order-check.md`](UPSTREAM-elflint-no-phdr-order-check.md) (drafted, not filed).

## The ladder sets — one per firmware door, in the class it actually loads (B.4 Spike 0, 2026-09-05)

`--ladder ARCH VADDR OVL` writes `ladder-ARCH/` with eight files **in the class, byte order and
machine the named door's C loader recognises** — x86: ELF32 LSB EM_386; amd64: ELF64 LSB
EM_X86_64; ppc: ELF32 MSB EM_PPC — so `load` of the bare file reaches `elf_init_program()`'s gate
([patch 68](../../patches/68-an-elf-gate-in-front-of-the-copy.patch)) instead of being inspected as
data. That is the measurement that moved this lab's fixtures off ELF64: `is_elf()` accepts only the
door's own class, so B.3's four ELF64 files were never on the boot path of x86 or ppc at all.

`good.elf` is **runnable**. Its body is real code at `e_entry`: on x86 and amd64
`mov dx,0x3f8; mov al,'R'; out dx,al; ret` (the same eight bytes mean the same in long mode), so
the image writes `R` to COM1 and returns onto the return address the firmware planted; on ppc a
single `blr`. `VADDR` is where the caller wants it placed (the track uses `0x20000`, the client
window below the x86 firmware, and `0x1000000` on ppc); `OVL` is the door's **entry point**, read
by the track from `readelf -h` of the firmware image on every run rather than written down.

| file | the one clause it breaks | where it differs from `good.elf` |
|---|---|---|
| `badord.elf` | `PT_PHDR` after a `PT_LOAD` | the phdr table |
| `baddup.elf` | `PT_INTERP` twice | the phdr table |
| `badint.elf` | `PT_INTERP` after a `PT_LOAD` | the phdr table |
| `badtrunc.elf` | LOAD#2's `p_filesz`/`p_memsz` reach past the end of the file | LOAD#2's phdr |
| `badmem.elf` | LOAD#2's `p_memsz < p_filesz` | LOAD#2's phdr |
| `badovl.elf` | LOAD#2 lands on the page of the firmware's entry point | LOAD#2's phdr |
| `badentry.elf` | `e_entry` inside no `PT_LOAD` | `e_entry` |

The script prints `LADDER ARCH NAME LO HI` for each: the half-open byte range every differing
byte must fall in, and the track checks it with `cmp -l`. The first `badovl` broke **two** rules —
its `p_offset` and `p_vaddr` were not congruent modulo `p_align`, and `eu-elflint` said so — which
is exactly the badint lesson again, so it now keeps the congruence and no hosted tool has anything
to say about it: only the firmware knows where the firmware is.

**What the hosted tools see, measured 2026-09-05 (readelf 2.42, eu-elflint 0.190), identical on
all three classes:**

| clause | `readelf -lW` | `eu-elflint` |
|---|---|---|
| PHDR after LOAD | *the PHDR segment must occur before any LOAD segment* | silent |
| INTERP twice | silent | *more than one INTERP entry in program header* |
| INTERP after LOAD | silent | silent |
| a PT_LOAD past the end of the file | silent | silent (also with `--strict`) |
| `p_filesz > p_memsz` | *the segment's file size is larger than its memory size* | *file size greater than memory size* |
| segment on the firmware | silent | silent (nothing to know) |
| entry in no PT_LOAD | silent | silent |

Four of seven are checked by **neither** tool. Two of those are the dangerous ones — a segment
past the end of the file has the loader copy whatever lies beyond the buffer — and are candidates
for upstream reports beside the one already drafted. The `elf-ladder` track re-measures every cell
on every run and words its verdict from what it measured.

The fifth subject is not here: the host's own `/bin/true`, when `file` says it is an ELF64 LE,
padded and put through the same gate — a real binary whose PHDR and INTERP really do precede its
LOADs.
