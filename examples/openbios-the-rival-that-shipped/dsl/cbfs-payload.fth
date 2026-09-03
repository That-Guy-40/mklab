\ cbfs-payload.fth — dissect a coreboot SELF payload's segment table (B.3 Spike 2).
\
\ THE LAYER THAT TELLS PAYLOAD KINDS APART. Every coreboot ROM on this host carries
\ its OS-facing payload as a CBFS entry of type `simple elf` (fallback/payload) —
\ so the CBFS *type* does not distinguish a Linux+u-root ROM from an OpenBIOS one
\ from a Firmworks one. What distinguishes them is INSIDE that entry: a coreboot
\ "self" payload is NOT a raw ELF but an array of
\
\   struct cbfs_payload_segment {          \ 28 bytes, ALL BIG-ENDIAN
\     uint32_t type;                        \ 'CODE' 'DATA' 'BSS ' 'PARA' 'ENTR'
\     uint32_t compression;                 \ 0 none / 1 LZMA
\     uint32_t offset;                      \ within the payload blob
\     uint64_t load_addr;                   \ where the segment loads
\     uint32_t len;                         \ (compressed) bytes in the blob
\     uint32_t mem_len;                     \ bytes in memory
\   };
\
\ terminated by an ENTR segment whose load_addr is the ENTRY POINT. The segment
\ count, the load map and the entry differ per payload, so this walk is §12's
\ "the payload is the variable, the toolkit is the constant" made concrete.
\
\ ANOTHER BIG-ENDIAN STRUCTURE, so the arch matrix earns its keep again: ppc reads
\ these fields native while the LE arches byte-swap through l@-be. Graded against
\ readelf of the RECONSTITUTED ELF (cbfstool extract -m ARCH): each loadable
\ segment's (load_addr, mem_len) equals a PT_LOAD's (VirtAddr, MemSiz), and the
\ ENTR load equals e_entry — a foreign decoder confirming the walk, not our reader.
\
\ Load struct.fth, cbfs.fth AND cbfs-write.fth (for cbfs-find) FIRST, then this.
hex

\ segment type tags, printed as a fixed 4-char tag so a host can diff the listing.
: .seg-type ( u -- )
  dup 434f4445 = if ." CODE" drop exit then   \ 'CODE'
  dup 44415441 = if ." DATA" drop exit then   \ 'DATA'
  dup 42535320 = if ." BSS " drop exit then   \ 'BSS '
  dup 50415241 = if ." PARA" drop exit then   \ 'PARA'
  dup 454e5452 = if ." ENTR" drop exit then   \ 'ENTR'
  ." seg-" u. ;

variable ps-type  variable ps-load  variable ps-len  variable ps-mem

\ walk ONE segment at the cursor; print type/load/len/mem; return its type. The
\ 8-byte load_addr is read as two u32be (this Forth has no 8-byte BE fetch, and a
\ 32-bit cell cannot hold >4 GiB anyway): the high word must be zero for these
\ payloads, and is FLAGGED if not so a >4 GiB load can never pass silently.
: .payload-seg ( -- type )
  u32be t@+ ps-type !            \ type
  u32be t@+ drop                 \ compression
  u32be t@+ drop                 \ offset
  u32be t@+                      \ load_addr high 32
  dup if ." !LOAD-HI=" dup .hx8 then drop
  u32be t@+ ps-load !            \ load_addr low 32
  u32be t@+ ps-len !             \ len
  u32be t@+ ps-mem !             \ mem_len
  ." pseg| type=" ps-type @ .seg-type
  ."  load=" ps-load @ .hx8
  ."  len="  ps-len  @ .hx8
  ."  mem="  ps-mem  @ .hx8  cr
  ps-type @ ;

\ walk the segment table at `adr`, bounded by `max` segments, stopping at ENTR
\ (whose load is the entry point). A bound so a mangled type cannot loop forever.
: payload-segs ( adr max -- )
  swap >rec                      ( max )
  begin dup 0> while
    .payload-seg 454e5452 =      ( max flag )   \ 'ENTR'
    if drop ." PAYLOAD-END" cr exit then
    1-
  repeat
  drop ." PAYLOAD-TRUNC" cr ;

\ convenience: find fallback/payload in the CBFS at region base `rb` and walk its
\ segment table. ( rb max-entries max-segs -- )
: payload-of ( rb maxent maxseg -- )
  >r  s" fallback/payload" cbfs-find    ( cadr clen -1 | 0 0 0 )  ( r: maxseg )
  0= if r> drop 2drop ." NO-PAYLOAD" cr exit then
  drop                                   ( cadr )
  r> payload-segs ;
