\ uki-dissect.fth — the UKI Workbench capstone: dissect a Unified Kernel Image
\ using ONLY the conformance-contract vocabulary (contract v1).
\
\ A UKI is one PE/COFF file that CONTAINS several typed artifacts — a bzImage
\ `.linux`, a newc-cpio `.initrd`, string sections. This word reads every claim it
\ makes about itself by handing each contained blob to `identify`, the registry-
\ driven capstone (dsl/identify.fth), which names a format by trying each
\ registered module's `NAME-validate` — with NO per-format knowledge of its own.
\ So this consumer, too, contains NO per-format code: it opens the container with
\ the contract's `pe-open`, locates the sections with pe.fth's own walk, and lets
\ `identify` name what is inside. Add a module (load its `-conform` sidecar) and a
\ UKI section of that kind is named for free; drop one and it stops being claimed.
\ That is the federation payoff — "a capstone can consume any module the same way"
\ (FIRMWARE_FAMILY_ROADMAP §2) — made concrete on a real artifact.
\
\ LOAD ORDER (the profile the smoke track stages), so redefinition lands right and
\ every reader has registered before identify runs:
\   struct.fth  contract.fth
\   bootparams.fth bootparams-conform.fth        \ .linux  -> "bootparams" (a kernel)
\   pe.fth pe-conform.fth                          \ the container -> "pe"
\   cpio.fth cpio-conform.fth                      \ .initrd -> "cpio"
\   identify.fth  <this>
\ Registration ORDER is the dispatch policy: bootparams before pe means the
\ POLYMORPHIC .linux (an EFI-stub kernel is BOTH a valid PE and a valid x86 boot
\ image) is named by its kernel identity, the meaningful one, since identify
\ returns the first registered claimant.
hex

\ ud-id ( uki-a uki-l name-a name-l -- )  find a named section in the UKI and hand
\ its bytes to identify; note a missing section by name rather than mis-claiming.
: ud-id ( uki-a uki-l name-a name-l -- )
  pe-find dup if identify else 2drop ." (section absent)" cr then ;

\ uki-dissect ( adr len -- )  the whole dissection, in contract words only.
: uki-dissect ( adr len -- )
  2dup pe-open dup 0= if drop ." UKI| not a PE (refused above)" cr 2drop exit then
  drop                                        ( adr len )   \ pe-open validated it
  2dup pe-walk 0= if ." UKI| PE section table did not parse" cr 2drop exit then
  cr ." UKI| the container itself: " 2dup identify           \ -> IDENTIFY: pe
  cr ." UKI| .linux  -> "  2dup s" .linux"  ud-id            \ -> IDENTIFY: bootparams
     ." UKI| .initrd -> "  2dup s" .initrd" ud-id            \ -> IDENTIFY: cpio
  2drop
  cr ." UKI| modules the dispatcher consulted (drop one and its kind stops being named):" cr
  .modules ;
