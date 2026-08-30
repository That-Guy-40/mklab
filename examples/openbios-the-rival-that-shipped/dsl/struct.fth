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

: (tfield) ( off width order -- off' )
  create
    >r                  ( off width )        ( r: order )
    over ,              \ +0  offset
    dup  ,              \ +1  width
    r>   ,              \ +2  order
    +                   ( off' )
  does>                 ( base pfa -- adr tid )
    dup >r @ + r>
  ;

: t-off   ( tid -- n )  @ ;
: t-width ( tid -- n )  cell+ @ ;
: t-order ( tid -- n )  cell+ cell+ @ ;
: t-adr   ( adr tid -- adr )  drop ;

: field:    ( off width -- off' )  0 (tfield) ;   \ big-endian  (1275 native)
: le-field: ( off width -- off' )  1 (tfield) ;   \ little-endian

\ ── typed fetch and store ──────────────────────────────────────────
\ An unsupported width REFUSES and names the width. Returning a plausible number
\ for a width nobody implemented is how a parser reports success while reading
\ the wrong bytes; a `blob` field (e_ident, 16 bytes) is addressable and NOT
\ scalar-readable, and saying so is the point.

: t-width-err ( width -- )  ." T-ERR-width=" . cr abort ;
: t-be64-err  ( -- )        ." T-ERR-be64" cr abort ;

: t@ ( adr tid -- u )
  dup t-order swap t-width                  ( adr order width )
  dup 1 = if 2drop c@                   else
  dup 2 = if drop if le-w@ else w@-be then else
  dup 4 = if drop if le-l@ else l@-be then else
  dup 8 = if drop if le-x@ else t-be64-err then else
  t-width-err then then then then ;

: t! ( u adr tid -- )
  dup t-order swap t-width                  ( u adr order width )
  dup 1 = if 2drop c!                   else
  dup 2 = if drop if le-w! else w!-be then else
  dup 4 = if drop if le-l! else l!-be then else
  dup 8 = if drop if le-x! else t-be64-err then else
  t-width-err then then then then ;

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
constant /elf64-ehdr

\ A SECOND VIEW of the same bytes, and it is the arch control. e_entry lives at
\ 0x18 in an ELF64 header; declaring it as ONE 8-byte little-endian field must
\ agree with e_entry-hi:e_entry-lo above on a 64-bit cell -- and must REFUSE by
\ name on a 32-bit one. Two views of one region that disagree would mean the
\ offsets are arithmetic nobody checked.

struct
  18   field: x-ident-and-more   \ blob up to e_entry
  8 le-field: x-entry
constant /elf64-entry
