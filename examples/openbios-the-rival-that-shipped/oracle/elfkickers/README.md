# ELFkickers — vendored as the differential oracle (elfls)

This is a **minimal byte-exact subset** of Brian Raiter's *ELFkickers*, vendored
so [`smoke-openbios.sh file-writer`](../../smoke-openbios.sh) can grade the ELF
the firmware authored against a **second, independent** ELF decoder — one that is
not this repo's `dsl/elf.fth` and not the host's `readelf`. Three decoders that
disagree is a finding; three that agree, plus a kernel that *runs* the file, is
proof.

## Why this tool, in this lab

The [design notes](../../../../DESIGN-NOTES-preboot-forth-binary-structures.md)
open with GNU poke **and** ELFkickers. The
[review](../../../../REVIEW-preboot-forth-as-a-poke-engine.md) §G5 kept ELFkickers
as *the authoring model* — hand-laying ELF headers with deliberate overlap — while
correctly noting it shares no code path with the firmware. This is that
intellectual link made operational: the firmware now **authors** an ELF the way
ELFkickers' teensy-ELF essays do (by hand, byte by byte), and `elfls` — the kit's
header roadmap tool — is the tool that reads it back. `elfls` is the counterpart
to `dsl/elf.fth`'s reader, from a different author, so agreement between them is
not two views of one bug.

## Provenance

| | |
|---|---|
| **Project** | ELF Kickers |
| **Author** | Brian Raiter (`breadbox@muppetlabs.com`) |
| **Canonical URL** | <https://git.sr.ht/~breadbox/ELFkickers> |
| **Homepage** | <http://www.muppetlabs.com/~breadbox/software/elfkickers.html> |
| **Commit** | `0aa73da875fbf14d94063c03c76a327d92369f16` (2022-03-29, "version 3.2") |
| **Retrieved** | 2026-09-01 |
| **License** | GPL-2.0-or-later (see [`COPYING`](COPYING)) |

## What is vendored, and what is not

Vendored: **only** the two components `file-writer` runs — the `elfrw` wrapper
library and the `elfls` tool that links it. That is the whole build:

    make -C elfrw && make -C elfls    # → elfls/elfls

**Not vendored** (cited, not mirrored — they are not on the lab's measured path):
`sstrip`, `objres`, `rebind`, `infect`, `elftoc`, `ebfc`. Of these, `elftoc`
(ELF → C `struct` initialiser) is the true mirror image of `dsl/elf.fth` and the
richest future oracle; it is heavier to build (it reads your libc's `elf.h` via
`cpp -dM`) and is left to the upstream tree. Fetch the full kit from the canonical
URL above; `git rm -r oracle/elfkickers` to remove this archive.

## Per-file sha256 (byte-exact record)

| `COPYING` | `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643` |
| `elfls/elfls.1` | `3a836ebc058059742398bee1358f11a48444270f53e8ddfb1ab2467211fb3437` |
| `elfls/elfls.c` | `136ac98207e631369de8ca38786bdbf8e9e8085b4ac5ea251bd3ecaf21c9cd84` |
| `elfls/Makefile` | `4e563caad9d86d049d644aa313908f3d224fef17e94940b6586737da7bea9dd3` |
| `elfls/README` | `dbd6d27b1deca3206ef66289bb4fa2f9263dce02dae108f80f63620e40adfbe7` |
| `elfrw/elfrw.c` | `1aab15c049d4356752ab3de7d5660299027c9aea1ecc0d137db79aa5dd352a2c` |
| `elfrw/elfrw_dyn.c` | `74bc84c4f9117cfadb17d69f13922b29e30d1c7265c562c340ee015c9f0f9062` |
| `elfrw/elfrw_ehdr.c` | `e11d8b4a5e2a007f1f459164cbaeb0a12a1d813efc3ac8fd89f8100a05b66d20` |
| `elfrw/elfrw.h` | `81828086f86cddfa80f4dac4f45dd26702969c57983eb466ac1d54cc007fd16b` |
| `elfrw/elfrw_int.h` | `3b292334c0b0d0233a7ad40af35d576a784249dba37b618d3350f3cf0f9081e3` |
| `elfrw/elfrw_phdr.c` | `a3b7dbdcb3dc77fb80e39c167c746da8c50b51e194e082882879879d54a01417` |
| `elfrw/elfrw_rel.c` | `82180b9decbd2664a00e469cc033d61e6826fe5beb2c314d69bd31f55af0323d` |
| `elfrw/elfrw_shdr.c` | `8af4cacb02f32e9ba118db6211c9742e87abd7f33a8a1c53e1bee7b1eca23b32` |
| `elfrw/elfrw_sym.c` | `c26aea00264ca73ee9b74e999c2f432f67759d4073f51f1699518ef6368cb177` |
| `elfrw/elfrw_ver.c` | `b4f33b04abedc128fb6e557c39b6331d007280d3edb5651fc507e46fd1c445b0` |
| `elfrw/Makefile` | `eb90f9f2696ac9aca5a0c71c37b7b6a2203382c0820f17936d29caedb6fb58ef` |
| `elfrw/README` | `c619b23fd1c7320e6b8a01300fa84d335123f9d1ffe95c1f9a7f3bf96078dbf1` |

Regenerate this table after any re-vendor:

    cd oracle/elfkickers && find elfrw elfls COPYING -type f | sort \
      | while read -r f; do printf '| `%s` | `%s` |\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done

All copyright remains with the author; archived here for offline, reproducible
grading. This subset is unmodified from upstream at the commit above.
