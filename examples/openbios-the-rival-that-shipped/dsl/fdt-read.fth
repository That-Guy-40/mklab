\ fdt-read.fth — the READER half of fdt.fth: a flattened device tree, walked, and
\ MATERIALIZED into the live tree. B.3 Spike 5. Where dt>fdt hands the
\ firmware's world over, fdt>dt takes one in -- the DTB a kernel would be given,
\ or one dtc authored on the host -- and builds real device nodes from it, so
\ the tree can be flattened AGAIN and dtc asked whether it got the same tree.
\
\ Two words over one walker (fr-make selects):
\   fdt-walk ( adr -- ok? )  parse only; count nodes and properties
\   fdt>dt   ( adr -- ok? )  the same walk, creating: the blob's ROOT properties
\                            land on the ACTIVE package, every child becomes a
\                            new-device under it, every property a property
\ Every field is read big-endian (l@-be), which is the byte-order axis again --
\ ppc reads native, the little-endian arches swap -- and every refusal is by
\ name: BAD-MAGIC, BAD-TOKEN, or running off the end of the blob.
\
\ A node's FDT name is `base@unit`; OpenBIOS derives the unit from `reg` through
\ the parent's encode-unit, so the materializer stores the BASE name only and
\ lets the tree regenerate the unit. Load struct.fth and fdt.fth first. Hex.
hex

variable fr-buf   variable fr-cur   variable fr-str   variable fr-end
variable fr-nodes variable fr-props variable fr-depth variable fr-make

: fr@ ( adr -- u )  l@-be ;
: fdt-open ( adr -- ok? )
  dup fr@ fdt-magic <> if ." fdt| BAD-MAGIC " fr@ u. cr false exit then
  dup fr-buf !
  dup dup 8 + fr@ + fr-cur !               \ off_dt_struct
  dup dup c + fr@ + fr-str !               \ off_dt_strings
  dup 4 + fr@ + fr-end !                   \ totalsize
  0 fr-nodes !  0 fr-props !  0 fr-depth !  true ;
: fr-tok ( -- tok )    fr-cur @ fr@  4 fr-cur +! ;
: fr-align ( -- )      fr-cur @ 3 + -4 and fr-cur ! ;
: fr-cstr ( -- adr len )  fr-cur @ dup cstrlen  2dup + 1+ fr-cur !  fr-align ;
: fr-pname ( off -- adr len )  fr-str @ + dup cstrlen ;
: fr-value ( len -- adr len )  fr-cur @ swap  2dup + fr-cur !  fr-align ;
: fr-base ( adr len -- adr len' )            \ the name up to its @unit
  dup 0 ?do  over i + c@ 40 = if drop i unloop exit then  loop ;

: fr-begin ( -- )
  fr-cstr  1 fr-nodes +!
  fr-depth @ 0<> fr-make @ and if fr-base new-device device-name else 2drop then
  1 fr-depth +! ;
: fr-prop ( -- )
  fr-tok fr-tok fr-pname  rot fr-value       ( name$ adr len )
  1 fr-props +!
  fr-make @ if 2swap property else 2drop 2drop then ;
: fr-endnode ( -- )
  -1 fr-depth +!  fr-depth @ 0<> fr-make @ and if finish-device then ;

: (fdt-walk) ( adr -- ok? )
  fdt-open 0= if false exit then
  begin
    fr-cur @ fr-end @ >= if ." fdt| RAN-OFF-END" cr false exit then
    fr-tok
    dup FDT_BEGIN_NODE = if drop fr-begin   else
    dup FDT_PROP       = if drop fr-prop    else
    dup FDT_END_NODE   = if drop fr-endnode else
    dup FDT_END        = if drop true exit  else
    dup 4 = if drop else ." fdt| BAD-TOKEN " u. cr false exit then
    then then then then
  again ;
: fdt-walk ( adr -- ok? )  false fr-make !  (fdt-walk) ;
: fdt>dt   ( adr -- ok? )  true  fr-make !  (fdt-walk) ;
: .fr-counts ( -- )
  ." RNODES=" fr-nodes @ u.  ." RPROPS=" fr-props @ u.  cr ;
