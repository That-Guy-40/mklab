\ bootparams-conform.fth — dsl/bootparams.fth's opt-in to the contract (v1).
\
\ A SIDECAR, not a merge. Load struct.fth + contract.fth + bootparams.fth FIRST,
\ then this. See dsl/CONTRACT.md. Module NAME is `bootparams` (the code's own
\ words are `bp-*`; `bootparams-open` below does not collide with `bp-open`). Hex.
hex

\ bootparams-validate ( handle -- c-addr u )  the format invariant: the two anchors
\ of an x86 setup header — boot_flag 0xAA55 @0x1fe and "HdrS" 0x53726448 @0x202.
\ Both are little-endian, so this is where ppc earns its keep (a native read there
\ would see 0x48647253, not "HdrS"). The length-dependent TRUNCATED is caught by
\ bootparams-open, which has the buffer length.
: bootparams-validate ( handle -- c-addr u )
  dup bp-boot-flag t@ aa55 <> if drop s" bootparams: no 0xAA55 boot flag at 0x1fe" exit then
      bp-header    t@ 53726448 <> if s" bootparams: no HdrS magic at 0x202" exit then
  0 0 ;

\ bootparams-open ( addr len -- handle )  reuse bp-open (binds bp-img/bp-end, full
\ validation incl. TRUNCATED); refuse BY NAME on a nonzero status, else return the
\ buffer base as the handle.
: bootparams-open ( addr len -- handle )
  2dup bp-open ?dup if
    ." REFUSED: bootparams: "
    dup 1 = if ." no 0xAA55 boot flag at 0x1fe"
    else dup 2 = if ." no HdrS magic at 0x202"
    else ." truncated (setup header runs past the buffer)" then then
    cr drop 2drop 0 exit
  then drop ;                      \ ( -- addr ): the handle is the buffer base

\ bootparams-fields ( handle -- )  the fields a loader reads (fixed offsets, LE).
: bootparams-fields ( handle -- )  drop
  s" boot_flag"    1fe 2 .field3
  s" header"       202 4 .field3
  s" version"      206 2 .field3
  s" code32_start" 214 4 .field3
  s" cmd_line_ptr" 228 4 .field3
  s" init_size"    260 4 .field3 ;

\ bootparams-manifest ( -- )  ARCH:4/4 — the x86 boot protocol is little-endian by
\ definition; the four-arch row proves ppc reads "HdrS" like every other arch. This
\ is a PCR-free loader view of the zero page (the boot artifact, not a live TPM).
: bootparams-manifest ( -- )
  ." reads the x86 boot zero-page (an x86-domain format read little-endian; ppc proves the LE reads); refuses BAD-BOOTFLAG/BAD-HDRS/TRUNCATED by name "
  arch-4/4 cr ;

s" bootparams" ['] bootparams-manifest register-module
