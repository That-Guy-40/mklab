\ struct.fth — a TYPE layer over OpenBIOS Forth, for REVIEW G2.
\
\ THIS FILE IS THE ENGINE. The ELF layouts that used to live here moved to
\ dsl/elf.fth on 2026-08-30, which is poke's own structure (elf-64.pk is a
\ separate pickle from libpoke) and REVIEW §E6's lesson applied to ourselves:
\ keeping the format out of the engine is why elf-64.pk stays 446 readable
\ lines. Load this first, then whichever format you are looking at.
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

\ ── §E3: a TABLE — an array whose BASE and COUNT are fields of a header ─────
\ poke:  Elf64_Phdr[ehdr.e_phnum] phdr @ ehdr.e_phoff
\ Three things bound once: the field the OFFSET is read from, the field the
\ COUNT is read from, and the stride. `array:` gives the stride and nothing
\ else, so until 2026-09-03 the other two were spelled out at every use
\ (elf64-phtab, elf64-phnum, elf64-ph -- REVIEW E3's complaint, verbatim). A
\ table takes the two field words by xt, because a field word is what knows
\ its own offset/width/order: `' e_phoff-lo ' e_phnum /elf64-phdr table: NAME`.
\
\ THIS IS THE OFFSET-MODE `file:`; vfield: (below) IS THE CURSOR-MODE ONE. The
\ plan's Spike 0 wrote that "vfield: IS the cursor-mode file:" and read that as
\ answering E3 -- it did not: E3's example is a member mapped AT an offset read
\ from an earlier member, with a count from another, not a member whose bytes
\ FOLLOW its length. Both shapes exist in the subjects (ELF's phdr/shdr tables
\ are offset-mode; a TLV note, an event-log entry and an FDT token stream are
\ cursor-mode), so both definers exist, and the decision is written here.
\
\ tbl@ is BOUND-CHECKED. An index at or past the count is refused by name
\ (T-ERR-index), because `array:` at a bad index reads N plausible structures out
\ of whoever's bytes come next and every field "succeeds" -- the same silence
\ the stride control in `struct-array` exists to expose.
: table: ( off-xt count-xt stride "name" -- )  create , , , ;
: tbl-stride ( tbl -- n )        @ ;
: tbl-count  ( hdr tbl -- n )    cell+ @ execute t@ ;
: tbl-base   ( hdr tbl -- adr )  over swap 2 cells + @ execute t@ + ;
: tbl-index-err ( i n -- )  ." T-ERR-index=" swap u. ." count=" u. cr abort ;
: tbl@ ( hdr i tbl -- adr )
  >r  over r@ tbl-count           ( hdr i count )
  2dup u< 0= if r> drop tbl-index-err then
  drop  r@ tbl-stride *           ( hdr off )
  over r> tbl-base + nip ;


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
\ THE ONE CACHED FACT, said out loud: LOAD_BASE_PHYS itself is read from C and
\ selected here per arch. Nothing in the device tree publishes it. Publishing
\ virt_offset -- or implementing 1275's `map-in` -- would remove this last
\ constant; until then the pair below is checked by `smoke-openbios.sh
\ struct-device`, which paints through it and reads PHYSICAL memory back from
\ outside the firmware.
\
\ SELECTING IT BY CELL WIDTH ALONE WAS A BUG (fixed 2026-09-02, B.3 Spike 0).
\ `/n 8 =` reads as "amd64/unix : x86", but ppc is ALSO 32-bit and its
\ LOAD_BASE_PHYS is 0x4000000, not x86's 0x400000 -- so a 32-bit cell silently
\ handed ppc x86's value and >virt/>phys were wrong-by-construction there. The
\ real discriminator is RELOCATION, and only x86 relocates: arch/x86/segment.c
\ reassigns virt_offset, while arch/{amd64,ppc,unix} set it to 0 and never touch
\ it (source-confirmed), so their load-base == load-base-phys (identity) and the
\ constant is 0x4000000. x86 is the 32-bit LITTLE-endian target; ppc is 32-bit
\ BIG-endian -- so among 32-bit arches the NATIVE CPU byte order tells them
\ apart, and byte order is exactly what makes a physical access differ, so it is
\ the property to measure rather than a proxy for it. Measured on all four
\ (B.3 Spike 0): amd64/unix lbp=4000000, ppc lbp=4000000 (nbe=-1), x86 lbp=400000
\ (nbe=0). x86/amd64 values are UNCHANGED by this rewrite; only ppc moves.

\ native-be? ( -- flag )  true if the CPU is big-endian, measured by a NATIVE
\ 32-bit store read back a byte at a time (l! is native order; le-l! is not).
variable (be-probe)
: native-be? ( -- flag )  12345678 (be-probe) l!  (be-probe) c@ 12 = ;

: load-base-phys ( -- p )
  /n 8 = if 4000000 else                    \ 64-bit: amd64/unix, identity
    native-be? if 4000000 else 400000 then  \ 32-bit: ppc (BE) : x86 (LE)
  then ;
: >virt ( phys -- adr )    load-base-phys - load-base + ;
: >phys ( adr -- phys )    load-base - load-base-phys + ;

\ ── constraints: the primitive REVIEW §E1 is about ─────────────────
\ GNU poke attaches a predicate to a field and REFUSES TO MAP when it is false
\ (`Elf_Half e_shstrndx : e_shnum == 0 || e_shstrndx < e_shnum;`). The layer so
\ far refuses what it CANNOT REPRESENT -- a width it does not implement, an
\ 8-byte field on a 32-bit cell -- and says nothing about what it SHOULD NOT
\ ACCEPT. This is that other half, and it is the same idea: a plausible wrong
\ number is worse than an honest stop.
\
\ THE FIRST DESIGN DID NOT WORK, and the failure is worth keeping. `chk"` was
\ built as an immediate word wrapping abort" -- `postpone chk-report postpone
\ abort"` -- on the assumption that POSTPONE of an immediate word defers its
\ compilation semantics. In this Forth it does not: the string was never parsed
\ and the firmware answered `never": undefined word.` So the message is passed
\ as an ordinary string instead, which needs no immediacy and reads at least as
\ well:
\
\     @elf e_class t@ 2 s" not ELF64 (e_class)" chk
\
\ Each prints BOTH values on failure, because "constraint failed" without them
\ sends you back to the prompt to find out which.
\
\ THE CONSTRAINT MUST NOT BE THE ONLY CHECK OF ITSELF: a validator that has
\ never rejected anything is a scan that matches nothing. Every `?`-word that
\ ships here is driven, in `smoke-openbios.sh elf-methods`, against a
\ deliberately corrupted copy as well as a real one.

\ chk  ( actual expected c-addr u -- )   equal, or report both and abort
: chk
  2over = if 2drop 2drop exit then
  cr ." CONSTRAINT: " type ."  -- want=" u. ."  got=" u. cr abort ;

\ chk< ( n limit c-addr u -- )           unsigned n < limit, or abort
: chk<
  2over u< if 2drop 2drop exit then
  cr ." CONSTRAINT: " type ."  -- limit=" u. ."  got=" u. cr abort ;

\ chk? ( flag c-addr u -- )              an arbitrary predicate, incl. poke's
\                                        `=>` implication as `0= swap or`
: chk?
  rot if 2drop exit then
  cr ." CONSTRAINT: " type cr abort ;

\ ── bit-fields (REVIEW §G4: "cheap, do it") ────────────────────────
\ Mask-and-shift over primitives the kernel already has. A p_flags RWX triple or
\ an st_info bind/type split is two of these and nothing else.
: bits@ ( value lsb width -- field )  1 swap lshift 1- -rot rshift and ;
: bit?  ( value n -- flag )           1 swap lshift and 0<> ;

\ ── read-modify-write a field: set / clear / toggle bits ───────────
\ FROM mudge, "FORTH Hacking on Sparc Hardware", Phrack 53:9 (1998) --
\ ../upstream-tutorial/. His canonical example is a read-modify-write on a
\ device register:
\
\     :light-on   1 aux@ or aux!       ;   \ set bit 0 of the aux register
\     :light-off  1 invert aux@ and aux! ;  \ clear bit 0
\
\ GENERALISED HERE, and deliberately NOT named for an LED. These set/clear/
\ toggle bits in a TYPED field, so the width, byte order and address space ride
\ along -- the same word works on a scratch byte and on a device register
\ (dev-field:), which is where mudge's `aux@ or aux!` actually lived. or /
\ and-not / xor are the three ops he uses across both programs in the article.
\
\ THE WHOLE POINT IS THAT THEY PRESERVE THE OTHER BITS. That is why mudge wrote
\ `1 aux@ or aux!` and not `1 aux!`: a bare store clobbers every other bit in
\ the register. On a device register that is not a nicety, it is correctness --
\ the neighbouring bits belong to other functions. `smoke-openbios.sh
\ rmw-fields` proves the neighbour survives, with a bare `t!` as the control
\ that shows it does not.

: t-set ( mask adr tid -- )  rot        >r  2dup t@  r> or  -rot t! ;
: t-clr ( mask adr tid -- )  rot invert >r  2dup t@  r> and -rot t! ;
: t-tog ( mask adr tid -- )  rot        >r  2dup t@  r> xor -rot t! ;

\ ── named controls: mudge's light-on flavour, generalised ──────────
\ t-set/t-clr/t-tog still take a mask, a field and a base every time. A CONTROL
\ bakes all three behind a name -- the way mudge's `light-on` baked in "bit 0 of
\ the aux register" -- so the verbs read as English and the read-modify-write,
\ the mask, the byte order and the address are all hidden:
\
\     struct  1 dev-field: d-ch  1 dev-field: d-at  constant /dc
\     /dc array: dcell[]
\     b8000 >virt 800 dcell[] value spare   \ cell 800 is PAST the 7d0-cell
\     spare d-at  10  control: backlight    \ screen; d-at is the attr, at +1
\     backlight enable        \ set the bit(s), preserving the rest
\     backlight disable
\     backlight toggle
\     backlight enabled?       \ -1 if any masked bit is set
\
\ NOT `on`/`off`: those are the firmware's own flag setters
\ (bootstrap.fs:599-600, `variable x  x on`), and `control` is taken too --
\ shadowing either is the `elf isn't unique.` mistake. The verbose names are
\ the ones that are free AND the ones that read better.
\
\ A control stores ( mask tid adr ) and re-pushes ( mask adr tid ) -- exactly
\ what the three verbs (and enabled?) consume, so no juggling at the call site.
\ mudge's own words come back as one-liners on top: `: light-on backlight enable ;`

: control: ( adr tid mask "name" -- )
  create , , ,                    \ +0 mask  +1 tid  +2 adr
  does>  dup @  over 2 cells + @  rot cell+ @ ;   \ ( -- mask adr tid )

: enable   ( mask adr tid -- )       t-set ;
: disable  ( mask adr tid -- )       t-clr ;
: toggle   ( mask adr tid -- )       t-tog ;
: enabled? ( mask adr tid -- flag )  rot >r t@ r> and 0<> ;

\ ── NUL-terminated strings, which poke spells `string @ offset` ────
\ REVIEW §E4 named this the smallest concrete gap in the layer: poke-elf's
\ get_section_name is a string read out of a string table, and there was no
\ string type here at all.
: cstr-len ( adr -- len )  dup begin dup c@ while 1+ repeat swap - ;
: cstr     ( adr -- adr len )  dup cstr-len ;
: .cstr    ( adr -- )  cstr type ;

\ ── a hex+ASCII dump, because exploring needs one ──────────────────
\ Not poke-derived; poke gives you this for free and a bare `0 >` prompt does
\ not. 16 bytes a line, address first, printable ASCII on the right.
: .hexbyte ( c -- )  dup 10 < if ." 0" then u. ;

\ CONTIGUOUS 2-hex, no trailing space — `.hexbyte` uses u. which appends one, so a
\ byte string it prints cannot be compared against a foreign hex digest (readelf's
\ Build ID, sha256sum) without the host normalising spaces. .hx2 prints exactly two
\ hex chars so `<n> 0 do a i + c@ .hx2 loop` is a digest a host can diff verbatim.
: .hex1 ( n -- )  dup a < if 30 + else 57 + then emit ;   \ 0-9a-f, base HEX
: .hx2  ( c -- )  dup 4 rshift .hex1  f and .hex1 ;
\ .hx8 ( u -- ) the low 32 bits as 8 fixed hex digits, MSB first, no space -- a
\ u32 field a host can diff against a formatter's column. Width-agnostic: it reads
\ nibbles by shifting the value RIGHT, so it works on a 32- and a 64-bit cell alike.
: .hx8  ( u -- )  8 0 do  dup  1c i 4 * -  rshift  f and  .hex1  loop  drop ;
: .ascii   ( adr n -- )
  0 do dup i + c@ dup 20 7f within if emit else drop 2e emit then loop drop ;
: dump ( adr len -- )
  over + swap ?do
    i 8 u.r ." : "
    10 0 do
      i j + c@ .hexbyte
      i 7 = if ."  " then
    loop
    ."  |" i 10 .ascii ." |" cr
  10 +loop ;

\ ── the CURSOR: length-prefixed / TLV records (B.3 Spike 0) ─────────
\ The static layer above (field:/array:) bakes every offset at COMPILE time --
\ `base field: → adr` -- which is exactly right for a fixed header (ELF, a CBFS
\ master header) and CANNOT express a record whose later offsets depend on a
\ length read at RUNTIME (a TCG event-log entry, an ELF note, a CBFS file name).
\
\ THE MODEL DECISION (Spike 0, option A vs B), decided by building it: this is
\ OPTION B -- a PARALLEL cursor vocabulary, `field:`/`array:`/`(tfield)` left
\ UNTOUCHED. Why not A (a cursor mode inside the field word): `t@ ( adr tid -- u )`
\ is ALREADY offset-agnostic -- it reads width/order/space from the tid and takes
\ the address from the caller; the offset is added by the FIELD WORD's `does>`,
\ never by `t@`. So a length-prefixed walk needs no change to `field:` at all,
\ only (i) a running cursor to feed `t@` and (ii) a BARE tid per element. Baking a
\ cursor into the field word would contaminate the static-offset path the headers
\ rely on, for nothing. Proven byte-identical on unix/amd64/x86/ppc, 2026-09-02.

\ type: a BARE type id (no baked offset), for the cursor. `field:` yields
\ ( base -- adr tid ); a walk has no static base, so `type:` builds the same
\ 4-cell tid t@/t! already understand (+0 off, +1 width, +2 order, +3 space) but
\ the created word yields ( -- tid ): its own pfa. `<width> <order> <space> type:`.
: type: ( width order space "name" -- )  create 0 , rot , swap , , ;

\ the cursor. A record is walked by a running address; rec-base anchors alignment
\ (TLV padding is relative to the record start, not the absolute address).
variable rec-base
variable rec-cur
: >rec    ( adr -- )  dup rec-base ! rec-cur ! ;
: rec@    ( -- adr )  rec-cur @ ;
: +rec    ( n -- )    rec-cur +! ;
: rec-off ( -- n )    rec-cur @ rec-base @ - ;

\ alignto ( n -- ) advance the cursor so (cur-base) is the next multiple of n.
\ aligned = (off + n - 1) / n * n ; cur = base + aligned.
: alignto ( n -- )  dup rec-off + 1- over / * rec-base @ + rec-cur ! ;

\ read/store a fixed field AT the cursor, then advance by its width -- composing
\ with the SAME t@/t! machinery as every header field, so a length prefix is read
\ through the width/endian-aware path, never a raw fetch (the property the ppc
\ negative control defends: a bare l@ there would byte-swap and only ppc notices).
: t@+ ( tid -- u )  rec@ over t@  swap t-width +rec ;
\ t!+ is NOT the mirror of t@+: t! takes THREE items ( u adr tid ) where t@ takes
\ two ( adr tid ), so the `rec@ over` shape that works for t@+ mis-orders t!'s args
\ (it fed t! the tid as the value and wrote a dictionary pointer to storage — found
\ 2026-09-02 by the amd64 NVDIMM control, the first user of t!+). Save the tid for
\ the width, then present exactly ( u adr tid ).
: t!+ ( u tid -- )  dup >r  rec@ swap  t!  r> t-width +rec ;

\ vfield: a length-PREFIXED byte field -- poke's cursor-mode `file:` in one line
\ (a member whose extent is read from an earlier member). `<prefix-tid> vfield:
\ NAME` makes NAME ( -- adr len ): read the length through the prefix tid
\ (advancing past it), then hand back the bytes and advance past them. The count
\ is a RUNTIME value -- what the static-offset model cannot express, and the
\ whole reason this section exists.
: vfield: ( ptid "name" -- )
  create ,
  does>  ( -- adr len )  @ t@+  ( len )  rec@ over +rec  swap ;

\ vbytes ( len -- adr ) — the length-ALREADY-KNOWN complement to vfield:. Where
\ vfield: reads a prefix immediately before its bytes, vbytes takes a length read
\ EARLIER (Elf_Note reads namesz and descsz up front, three fields before name)
\ and hands back the current cursor, advancing past the len bytes.
: vbytes ( len -- adr )  rec@ swap +rec ;
