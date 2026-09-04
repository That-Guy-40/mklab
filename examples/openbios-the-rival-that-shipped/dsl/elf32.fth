\ elf32.fth — the OTHER ELF class, on top of dsl/struct.fth and dsl/elf.fth.
\
\ Load order: struct.fth, elf.fth, then this. It is OPTIONAL: without it every
\ generic word in elf.fth still works on an ELF64 and refuses an ELF32 by name.
\ Loading it fills in elf.fth's hooks and the generics dispatch on e_class.
\
\ WHAT IS SHARED IS SHARED LITERALLY. The first 0x18 bytes of an ELF header are
\ IDENTICAL in both classes -- e_ident[16], e_type, e_machine, e_version -- so
\ elf.fth's e_magic / e_class / e_data / e_version1 / e_osabi / e_abiversion /
\ e_type / e_machine / e_version address the right bytes in an ELF32 too, and
\ nothing is redeclared here. That shared prefix is what poke-elf keeps in
\ elf-common.pk; here it fell out of the offsets rather than being designed.
\
\ WHAT DIVERGES IS NOT JUST WIDTHS, and this is the part a careless port gets
\ wrong. From e_entry on, ELF32 uses 4-byte addresses and a 0x34-byte header
\ instead of 0x40. But the PROGRAM HEADER also REORDERS its fields:
\
\     ELF64  p_type p_flags p_offset p_vaddr p_paddr p_filesz p_memsz p_align
\     ELF32  p_type p_offset p_vaddr p_paddr p_filesz p_memsz p_flags p_align
\
\ p_flags is the SECOND member in ELF64 and the SEVENTH in ELF32. A layer that
\ only narrowed the widths would read p_flags out of p_offset and never fault --
\ it would just print the wrong permissions, confidently. Checked against
\ poke-elf's elf-32.pk at ae45538, not against memory.
\
\ Base is HEX.
hex

\ ── the layouts ────────────────────────────────────────────────────
\ The header's first 0x18 bytes are elf.fth's; only what follows is declared.

struct
  18   field: e32-ident         \ the shared prefix, addressed by elf.fth
  4 le-field: e32-entry
  4 le-field: e32-phoff
  4 le-field: e32-shoff
  4 le-field: e32-flags
  2 le-field: e32-ehsize
  2 le-field: e32-phentsize
  2 le-field: e32-phnum
  2 le-field: e32-shentsize
  2 le-field: e32-shnum
  2 le-field: e32-shstrndx
constant /elf32-ehdr             \ 0x34, and the file says so in e32-ehsize

struct
  4 le-field: p32-type
  4 le-field: p32-offset
  4 le-field: p32-vaddr
  4 le-field: p32-paddr
  4 le-field: p32-filesz
  4 le-field: p32-memsz
  4 le-field: p32-flags          \ SEVENTH here, SECOND in ELF64
  4 le-field: p32-align
constant /elf32-phdr             \ 0x20

struct
  4 le-field: s32-name
  4 le-field: s32-type
  4 le-field: s32-flags
  4 le-field: s32-addr
  4 le-field: s32-offset
  4 le-field: s32-size
  4 le-field: s32-link
  4 le-field: s32-info
  4 le-field: s32-addralign
  4 le-field: s32-entsize
constant /elf32-shdr             \ 0x28

/elf32-phdr array: phdr32[]
/elf32-shdr array: shdr32[]

\ ── the same shape as the 64-bit half ──────────────────────────────

' e32-phoff ' e32-phnum /elf32-phdr table: phdr32-table
' e32-shoff ' e32-shnum /elf32-shdr table: shdr32-table

: elf32-phnum ( -- n )   @elf phdr32-table tbl-count ;
: elf32-shnum ( -- n )   @elf shdr32-table tbl-count ;
: elf32-phtab ( -- adr ) @elf phdr32-table tbl-base ;
: elf32-shtab ( -- adr ) @elf shdr32-table tbl-base ;
: elf32-ph ( i -- adr )  @elf swap phdr32-table tbl@ ;
: elf32-sh ( i -- adr )  @elf swap shdr32-table tbl@ ;

\ ── §E1: constraints ───────────────────────────────────────────────
\ The mirror of ?elf64, including the class check pointed the other way -- so an
\ ELF64 handed to the 32-bit half is refused just as loudly as the reverse.

: ?elf32 ( -- )
  @elf e_magic   t@ 464c457f      s" bad ELF magic (want 7f 'E' 'L' 'F')"  chk
  @elf e_class   t@ 1             s" not ELF32 (e_class)"                  chk
  @elf e_data    t@ 1             s" big-endian ELF: this layer declares byte order per field, so it would MISREAD one (REVIEW E2)" chk
  @elf e32-ehsize t@ /elf32-ehdr  s" e32-ehsize disagrees with the layout" chk
  elf32-phnum 0<> if
    @elf e32-phentsize t@ /elf32-phdr s" e32-phentsize disagrees with the layout" chk
  then
  elf32-shnum 0<> if
    @elf e32-shentsize t@ /elf32-shdr s" e32-shentsize disagrees with the layout" chk
    @elf e32-shstrndx t@ elf32-shnum  s" e32-shstrndx is past the last section"   chk<
  then
  @elf e_osabi t@ 0= 0=  @elf e_abiversion t@ 0=  or
    s" e_abiversion must be 0 when e_osabi is NONE" chk? ;

: ?phdrs32 ( filesize -- )
  ?ph-order-begin                          \ the gABI ordering rule, shared with ?phdrs64
  elf32-phnum 0 ?do
    i elf32-ph dup p32-type t@ dup ?ph-order 1 = if
      dup p32-offset t@ over p32-filesz t@ +  2 pick u> 0=
        s" a PT_LOAD segment runs past the end of the file" chk?
    then drop
  loop drop ;

\ ── §E4: methods ───────────────────────────────────────────────────

: elf32-load-base ( -- vaddr )
  -1                                   \ max unsigned; `min` is SIGNED, see elf.fth
  elf32-phnum 0 ?do
    i elf32-ph dup p32-type t@ 1 = if
      p32-vaddr t@  2dup u< if drop else swap drop then
    else drop then
  loop ;

0 value _va32
0 value _ph32
: seg32-holds? ( -- flag )
  _ph32 p32-type t@ 1 <> if false exit then
  _va32  _ph32 p32-vaddr t@  dup _ph32 p32-memsz t@ +  within ;

: vaddr32>off ( vaddr -- fileoff | -1 )
  to _va32  -1
  elf32-phnum 0 ?do
    i elf32-ph to _ph32
    dup -1 = seg32-holds? and if
      drop  _va32 _ph32 p32-vaddr t@ -  _ph32 p32-offset t@ +
    then
  loop ;

: elf32-shstrtab ( -- adr )  @elf e32-shstrndx t@ elf32-sh s32-offset t@ @elf + ;
: sh32-name ( i -- adr )     elf32-sh s32-name t@ elf32-shstrtab + ;

\ ── exploring ──────────────────────────────────────────────────────

: .elf32 ( -- )
  ." ELF32  entry=" @elf e32-entry t@ u.
  ."  phnum=" elf32-phnum u. ."  shnum=" elf32-shnum u.
  ."  ehsize=" @elf e32-ehsize t@ u. cr ;

: .phdrs32 ( -- )
  ." idx type     flg offset   vaddr    filesz   memsz" cr
  elf32-phnum 0 ?do
    i 3 u.r ."  " i elf32-ph
    dup p32-type t@ .p-type ."  "
    dup p32-flags t@ .p-flags ."  "
    dup p32-offset t@ 8 u.r
    dup p32-vaddr  t@ 8 u.r
    dup p32-filesz t@ 8 u.r
        p32-memsz  t@ 8 u.r cr
  loop ;

: .sections32 ( -- )
  ." idx name                 type      addr     offset   size" cr
  elf32-shnum 0 ?do
    i 3 u.r ."  " i sh32-name 14 .name-pad
    i elf32-sh
    dup s32-type   t@ .sh-type ."  "
    dup s32-addr   t@ 8 u.r
    dup s32-offset t@ 8 u.r
        s32-size   t@ 8 u.r cr
  loop ;

\ ── authoring ──────────────────────────────────────────────────────
: elf32-new ( adr -- )
  dup /elf32-ehdr erase
  dup elf-at
  464c457f    @elf e_magic      t!
  1           @elf e_class      t!
  1           @elf e_data       t!
  1           @elf e_version1   t!
  2           @elf e_type       t!
  3           @elf e_machine    t!      \ EM_386
  1           @elf e_version    t!
  /elf32-ehdr @elf e32-ehsize    t!
  /elf32-phdr @elf e32-phentsize t!
  /elf32-shdr @elf e32-shentsize t!
  drop ;

\ ── fill in elf.fth's hooks, so the generic names dispatch ─────────
' ?elf32          'x?elf   !
' ?phdrs32        'x?phdrs !
' .elf32          'x.elf   !
' .phdrs32        'x.phdrs !
' .sections32     'x.sects !
' elf32-load-base 'xlbase  !
' vaddr32>off     'xva>off !
' sh32-name       'xshname !
' elf32-phnum     'xphnum  !
' elf32-shnum     'xshnum  !
