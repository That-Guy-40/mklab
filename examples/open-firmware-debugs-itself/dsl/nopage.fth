\ nopage.fth — make OFW's pager unreachable, for scripted drives.
\
\ `no-page` is not enough: something re-enables page mode inside `debug`, and
\ (exit?) has a second trap -- `key? if key ...` STEALS a pending keystroke to
\ answer its own prompt, so keys meant for a full-screen app get eaten by the
\ pager while a listing is still printing.
\
\ lines/page is a DEFER (forth/lib/suspend.fth: `defer lines/page`), so pointing
\ it at an absurd number means #line can never reach it and `suspend` is never
\ called. Unlike no-page this survives (reset-page), which only clears #line.
\
\ NOT a substitute for `' false to interactive?` -- that one also silences the
\ `ok` prompt itself (interactive? means "is input coming from the keyboard?"),
\ which leaves a scripted driver with nothing to synchronise on.

d# 30000 constant huge-page
' huge-page to lines/page

." nopage loaded: the pager can no longer interrupt a listing" cr
