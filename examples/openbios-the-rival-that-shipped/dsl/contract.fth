\ contract.fth — the module conformance contract's shared vocabulary (contract v1).
\
\ See dsl/CONTRACT.md for the convention this implements. This file is NOT a
\ framework and NOT a merge: it is the small, uniform vocabulary each format
\ module opts into so a capstone can consume any of them the same way while the
\ modules stay separate, prunable files (FIRMWARE_FAMILY_ROADMAP.md §2).
\
\ The reason seam itself (chk-catch / validate / .refusal / why-adr / why-len)
\ lives in dsl/struct.fth, because chk lives there and Forth redefinition is not
\ retroactive — a module's checker compiled against chk must see the seam already
\ in it. This file adds the two things that are genuinely shared ON TOP of the
\ seam: the manifest/field helpers a module prints through, and the loader/
\ registry that composes what is present and NAMES what is absent.
\
\ Load dsl/struct.fth FIRST, then this, then any subset of the format modules. Hex.
hex

\ ── a byte-compare for two counted strings, which this Forth does not ship ──
\ ( a1 u1 a2 u2 -- flag )  true iff equal length and equal bytes.
: $= ( a1 u1 a2 u2 -- flag )
  rot over <> if drop 2drop false exit then   ( a1 a2 u )
  0 ?do                                        ( a1 a2 )
    over i + c@  over i + c@  <> if 2drop false unloop exit then
  loop 2drop true ;

\ ── the honesty axes (dsl/CONTRACT.md §5), as words a manifest prints through ──
\ ARCH scope is REQUIRED on every manifest; the liveness label only where it
\ applies. Printed as fixed tokens the checker greps for.
: arch-4/4      ( -- )  ." ARCH:4/4 " ;        \ correct on unix/amd64/x86/ppc
: arch-x86-only ( -- )  ." ARCH:x86-only " ;   \ inherently single-arch (pe, uefi)
: host-only     ( -- )  ." HOST-ONLY " ;       \ a host oracle grades it / hosted-only step
: live-view     ( -- )  ." LIVE " ;            \ a seam-backed live handle (pacme)
: snapshot-view ( -- )  ." SNAPSHOT " ;        \ a captured, not-live subject

\ ── NAME-fields helper: print one field from its type-id, name given once ──
\ A field word made by struct.fth's field:/le-field: yields ( base -- adr tid ),
\ and its tid (the word's body) carries off/width. So `' e_class >body` is the
\ tid, and .field reads the numbers from it — the layout is never restated, only
\ the human name is supplied. ( name-adr name-len tid -- )
: .field ( a u tid -- )
  ." fld| name=" -rot type
  ."  off=" dup t-off .hx8
  ."  w=" t-width u. cr ;

\ .field3 ( name-adr name-len off width -- ) — the same line for a CURSOR-mode
\ module (cbfs, evlog) that walks its layout through t@+ and has no named
\ field: word to read a tid from. The layout is stated once, in NAME-fields.
: .field3 ( a u off width -- )
  >r >r ." fld| name=" type
  ."  off=" r> .hx8  ."  w=" r> u. cr ;

\ ── the registry: compose what is present, NAME what is absent ──────────────
\ Generalises elf.fth's `hook` (`… dsl/elf32.fth is not loaded`) to every module.
14 constant MAX-MODULES                 \ 20 decimal; more than the family will ever have
create module-tab  MAX-MODULES 3 * cells allot
variable #modules   0 #modules !
: >mrec ( i -- adr )  3 * cells module-tab + ;
: m-name     ( i -- a u )  >mrec dup @ swap cell+ @ ;
: m-manifest ( i -- xt )   >mrec 2 cells + @ ;

\ strsave ( a u -- a2 u ) — copy a string into PERMANENT dictionary storage.
\ Interpreted s" hands back a TRANSIENT buffer that the next s" reuses, so a
\ registry that stored the raw pointer would compare a clobbered name later
\ (measured 2026-09-21: need-module reported a REGISTERED module "not loaded"
\ because a later s" had overwritten the bytes its stored pointer named).
: strsave ( a u -- a2 u )
  here                         ( a u dest )
  dup >r                       ( a u dest )   ( r: dest )
  swap                         ( a dest u )
  dup >r                       ( a dest u )   ( r: dest u )
  dup allot                    ( a dest u )   \ reserve u bytes at dest
  move                         ( )            \ ( src dest len ) copy the name in
  r> r> swap ;                 ( dest u )     \ ( a2 u ) — the permanent copy
: register-module ( a u xt -- )
  >r  strsave  r>               ( a2 u xt )   \ copy name to permanent storage first
  #modules @ >mrec              ( a2 u xt rec )
  dup >r  2 cells + !           ( a2 u )      ( r: rec )
  r@ cell+ !                    ( a2 )
  r> !
  1 #modules +! ;

\ .modules — list every registered module and call each manifest (which prints
\ its ARCH scope and honesty label).
: .modules ( -- )
  ." MODULES-BEGIN #=" #modules @ . cr
  #modules @ 0 ?do
    ." module " i m-name type ." : " i m-manifest execute
  loop
  ." MODULES-END" cr ;

\ module? ( name-adr name-len -- flag ) — is a module registered by that name?
: module? ( a u -- flag )
  #modules @ 0 ?do
    2dup i m-name $= if 2drop true unloop exit then
  loop 2drop false ;

\ need-module ( name-adr name-len -- ) — the absence-naming word. A build without
\ module X is not an error; it says so, by name, once. Present → nothing.
: need-module ( a u -- )
  2dup module? if 2drop exit then
  ." MODULE " type ." : not loaded" cr ;
