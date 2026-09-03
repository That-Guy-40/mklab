\ lbregion.fth — region.fth aimed at the firmware's OWN coreboot-table parser.
\
\ The change a region diff shows has to be one the FIRMWARE caused, not one the
\ test staged to be found, so the subject is a code path already in the tree:
\ libopenbios/linuxbios_info.c, which parses the coreboot tables at init and
\ which this lab has already patched twice (01: publish the real memory map;
\ 39: chase LB_TAG_FORWARD into CBMEM). Patch 58 binds three words so it can be
\ re-run and watched:
\
\   lb-table    ( -- phys len )  the CBMEM-forwarded table, header included
\   lb-walk     ( -- n )         re-run the parse into a SCRATCH sys_info;
\                                n = RAM ranges written, -1 = no table found
\   heap-cursor ( -- phys avail ) where arch/{x86,amd64}/lib.c's bump allocator
\                                will put the NEXT malloc
\
\ THE REVIEW'S PREMISE WAS WRONG AND THAT IS WHY BOTH ROWS ARE HERE. The plan's
\ F5/F6 said to "snapshot the CBMEM-forwarded table region, re-run the walk,
\ diff". Measured 2026-09-03: read_lbtable() is a READER, so that region does
\ not change -- LBTAB=0 every time. The table is therefore the NEGATIVE CONTROL,
\ and the subject is one level down: convert_memmap() calls malloc() and fills
\ what it gets, so the firmware's own write lands at heap-cursor.
\
\ x86 and amd64 only: CONFIG_LINUXBIOS is false on ppc/sparc, and the bump
\ allocator heap-cursor reports exists only in those same two arch/*/lib.c.
\ Load struct.fth and region.fth first. Base is hex.
hex

: .lb-table ( -- )  lb-table ." LBT=" swap u. ." LBLEN=" u. cr ;

\ the NEGATIVE control: the region the walk READS must come back unchanged
: lb-table-diff ( -- )
  lb-table dup 0= if 2drop ." LBTAB=none" cr exit then
  region-snap  lb-walk drop
  ." LBTAB=" region-diffs u. cr ;

\ the SUBJECT: the bytes the walk's own malloc writes, through >virt.
\ STEP is how far the bump pointer moved -- convert_memmap()'s single
\ malloc(lbcount * sizeof(struct memrange)) -- so it is also the BOUND: every
\ byte the firmware changed must be inside the block it asked for, which is
\ what LAST (the highest changed offset) is compared against. A count says
\ something moved; the bound says the firmware wrote where it said it would.
: lb-heap-diff ( -- )
  heap-cursor drop  dup ." HEAPP=" u. cr      \ for an observer OUTSIDE the guest
  dup 100 region-snap
  lb-walk ." RANGES=" dup u. cr  -1 = if ." NO-TABLE" cr drop exit then
  heap-cursor drop swap -  ." STEP=" u. cr
  region-diff
  ." HEAP=" region-diffs u. cr
  ." LAST=" region-last u. cr ;

\ the TRAP, measured: the same bytes snapshotted at the PHYSICAL address with no
\ >virt. On x86 that is different memory and the count comes back 0 -- a clean,
\ confident, wrong answer. On amd64 >virt is the identity, so there is no trap
\ to bite and this must EQUAL the row above; asserting both is what makes the
\ x86 zero a statement about relocation rather than about a broken snapshot.
: lb-raw-diff ( -- )
  heap-cursor drop 100 region-snapv
  lb-walk drop
  ." RAW=" region-diffs u. cr ;
