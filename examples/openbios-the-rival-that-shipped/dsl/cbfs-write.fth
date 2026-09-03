\ cbfs-write.fth — CBFS surgery in OpenBIOS Forth (B.3 Spike 2, WRITE direction).
\
\ The reader (cbfs.fth) proved the firmware can WALK a real CBFS and name every
\ file. This is the writer half: find a named `raw` entry, overwrite its content
\ bytes IN PLACE, and let the host persist the whole image with write-file. The
\ patch is SAME-LENGTH on purpose — every offset in the archive (the next entry,
\ the (empty) free-space marker, the master header) stays exactly where it was,
\ so a correct surgery disturbs nothing but the bytes it meant to change.
\
\ THE ORACLE IS cbfstool, NEVER OUR OWN READER. A parser and a writer wrong the
\ same way agree with each other, so "cbfs.fth still reads it" proves nothing.
\ The test (in the smoke track) is that coreboot's own cbfstool still accepts the
\ WHOLE image afterward: `print` lists the same coherent archive and `extract`
\ returns our bytes unchanged. A patch our reader loves and cbfstool rejects is a
\ silent corruption, and catching it is the entire reason the oracle is foreign.
\
\ Load struct.fth AND cbfs.fth FIRST, then this. Reuses their cursor (>rec/t@+/
\ vbytes/rec@/cstr), the u32be type, cbfs-rb/cf-len/cf-coff, and the reader's
\ region-relative 64-byte alignment unchanged — the writer walks with the exact
\ same stepper the reader was graded on, so "find" cannot drift from "list".
hex

variable cbw-want-a   variable cbw-want-l   \ the name being searched for
variable cbw-ent                            \ matched entry base (absolute)

\ Parse ONE entry at `cur` silently: store its content length in cf-len and its
\ content offset in cf-coff (both as cbfs-entry does), and return this entry's
\ filename as ( name-adr name-len ). Same field walk as cbfs-entry, no printing.
: (cbw-fields) ( cur -- name-adr name-len )
  >rec
  8 vbytes drop            \ magic "LARCHIVE" (already vetted by larchive?)
  u32be t@+ cf-len  !
  u32be t@+ cf-type !      \ kept -- the author path finds free space by type
  u32be t@+ drop           \ attributes_offset
  u32be t@+ cf-coff !
  rec@ cstr ;

\ Step to the next entry from `cur`, reading cf-coff/cf-len set by (cbw-fields).
\ Byte-identical to the tail of cbfs-entry: region-relative align_up to 64.
: (cbw-next) ( cur -- next )
  dup cf-coff @ + cf-len @ +  cbfs-rb @ -  3f + 40 negate and  cbfs-rb @ + ;

\ Walk the CBFS from region base `rb` (bounded by `max` entries) looking for a
\ named entry. On a hit, record its base in cbw-ent and return its CONTENT
\ address and length with a true flag; on a miss return ( 0 0 0 ).
: cbfs-find ( rb max name-adr name-len -- cadr clen -1 | 0 0 0 )
  cbw-want-l !  cbw-want-a !
  swap dup cbfs-rb !            ( max cur )
  begin
    over 0>  over larchive?  and
  while
    dup (cbw-fields)           ( max cur name-adr name-len )
    cbw-want-a @ cbw-want-l @  $=   ( max cur flag )
    if  nip  dup cbw-ent !  cf-coff @ +  cf-len @  -1  exit  then
    (cbw-next)                 ( max next )
    swap 1- swap               ( max-1 next )
  repeat
  2drop  0 0 0 ;

\ The surgery itself: overwrite `clen` bytes at `adr` with byte `b`. A constant
\ fill is the un-fakeable patch — the host reads back exactly clen copies of b,
\ so no accidentally-correct leftover bytes can pass for the write. ( adr clen b -- )
: cbfs-fill ( adr clen b -- )  fill ;

\ ── authoring a brand-new raw entry into free space (the OTHER origin) ───────
\ Where the patch above rewrites the bytes of an entry cbfstool built, this
\ AUTHORS a whole cbfs_file — the big-endian len/type/offset fields and the name
\ — in the (empty) free-space entry, then relinks a fresh (empty) covering what
\ is left. This is the write side of the STRUCTURE toolkit: the firmware composes
\ CBFS metadata through the SAME width/endian-aware cursor the reader was graded
\ on (u32be t!+ is l!-be on every arch), and coreboot's cbfstool must then accept
\ every field it wrote. Nothing before the free space moves; only free space is
\ consumed, exactly as `cbfstool add` does.

variable au-base    \ new entry base (= the old (empty) base)
variable au-oldlen  \ old (empty) content length
variable au-oldoff  \ old (empty) offset field (reused for the fresh (empty))
variable au-off     \ new entry's content offset (24 + name + NUL, padded)
variable au-clen    \ new content length
variable au-cadr    \ new content source
variable au-na  variable au-nl

\ align n up to the next multiple of m (m a power of two). ( n m -- n' )
: au-align ( n m -- n' )  dup >r 1- +  r> negate and ;

\ find the (empty) free-space entry (type 0xffffffff); return its base, content
\ length and offset field. ( rb max -- ebase elen eoff -1 | 0 0 0 0 )
: cbfs-find-empty ( rb max -- ebase elen eoff -1 | 0 0 0 0 )
  swap dup cbfs-rb !          ( max cur )
  begin
    over 0>  over larchive?  and
  while
    dup (cbw-fields) 2drop    ( max cur )     \ sets cf-len/cf-type/cf-coff
    cf-type @ ffffffff = if
      nip  dup cf-len @  cf-coff @  -1  exit  ( ebase elen eoff -1 )
    then
    (cbw-next)  swap 1- swap   ( max-1 next )
  repeat
  2drop  0 0 0 0 ;

\ author a raw entry named name$ with content [cadr,cadr+clen) into free space,
\ then write a fresh (empty) spanning the remainder. Every multi-byte field is a
\ big-endian store through u32be t!+, so a byte-order slip in the WRITER is what
\ cbfstool's validation is here to catch. ( ebase elen eoff cadr clen name-a name-l -- )
: cbfs-author
  au-nl ! au-na !  au-clen ! au-cadr !  au-oldoff ! au-oldlen ! au-base !
  \ content offset: header(24) + name + NUL, padded up to 16 (as cbfstool lays it)
  18 au-nl @ + 1+  10 au-align  au-off !
  \ --- the new entry's header, authored field by field through the cursor ---
  au-base @ >rec
  s" LARCHIVE" rec@ swap move  8 +rec           \ magic
  au-clen @ u32be t!+                            \ len   (BE)
  50       u32be t!+                            \ type = raw (BE)
  0        u32be t!+                            \ attributes_offset (BE)
  au-off @ u32be t!+                            \ offset (BE) -> cursor now at +24
  au-base @ 18 +  au-off @ 18 -  erase          \ zero name+pad region [24,off)
  au-na @  au-base @ 18 +  au-nl @  move         \ copy the name (NUL already there)
  \ --- the content ---
  au-cadr @  au-base @ au-off @ +  au-clen @  move
  \ --- the fresh (empty), region-relative 64-aligned after the content ---
  au-base @ au-off @ + au-clen @ +  cbfs-rb @ -  40 au-align  cbfs-rb @ +   ( nextabs )
  dup >rec
  s" LARCHIVE" rec@ swap move  8 +rec
  \ new (empty) content len = old_end - (nextabs + oldoff); old_end = base+oldoff+oldlen
  au-base @ au-oldoff @ + au-oldlen @ +  over au-oldoff @ +  -   ( nextabs newlen )
  u32be t!+                                     \ len (BE)
  ffffffff u32be t!+                            \ type = null (BE)
  0        u32be t!+                            \ attributes_offset
  au-oldoff @ u32be t!+                          \ offset (reuse the old (empty)'s)
  dup 18 +  au-oldoff @ 18 -  erase              \ zero the (empty) name region
  drop ;
