\ region.fth — snapshot a span of memory, let something happen, show only what
\ moved. B.3 Spike 3's other half, and the one success-signature line in plan §9
\ that nothing had observed: "a region diff shows a firmware-caused change".
\
\ PORTED, NOT SHARED. These began as `region-snap`/`region-diff` in
\ examples/open-firmware-debugs-itself/dsl/ofscope.fth, where they run under
\ Bradley's Firmworks OFW. That is a DIFFERENT FIRMWARE -- the review that
\ scheduled this work (F6) called the plan's word "existing" the one that hides
\ a step -- so the self-containment rule says copy, and the habitats lab's
\ PORTING.md is the checklist. What actually had to change under OpenBIOS:
\
\   - the counting loop is also a word that RETURNS the count (`region-diffs`),
\     because a test has to assert a number, not read prose;
\   - a re-snap reuses its buffer instead of leaking one per call;
\   - the entry point splits in two, `region-snapv` (virtual) and `region-snap`
\     (physical), because on this firmware the address is the whole problem;
\   - `#R ` became `region| `, the prefix every reader in this dsl/ uses.
\ Nothing else moved: `alloc-mem`, `move` and `c@` are all this needs, and all
\ four arches have them.
\
\ THE ADDRESS TRAP, and it is not a footnote -- it is a row in the track:
\ x86 relocates itself by rebasing the GDT (arch/x86/segment.c), so a PHYSICAL
\ address used directly as a Forth address lands somewhere else that READS BACK
\ CONVINCINGLY. No error, plausible bytes, and a diff of ZERO -- the snapshot
\ and the re-read agree because they are both looking at the wrong memory, which
\ is the failure mode that looks exactly like success. `region-snap` therefore
\ takes PHYSICAL and applies >virt (dsl/struct.fth) itself, once, so a caller
\ cannot forget; `region-snapv` is the raw form kept deliberately, so the trap
\ can be MEASURED rather than described (see dsl/lbregion.fth).
\
\ Load struct.fth first. Base is hex.
hex

0 value snap-virt
0 value snap-len
0 value snap-buf
0 value snap-cap

\ region-snapv ( virt len -- )  keep a private copy of the bytes at a FORTH address
: region-snapv ( virt len -- )
  dup snap-cap > if                       \ grow only when the ask is bigger
    dup alloc-mem to snap-buf  dup to snap-cap
  then
  to snap-len  to snap-virt
  snap-virt snap-buf snap-len move
  ." region| snapped " snap-len u. ." bytes at " snap-virt u. cr ;

\ region-snap ( phys len -- )  the same, from a PHYSICAL address (the safe form)
: region-snap ( phys len -- )  swap >virt swap region-snapv ;

\ region-diffs ( -- n )  how many bytes differ from the snapshot, silently
: region-diffs ( -- n )
  snap-buf 0= if 0 exit then
  0  snap-len 0 ?do
    snap-virt i + c@  snap-buf i + c@  <> if 1+ then
  loop ;

\ region-diff ( -- )  the listing: the first eight changed bytes, then the count
: region-diff ( -- )
  snap-buf 0= if ." region| no snapshot taken" cr exit then
  0  snap-len 0 ?do
    snap-virt i + c@  snap-buf i + c@  <> if
      1+
      dup 9 < if                          \ cap the listing, keep counting
        ." region| diff +" i u.
        ."  was " snap-buf i + c@ u.
        ."  now " snap-virt i + c@ u. cr
      then
    then
  loop
  ." region| total-diffs=" u. cr ;

\ region-last ( -- off )  the HIGHEST changed offset, or -1 when nothing moved.
\ A count alone cannot say WHERE, and "where" is the invariant worth having when
\ the change came from an allocator: everything the firmware wrote must lie
\ inside what the firmware asked for.
: region-last ( -- off )
  -1  snap-len 0 ?do
    snap-virt i + c@  snap-buf i + c@ <> if drop i then
  loop ;

\ ── the instrument's own calibration ────────────────────────────────────────
\ A region that did not change and an instrument that cannot see a change print
\ the same clean run, so before this is aimed at the firmware it is aimed at a
\ byte we moved ourselves: snapshot a scratch buffer, poke ONE byte, and require
\ exactly one difference. If this row is not 1, no other row here means anything.
\ (The repo's must-catch fixture rule, in Forth.)
: region-selftest ( -- )
  40 alloc-mem                            ( adr )
  dup 40 0 fill
  dup 40 region-snapv
  dup 10 + 5a swap c!                     \ the poke: +0x10 becomes 0x5a
  ." SELFTEST=" region-diffs u. cr
  40 free-mem ;

\ ...and the other control: a snapshot with nothing done to it must be 0, or a
\ non-zero count would mean the region moves on its own and every row is noise.
: region-quiet ( -- )
  40 alloc-mem dup 40 0 fill
  dup 40 region-snapv
  ." QUIET=" region-diffs u. cr
  40 free-mem ;
