\ cpio.fth — a newc cpio reader on dsl/struct.fth's cursor (TODO §0.7).
\
\ The `newc` format — the one `u-root -o initramfs.cpio` writes and the kernel's
\ initramfs unpacker reads — is a sequence of members, each: a 110-byte header
\ (a 6-byte ASCII magic "070701", then THIRTEEN 8-char ASCII-HEX fields), the
\ NUL-terminated name padded so header+name is 4-aligned, the file data padded
\ to 4; the last member is named "TRAILER!!!". Length-prefixed, 4-aligned,
\ sequential: exactly the record the Spike-0 cursor (>rec/+rec/alignto/cstr) was
\ built for — plus ONE thing the width/endian integer types cannot express, a
\ field that is ASCII TEXT. So there is NO byte order to get wrong: the four-arch
\ matrix grades the hex PARSE, and ppc is a real row, not a byte-swap of x86.
\
\ Load struct.fth first, then this. The cursor is anchored at the ARCHIVE base
\ and never re-anchored, so `alignto 4` is archive-relative — which is precisely
\ newc's padding rule (every member begins on a 4-boundary because the previous
\ one ended on one). Refusals are BY NAME, the way fdt-read's are — a corrupt
\ archive is REFUSED, never read wrong and reported as success:
\   cpio| BAD-MAGIC    a member without the "070701" magic
\   cpio| TRUNCATED    a header/name/data that runs past the buffer end
\   cpio| NO-TRAILER   `max` members walked and no "TRAILER!!!" — a runaway
hex

\ ── the one new "type": 8 ASCII hex chars at the cursor, as a number ─────────
\ struct.fth's `type:` reads a width/endian INTEGER; a newc field is text. This
\ folds 'A'..'F' down to 'a'..'f' (bit 20) and accumulates base-16, advancing 8.
\ No endianness — the reason this reader's ppc row is not a swap of its x86 one.
: hexdig ( ch -- n )
  dup [char] 9 > if 20 or then                    \ 'A'..'F' -> 'a'..'f'
  dup [char] a < if [char] 0 - else [char] a - 0a + then ;
: h8 ( -- u )  0  8 0 ?do  10 *  rec@ c@ hexdig +  1 +rec  loop ;

\ ── the fixed header ─────────────────────────────────────────────────────────
\ The fields kept for the walk and the find; the rest are read (to advance the
\ cursor the right distance) and dropped, in on-disk order.
variable cp-ino    variable cp-mode   variable cp-nlink
variable cp-fsize  variable cp-nsize  variable cp-data
: cp-hdr ( -- )                                   \ read all 110 header bytes
  6 +rec                                          \ magic (already vetted)
  h8 cp-ino !   h8 cp-mode !  h8 drop  h8 drop     \ ino mode uid gid
  h8 cp-nlink ! h8 drop       h8 cp-fsize !        \ nlink mtime filesize
  h8 drop h8 drop h8 drop h8 drop                  \ dev/rdev major/minor
  h8 cp-nsize ! h8 drop ;                          \ namesize check

\ the 6 magic bytes as TEXT, compared byte-for-byte (endian-free on purpose: a
\ word read here would byte-swap and only ppc would notice — the very slip the
\ four-arch matrix exists to catch).
: newc? ( adr -- flag )
  dup     c@ [char] 0 =
  over 1+ c@ [char] 7 = and
  over 2 + c@ [char] 0 = and
  over 3 + c@ [char] 7 = and
  over 4 + c@ [char] 0 = and
  swap 5 + c@ [char] 1 = and ;

\ "TRAILER!!!" — the sentinel last member.
: trailer? ( adr len -- flag )  s" TRAILER!!!" $= ;

variable cp-end                                    \ archive base + length
: cp-room? ( n -- flag )  rec@ +  cp-end @  u> 0= ;  \ do n more bytes fit?

\ ── one member at the cursor ─────────────────────────────────────────────────
\ Vet the magic, read the header, bind the name, record the data address, and
\ advance the cursor past name+pad and data+pad to the next member. There are no
\ exceptions here, so the outcome is a status returned on the stack:
\   ( -- name-adr name-len 0 )  ok      (cursor advanced; cp-data/cp-fsize set)
\   ( -- name-adr name-len 1 )  TRAILER (name is "TRAILER!!!"; cursor untouched)
\   ( --      0      0     2 )  BAD-MAGIC
\   ( --      0      0     3 )  TRUNCATED
: cp-step ( -- adr len status )
  6e cp-room? 0= if 0 0 3 exit then                \ the 110-byte header must fit
  rec@ newc? 0= if 0 0 2 exit then
  cp-hdr
  cp-nsize @ cp-room? 0= if 0 0 3 exit then         \ the name must fit
  rec@ cstr                                         \ ( adr len ) the name
  2dup trailer? if 1 exit then
  cp-nsize @ +rec  4 alignto                        \ past name + its pad
  rec@ cp-data !                                    \ the data starts here
  cp-fsize @ cp-room? 0= if 2drop 0 0 3 exit then    \ the data must fit
  cp-fsize @ +rec  4 alignto                        \ past data + its pad
  0 ;

\ ── cpio-walk ( adr len max -- ok? ) ─────────────────────────────────────────
\ List every member (name / mode / size) up to `max` (a corrupt archive cannot
\ loop forever), stopping at TRAILER!!!. Answers true only on a clean walk that
\ reached the trailer; refuses BY NAME and answers false otherwise.
: cpio-walk ( adr len max -- ok? )
  >r  over +  cp-end !  >rec  r>                    ( max ) ( R: -- )
  0 ?do
    cp-step                                         ( adr len status )
    dup 2 = if drop 2drop ." cpio| BAD-MAGIC"  cr false unloop exit then
    dup 3 = if drop 2drop ." cpio| TRUNCATED"  cr false unloop exit then
    dup 1 = if drop 2drop ." CPIO-END"         cr true  unloop exit then
    drop                                            ( adr len )  \ status 0
    ." cpio| name=" type
    ."  mode=" cp-mode @ .hx8  ."  size=" cp-fsize @ .hx8  cr
  loop
  ." cpio| NO-TRAILER" cr false ;

\ ── cpio-find ( adr len max caddr u -- data-adr size | 0 0 ) ─────────────────
\ The named member's DATA address and byte size, or 0 0 if it is absent (walked
\ to TRAILER without a match) or the archive refused. Walks without printing.
variable cp-qadr   variable cp-qlen
: cpio-find ( adr len max caddr u -- data-adr size | 0 0 )
  cp-qlen !  cp-qadr !                              \ the query name, off the stack
  >r  over +  cp-end !  >rec  r>                     ( max )
  0 ?do
    cp-step                                          ( adr len status )
    dup 0<> if drop 2drop 0 0 unloop exit then       \ TRAILER(1) / refusal → 0 0
    drop                                             ( adr len )
    cp-qadr @ cp-qlen @ $=                             \ name == query ?
    if  cp-data @ cp-fsize @  unloop exit  then
  loop
  0 0 ;
