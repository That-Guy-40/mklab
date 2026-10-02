\ fdt-conform.fth — dsl/fdt-read.fth's opt-in to the conformance contract (v1).
\
\ A SIDECAR, not a merge. Load struct.fth + contract.fth + fdt.fth + fdt-read.fth
\ FIRST, then this. See dsl/CONTRACT.md. Hex.
\
\ NOTE ON fdt-open: fdt-read.fth already has an internal `fdt-open ( adr -- ok? )`
\ that its (fdt-walk) calls. Forth redefinition is NOT retroactive, so the walker
\ keeps the original; the contract `fdt-open` below is a SEPARATE, later binding
\ (nothing but this contract calls it), and it has the contract signature.
hex

\ fdt-validate ( handle -- c-addr u )  the format invariant: the FDT magic. Read
\ big-endian through fdt-read.fth's own fr@, so ppc reads it native.
: fdt-validate ( handle -- c-addr u )
  fr@ fdt-magic = if 0 0 else s" fdt: bad FDT magic (want d00dfeed)" then ;

\ fdt-open ( addr len -- handle )  bind; refuse a bad magic BY NAME (return 0).
: fdt-open ( addr len -- handle )
  drop dup fr@ fdt-magic <> if
    drop ." REFUSED: fdt: bad FDT magic (want d00dfeed)" cr 0 exit
  then ;                         ( addr )

\ fdt-fields ( handle -- )  the flattened-device-tree HEADER (all big-endian).
\ Cursor/offset reader, so the layout is stated here.
: fdt-fields ( handle -- )  drop
  s" magic"             0  4 .field3
  s" totalsize"         4  4 .field3
  s" off_dt_struct"     8  4 .field3
  s" off_dt_strings"    c  4 .field3
  s" off_mem_rsvmap"   10  4 .field3
  s" version"          14  4 .field3
  s" last_comp_version" 18 4 .field3
  s" size_dt_strings"  20  4 .field3
  s" size_dt_struct"   24  4 .field3 ;

\ fdt-live ( -- handle )  the contract's NAME-live: a SEAM-BACKED LIVE handle over
\ the firmware's OWN device tree. Each call RE-FLATTENS the live tree (dt>fdt from
\ `/`) into a buffer and returns it, so a property the firmware just set, or a node
\ it just created, is reflected on the next read — the live-vs-snapshot distinction
\ the contract grades. Its snapshot cousin is fdt-open on a CAPTURED DTB, whose
\ bytes do not change. The buffer is alloc-mem'd once, lazily (dt>fdt needs
\ /fdt-buf of room); re-flattening reuses it. LIVE only makes sense in the firmware
\ that owns the tree — the pacme host side reads a captured flatten and is SNAPSHOT.
variable fdt-live-buf   0 fdt-live-buf !
: fdt-live ( -- handle )
  fdt-live-buf @ 0= if /fdt-buf alloc-mem fdt-live-buf ! then
  fdt-live-buf @ dt>fdt drop        \ re-flatten the LIVE tree each call
  fdt-live-buf @ ;                  ( handle = the freshly-flattened DTB )

\ fdt-manifest ( -- )  ARCH:4/4 — every field is read big-endian (l@-be), so ppc
\ reads native while the LE arches byte-swap; correct on all four. Refuses BAD-MAGIC
\ / BAD-TOKEN / running off the end by name (fdt-read.fth). Offers a LIVE seam-backed
\ handle (fdt-live, re-flattening the firmware's own tree); fdt-open on a captured DTB
\ is the SNAPSHOT cousin. MATERIALIZES into the live tree (fdt>dt), which is why
\ fdt.fth must be loaded too.
: fdt-manifest ( -- )
  ." reads a flattened device tree (big-endian) and materializes it into the live tree; offers a LIVE handle (fdt-live) over the firmware's own tree; refuses bad magic/token/overrun by name "
  arch-4/4 live-view cr ;

s" fdt" ['] fdt-manifest register-module
