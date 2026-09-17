# `fixtures/pe/` — a UKI (a PE/COFF `.efi`) for the `pe` track

[`build-pe-fixture.sh`](build-pe-fixture.sh) authors a **real Unified Kernel
Image at run time** (derived, never cached — the repo's rule) with the host's own
`ukify` (systemd's UKI builder, the [UKI workbench
plan](../../../../UKI_WORKBENCH_LAB_PLAN.md)'s oracle), so the `objdump -h` that
lists its sections is a faithful oracle of the exact bytes
[`dsl/pe.fth`](../../dsl/pe.fth) walks — and `ukify` is an **independent author**
from the reader. It is our own authored fixture, not a vendored upstream
artifact: the builder *is* the provenance.

The subject is genuinely a UKI — the systemd EFI stub with named PE sections
glued on:

| section | contents | why |
|---|---|---|
| `.text`/`.rodata`/`.data`/`.sbat`/`.sdmagic`/`.reloc` | the stub's own sections | authored by the systemd/gnu-efi build — graded against `objdump`, a *different* tool |
| `.osrel` | an os-release stanza | a named section |
| `.cmdline` | `root=/dev/sda1 ro quiet\n` | `pe-find` hands it to `type`; the track greps it back |
| `.initrd` | the newc cpio from [`fixtures/cpio/`](../cpio/) | `pe-find` hands it to **`cpio.fth`** |
| `.linux` | the stub again (a stand-in kernel; `ukify` wants a PE) | the largest section |

**The `.initrd` being the very archive the [`cpio` track](../cpio/) walks is the
point.** The `pe` track ([`smoke-openbios.sh pe`](../../smoke-openbios.sh)) reads
`.initrd` **out of the PE** with `pe-find` and walks it as cpio with `cpio-walk`
— the UKI workbench's **Spike 2 handoff** (read the section, grade it by what it
is) end to end, on **unix, x86, amd64 and ppc**.

PE fields are **little-endian on every target**, so — unlike cpio's ASCII-hex —
there *is* a byte order to get wrong: a naive native `l@` on **ppc** (big-endian)
would byte-swap every field, and the four-arch row proves ppc reads the same
section table as x86, not a swap of it. The reader locates the section table by
`SizeOfOptionalHeader` (never by walking the parsed optional header) and reads
the optional-header magic first (PE32+ for a UKI) — the two things poke's `pe.pk`
oracle pins (plan §4a).

**Controls (unix):** a zeroed byte 0 → `pe| BAD-MZ` and `false`; a flipped
`PE\0\0` → `pe| BAD-PESIG` and `false`; a buffer cut before `e_lfanew` →
`pe| TRUNCATED` and `false`. A malformed PE is **refused by name**, never read
wrong and reported as success.

Rebuild by hand:

```sh
./build-pe-fixture.sh /tmp/uki.efi
objdump -h /tmp/uki.efi                                   # the section-table oracle
objcopy -O binary --only-section=.initrd /tmp/uki.efi - | cpio -itv   # the .initrd oracle
```
