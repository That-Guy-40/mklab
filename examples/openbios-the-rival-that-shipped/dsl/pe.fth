\ pe.fth — a PE/COFF section-table reader on dsl/struct.fth's types (roadmap Tier 1).
\
\ A UKI is a PE/COFF (.efi) application with the kernel, initramfs, cmdline and
\ os-release glued on as NAMED PE SECTIONS (.linux/.initrd/.cmdline/.osrel). To
\ grade any of them you must first WALK THE SECTION TABLE — which is this reader,
\ the prerequisite the UKI workbench's Spike 2 names (UKI_WORKBENCH_LAB_PLAN.md).
\ The depth is that plan's floor, "A": the headers, the section table, and
\ find-by-name. The data directories and the signed-region hash (its B/C) grow
\ along the SIGNATURE path, later, and are deliberately NOT here.
\
\ PE IS LITTLE-ENDIAN ON EVERY TARGET — unlike cpio's ASCII-hex, which has no
\ byte order at all. So every multi-byte field is read through struct.fth's
\ le-field: / le-w@ / le-l@, explicitly little-endian, never the host CPU's
\ native order — and THAT is what makes ppc a real negative-control row: a naive
\ `l@`/`w@` there would byte-swap the field and only the big-endian arch would
\ notice. The four-arch matrix grades that ppc reads the SAME section table as
\ x86, not a byte-swap of it.
\
\ TWO THINGS THE poke pe.pk ORACLE PINS, applied here (UKI plan §4a):
\  - LOCATE THE SECTION TABLE BY SizeOfOptionalHeader, never by walking to the
\    end of the PARSED optional header (they can disagree on a real image). This
\    is "assert the outcome, not the mechanism" in PE form — the size is the
\    authority, the parse is not.
\  - READ THE OPTIONAL-HEADER MAGIC FIRST (0x10b PE32 / 0x20b PE32+); a UKI is
\    PE32+. Depth A locates the table from the COFF header and reads fixed 40-byte
\    entries, so it does not branch on the magic — but it reads and SHOWS it,
\    because every optional-header field past it depends on the answer, and the
\    B/C growth will.
\
\ Refusals are BY NAME, the way cpio.fth's are — a malformed PE is REFUSED, never
\ read wrong and reported as success:
\   pe| BAD-MZ       no 'MZ' at file offset 0
\   pe| BAD-PESIG    no 'PE\0\0' at e_lfanew
\   pe| TRUNCATED    a header or the section table runs past the buffer end
\
\ Load struct.fth first, then this.
hex

\ ── the DOS stub: only e_lfanew matters ──────────────────────────────
\ File offset 0 is 'M','Z'; a 4-byte LE offset at 0x3c (e_lfanew) points at the
\ PE signature. The magic is a byte compare (endian-free); e_lfanew is le-l@.
: mz?    ( adr -- flag )  dup c@ [char] M =  swap 1+ c@ [char] Z =  and ;
: pe-off ( adr -- n )     3c + le-l@ ;

\ ── the PE signature + the COFF file header ───────────────────────────
\ At e_lfanew: 'P','E',0,0, then the 20-byte COFF header, then the optional
\ header (its first two bytes are the PE32/PE32+ magic). Fields are declared off
\ the SIGNATURE base; the 4 signature bytes are stepped over by the running
\ offset. The bracketed field words are read only to advance the layout; the
\ unbracketed ones are the reader's subjects.
: pesig? ( adr -- flag )
  dup     c@ [char] P =
  over 1+ c@ [char] E = and
  over 2 + c@ 0 = and
  swap 3 + c@ 0 = and ;

0
  4 le-field: (pe-sig)      \ +00  'P','E',0,0
  2 le-field: pe-machine    \ +04  u16 Machine        (0x8664 x86-64, 0x14c i386)
  2 le-field: pe-nsec       \ +06  u16 NumberOfSections
  4 le-field: (pe-tstamp)   \ +08  u32 TimeDateStamp
  4 le-field: (pe-symtab)   \ +0c  u32 PointerToSymbolTable
  4 le-field: (pe-nsym)     \ +10  u32 NumberOfSymbols
  2 le-field: pe-optsize    \ +14  u16 SizeOfOptionalHeader   ← locates the table
  2 le-field: (pe-chars)    \ +16  u16 Characteristics
  2 le-field: pe-optmagic   \ +18  u16 optional-header Magic  ← read and shown
constant /pe-coff           \ = 1a

\ the section table's offset FROM the signature base is past the signature (4)
\ and the COFF header (0x14 = 20) — then the optional header's DECLARED size.
18 constant pe-postcoff     \ 4 (signature) + 14 (COFF header)

\ ── one section-table entry: 40 (0x28) bytes, name at +0 ──────────────
\ The name is 8 bytes of ASCII, NUL-padded (a name filling all 8 has no NUL).
\ Names longer than 8 are '/'-offsets into a string table — a shape UKIs never
\ use and this reader does not resolve (such a name simply matches no query). The
\ name is addressed directly at the entry base, so it needs no field word; the
\ layout below therefore starts its running offset at 8.
8
  4 le-field: sec-vsize     \ +08  u32 VirtualSize
  4 le-field: sec-vaddr     \ +0c  u32 VirtualAddress
  4 le-field: sec-rawsize   \ +10  u32 SizeOfRawData
  4 le-field: sec-rawoff    \ +14  u32 PointerToRawData
  4 le-field: (sec-relocs)  \ +18  u32 PointerToRelocations
  4 le-field: (sec-lines)   \ +1c  u32 PointerToLinenumbers
  2 le-field: (sec-nreloc)  \ +20  u16 NumberOfRelocations
  2 le-field: (sec-nline)   \ +22  u16 NumberOfLinenumbers
  4 le-field: (sec-chars)   \ +24  u32 Characteristics
constant /pe-sec            \ = 28
/pe-sec array: pe-sec[]     \ ( sectab index -- entry-adr )

\ ── header state, set by pe-open ─────────────────────────────────────
variable pe-img            \ image base — the file is loaded contiguously here
variable pe-end            \ image base + length (one past the last byte)
variable pe-hdr            \ pe-img + e_lfanew — the signature base
variable pe-nsecs          \ NumberOfSections
variable pe-sectab         \ section-table base

\ pe-open ( adr len -- status )  0 ok / 1 BAD-MZ / 2 BAD-PESIG / 3 TRUNCATED
\ Validate MZ + 'PE\0\0', read the section count, LOCATE the section table by
\ SizeOfOptionalHeader, and bounds-check every span it will read. On ok the five
\ variables above are set; on a refusal the status names which invariant broke.
: pe-open ( adr len -- status )
  over pe-img !  over + pe-end !            ( adr )
  dup 40 + pe-end @ u> if drop 3 exit then  \ bytes through e_lfanew (0x3c..0x3f)
  dup mz? 0= if drop 1 exit then
  dup pe-off  pe-img @ +  pe-hdr !  drop    ( )  \ pe-hdr = img + e_lfanew
  pe-hdr @ /pe-coff + pe-end @ u> if 3 exit then \ COFF header + optmagic must fit
  pe-hdr @ pesig? 0= if 2 exit then
  pe-hdr @ pe-nsec t@ pe-nsecs !
  pe-hdr @ pe-postcoff +  pe-hdr @ pe-optsize t@ +  pe-sectab !
  pe-sectab @  pe-nsecs @ /pe-sec *  +  pe-end @ u> if 3 exit then
  0 ;

\ ── section names: an 8-byte inline compare ──────────────────────────
\ The name length: non-NUL bytes, capped at 8 (the field width).
: sec-namelen ( entry-adr -- n )
  0  begin  dup 8 < if 2dup + c@ else 0 then  while  1+  repeat  nip ;
: .secname ( entry-adr -- )  dup sec-namelen type ;

\ A query of length u (u<=8) matches when the entry's first u bytes equal it AND
\ (u==8, or the u'th byte is the NUL pad). The pad check is what keeps ".init"
\ from matching ".initrd" — without it a short query is a prefix match.
variable q-adr  variable q-len
: sec-name= ( entry-adr caddr u -- flag )
  dup 8 u> if drop 2drop false exit then
  q-len !  q-adr !                          ( entry-adr )
  dup q-len @  q-adr @ q-len @  $= 0= if drop false exit then
  q-len @ 8 = if drop true exit then         \ full 8: no pad byte to check
  q-len @ + c@ 0= ;                          \ else the pad byte must be NUL

\ the bytes of a section actually PRESENT in the file: VirtualSize, but never
\ more than SizeOfRawData. A section may declare more virtual space than it has
\ raw bytes (.bss-like); extracting past the raw data would read the next
\ section. min(vsize, rawsize).
: sec-len ( entry-adr -- n )
  dup sec-vsize t@  swap sec-rawsize t@  2dup u> if swap then drop ;

\ ── pe-walk ( adr len -- ok? ) ────────────────────────────────────────
\ Print machine/magic/section-count, then every section (name/vaddr/vsize/rawoff/
\ rawsize) — the columns objdump -h and poke's pe.pk print, so a host oracle
\ grades them directly. Refuses BY NAME and answers false on a malformed image.
: pe-walk ( adr len -- ok? )
  pe-open
  dup 1 = if drop ." pe| BAD-MZ"    cr false exit then
  dup 2 = if drop ." pe| BAD-PESIG" cr false exit then
  dup 3 = if drop ." pe| TRUNCATED" cr false exit then
  drop
  ." pe| machine=" pe-hdr @ pe-machine  t@ .hx8
  ."  magic="      pe-hdr @ pe-optmagic t@ .hx8
  ."  nsec="       pe-nsecs @ .hx8  cr
  pe-nsecs @ 0 ?do
    pe-sectab @ i pe-sec[]                   ( entry )
    ." pe| name="   dup .secname
    ."  vaddr="     dup sec-vaddr   t@ .hx8
    ."  vsize="     dup sec-vsize   t@ .hx8
    ."  rawoff="    dup sec-rawoff  t@ .hx8
    ."  rawsize="       sec-rawsize t@ .hx8  cr
  loop
  ." PE-END" cr true ;

\ ── locate a section-table entry by name (the shared primitive) ──────
\ Both pe-find (data+size) and the editor (dsl/pe-edit.fth) build on THIS, so the
\ editor reuses the reader's table walk rather than re-implementing it (Spike 2's
\ "assembly, not reimplementation"). pe-entry-of assumes pe-open has already
\ succeeded and scans for the name in peq-a/peq-l; pe-find-entry is the one-shot
\ (stash the name, open, scan) for a caller starting from raw bytes.
variable peq-a  variable peq-l
: pe-entry-of ( -- entry | 0 )                 \ AFTER pe-open
  pe-nsecs @ 0 ?do
    pe-sectab @ i pe-sec[]                      ( entry )
    dup peq-a @ peq-l @ sec-name=               ( entry flag )
    if unloop exit then
    drop
  loop  0 ;
: pe-find-entry ( adr len caddr u -- entry | 0 )
  peq-l ! peq-a !                              ( adr len )   \ stash the name
  pe-open if 0 exit then
  pe-entry-of ;

\ A section's raw data must lie WITHIN the loaded image. pe-open validates that the
\ section TABLE fits, but NOT each section's data extent — a malformed PE can name a
\ rawoff/rawsize that runs past the buffer. A reader that trusted it would read past
\ the end; an EDITOR (dsl/pe-edit.fth) would WRITE past it. This gate closes both.
\ in-image = the section's data end does NOT run past the buffer end; `u> 0=` is
\ the same "not beyond" test pe-open uses (this Forth has u</u>, not u<=).
: sec-in-image? ( entry -- flag )
  dup sec-rawoff t@  swap sec-rawsize t@  +  pe-img @ +  pe-end @ u> 0= ;

\ ── pe-find ( adr len caddr u -- data-adr size | 0 0 ) ────────────────
\ The named section's DATA address (image base + PointerToRawData) and its
\ meaningful length (sec-len). 0 0 if the section is absent, its data lies outside
\ the image, or the PE refused. This is the Spike 2 seam: `s" .initrd" pe-find`
\ hands the initramfs straight to cpio.fth's cpio-walk, and `s" .cmdline" pe-find`
\ hands the string to `type`.
: pe-find ( adr len caddr u -- data-adr size | 0 0 )
  pe-find-entry ?dup 0= if 0 0 exit then       ( entry )
  dup sec-in-image? 0= if drop 0 0 exit then    \ a section outside the image → 0 0
  dup sec-rawoff t@ pe-img @ +  swap sec-len ;
