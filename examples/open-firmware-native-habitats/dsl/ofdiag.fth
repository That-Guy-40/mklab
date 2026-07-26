\ ofdiag.fth — boot forensics for OpenBIOS, in Open Firmware's native habitats
\
\ A PORT of ../../open-firmware-debugs-itself/dsl/ofdiag.fth, which runs on
\ Bradley's OFW on x86. Same vocabulary — same word names, same four fault
\ classes, same `#T`-style machine-readable output — but NOT the same code.
\ That is the lesson: a vocabulary is portable, an implementation is not.
\
\ What survived the port unchanged:
\   expand-alias   ( alias$ -- expansion$ expanded? )   same contract, same trap
\   find-package   ( name$ -- phandle true | false )
\   open-dev       ( path$ -- ihandle | 0 )             returns 0, does not throw
\   left-parse-string ( str$ char -- rest$ head$ )
\ so the three-way discriminator is free here too — no `catch` anywhere.
\
\ What did NOT survive, and why (see PORTING.md):
\   * a FIFTH rung was forced. On x86 boot-device is "disk net" — bare names.
\     In the native habitats every entry carries device ARGUMENTS:
\         Sun    "disk:a disk"
\         Apple  "hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT"
\     Alias lookup must therefore see the HEAD only, or every real-world
\     boot-device entry misdiagnoses as OFDIAG-1.
\   * the TRACERS are gone. OFW ships `defer ?show-device / load-started /
\     load-done` as pass-through hooks on its boot path; OpenBIOS declares no
\     defer anywhere on that path (verified: `grep -rn "defer" forth/`), so
\     there is nothing to re-point. See tracers.fth for what replaces them.
\
\ Load it with (SPARC only — see DELIVERY.md; PPC has no readable filesystem):
\   load cdrom:\OFDIAG.FTH
\   load-base load-size evaluate

\ ═══════════════════════════════════════════════════════════════════════════
\  The diagnosis ladder
\ ═══════════════════════════════════════════════════════════════════════════

\ The device part of "disk:a" / "hd:,\ppc\bootinfo.txt" — everything before the
\ first ':'. left-split leaves the tail in R$ and the head in L$, and when the
\ delimiter is absent it hands back the WHOLE string as L$ (forth/lib/split.fs),
\ which is exactly the behaviour a bare "disk" needs.
: dev-head  ( dev$ -- head$ )
   ascii : left-parse-string  2swap 2drop
;

\ CAUTION, inherited from the x86 lab and still true here: expand-alias's flag
\ means "an alias WAS expanded", NOT "success". A full pathname is legitimately
\ not an alias and comes back false with the string untouched. Treating false as
\ failure makes EVERY input report OFDIAG-1. The real test for an unknown name
\ is the one `aliased?` uses: a pathname beginning with "/" is not an alias.
: diag-open  ( dev$ -- )
   ." OFDIAG target: " 2dup type cr
   2dup dev-head                              ( dev$ head$ )
   2dup expand-alias  >r                      ( dev$ head$ path$   r: expanded? )
   2swap 2drop                                ( dev$ path$ )
   r>  0=  if
      over c@  ascii /  <>  if
         2drop 2drop
         ." OFDIAG-1: not a path, and no such devalias" cr  exit
      then
   then
   ." OFDIAG path:   " 2dup type cr
   2dup find-package  0=  if                  ( dev$ path$ )
      2drop 2drop
      ." OFDIAG-2: no such node in the device tree" cr  exit
   then                                       ( dev$ path$ phandle )
   drop 2drop                                 ( dev$ )
   \ Open the FULL entry, arguments and all — ":a", ",\ppc\bootinfo.txt" and
   \ "%BOOT" are what the open method actually acts on. (The x86 version opened
   \ the resolved path, which is equivalent only because x86 had no arguments.)
   2dup open-dev  ?dup  if                    ( dev$ ihandle )
      close-dev  2drop
      ." OFDIAG-0: opens OK - failure is later (load/execute)" cr  exit
   then                                       ( dev$ )
   2drop
   ." OFDIAG-3: node exists but its open method FAILED" cr
;

\ boot-device is a LIST on every one of the three architectures — that is the
\ whole reason this word walks rather than tests:
\   x86    "disk net"
\   Sun    "disk:a disk"
\   Apple  "hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT"
\ OpenBIOS exposes boot-device as a config WORD pushing ( -- str len ), the same
\ shape OFW's `boot-device` has, so the walk itself ported verbatim.
: why-no-boot  ( -- )
   ." OFDIAG: boot-device = " boot-device type cr
   boot-device                                ( devs$ )
   begin  dup  while                          ( devs$ )
      bl left-parse-string                    ( rest$ tok$ )
      dup  if  2dup diag-open  then           ( rest$ tok$ )
      2drop                                   ( rest$ )
   repeat
   2drop
;

." ofdiag loaded: dev-head diag-open why-no-boot" cr
