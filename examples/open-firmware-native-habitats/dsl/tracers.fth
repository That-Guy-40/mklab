\ tracers.fth — boot tracing on a firmware that ships no tracepoints
\
\ The x86 sibling's ofdiag installs its tracers by re-pointing hooks OFW SHIPS:
\
\   ['] t-show-device to ?show-device      \ bootparm.fth declares these as
\   ['] t-load-started to load-started     \ `defer` pass-throughs on the boot
\   ['] t-load-done   to load-done         \ path, for exactly this purpose
\
\ OpenBIOS declares NO `defer` anywhere on its boot path — not in `$load`, not
\ in `boot`, not around `open-dev`. There is nothing to re-point. So the tracers
\ could not be ported; they had to be rebuilt on the standard's OTHER answer,
\ `patch` (7.5.3.3) — which OpenBIOS also ships empty, and which ../dsl/patch.fth
\ therefore implements. Load that FIRST.
\
\ The result is arguably better than the x86 version: OFW's tracers only work
\ where OFW's author thought to put a hook. These work at ANY call site in ANY
\ colon definition, because they rewrite the call itself.

\ ═══════════════════════════════════════════════════════════════════════════
\  The traced replacements
\ ═══════════════════════════════════════════════════════════════════════════
\
\ Each wrapper prints a machine-readable `#T` milestone and then calls the word
\ it replaces. No recursion hazard: `patch` rewrites the call site inside a
\ NAMED word only, so t-open-dev's own reference to open-dev is untouched.

: t-open-dev  ( path$ -- ihandle )
   ." #T open " 2dup type cr
   open-dev
;

: t-load  ( path$ -- )
   ." #T load-begin" cr
   $load
   ." #T load-end" cr
;

\ ═══════════════════════════════════════════════════════════════════════════
\  Install / remove
\ ═══════════════════════════════════════════════════════════════════════════
\
\ Two sites, deliberately at different depths:
\   open-dev inside $load   — every device the loader opens
\   $load    inside boot    — brackets the load itself
\
\ untrace is the SAME patch with the arguments exchanged. A tracer you cannot
\ remove is a bug, so this is not a convenience — proving the firmware goes back
\ to silence is how you know you measured it rather than changed it.

0 value trace-sites

: trace-boot  ( -- )
   0 to trace-sites
   ['] t-open-dev false  ['] open-dev false  ['] $load  (patch)
   patch-count trace-sites + to trace-sites
   ['] t-load     false  ['] $load    false  ['] boot   (patch)
   patch-count trace-sites + to trace-sites
   ." #T tracing ON, " trace-sites . ." call site(s) rewritten" cr
;

: untrace  ( -- )
   0 to trace-sites
   ['] open-dev false  ['] t-open-dev false  ['] $load  (patch)
   patch-count trace-sites + to trace-sites
   ['] $load    false  ['] t-load     false  ['] boot   (patch)
   patch-count trace-sites + to trace-sites
   ." #T tracing OFF, " trace-sites . ." call site(s) restored" cr
;

." tracers loaded: trace-boot untrace t-open-dev t-load" cr
