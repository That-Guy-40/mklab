# Draft upstream report — elfutils `elflint`: no program-header ordering check

*Drafted 2026-09-05 from measurements in this lab; not yet filed. Filing (sourceware.org bugzilla,
product elfutils) is a human's step. Everything below was observed with elfutils 0.190 (Ubuntu) and
read in `src/elflint.c` at 0.192.*

## Summary

`eu-elflint` validates several program-header properties — more than one `PT_INTERP`
(`check_program_header`: *"more than one INTERP entry in program header"*), more than one
`PT_TLS`/`PT_GNU_RELRO`, `PT_PHDR` contained in a `PT_LOAD` and matching `e_phoff` — but it has
**no check of the gABI's ordering rule** for `PT_PHDR` and `PT_INTERP`:

> PT_PHDR … may occur only once, if at all, and must precede any loadable segment entry.
> PT_INTERP … it may not occur more than once in a file. If it is present, it must precede any
> loadable segment entry.

GNU `readelf -l` enforces the PHDR half (*"the PHDR segment must occur before any LOAD
segment"*) and nothing else; `elflint` enforces the multiplicity half and nothing else. No
tool we found enforces the INTERP-order half.

## Reproducers

Two minimal ELF64 LE executables, byte-identical outside the program-header table (header,
body, every `PT_LOAD` inside the file), written by
[`build-elf-gate-fixtures.py`](build-elf-gate-fixtures.py):

| file | program headers | `readelf -lW` | `eu-elflint` |
|---|---|---|---|
| `good.elf` | `PHDR INTERP LOAD LOAD` | silent | `No errors` |
| `badord.elf` | `LOAD PHDR INTERP LOAD` | *Error: the PHDR segment must occur before any LOAD segment* | `No errors` ← expected an error |
| `badint.elf` | `PHDR LOAD INTERP LOAD` | silent | `No errors` ← expected an error |

```
python3 build-elf-gate-fixtures.py out
eu-elflint out/badord.elf ; echo rc=$?     # No errors, rc=0
eu-elflint out/badint.elf ; echo rc=$?     # No errors, rc=0
```

## Suggested check

In `check_program_header`, track whether a `PT_LOAD` has been seen and report a `PT_PHDR` or
`PT_INTERP` entry that follows one, e.g. *"phdr[%d]: PT_PHDR entry after a loadable segment"* /
*"phdr[%d]: PT_INTERP entry after a loadable segment"*, beside the existing multiplicity check.

## Why it matters to us

A firmware-hosted ELF validator (OpenBIOS Forth, this lab) refuses both files by name; for
`badint.elf` it does so with no second opinion available from any hosted tool, which is an
uncomfortable place for a validator to stand.
