# Panning the poke-elf pickles — a prospecting report (2026-09-01)

A second pass over **all sixteen** GNU poke ELF pickles
(<https://jemarch.net/poke-elf-1.0-manual/html_node/Pickles-Overview.html>),
read at the same commit `dsl/elf.fth` transliterates from — `ae45538`
(2024-10-15). The first pass (`REVIEW-preboot-forth-as-a-poke-engine.md` §E)
mined `elf-common.pk`/`elf-64.pk` for the type layer and the address methods.
This pass walked the rest — the config registry, the OS and machine pickles, the
whole-file types, the notes — and grades every seam for **this** project: an
OpenBIOS Forth that inspects boot images, builds device trees, hands structures
to the next stage, and (as of TODO §20) **authors** ELF files.

**The honest frame first.** Most of poke-elf is a *linker's* view of ELF —
relocation types, symbol tables, dynamic sections, section groups, and per-arch
registries of hundreds of reloc kinds (`elf-mach-aarch64.pk` is 681 lines,
`mips` 648, almost all reloc tables). A firmware that authors an `exit(N)` binary
and reads a bzImage never relocates, so that ore is real but **not ours**. The
gold is the *format-agnostic machinery* and the *boot-relevant records*. Graded
by how much digging each is worth:

## Loose gold — on the surface, cheap to pocket

- **The program-header ORDERING check.** `elf64_check_phdr` (wired as a
  whole-table field constraint: `phdr : elf64_check_phdr(phdr)`) encodes a real
  ELF invariant — `PT_INTERP` and `PT_PHDR` must appear **before** any `PT_LOAD`
  and only once. Our `?phdrs64` checks the *complementary* thing (no `PT_LOAD`
  runs past EOF) and nothing about ordering. A firmware that is about to **run**
  an image should refuse a malformed one; adding the ordering rule to `?phdrs64`
  is a handful of lines and the two checks together are the honest gate.
- **`elf_hash`** (`elf-common.pk`) — the SysV symbol-hash function, a pure ~10-line
  loop over a string. Trivially transliterated to Forth, and a clean self-contained
  primitive the moment anything touches a `.hash` section or wants a small content
  digest at the prompt. Not needed today; free to keep in the pan.

## Gems — worth breaking out the pickaxe

- **`Elf_Note` is the reusable extensible-record archetype, and we have nothing
  like it.** The type (`elf-common.pk`, deliberately class-agnostic) is a TLV:
  `namesz, descsz, type, name[namesz], pad-to-4, desc[descsz], pad-to-4`. That is
  **structurally identical** to a TPM measured-boot event-log entry, to an FDT
  `/chosen` note, and to the boot-handoff blobs `DESIGN-NOTES-...` §8 names —
  *"the same type description that builds an event-log entry also parses one
  back."* `.note.gnu.build-id` is itself an **image content hash**, which is the
  repo's own "bind the fact to its subject's identity" law wearing an ELF hat
  (cf. metal-as-a-service's `pcrs.expected`/build-id lesson). `dsl/elf.fth` only
  *names* `NOTE` as a `p_type` string; it parses no note. A Forth `note:`/`tlv:`
  layout word is the single richest vein here — it turns the type layer from an
  ELF reader into a describer of the extensible records the fleet actually hands
  around at boot.
- **The two `struct.fth` primitives the notes expose as missing.** `Elf_Note`
  needs (a) a **length-prefixed array** — `uint<8>[namesz] name`, an array whose
  count is a *prior field*, where our `array:` takes a fixed stride only — and
  (b) **`alignto(OFFSET, 4#B)`** — padding computed from the *running offset*, not
  a constant. Both are exactly the cell-width/offset hazards `DESIGN-NOTES` §3
  warns about, met head-on. They are also what it would take to describe the
  device tree's own structure block (FDT is length-prefixed, `nul`-padded,
  4-byte-aligned). Adding `vfield:`/`alignto` to `struct.fth` is the enabling
  work under the note gem.

## Panning downriver — derivative value, further from the source

- **The config registry** (`elf-config.pk`), re-assayed. Its real payoff is not
  pretty-printing but **field validity keyed by context**: `ei_class`,
  `ei_data`, and a note's `_type` are all constrained through
  `elf_config.check_enum(class, machine, value)`, so a field *refuses* a value not
  registered for the current machine. For us the machine is the wrong key — but
  the **shape** (a `{class, context, value, name}` store with `check`/`format`/
  `apropos`, decoupled from layout) maps precisely onto our one genuine
  context-parameterized decode: IEEE-1275 `#address-cells`, which is `2` on the
  amd64 root, `1` on its children and on x86 (`arch/{amd64,x86}/init.fs`; the
  amd64-port notes flag that the root's `decode-unit`/`encode-unit` **must** move
  with the count). Today we handle enum naming with hardcoded nested-`if` tables
  (`.p-type`/`.sh-type`) and the DT decode with inline per-node assumptions; a
  small context-keyed registry is the honest generalization of both.
- **The field-reconfigures-the-reader pattern.** `Elf_Ident.ei_data` doesn't just
  validate — it **sets the reader's endianness for every subsequent field**
  (`ei_data == 2LSB ? set_endian(LITTLE) : set_endian(BIG)`). We deliberately
  declined this (REVIEW §E2: per-field byte order plus an honest refusal of a
  big-endian ELF64). But the *pattern* — a field that reconfigures how its
  siblings decode — is the archetype for a DT `#address-cells` property changing
  how the cells after it are read. Borrow the pattern; don't port the ELF use.
- **`get_load_base` aligns down by `p_align`.** poke returns `min(p_vaddr &
  ~(p_align-1))` over `PT_LOAD`; our `elf64-load-base` returns the raw minimum
  `p_vaddr`. For our `vaddr>off` these agree on a normally-aligned image and
  differ on the page base. A one-line refinement to consider only if page-base
  semantics are ever wanted — noted so the divergence is deliberate, not drift.

## Left in the ground — assayed, barren for us

Symbol tables, section groups (COMDAT), the dynamic section, relocation entries,
and the per-arch reloc registries (`elf-mach-*`) are a linker/loader's concern.
This firmware authors and inspects; it does not link or relocate. `elf.fth`
already lifted the pieces that *are* ours — REVIEW §E1's constraints-that-refuse
(`?elf64`) and §E4's address methods (`vaddr>off`, `elf-load-base`), the latter
with a hard-won unsigned-comparison fix the narrow cell exposed — so those are
not re-counted here.

## What this map is for

Nothing above is scheduled. It is a **claim map**: when a future item touches
measured-boot/attestation records, FDT construction, or FCode/property naming —
all TLV- or context-keyed — the vein to work is the `Elf_Note` archetype plus the
two `struct.fth` primitives (the pickaxe), then the context-keyed registry (the
pan), not the reloc tables (the barren rock). It is the concrete form of
`DESIGN-NOTES-preboot-forth-binary-structures.md` §5's thesis — *generalize the
encode/decode wordset outward from device-tree properties to arbitrary binary
structures* — with poke-elf pointing at exactly which structures pay.

---

*Duplicated verbatim in the repo's top-level `TODO.md` (§21) by request; if you
edit one, edit both.*
