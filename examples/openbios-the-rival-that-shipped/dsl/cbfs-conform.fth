\ cbfs-conform.fth — dsl/cbfs.fth's opt-in to the conformance contract (v1).
\
\ A SIDECAR, not a merge: cbfs.fth stays standalone-loadable (struct.fth only),
\ and this file — loaded after struct.fth + contract.fth + cbfs.fth — adds the
\ contract's required core so a capstone can consume CBFS the same way as any
\ other module. See dsl/CONTRACT.md. The DEFECT FIX (cbfs-list refusing a corrupt
\ first entry by name) lives in cbfs.fth itself, because it is a bug in the
\ shipped reader; this file is only the contract surface. Hex.
hex

\ cbfs-validate ( handle -- c-addr u )  the format invariant: a CBFS region must
\ open on a LARCHIVE entry. handle is the region base (what cbfs-open returned).
: cbfs-validate ( handle -- c-addr u )
  larchive? if 0 0 else s" cbfs: no LARCHIVE magic at region start" then ;

\ cbfs-open ( addr len -- handle )  bind the region base; refuse a bad magic BY
\ NAME (print REFUSED: … and return 0). The handle is the region base itself.
: cbfs-open ( addr len -- handle )
  drop dup cbfs-rb !              ( addr )
  dup cbfs-validate ?refused if  ( addr c-addr u )
    .refusal drop 0 exit
  then
  2drop ;                        ( addr )

\ cbfs-fields ( handle -- )  the cbfs_file header, walked through the cursor, so
\ the layout is stated here (cursor mode has no named field: word to read a tid).
: cbfs-fields ( handle -- )  drop
  s" magic"   0  8 .field3
  s" len"     8  4 .field3
  s" type"    c  4 .field3
  s" attrs"  10  4 .field3
  s" offset" 14  4 .field3 ;

\ cbfs-manifest ( -- )  ARCH:4/4 — CBFS metadata is big-endian, so ppc reads it
\ native while the LE arches byte-swap; the read is correct on all four. The
\ WRITE half is dsl/cbfs-write.fth (HOST-ONLY there), not this reader.
: cbfs-manifest ( -- )
  ." reads coreboot CBFS (big-endian LARCHIVE metadata); refuses a corrupt first entry by name; does NOT write (dsl/cbfs-write.fth) "
  arch-4/4 cr ;

s" cbfs" ['] cbfs-manifest register-module
