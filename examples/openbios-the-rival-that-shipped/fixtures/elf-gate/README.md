# `fixtures/elf-gate/` — three ELFs that differ only in their `p_type` words, and a hash oracle

The subjects for `smoke-openbios.sh elf-gate` (B.3, the gleanings' *loose gold*, 2026-09-03).
Nothing here is vendored; [`build-elf-gate-fixtures.py`](build-elf-gate-fixtures.py) **authors**
the fixtures at run time, so the track never depends on a checked-in binary.

| file it writes | phdr types | why |
|---|---|---|
| `good.elf` | `PHDR INTERP LOAD LOAD` | the gABI order; `readelf -l` is silent on it |
| `badord.elf` | `LOAD PHDR INTERP LOAD` | PHDR after a LOAD — `readelf` says *"the PHDR segment must occur before any LOAD segment"* |
| `baddup.elf` | `PHDR INTERP INTERP LOAD` | INTERP twice — the gABI forbids it; **`readelf` does not check it**, so here the Forth is stricter than the oracle, and the track says so |

The three are byte-identical outside the program-header table — same header, same body — and
the track asserts exactly that (every differing byte lies in offsets 64..288). *Inside* the table
more than the type word moves, because a segment's offset and size follow its type (a LOAD covers
the file, a PHDR points at the table, an INTERP at 8 body bytes); the first draft claimed "only
the `p_type` words differ" and the track's own guard refused it. Every `PT_LOAD` fits inside the
file, so `?phdrs`'s older check (a segment past EOF) is satisfied by all three: whatever it
refuses, it refuses for the ordering rule.

The script also prints `NAME HASH` for the names the track types at the firmware, computed by a
transliteration of the SysV gABI's `elf_hash` (Figure 5-13) — and, when a C compiler is present,
checks *that* transliteration against the **linker**: it builds a shared object with
`ld --hash-style=sysv` and requires every symbol to be reachable from
`bucket[elf_hash(name) % nbucket]` of the `.hash` section ld wrote. The first line of its output
is `LINKER OK …` or `LINKER UNKNOWN …`; the track carries it into its note verbatim.

The fourth subject is not here: the host's own `/bin/true`, when `file` says it is an ELF64 LE,
padded and put through the same gate — a real binary whose PHDR and INTERP really do precede its
LOADs.
