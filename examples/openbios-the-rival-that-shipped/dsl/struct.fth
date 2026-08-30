\ struct.fth — a TYPE layer over OpenBIOS Forth, for REVIEW G2.
\
\ WHAT THIS IS NOT. It is not a definer built from scratch: OpenBIOS already
\ ships one. `forth/bootstrap/bootstrap.fs:1570` has
\
\     0 constant struct
\     : field  create over , + does> @ + ;
\
\ so `struct  4 field a  2 field b  constant size` works at the prompt today and
\ `a` is ( base -- adr ). Measured on amd64 2026-08-29: size=7, offsets 0/4/6.
\ REVIEW-preboot-forth-as-a-poke-engine.md G2 said `create ... does>` "has never
\ been pointed at a structure" in THIS repo, which is true, and understated
\ upstream: the address half of the type layer has been sitting in the firmware
\ the whole time.
\
\ WHAT IS ACTUALLY MISSING is the TYPE. `field` carries an offset and nothing
\ else, so every read at a field has to re-state how wide it is and which byte
\ order it is in -- and that restatement is where a binary-structure parser goes
\ wrong. A field word here leaves ( base -- adr tid ): the ADDRESS FIRST, so a
\ bare store through it is still the write, and a type id after it so `t@`/`t!`
\ need no repetition.
\
\ WHY THE ADDRESS COMES FIRST, and it is the whole design. GNU poke's manual
\ specifies a three-step map/modify/POKE-BACK for a scalar --
\
\     (poke) var n = int @ offset
\     (poke) n = n + 1
\     (poke) int @ offset = n
\
\ -- because `n` is a copy. There is no copy here to write back FROM: a field
\ yields the address of the bytes themselves, so `t!` IS the write and so is a
\ bare `le-l!` through `t-adr`. That is REVIEW §P1 reached from the other side.
\
\ Base is HEX -- .fs/.fth sources compile in hex in OpenBIOS.
hex

\ ── the two accessors the firmware does not ship ────────────────────
\ le-w@/le-w!/le-l@/le-l! are bound in libopenbios/init.c:447-450 and l@-be/
\ l!-be are Forth in forth/device/property.fs. Nothing provides 2-byte BIG-endian
\ (1275 never needed it: a property cell is four bytes) or 8-byte either way.

: w@-be ( adr -- w )  dup c@ 8 lshift swap 1+ c@ or ;
: w!-be ( w adr -- )  over 8 rshift over c! 1+ swap ff and swap c! ;

\ 8 bytes will not fit a 32-bit cell. TRUNCATING IS THE ONE THING THIS MUST NOT
\ DO -- it is the LIED rung, and it is exactly the defect TODO 13.2(b) found in
\ l!-be. So the narrow cell REFUSES BY NAME instead, and on x86 that refusal is
\ the observable: an honest halt, not a number that is wrong by four bytes.
: ?x-cell ( -- )
  /n 8 < if
    ." T-ERR-narrow-cell" cr
    abort
  then ;
: le-x@ ( adr -- x )  ?x-cell dup 4 + le-l@ 20 lshift swap le-l@ or ;
: le-x! ( x adr -- )  ?x-cell 2dup 4 + swap 20 rshift swap le-l! le-l! ;

\ ── the definer ────────────────────────────────────────────────────
\ Three cells per field: offset, width, order (0 = big-endian, the 1275 native
\ order; 1 = little-endian, which is every x86 binary structure). Endianness is
\ PER FIELD because a real structure mixes them -- a 1275 property cell inside a
\ little-endian handoff page is not hypothetical.

\ ── the SECOND backend: device registers ───────────────────────────
\ GNU poke's IO spaces are seven function pointers and eight backends
\ (REVIEW §P2); the same layout applied over a file, over memory, or over a
\ device is the whole point of that split. Forth's version of the split is
\ already in IEEE 1275: 5.3.7.2's rb@/rw@/rl@/rb!/rw!/rl! are the
\ device-register accessors, distinct from c@/w@/l@ precisely because a
\ platform may need a barrier or a bus byte-swap there.
\
\ **They were EMPTY in this firmware** and patch 49 gave them bodies -- see
\ forth/device/other.fs. Everything below is built from rb@/rb! ALONE, a byte
\ at a time, so the byte order is explicit rather than inherited from whatever
\ the host CPU does; that also means a device field behaves identically on x86
\ and amd64, which is what makes the arch comparison in the track meaningful.

: rw@-le ( adr -- w )  dup rb@ swap 1+ rb@ 8 lshift or ;
: rw@-be ( adr -- w )  dup rb@ 8 lshift swap 1+ rb@ or ;
: rw!-le ( w adr -- )  over ff and over rb! 1+ swap 8 rshift swap rb! ;
: rw!-be ( w adr -- )  over 8 rshift over rb! 1+ swap ff and swap rb! ;
: rl@-le ( adr -- l )  dup rw@-le swap 2 + rw@-le 10 lshift or ;
: rl@-be ( adr -- l )  dup rw@-be 10 lshift swap 2 + rw@-be or ;
: rl!-le ( l adr -- )  2dup 2 + swap 10 rshift swap rw!-le rw!-le ;
: rl!-be ( l adr -- )  2dup 2 + rw!-be swap 10 rshift swap rw!-be ;

\ ── the definer ────────────────────────────────────────────────────
\ FOUR cells per field: offset, width, order (0 = big-endian, the 1275 native
\ order; 1 = little-endian) and SPACE (0 = memory, 1 = device register).
\ Endianness is per field because a real structure mixes them; the space is per
\ field because a mapped region can span both -- a descriptor in RAM whose last
\ member is a doorbell is the ordinary case, not the exotic one.

: (tfield) ( off width order space -- off' )
  create
    >r >r               ( off width )   ( r: space order )
    over ,              \ +0  offset
    dup  ,              \ +1  width
    r>   ,              \ +2  order
    r>   ,              \ +3  space
    +                   ( off' )
  does>                 ( base pfa -- adr tid )
    dup >r @ + r>
  ;

: t-off   ( tid -- n )  @ ;
: t-width ( tid -- n )  cell+ @ ;
: t-order ( tid -- n )  cell+ cell+ @ ;
: t-space ( tid -- n )  cell+ cell+ cell+ @ ;
: t-adr   ( adr tid -- adr )  drop ;

: field:        ( off width -- off' )  0 0 (tfield) ;  \ big-endian  (1275 native)
: le-field:     ( off width -- off' )  1 0 (tfield) ;  \ little-endian
: dev-field:    ( off width -- off' )  0 1 (tfield) ;  \ ...through rb@/rb!
: le-dev-field: ( off width -- off' )  1 1 (tfield) ;

\ ── typed fetch and store ──────────────────────────────────────────
\ An unsupported width REFUSES and names the width. Returning a plausible number
\ for a width nobody implemented is how a parser reports success while reading
\ the wrong bytes; a `blob` field (e_ident, 16 bytes) is addressable and NOT
\ scalar-readable, and saying so is the point.

: t-width-err     ( width -- )  ." T-ERR-width=" . cr abort ;
: t-be64-err      ( -- )        ." T-ERR-be64" cr abort ;
: t-dev-width-err ( width -- )  ." T-ERR-devwidth=" . cr abort ;

: (t@mem) ( adr order width -- u )
  dup 1 = if 2drop c@                   else
  dup 2 = if drop if le-w@ else w@-be then else
  dup 4 = if drop if le-l@ else l@-be then else
  dup 8 = if drop if le-x@ else t-be64-err then else
  t-width-err then then then then ;

\ No 8-byte device field: a 64-bit register is not one access on a 32-bit bus,
\ and pretending otherwise is the split-transaction bug nobody sees until the
\ device latches half of it. Refused by name.
: (t@dev) ( adr order width -- u )
  dup 1 = if 2drop rb@                        else
  dup 2 = if drop if rw@-le else rw@-be then  else
  dup 4 = if drop if rl@-le else rl@-be then  else
  t-dev-width-err then then then ;

: (t!mem) ( u adr order width -- )
  dup 1 = if 2drop c!                   else
  dup 2 = if drop if le-w! else w!-be then else
  dup 4 = if drop if le-l! else l!-be then else
  dup 8 = if drop if le-x! else t-be64-err then else
  t-width-err then then then then ;

: (t!dev) ( u adr order width -- )
  dup 1 = if 2drop rb!                        else
  dup 2 = if drop if rw!-le else rw!-be then  else
  dup 4 = if drop if rl!-le else rl!-be then  else
  t-dev-width-err then then then ;

: t@ ( adr tid -- u )
  dup t-space >r
  dup t-order swap t-width                  ( adr order width )
  r> if (t@dev) else (t@mem) then ;

: t! ( u adr tid -- )
  dup t-space >r
  dup t-order swap t-width                  ( u adr order width )
  r> if (t!dev) else (t!mem) then ;

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
  8    field: e_pad            \ blob: addressable, not scalar-readable
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

\ ── arrays of a type ───────────────────────────────────────────────
\ The other half of GNU poke's COMPOSITE model, and the half a single mapped
\ struct does not reach. poke writes `Elf64_Phdr[ehdr.e_phnum] @ ehdr.e_phoff`;
\ the Forth equivalent is a stride and an index, which is what `array:` is.
\
\ `<stride> array: NAME` creates NAME ( base index -- elem-base ), so a field
\ word composes straight onto it:
\
\     phtab i phdr[] p_filesz-lo t@
\
\ THE STRIDE IS DECLARED, AND THE SUBJECT ALSO STATES IT. An ELF header carries
\ `e_phentsize`; a declaration that disagrees with it is a layout describing a
\ different file, so the caller is expected to compare the two rather than trust
\ either. That comparison is the array's version of the poison byte: without it,
\ walking N elements at the wrong stride reads N plausible structures out of the
\ middle of somebody else's bytes and every field "succeeds".

: array: ( stride -- )
  create ,
  does>   ( base index pfa -- elem-base )
    @ * +
  ;

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

\ ── the address space, which a type layer does NOT give you ────────
\ A layout makes field access convenient. It does nothing whatsoever to make an
\ ADDRESS correct, and on arch/x86 the naive one is wrong in the worst way: the
\ store lands in ordinary RAM, reads back perfectly through the accessor that
\ wrote it, and never reaches the device.
\
\ x86 relocates itself by REBASING THE GDT (arch/x86/segment.c), so every Forth
\ address is segment-relative and the CPU adds virt_offset to reach physical
\ memory. amd64 does not relocate -- long mode ignores segment bases and
\ arch/amd64/segment.c sets virt_offset = 0 -- so there the two are the same.
\
\ virt_offset IS DERIVABLE AT THE PROMPT, and that is the whole trick.
\ arch/x86/openbios.c:573 defines the load-base constant as
\ `phys_to_virt(LOAD_BASE_PHYS)`, and phys_to_virt(P) is P - virt_offset
\ (include/arch/x86/io.h:9). So
\
\     virt_offset = LOAD_BASE_PHYS - load-base
\
\ and no C needs to publish anything. Measured on x86 2026-08-30:
\ load-base = e0670bd0, so virt_offset = 1fd8f430 -- and note that
\ arch/x86/context.c:189 records 1fd8fe50 from 2026-08-26. Both are right for
\ the tree they were measured on: relocation targets the TOP of RAM, so the
\ value moves whenever the image size does. It is a fact to DERIVE, never one
\ to write down -- which is exactly why this computes it every time.
\
\ THE ONE CACHED FACT, said out loud: LOAD_BASE_PHYS itself is read from C
\ (arch/x86/openbios.c:32 = 400000; forth/admin/nvram.fs's amd64 arm = 4000000)
\ and is selected here by cell width. Nothing in the device tree publishes it.
\ Publishing virt_offset -- or implementing 1275's `map-in` -- would remove this
\ last constant; until then the pair below is checked by `smoke-openbios.sh
\ struct-device`, which paints through it and reads PHYSICAL memory back from
\ outside the firmware.

: load-base-phys ( -- p )  /n 8 = if 4000000 else 400000 then ;
: >virt ( phys -- adr )    load-base-phys - load-base + ;
: >phys ( adr -- phys )    load-base - load-base-phys + ;
