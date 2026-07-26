\ ofdiag.fth — boot forensics for Open Firmware
\
\ A boot failure must name the SPECIFIC failing step, not just "Can't open boot
\ device". Two halves:
\
\   diag-open / why-no-boot   a diagnosis LADDER — four distinct fault classes
\   trace-boot / untrace      TRACERS on the firmware's own defer hooks
\
\ Load it with:  fload <device>:\ofdiag.fth
\ (Never type a colon definition at a serial prompt — no flow control, and long
\ lines arrive silently mangled. See the repo's serial doctrine in CLAUDE.md.)

\ ═══════════════════════════════════════════════════════════════════════════
\  The diagnosis ladder
\ ═══════════════════════════════════════════════════════════════════════════
\
\ No `catch` is needed anywhere: expand-alias returns a flag, find-package
\ returns a flag, and open-dev returns 0 rather than throwing. The firmware
\ hands over a clean three-way discriminator for free.
\
\ CAUTION, learned the hard way: expand-alias's flag means "an alias WAS
\ expanded", NOT "success". A full pathname is legitimately not an alias and
\ comes back false with the string untouched. Treating false as failure makes
\ EVERY input report OFDIAG-1. The real test for an unknown name is the one
\ `aliased?` uses: a pathname beginning with "/" is not an alias.

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

\ boot-device is a LIST ("disk net" by default), so diagnose each entry in turn.
\ The tokenizing idiom is the firmware's own: default-device (bootparm.fth:139)
\ walks it with `bl left-parse-string`.

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

\ ═══════════════════════════════════════════════════════════════════════════
\  The tracers
\ ═══════════════════════════════════════════════════════════════════════════
\
\ No call-site patching: the firmware SHIPS its tracepoints. bootparm.fth
\ declares `defer ?show-device ( adr len -- adr len )`, a pass-through hook that
\ receives the device path right before open-dev (line 109) and again while
\ iterating the boot-device list (145); load-started / load-done bracket the
\ load (119/127). All three live inside (boot-read).
\
\ Find them yourself with the firmware's own cross-referencer:  ' open-dev .calls
\ lists (boot-read) and default-device among the callers.
\
\ Output is machine-readable `#T` milestone lines so a host-side renderer
\ (tools/control-pane) can draw a firmware boot timeline.

: t-show-device  ( adr len -- adr len )  ." #T open " 2dup type cr  ;
: t-load-started ( -- )                  ." #T load-begin" cr  ;
: t-load-done    ( -- )                  ." #T load-end" cr  ;

: trace-boot  ( -- )
   ['] t-show-device   to ?show-device
   ['] t-load-started  to load-started
   ['] t-load-done     to load-done
   ." OFDIAG: tracing ON" cr
;

\ A tracer you cannot remove is a bug. Restore every hook to its shipped noop,
\ then prove it by re-running the traced operation and getting silence.
: untrace  ( -- )
   ['] noop  to ?show-device
   ['] noop  to load-started
   ['] noop  to load-done
   ." OFDIAG: tracing OFF" cr
;

." ofdiag loaded: diag-open why-no-boot trace-boot untrace" cr
