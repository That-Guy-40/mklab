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

\ ────────────────────────────────────────────────────────────────────────────
\ mem-map — the memory regions the firmware believes it has.
\ /memory@0's "available" property is a list of (start,size) pairs. Cross-check
\ the total against QEMU's -m from outside: the firmware's own arithmetic is not
\ evidence about the machine, it is a claim about the machine.
\ NB: OFW's get-package-property returns TRUE on FAILURE (error-flag convention).

0 value memtotal

: mem-map  ( -- )
   0 to memtotal
   ." #M begin" cr
   " /memory@0" find-package  0=  if
      ." #M no /memory@0 node" cr  exit
   then                                       ( phandle )
   " available" rot get-package-property  if
      ." #M no available property" cr  exit
   then                                       ( data$ )
   begin  dup  while                          ( data$ )
      decode-int  >r                          ( data$'   r: start )
      decode-int                              ( data$'' size )
      ." #M region start=" r> u.  ." size=" dup u.  cr
      memtotal + to memtotal                  ( data$'' )
   repeat
   2drop
   ." #M total=" memtotal u. cr
   ." #M end" cr
;

\ ────────────────────────────────────────────────────────────────────────────
\ region-diff — snapshot RAM, do a thing, show only what moved.
\ The forensic primitive the parent lab needed by hand in POC-2 when it had to
\ prove an initrd was intact and the corruption happened later.

0 value snapadr
0 value snaplen
0 value snapbuf

: region-snap  ( adr len -- )
   to snaplen  to snapadr
   snaplen alloc-mem to snapbuf
   snapadr snapbuf snaplen move
   ." #R snapped " snaplen u. ." bytes at " snapadr u. cr
;

: region-diff  ( -- )
   snapbuf 0=  if  ." #R no snapshot taken" cr  exit  then
   0                                          ( ndiff )
   snaplen 0  do
      snapadr i + c@   snapbuf i + c@   <>  if
         1+
         dup 9 <  if                          \ cap the listing, keep counting
            ." #R diff +" i u.
            ."  was " snapbuf i + c@ u.
            ."  now " snapadr i + c@ u.  cr
         then
      then
   loop
   ." #R total-diffs=" u. cr
;
