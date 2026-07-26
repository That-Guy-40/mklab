\ patch.fth — IEEE 1275 section 7.5.3.3, implemented, because OpenBIOS ships it empty
\
\   0 > see patch
\   : patch
\     ;
\
\ That stub is why this lab could not port the x86 sibling's boot tracers: OFW
\ SHIPS `defer` tracepoints on its boot path, OpenBIOS declares none anywhere,
\ and the standard's own answer to "no hook" — patch the call site — is a no-op.
\ So: write it.
\
\ This is deliberately arch-neutral. OpenBIOS's dictionary format is the same on
\ every target it builds, so one implementation serves the SPARC and PPC tracks
\ (and x86, and amd64) without a line of conditional code.
\
\ ─────────────────────────────────────────────────────────────────────────────
\ How a colon definition is laid out (learned from the firmware's OWN
\ decompiler, forth/debugging/see.fs — the authoritative walker):
\
\   xt      -> a TYPE CODE: 1 colon, 3 constant, 4 variable, 5 defer, else prim
\   xt+cell -> the body: a run of cells, each an xt, ending at ['] (semis)
\   xt-cell -> the link field; `lfa2name` turns it into the word's name
\
\ Some xts carry INLINE DATA in the cells that follow, and stepping over it is
\ the entire correctness problem here. A naive "scan every cell for old-xt"
\ would happily corrupt a branch offset or a literal that merely happens to hold
\ the same value — a bug that would not show up until the patched word ran.
\
\ Load it with (SPARC):  load cdrom:\PATCH.FTH   then  load-base load-size evaluate
\ or through nvramrc on either track — see ../DELIVERY.md.
\
\ NB: no `abort"` anywhere below, on purpose. `abort"` cannot survive
\ minify-fth.py (its trailing quote reads as a string opener, splitting the word
\ in two), and this vocabulary has to fit through the NVRAM door.

\ ═══════════════════════════════════════════════════════════════════════════
\  Walking a body
\ ═══════════════════════════════════════════════════════════════════════════

\ How many cells of inline data follow this xt. Mirrors see.fs's case arms:
\ do?branch/dobranch carry a branch target, (lit) carries the literal, and
\ (while)/(repeat) carry two.
: inline-cells  ( xt -- n )
   dup ['] do?branch =  if  drop 1 exit  then
   dup ['] dobranch  =  if  drop 1 exit  then
   dup ['] (lit)     =  if  drop 1 exit  then
   dup ['] (while)   =  if  drop 2 exit  then
   dup ['] (repeat)  =  if  drop 2 exit  then
   drop 0
;

\ Step from one body item to the next. (") is the awkward one: its length lives
\ in the following cell and the string itself is inline, so the next item starts
\ at aligned(adr+len) + 2 cells — the same arithmetic see.fs does, arrived at
\ the same way.
: /body-item  ( adr -- adr' )
   dup @  ['] (") =  if
      dup cell+ @  over +  aligned  nip  2 cells +  exit
   then
   dup @ inline-cells  1+ cells  +
;

: colon-def?  ( xt -- flag )  @ 1 =  ;

\ ═══════════════════════════════════════════════════════════════════════════
\  (patch) — the engine
\ ═══════════════════════════════════════════════════════════════════════════
\
\ 1275 signature: ( new-n1 num1? old-n2 num2? xt -- )
\ A `num?` flag true means the corresponding item is a LITERAL rather than a
\ word — `patch 5 3 foo` replaces the literal 3 with 5 inside foo.
\
\ Parameters go into values rather than being juggled on the stack: five items
\ threaded through a loop is how you write a word nobody can read or verify.

0 value patch-new
0 value patch-old
0 value patch-newlit?
0 value patch-oldlit?
0 value patch-count

: patch-match?  ( adr -- adr flag )
   patch-oldlit?  if
      dup @ ['] (lit) =  if  dup cell+ @ patch-old =  else  false  then
   else
      dup @ patch-old =
   then
;

: patch-store  ( adr -- )
   patch-oldlit?  if  cell+  then      \ aim past (lit), at the literal itself
   patch-new swap !
   patch-count 1+ to patch-count
;

: (patch)  ( new-n1 num1? old-n2 num2? xt -- )
   >r
   to patch-oldlit?  to patch-old
   to patch-newlit?  to patch-new
   0 to patch-count
   \ Swapping a word for a literal (or back) changes how many cells the item
   \ occupies, so it cannot be done in place. Refuse rather than corrupt.
   patch-newlit? patch-oldlit? <>  if
      r> drop
      ." patch: cannot exchange a word for a literal in place" cr  exit
   then
   r> dup colon-def? 0=  if
      drop  ." patch: not a colon definition" cr  exit
   then
   cell+                                    ( adr )
   begin  dup @ ['] (semis) <>  while
      patch-match?  if  dup patch-store  then
      /body-item
   repeat
   drop
;

\ ═══════════════════════════════════════════════════════════════════════════
\  patch — the user-facing word
\ ═══════════════════════════════════════════════════════════════════════════
\
\   patch <new> <old> <word-to-patch>
\
\ Each of <new> and <old> is a word if one of that name exists, else a number —
\ which is why (patch) needs the num? flags at all.
\
\ ORDER MATTERS, and the obvious order is the wrong one. Trying `$number` first
\ looks natural and cost this lab a debugging session: the base here is HEX, so
\ `aa` and `bb` are perfectly good numbers (170 and 187). A test that patched
\ `bb` for `aa` inside a word visibly built from `aa` reported
\ "0 occurrence(s) replaced" — correctly, because it had gone looking for the
\ literal 170. Plenty of plausible Forth names are hex: aa, bb, dead, beef,
\ face, add, cafe. So: LOOK THE WORD UP FIRST, and fall back to a number only
\ when no such word exists.
: patch-parse  ( -- val num? )
   parse-word                        ( str len )
   2dup $find  if                    ( str len xt )   \ a word wins
      >r 2drop r>  false  exit
   then                              ( str len str len )
   2drop
   2dup $number  0=  if              ( str len n )    \ $number: false = success
      >r 2drop r>  true  exit
   then                              ( str len )
   type ." : not a word, and not a number" cr  -13 throw
;

: patch  ( "new< >old< >word-to-patch< >" -- )
   patch-parse  patch-parse          ( new num1? old num2? )
   parse-word  $find  0=  if
      type ." : undefined word" cr  -13 throw
   then                              ( new num1? old num2? xt )
   (patch)
   ." patch: " patch-count . ." occurrence(s) replaced" cr
;

." patch loaded: patch (patch) patch-count inline-cells /body-item" cr
