\ autotrace.fth — shipped as the `boot-` dropin, to trace the POWER-ON autoboot.
\
\ This is the one thing `fload` can never do. By the time you have a prompt to
\ type at, the machine has already tried to boot; the tracers arrive too late to
\ see it. OFW's answer is a startup-hook dropin, and there are two candidates:
\
\   `boot-`    ofw/core/bootparm.fth: " boot-" do-drop-in / do-auto-boot
\              Fires nearest the boot -- but auto-boot's `reboot?` branch takes an
\              early `exit` BEFORE reaching it, so a WARM REBOOT is never traced.
\
\   `banner-`  ofw/core/banner.fth:141, the first act of banner(), which startup
\              calls before auto-boot on EVERY path. No such hole.  <-- we use this
\
\ So the tracers are armed from `banner-`: earlier than strictly necessary, which
\ only means more coverage, and no blind spot on the reboot path.
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

." #T autotrace armed (banner- dropin)" cr

\ Reachability note: the warm-reboot path cannot be exercised on this firmware at
\ all. `reboot?` is set only by copy-reboot-info from the NVRAM variable
\ `reboot-command` (ofw/core/reboot.fth), and this demo build cannot write NVRAM:
\   ok " testcmd" " reboot-command" $setenv
\   Unimplemented package interface procedure
\ so reboot? is always false here. Using `banner-` closes the hole BY
\ CONSTRUCTION; on hardware with working NVRAM it would also be demonstrable.
