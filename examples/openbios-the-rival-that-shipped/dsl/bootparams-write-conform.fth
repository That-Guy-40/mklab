\ bootparams-write-conform.fth — bootparams.fth's WRITER half, contract v1.
\
\ A SIDECAR. Load struct.fth + contract.fth + bootparams.fth + bootparams-conform.fth
\ + bootparams-edit.fth FIRST, then this. See dsl/CONTRACT.md. Hex.
\
\ bootparams-write is the contract's NAME-write for bootparams: it locates
\ boot_params in a phys-0 dump (bootparams-edit.fth's cle-open, by the reader's own
\ anchors), follows cmd_line_ptr, and rewrites the command line in place — refusing
\ BY NAME before any byte moves (bp| NO-CMDLINE / CMDLINE-TOO-BIG / CMDLINE-OOB, and
\ a cle-open failure) and writing NOTHING on refusal. Graded on the DELTA (the
\ command line changed, a neighbouring field did not) by the conformance checker.
hex

: bootparams-write ( adr len new-adr new-len -- ok? )
  >r >r  cle-open  dup if                 ( status ) ( r: new-len new-adr )
    r> r> 2drop                           ( status )
    4 = if ." bp| NO-BOOTPARAMS" else ." bp| BAD-SETUP-HEADER" then cr
    false exit
  then
  drop  r> r>  bp-cmdline-set ;           ( ok? )
