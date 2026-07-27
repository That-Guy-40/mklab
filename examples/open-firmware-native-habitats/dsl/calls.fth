\ calls.fth — IEEE 1275 section 7.5.3.1, the other empty stub
\
\   0 > see .calls
\   : .calls
\     ;
\
\ "Who calls this word?" — the question you ask before you patch something, and
\ the one the x86 sibling used to find its tracer sites (`' open-dev .calls`
\ named `(boot-read)` and `default-device`, exactly the words its tracers hook).
\
\ This is nearly free once patch.fth exists: a cross-reference is that same
\ body walk run over EVERY word instead of one. Load patch.fth FIRST — this
\ file uses its /body-item, and reusing it is deliberate: two independent
\ walkers would drift, and the walker is the part that is easy to get wrong.
\
\ The dictionary is a linked list. `words` (forth/bootstrap/bootstrap.fs:1156)
\ walks it as:  last  begin @ ?dup while  dup lfa2name type  repeat
\ so each link cell holds the PREVIOUS entry's lfa, and — from see.fs's
\ `cell - lfa2name` — an execution token sits one cell above its lfa:
\
\     lfa          the link to the previous word
\     lfa + cell   the xt: a TYPE CODE (1 = colon definition)
\     lfa + 2cells the body
\
\ ⚠️ But NOT from `last`, which is what cost this file its first run. Measured
\ at the ok prompt on sun4m:
\
\     last       -> a chain of    1 entry
\     forth-last -> a chain of 4d3 entries (1235)
\
\ `last` tracks the most recent definition in the CURRENT wordlist; with
\ `vocabularies?` true (it is, here) the firmware's own words live in the Forth
\ wordlist, reached from `forth-last` — the same one `$find` falls back to.
\ Walking `last` finds nothing and reports "0 caller(s)", which looks exactly
\ like a correct answer. Note that `words` walks `last` too.

0 value (calls-target)
0 value (calls-count)

\ Does this word's body mention the target? Only colon definitions have a body
\ worth scanning; constants, variables, defers and primitives are skipped by
\ the type-code test, which is also what stops the walk reading garbage.
: (calls-hit?)  ( xt -- flag )
   dup @ 1 <>  if  drop false exit  then
   cell+
   begin  dup @ ['] (semis) <>  while
      dup @ (calls-target) =  if  drop true exit  then
      /body-item
   repeat
   drop false
;

0 value (calls-scanned)

: .calls  ( xt -- )
   to (calls-target)
   0 to (calls-count)  0 to (calls-scanned)
   forth-last                               \ NOT `last` — see the note above
   begin  @  ?dup  while                    ( lfa )
      (calls-scanned) 1+ to (calls-scanned)
      dup cell+ (calls-hit?)  if
         dup lfa2name  dup  if  type space  else  2drop ." <headerless> "  then
         (calls-count) 1+ to (calls-count)
      then
   repeat
   cr ." .calls: " (calls-count) . ." caller(s) in " (calls-scanned) . ." words" cr
;

." calls loaded: .calls" cr
