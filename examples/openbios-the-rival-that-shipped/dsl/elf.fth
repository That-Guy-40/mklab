\ elf.fth — ELF64 as a FORMAT, on top of dsl/struct.fth's engine.
\
\ Load struct.fth first, then this. The split is poke's own (elf-64.pk is a
\ separate pickle from libpoke) and REVIEW §E6's lesson applied to ourselves:
\ keeping the format out of the engine is why poke's elf-64.pk stays 446
\ readable lines while covering seven architectures.
\
\ WHAT THIS IS A TRANSLITERATION OF, and what it deliberately is not. Read from
\ poke-elf at ae45538 (git://git.savannah.gnu.org/poke/poke-elf.git, unreleased):
\
\   §E1 constraints  -- fields that REFUSE to map            -> ?elf64, ?phdr
\   §E4 methods      -- semantics, not layout                -> vaddr>off,
\                                                               elf-load-base,
\                                                               sh-name
\   §E3 a table declared once, not spelled out per use       -> phdr[] shdr[]
\   §G4 bit-fields                                           -> .p-flags
\   NOT §E6 (a machine-parameterised enum registry): poke-elf carries seven
\        architectures and this lab has one. The small enum tables below print
\        names for the handful of values a human actually reads.
\   NOT §E7 (unit-typed offsets): deliberately skipped, see REVIEW §G4.
\   NOT §E2 (byte order taken from ei_data at map time): declared per field
\        here, so a BIG-ENDIAN ELF64 would be misread. ?elf64 REFUSES one by
\        name rather than letting it through -- an honest halt for a limit this
\        layer really has.
\
\ ELF64 ONLY, AND IT SAYS SO. poke-elf ships elf-32.pk (347 lines) beside
\ elf-64.pk; there is no equivalent here. An ELF32 is REFUSED by name --
\ `CONSTRAINT: not ELF64 (e_class) -- want=2 got=1` -- rather than misread,
\ which matters because the first 24 bytes of the two formats are IDENTICAL
\ (e_ident, e_type, e_machine, e_version) and everything from e_entry on
\ diverges: ELF32 puts e_entry at 0x18 as 4 bytes and its header is 0x34 long,
\ not 0x40. A layer without the class check would read the first six fields
\ correctly and then quietly produce nonsense.
\
\ AND YOU CANNOT `load` ONE ANYWAY, measured 2026-08-30: `load` of a real
\ ELF32 never returns to the prompt, because the firmware's OWN loader
\ recognises it and takes over. The same bytes with one magic byte changed
\ (`ELG`) load fine, which is how that was isolated. An ELF64 is not
\ recognised, which is the only reason the subject used throughout this lab is
\ loadable as data at all.
\
\ Base is HEX.
hex

\ ── the layouts ────────────────────────────────────────────────────
\ 8-byte members are declared as two 4-byte little-endian halves so ONE layout
\ serves a 32-bit cell too; an 8-byte field would refuse on x86 and halt the
\ parse on a field nobody asked about.
\ ── the ELF64 header, as a layout ──────────────────────────────────
\ e_entry/e_phoff/e_shoff are 8 bytes in ELF64 and are declared here as two
\ 4-byte little-endian halves ON PURPOSE, so one layout serves BOTH arches: an
\ 8-byte field would refuse on x86's 32-bit cell and the whole parse would halt
\ on a field nobody was asking about. The 8-byte path is exercised separately.

struct
  4 le-field: e_magic          \ 7f 'E' 'L' 'F', read as an LE quad
  1    field: e_class          \ 1 = ELF32, 2 = ELF64
  1    field: e_data
  1    field: e_version1
  1    field: e_osabi
  1    field: e_abiversion     \ split out of the pad, for poke's implication
  7    field: e_pad            \ blob: addressable, not scalar-readable
  2 le-field: e_type
  2 le-field: e_machine
  4 le-field: e_version
  4 le-field: e_entry-lo
  4 le-field: e_entry-hi
  4 le-field: e_phoff-lo       \ the program-header table's file offset
  4 le-field: e_phoff-hi
  4 le-field: e_shoff-lo
  4 le-field: e_shoff-hi
  4 le-field: e_flags
  2 le-field: e_ehsize         \ the header's OWN size -- see below
  2 le-field: e_phentsize      \ the stride of the phdr array
  2 le-field: e_phnum          \ ...and its length
  2 le-field: e_shentsize
  2 le-field: e_shnum
  2 le-field: e_shstrndx
constant /elf64-ehdr

\ /elf64-ehdr is 0x40, and so is `e_ehsize` READ OUT OF THE FILE. That equality
\ is the layout checking itself against its own subject: a structure that
\ declares its own size is rare and this one does, so an offset that drifted
\ anywhere above would be caught by a field the drift itself moved. It costs
\ one assertion and it is stronger than any constant written down twice.

\ A SECOND VIEW of the same bytes, and it is the arch control. e_entry lives at
\ 0x18 in an ELF64 header; declaring it as ONE 8-byte little-endian field must
\ agree with e_entry-hi:e_entry-lo above on a 64-bit cell -- and must REFUSE by
\ name on a 32-bit one. Two views of one region that disagree would mean the
\ offsets are arithmetic nobody checked.

struct
  18   field: x-ident-and-more   \ blob up to e_entry
  8 le-field: x-entry
constant /elf64-entry

\ ── the ELF64 program header ───────────────────────────────────────
\ Its 8-byte members are declared as 4-byte little-endian halves for the same
\ reason the ehdr's are: one layout has to serve a 32-bit cell too.

struct
  4 le-field: p_type
  4 le-field: p_flags
  4 le-field: p_offset-lo   4 le-field: p_offset-hi
  4 le-field: p_vaddr-lo    4 le-field: p_vaddr-hi
  4 le-field: p_paddr-lo    4 le-field: p_paddr-hi
  4 le-field: p_filesz-lo   4 le-field: p_filesz-hi
  4 le-field: p_memsz-lo    4 le-field: p_memsz-hi
  4 le-field: p_align-lo    4 le-field: p_align-hi
constant /elf64-phdr

/elf64-phdr array: phdr[]

\ ── the ELF64 section header ───────────────────────────────────────
\ The SECOND table, which is what makes REVIEW §E3 worth having: `shdr[]` and
\ `phdr[]` are declared once each instead of the base/count/stride being spelled
\ out at every use.

struct
  4 le-field: sh_name          \ an offset into the section-name string table
  4 le-field: sh_type
  4 le-field: sh_flags-lo   4 le-field: sh_flags-hi
  4 le-field: sh_addr-lo    4 le-field: sh_addr-hi
  4 le-field: sh_offset-lo  4 le-field: sh_offset-hi
  4 le-field: sh_size-lo    4 le-field: sh_size-hi
  4 le-field: sh_link
  4 le-field: sh_info
  4 le-field: sh_addralign-lo  4 le-field: sh_addralign-hi
  4 le-field: sh_entsize-lo    4 le-field: sh_entsize-hi
constant /elf64-shdr

/elf64-shdr array: shdr[]

\ ── the mapped file ────────────────────────────────────────────────
\ poke says `var f = Elf64_File @ 0#B` and then `f.ehdr.e_type`. The Forth
\ equivalent of that binding is a VALUE: set it once, and every word below takes
\ no arguments. It is also the honest shape -- there is no copy, only a base.

0 value @elf
: elf-at ( adr -- )  to @elf ;
\ NO `: elf @elf ;` CONVENIENCE ALIAS. It was here for one commit and the
\ firmware answered `elf isn't unique.` -- forth/debugging/client.fs:79 already
\ defines `1 constant elf`, and shadowing it would have broken the
\ client-program debugging path for a spelling nobody needed. @elf is the name.

: elf-phnum ( -- n )   @elf e_phnum t@ ;
: elf-shnum ( -- n )   @elf e_shnum t@ ;
: elf-phtab ( -- adr ) @elf  @elf e_phoff-lo t@ + ;
: elf-shtab ( -- adr ) @elf  @elf e_shoff-lo t@ + ;
: elf-ph ( i -- adr )  elf-phtab swap phdr[] ;
: elf-sh ( i -- adr )  elf-shtab swap shdr[] ;

\ ── §E1: constraints — this REFUSES a file it cannot describe ──────
\ Every line names what it wants and prints what it got. ?elf64 is driven
\ against a deliberately corrupted copy in `smoke-openbios.sh elf-methods`,
\ because a validator that has never rejected anything is a scan that matches
\ nothing.

: ?elf64 ( -- )
  @elf e_magic  t@ 464c457f     s" bad ELF magic (want 7f 'E' 'L' 'F')"      chk
  @elf e_class  t@ 2            s" not ELF64 (e_class)"                     chk
  @elf e_data   t@ 1            s" big-endian ELF: this layer declares byte order per field, so it would MISREAD one (REVIEW E2)" chk
  @elf e_ehsize t@ /elf64-ehdr  s" e_ehsize disagrees with the layout"      chk
  elf-phnum 0<> if
    @elf e_phentsize t@ /elf64-phdr s" e_phentsize disagrees with the layout" chk
  then
  elf-shnum 0<> if
    @elf e_shentsize t@ /elf64-shdr s" e_shentsize disagrees with the layout" chk
    @elf e_shstrndx t@ elf-shnum    s" e_shstrndx is past the last section"   chk<
  then
  \ poke-elf spells this `ei_osabi == ELF_OSABI_NONE => ei_abiversion == 0`.
  \ `a => b` is `a 0= b or`, which is all an implication ever was.
  @elf e_osabi t@ 0=  0=  @elf e_abiversion t@ 0=  or
    s" e_abiversion must be 0 when e_osabi is NONE" chk? ;

\ Every PT_LOAD segment must fit inside the file, which is the check that
\ catches a truncated or lying image -- poke-elf's elf64_check_phdr.
: ?phdrs ( filesize -- )
  elf-phnum 0 ?do
    i elf-ph dup p_type t@ 1 = if
      dup p_offset-lo t@ over p_filesz-lo t@ +  2 pick u> 0=
        s" a PT_LOAD segment runs past the end of the file" chk?
    then drop
  loop drop ;

\ ── §E4: methods — semantics, not layout ───────────────────────────
\ poke-elf's get_load_base and vaddr_to_file_offset. These are the two the
\ REVIEW calls the most useful thing in the whole pickle for this repo, because
\ "which bytes become that address at run time" is what boot forensics asks.

\ min p_vaddr over PT_LOAD -- poke's get_load_base.
\
\ THE COMPARISON MUST BE UNSIGNED, and the first draft used `min`, which is
\ SIGNED. With `ffffffff` as the starting sentinel that is +4294967295 on a
\ 64-bit cell and -1 on a 32-bit one, so amd64 answered 100000 and x86 answered
\ ffffffff -- the sentinel winning every comparison. A bug that exists only on
\ the narrow cell, found only because the track runs on both arches.
: elf-load-base ( -- vaddr )
  -1                                   \ max unsigned, at either cell width
  elf-phnum 0 ?do
    i elf-ph dup p_type t@ 1 = if
      p_vaddr-lo t@                    ( acc v )
      2dup u< if drop else swap drop then
    else drop then
  loop ;

0 value _va
0 value _ph
: seg-holds? ( -- flag )        \ does _ph's PT_LOAD range contain _va ?
  _ph p_type t@ 1 <> if false exit then
  _va  _ph p_vaddr-lo t@  dup _ph p_memsz-lo t@ +  within ;

: vaddr>off ( vaddr -- fileoff | -1 )   \ poke's vaddr_to_file_offset
  to _va  -1
  elf-phnum 0 ?do
    i elf-ph to _ph
    dup -1 = seg-holds? and if
      drop  _va _ph p_vaddr-lo t@ -  _ph p_offset-lo t@ +
    then
  loop ;

\ The string table, which poke spells `string @ shdr[strtab].sh_offset + off`.
: elf-shstrtab ( -- adr )  @elf e_shstrndx t@ elf-sh sh_offset-lo t@ @elf + ;
: sh-name ( i -- adr )     elf-sh sh_name t@ elf-shstrtab + ;

\ ── names for the values a human actually reads (a small §E6) ──────
: .p-type ( n -- )          \ fixed 7 columns, so the table lines up
  dup 1 = if ." LOAD   " else dup 2 = if ." DYNAMIC" else
  dup 3 = if ." INTERP " else dup 4 = if ." NOTE   " else
  dup 6 = if ." PHDR   " else dup 7 = if ." TLS    " else
  dup 0 = if ." NULL   " else ." t" dup 6 u.r
  then then then then then then then drop ;

: .sh-type ( n -- )         \ fixed 8 columns
  dup 1 = if ." PROGBITS" else dup 2 = if ." SYMTAB  " else
  dup 3 = if ." STRTAB  " else dup 4 = if ." RELA    " else
  dup 6 = if ." DYNAMIC " else dup 7 = if ." NOTE    " else
  dup 8 = if ." NOBITS  " else dup b = if ." DYNSYM  " else
  dup 0 = if ." NULL    " else ." t" dup 7 u.r
  then then then then then then then then then drop ;

\ §G4's bit-fields, and the one place they are obviously worth it.
: .p-flags ( n -- )
  dup 2 bit? if ." R" else ." -" then
  dup 1 bit? if ." W" else ." -" then
      0 bit? if ." X" else ." -" then ;

: .name-pad ( adr width -- )
  over cstr-len swap over - 0 max >r drop .cstr r> spaces ;

\ ── exploring: readelf's three most-used views, at the 0 > prompt ──
: .elf ( -- )
  ." ELF64  entry=" @elf e_entry-lo t@ u.
  ."  phnum=" elf-phnum u. ."  shnum=" elf-shnum u.
  ."  ehsize=" @elf e_ehsize t@ u. cr ;

: .phdrs ( -- )
  ." idx type     flg offset   vaddr    filesz   memsz" cr
  elf-phnum 0 ?do
    i 3 u.r ."  " i elf-ph
    dup p_type t@ .p-type ."  "
    dup p_flags t@ .p-flags ."  "
    dup p_offset-lo t@ 8 u.r
    dup p_vaddr-lo  t@ 8 u.r
    dup p_filesz-lo t@ 8 u.r
        p_memsz-lo  t@ 8 u.r cr
  loop ;

: .sections ( -- )
  ." idx name                 type      addr     offset   size" cr
  elf-shnum 0 ?do
    i 3 u.r ."  " i sh-name 14 .name-pad
    i elf-sh
    dup sh_type t@ .sh-type ."  "
    dup sh_addr-lo   t@ 8 u.r
    dup sh_offset-lo t@ 8 u.r
        sh_size-lo   t@ 8 u.r cr
  loop ;

\ ── authoring: build a valid header, then validate it with the SAME
\ ── constraint that rejects a bad one ──────────────────────────────
: elf-new ( adr -- )
  dup /elf64-ehdr erase
  dup elf-at
  464c457f    @elf e_magic     t!
  2           @elf e_class     t!
  1           @elf e_data      t!
  1           @elf e_version1  t!
  2           @elf e_type      t!
  3e          @elf e_machine   t!
  1           @elf e_version   t!
  /elf64-ehdr @elf e_ehsize    t!
  /elf64-phdr @elf e_phentsize t!
  /elf64-shdr @elf e_shentsize t!
  drop ;
