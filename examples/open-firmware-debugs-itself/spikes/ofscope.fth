\ ofscope.fth — memory & device exploration (spike 3, v2)
\
\ v1 BUG, caught by the QMP cross-check: it walked function 0 only, so the three
\ functions of the PIIX at dev 1 collapsed into one line. The firmware's own
\ device tree had them right (pci-ide@1,1, pci8086,7113@1,3) — the walker was
\ wrong, which is exactly what checking against ground truth is for.
\
\ Config address = dev<<11 | fn<<8 | reg. Multifunction is bit 7 of the header
\ type byte (reg 0x0c, bits 16-23).
hex

: cfg  ( dev fn -- base )  8 lshift  swap b lshift  or  ;

: .pcifn  ( dev fn -- )
   ." #P dev=" over .  ." fn=" dup .    ( dev fn )
   cfg                                  ( base )
   dup      config-l@  ." id="    u.
   dup 8  + config-l@  ." class=" u.
   dup 10 + config-l@  ." bar0="  u.
   dup 14 + config-l@  ." bar1="  u.
       30 + config-l@  ." rom="   u.
   cr
;

: present?  ( dev fn -- flag )
   cfg config-l@  dup ffffffff <>  swap 0<>  and
;
: multifn?  ( dev -- flag )
   0 cfg  c +  config-l@  10 rshift  80 and  0<>
;

: pci-map  ( -- )
   ." #P begin" cr
   20 0 do
      i 0 present?  if
         i 0 .pcifn
         i multifn?  if
            8 1 do
               j i present?  if  j i .pcifn  then
            loop
         then
      then
   loop
   ." #P end" cr
;
