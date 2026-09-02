\ cbfs.fth — a coreboot CBFS reader in OpenBIOS Forth (B.3 Spike 2).
\
\ CBFS metadata is BIG-ENDIAN, source-confirmed (coreboot's cbfs_serialized.h:
\ `#define CBFS_HEADER_MAGIC 0x4F524243 /* BE: 'ORBC' */`), which is the whole
\ reason to do this on real multi-arch firmware: ppc reads these fields natively
\ while the little-endian arches byte-swap them, so a hidden LE assumption dies on
\ the big-endian row and nowhere else. This file reuses Spike 0's cursor vocabulary
\ (struct.fth: type:/>rec/t@+/vbytes/rec@/cstr) unchanged — a CBFS entry is exactly
\ the length-prefixed, sequential record the cursor was built for.
\
\ Load struct.fth FIRST, then this.
\
\ On-disk layout (all fields BIG-ENDIAN):
\   struct cbfs_file {            \ sizeof == 24, then the filename
\     char     magic[8];          \ "LARCHIVE"
\     uint32_t len;               \ content length
\     uint32_t type;              \ CBFS_TYPE_*
\     uint32_t attributes_offset;
\     uint32_t offset;            \ struct-start -> content
\     char     filename[];        \ NUL-terminated, then padded
\   };
\ The next entry is align_up(struct-start + offset + len, 64).
hex

4 0 0 type: u32be                 \ 4-byte BIG-endian, memory (order 0 = BE)

\ CBFS_TYPE_* (cbfs_serialized.h). Printed as a fixed tag so a host can diff the
\ listing against `cbfstool print` type for type; an unknown type prints its hex.
: .cbfs-type ( type -- )
  dup ffffffff = if ." null      " drop exit then
  dup 00 = if ." deleted   " drop exit then
  dup 01 = if ." bootblock " drop exit then
  dup 02 = if ." header    " drop exit then
  dup 11 = if ." stage     " drop exit then
  dup 20 = if ." simple-elf" drop exit then
  dup 21 = if ." fit       " drop exit then
  dup aa = if ." cmos-dflt " drop exit then
  dup 1aa = if ." cmos-lay  " drop exit then
  dup 30 = if ." optionrom " drop exit then
  dup 50 = if ." raw       " drop exit then
  ." type-" u. ;

\ "LARCHIVE" as two big-endian words: "LARC"=0x4c415243, "HIVE"=0x48495645.
\ Read directly (not through the cursor) so the magic test never disturbs a walk.
: larchive? ( adr -- flag )
  dup l@-be 4c415243 =  swap 4 + l@-be 48495645 =  and ;

variable cbfs-rb                  \ region base (absolute), so a per-entry offset
: cbfs-off ( cur -- region-off )  cbfs-rb @ - ;  \ matches cbfstool print's column

\ walk ONE entry at absolute address `cur`; print it; return the next entry's
\ absolute address. The cursor reads len/type/attrs/offset through u32be (BE), then
\ lands on the filename; the content and the next entry are pure arithmetic.
variable cf-len  variable cf-type  variable cf-coff
: cbfs-entry ( cur -- next )
  dup >rec
  8 vbytes drop                   \ magic (already vetted by larchive?)
  u32be t@+ cf-len  !
  u32be t@+ cf-type !
  u32be t@+ drop                  \ attributes_offset
  u32be t@+ cf-coff !
  ." cbfs| off=" dup cbfs-off .hx8
  ."  type=" cf-type @ .cbfs-type
  ."  len=" cf-len @ .hx8
  ."  name=" rec@ cstr type cr
  \ next = region-base + align_up((cur-region-base) + offset + len, 64). The
  \ alignment is RELATIVE to the region, not the absolute address -- the region
  \ base need not be 64-aligned in memory, and aligning the absolute address
  \ lands short of the next entry when it is not (found 2026-09-02).
  cf-coff @ + cf-len @ +  cbfs-rb @ -  3f + 40 negate and  cbfs-rb @ + ;

\ walk the whole CBFS from region base `rb`, bounded by `max` entries so a corrupt
\ magic cannot loop forever. Stops at the first non-LARCHIVE (falling off the end,
\ or reading past a truncated window).
: cbfs-list ( rb max -- )
  swap dup cbfs-rb !              ( max cur )
  begin
    over 0>  over larchive?  and
  while
    cbfs-entry                    ( max next )
    swap 1- swap
  repeat
  2drop ." CBFS-END" cr ;
