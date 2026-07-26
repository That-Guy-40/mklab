\ ofdiag.fth — boot forensics vocabulary (spike 2, v1)
\
\ A boot failure must name the SPECIFIC failing step, not just "Can't open boot
\ device". Each rung is a distinct fault class, so one printed line identifies
\ the broken invariant.
\
\ v0 BUG (caught by the fault matrix on its first run): expand-alias's flag means
\ "an alias WAS expanded", NOT "success". A full path is legitimately not an
\ alias and returns false with the string untouched — so treating false as
\ failure made every input report OFDIAG-1. The real test for "unknown name" is
\ the one `aliased?` uses: a pathname beginning with "/" is not an alias.

: diag-open  ( dev$ -- )
   ." OFDIAG target: " 2dup type cr
   2dup expand-alias  >r                      ( dev$ path$   r: alias-expanded? )
   2swap 2drop                                ( path$ )
   r>  0=  if                                 ( path$ )
      over c@  ascii /  <>  if                ( path$ )
         2drop  ." OFDIAG-1: not a path, and no such devalias" cr  exit
      then
   then
   ." OFDIAG path:   " 2dup type cr
   2dup find-package  0=  if                  ( path$ )
      2drop  ." OFDIAG-2: no such node in the device tree" cr  exit
   then                                       ( path$ phandle )
   drop                                       ( path$ )
   2dup open-dev  ?dup  if                    ( path$ ihandle )
      close-dev  2drop
      ." OFDIAG-0: opens OK - failure is later (load/execute)" cr  exit
   then                                       ( path$ )
   2drop
   ." OFDIAG-3: node exists but its open method FAILED" cr
;

: why-no-boot  ( -- )  boot-device diag-open  ;
