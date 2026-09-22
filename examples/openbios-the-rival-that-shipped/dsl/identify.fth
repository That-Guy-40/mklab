\ identify.fth — a capstone that CONSUMES the conformance contract (contract v1).
\
\ The contract's headline claim (FIRMWARE_FAMILY_ROADMAP §2) is that "a capstone can
\ consume any module the same way." This is that capstone, in one word: hand `identify`
\ a buffer and it names the format — by walking the REGISTRY and trying each registered
\ module's `NAME-validate` through the contract's own naming convention, with NO
\ per-format knowledge of its own. Add a module (load its `-conform` sidecar) and
\ identify recognises its artifacts for free; drop one and identify simply stops
\ claiming that format — the federation's payoff, made checkable.
\
\ WHY NAME-validate AND NOT NAME-open: every module's validate reads the handle
\ DIRECTLY (a magic/anchor test) and RETURNS its verdict as ( c-addr u ) without
\ printing — so identify can try every module silently and print exactly one answer.
\ NAME-open, by contrast, prints its own `REFUSED:` on a bad magic, which is right for
\ a caller that meant to open THAT format but noise for a dispatcher trying all of them.
\
\ CAVEAT, stated: identify passes only the buffer ADDRESS to validate (the contract's
\ validate takes a handle, not a length), so the caller must hand it a buffer at least
\ as large as the largest format's anchor offset (bootparams reads to 0x204). A
\ length-bounded dispatcher would gate on NAME-open (which bounds-checks) instead; that
\ is the pacme inspector's job, not this demonstrator's.
\
\ Load struct.fth + contract.fth FIRST, then this, then any subset of `-conform`
\ sidecars (identify dispatches on whatever registered). Hex.
hex

\ a scratch buffer to build "<name>-validate" in, and a running length.
create id-buf  40 allot
variable id-len
: id-clr ( -- )   0 id-len ! ;
: >id ( src len -- )                 \ append src[0..len) to id-buf, advance id-len
  dup >r  id-buf id-len @ +  swap  move  r> id-len +! ;
: id-name ( -- a l )   id-buf id-len @ ;

\ (id-claims?) ( addr i -- valid? ) — does module i's NAME-validate accept addr?
\ Build "<name-of-i>-validate", find it, run it on addr; consumes addr either way.
: (id-claims?) ( addr i -- valid? )
  m-name  id-clr  >id  s" -validate" >id   ( addr )   \ id-buf := name ++ "-validate"
  id-name $find                            ( addr xt true | addr a l false )
  if   execute nip 0=                      ( valid? )   \ validate(addr) -> reason; u=0 ⟺ valid
  else 2drop drop false                    ( false )    \ no such validate word
  then ;

\ identify ( addr len -- ) — name the format, or say none of the loaded modules claim it.
: identify ( addr len -- )
  drop                                     ( addr )
  #modules @ 0 ?do
    dup i (id-claims?) if
      ." IDENTIFY: " i m-name type ."  — " i m-manifest execute
      drop unloop exit
    then
  loop
  drop ." IDENTIFY: unrecognised (no registered module claims these bytes)" cr ;
