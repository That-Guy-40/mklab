\ bootparams-edit.fth — in-place editor for the x86 kernel command line that
\ boot_params' cmd_line_ptr (u32 @0x228) names, on struct.fth + bootparams.fth
\ (UKI Spike 7a — the classic-kernel rescue seam).
\
\ Not every rescue target is a UKI. A plain `kernel + initrd` boot reads its
\ command line from a RUNTIME buffer whose address a bootloader writes into
\ cmd_line_ptr. bootparams.fth already READS that field; this word set FOLLOWS it
\ into the buffer and REWRITES the string in place (add `init=/bin/bash`,
\ `single`, `rd.break`) — the rescue edit the readers set up but never made.
\
\ THE FIXTURE IS A FOREIGN, PHYS-0-INDEXED DUMP, and that is the whole trick.
\ cmd_line_ptr is 0 on disk — only a bootloader sets it, in RAM — so there is no
\ on-disk value to grade. The fixture is therefore guest physical memory captured
\ from a real bootloader (QEMU's own -kernel loader) DUMPED FROM ADDRESS 0. In a
\ phys-0-indexed image, cmd_line_ptr — a physical address QEMU chose (0x20000) —
\ is a DIRECT OFFSET into the image: no pointer rebasing, so nothing about the
\ field under test is re-authored by us. boot_params itself sits somewhere inside
\ (QEMU: 0x10000), and we LOCATE it by scanning for bootparams.fth's own two
\ anchors, never a fixed address — the editor finds boot_params the same way the
\ reader validates it.
\
\ SECURITY — the write is bounded on BOTH ends before a byte moves, and each
\ refusal writes NOTHING and NAMES the reason, like the readers do:
\   bp| NO-CMDLINE       cmd_line_ptr is 0, or resolves outside the image
\   bp| CMDLINE-TOO-BIG  the new line exceeds cmdline_size (the PROTOCOL maximum,
\                        u32 @0x238) — the bound a real kernel enforces
\   bp| CMDLINE-OOB      the new line + NUL would run past the IMAGE end — the
\                        bound this captured buffer actually has
\ The two bounds are distinct on purpose: cmdline_size is the protocol's limit,
\ the image end is the fixture's; a write must satisfy both.
\
\ A COMMAND LINE IS DEFINED BY ITS NUL TERMINATOR (unlike a PE section, which a
\ reader takes up to VirtualSize) — so a NUL after the new bytes is the whole
\ edit; the stale tail past it is unreachable to the kernel and to `cstr`.
\
\ WHY THE FOUR-ARCH MATRIX STILL BITES though the byte copy is order-free: every
\ field this touches — the anchors in the scan, cmd_line_ptr, cmdline_size — is
\ LITTLE-ENDIAN and read through struct.fth's le-field:. A native fetch on ppc
\ would byte-swap cmd_line_ptr and follow it into hyperspace; the matrix proves
\ ppc resolves the same pointer x86 does. This is bootparams.fth's lesson, one
\ mutation further.
\
\ Load struct.fth, then bootparams.fth, then this.
hex

\ cmdline_size (u32 @0x238): the protocol's maximum command-line length. This is
\ the one field bootparams.fth does not declare (it reads to init_size @0x260);
\ the editor needs it as the TOO-BIG bound.
238 4 le-field: bp-cmdline-size drop

\ ── the phys-0 dump and the boot_params inside it ────────────────────
variable cle-dump    \ image base — the loaded dump, = guest physical 0
variable cle-dend    \ image end
variable cle-bp      \ boot_params, located within the dump by its anchors

: cle-anchored? ( c -- flag )   \ bootparams.fth's own two anchors at candidate c
  dup bp-boot-flag t@ aa55     <> if drop false exit then
      bp-header    t@ 53726448 = ;

\ cle-find-bp ( -- adr | 0 ) — first boot_params in the dump. Candidates are
\ paragraph-aligned: every real loader aligns boot_params (QEMU page-aligns it at
\ 0x10000), so a 16-byte stride finds it and never reads a field off the end.
: cle-find-bp ( -- adr | 0 )
  cle-dend @ cle-dump @ -                 ( dumplen )
  dup 264 u< if drop 0 exit then          \ too small to hold a boot_params
  264 - 4 rshift 1+                        ( paras )
  0 ?do
    cle-dump @ i 4 lshift +               ( c )
    dup cle-anchored? if unloop exit then
    drop
  loop 0 ;

\ cle-open ( adr len -- status )  0 ok / 4 NO-BOOTPARAMS / 1,2,3 from bp-open
\ Record the dump, find boot_params, then let bp-open validate the anchors and
\ set bp-img/bp-end (so bootparams.fth's own words work on the same boot_params).
: cle-open ( adr len -- status )
  2dup + cle-dend !  drop cle-dump !
  cle-find-bp dup 0= if drop 4 exit then  ( bpadr )
  dup cle-bp !                            ( bpadr )
  cle-dend @ over -  bp-open ;            ( status )

\ ── follow cmd_line_ptr into the dump ───────────────────────────────
: cle-ptr ( -- u )    cle-bp @ bp-cmdline-ptr t@ ;      \ the physical address
: cle-adr ( -- adr )  cle-dump @ cle-ptr + ;            \ = phys 0 + that address
: cle-ptr-ok? ( -- flag )   \ nonzero AND resolves inside the dump
  cle-ptr dup 0= if drop false exit then
  cle-dump @ + cle-dend @ u< ;

\ bp-cmdline ( -- adr len | 0 0 ) — the command line the pointer names, read to
\ its NUL. A zero or out-of-image pointer answers 0 0 (type prints nothing).
: bp-cmdline ( -- adr len | 0 0 )
  cle-ptr-ok? 0= if 0 0 exit then
  cle-adr cstr ;

\ ── the edit ─────────────────────────────────────────────────────────
\ bp-cmdline-set ( new-adr u -- ok? ) overwrite the command line in place and
\ NUL-terminate. Refuses BY NAME (above), writing NOTHING. new-adr/u are parked
\ so the refusal lines never juggle the stack (cpio-edit.fth's shape).
variable cle-src  variable cle-ulen
: bp-cmdline-set ( new-adr u -- ok? )
  cle-ulen !  cle-src !
  cle-ptr-ok? 0= if ." bp| NO-CMDLINE" cr false exit then
  cle-ulen @ cle-bp @ bp-cmdline-size t@ u>
      if ." bp| CMDLINE-TOO-BIG" cr false exit then
  cle-adr cle-ulen @ + 1+ cle-dend @ u>
      if ." bp| CMDLINE-OOB" cr false exit then
  cle-src @  cle-adr  cle-ulen @  move          \ write the new bytes
  0  cle-adr cle-ulen @ +  c!                    \ NUL-terminate
  true ;
