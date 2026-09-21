\ pe-conform.fth — dsl/pe.fth's opt-in to the conformance contract (v1).
\
\ A SIDECAR, not a merge. Load struct.fth + contract.fth + pe.fth FIRST, then this.
\ See dsl/CONTRACT.md. Hex.
\
\ NOTE ON pe-open: pe.fth already has `pe-open ( adr len -- status )` (0/1/2/3),
\ which its pe-walk/pe-find/sec-in-image? call. The contract needs `pe-open ( addr
\ len -- handle )`. We capture the native word's xt FIRST (`(pe-open0)`) and then
\ redefine `pe-open` on top of it — Forth redefinition is not retroactive, so the
\ words compiled in pe.fth keep the status opener, and nothing but this contract
\ (and code compiled after it) sees the handle opener. Nothing else co-loads with
\ this sidecar, so the two never collide.
hex

' pe-open value (pe-open0)         \ the native status opener, before we shadow it

\ pe-validate ( handle -- c-addr u )  the format invariant: 'MZ' at offset 0 and
\ 'PE\0\0' at e_lfanew. Both are byte compares (endian-free); the LE reads the
\ four-arch row exercises are e_lfanew and the section table, in pe.fth. TRUNCATED
\ (length-dependent) is caught by pe-open, which has the buffer length.
: pe-validate ( handle -- c-addr u )
  dup mz? 0= if drop s" pe: no MZ signature at offset 0" exit then
  dup pe-off + pesig? 0= if s" pe: no PE\0\0 signature at e_lfanew" exit then
  0 0 ;

\ pe-open ( addr len -- handle )  reuse the native opener (binds pe-img/pe-hdr/
\ pe-sectab…, full validation incl. TRUNCATED); refuse BY NAME on a nonzero
\ status, else return the buffer base as the handle.
: pe-open ( addr len -- handle )
  2dup (pe-open0) execute ?dup if
    ." REFUSED: pe: "
    dup 1 = if ." no MZ signature at offset 0"
    else dup 2 = if ." no PE\0\0 signature at e_lfanew"
    else ." truncated (a header/table span runs past the buffer)" then then
    cr drop 2drop 0 exit
  then drop ;                      \ ( -- addr ): the handle is the buffer base

\ pe-fields ( handle -- )  the COFF-header + section-entry fields, offsets read from
\ each field's own type-id (' name >body). The two groups have different bases (the
\ COFF fields off the PE signature, the sec-* fields off a section entry), which the
\ printed offset reflects.
: pe-fields ( handle -- )  drop
  s" Machine"      ['] pe-machine  >body .field
  s" NumSections"  ['] pe-nsec     >body .field
  s" OptHdrSize"   ['] pe-optsize  >body .field
  s" OptMagic"     ['] pe-optmagic >body .field
  s" sec.VirtAddr" ['] sec-vaddr   >body .field
  s" sec.VirtSize" ['] sec-vsize   >body .field ;

\ pe-manifest ( -- )  ARCH:4/4 — PE/COFF is the x86/UEFI executable format, but its
\ fields are little-endian on every target, so the reader IS in the four-arch
\ matrix: ppc reads the same section table as x86, not a byte-swap of it (a naive
\ native l@ there would swap every field). The x86 DOMAIN is stated in prose; the
\ reader's cross-arch correctness is the arch claim.
: pe-manifest ( -- )
  ." reads a PE/COFF section table (the x86/UEFI executable format; fields little-endian, ppc proves the LE reads); refuses BAD-MZ/BAD-PESIG/TRUNCATED by name "
  arch-4/4 cr ;

s" pe" ['] pe-manifest register-module
