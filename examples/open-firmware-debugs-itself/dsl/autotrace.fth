\ autotrace.fth — shipped as the `boot-` dropin, to trace the POWER-ON autoboot.
\
\ This is the one thing `fload` can never do. By the time you have a prompt to
\ type at, the machine has already tried to boot; the tracers arrive too late to
\ see it. OFW's answer is a startup-hook dropin: ofw/core/bootparm.fth runs
\
\     " boot-" do-drop-in
\     do-auto-boot
\     " boot+" do-drop-in
\
\ so a dropin named `boot-` is executed IMMEDIATELY BEFORE the autoboot, from
\ inside the ROM, with no media and nothing typed.
\
\ Source, not FCode, on purpose: ofw/fcode/byteload.fth's execute-buffer sniffs
\ the first byte (0xf0-0xf3/0xfd = FCode) and otherwise evaluates the buffer as
\ Forth text. The flavor already proves this works -- its `probe-` dropin is
\ builton.fth, plain source that defines words and edits the device tree.
\
\ Interpret-state tick (') here, NOT ['] -- we are not inside a colon definition.
\ Same idiom the sister lab used at the prompt: ' my-dma to allocate-dma

: t-show-device  ( adr len -- adr len )  ." #T open " 2dup type cr  ;
: t-load-started ( -- )                  ." #T load-begin" cr  ;
: t-load-done    ( -- )                  ." #T load-end" cr  ;

' t-show-device   to ?show-device
' t-load-started  to load-started
' t-load-done     to load-done

." #T autotrace armed (boot- dropin)" cr

\ CAVEAT, from the source: auto-boot's reboot? branch takes an early `exit`
\ BEFORE reaching `" boot-" do-drop-in`, so a warm reboot-with-saved-command is
\ NOT traced by this hook. Cold autoboot only.
