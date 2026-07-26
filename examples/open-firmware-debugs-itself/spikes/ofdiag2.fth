\ ofdiag2.fth — the TRACER half of ofdiag (spike 2b)
\
\ No call-site patching needed: the firmware SHIPS tracepoints. bootparm.fth
\ declares `defer ?show-device ( adr len -- adr len )` — a pass-through hook that
\ receives the device path immediately before open-dev (line 109) and again while
\ iterating the boot-device list (145) — plus load-started/load-done bracketing
\ the load (119/127). Deferred words are firmware-sanctioned patch points; this
\ is the parent lab's `' my-dma to allocate-dma` trick, systematized.
\
\ Output is machine-readable `#T ...` milestone lines, so tools/control-pane can
\ render a firmware boot timeline the same way it renders any other milestone.

: t-show-device  ( adr len -- adr len )  ." #T open " 2dup type cr  ;
: t-load-started ( -- )                  ." #T load-begin" cr  ;
: t-load-done    ( -- )                  ." #T load-end" cr  ;

: trace-boot  ( -- )
   ['] t-show-device   to ?show-device
   ['] t-load-started  to load-started
   ['] t-load-done     to load-done
   ." OFDIAG: tracing ON" cr
;

\ A tracer you cannot remove is a bug: restore every hook to its shipped noop.
: untrace  ( -- )
   ['] noop  to ?show-device
   ['] noop  to load-started
   ['] noop  to load-done
   ." OFDIAG: tracing OFF" cr
;
