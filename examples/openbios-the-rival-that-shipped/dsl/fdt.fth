\ fdt.fth — the LIVE device tree, flattened. B.3's named first candidate once
\ CBFS and the event log had paid (plan §6, review F7): OpenBIOS's device tree
\ is the one subject every arch has natively, and a `dt>fdt` flatten is the
\ boot-handoff structure DESIGN-NOTES §8 lists first.
\
\ THE FORMAT (devicetree spec v0.4, FDT version 17), every field BIG-ENDIAN:
\
\   header      10 x u32: magic d00dfeed, totalsize, off_dt_struct,
\               off_dt_strings, off_mem_rsvmap, version 11, last_comp 10,
\               boot_cpuid_phys, size_dt_strings, size_dt_struct
\   rsvmap      pairs of u64 {addr,size}, terminated by {0,0}
\   struct      a token stream: BEGIN_NODE(1) name\0 pad4, then per property
\               PROP(3) len nameoff value pad4, then children, END_NODE(2);
\               END(9) after the root
\   strings     the property NAMES, NUL-terminated, referenced by nameoff
\
\ So it is the Spike-0 cursor vocabulary (length-prefixed, NUL-padded,
\ 4-byte-aligned) plus one big-endian 32-bit store -- the same axis CBFS-write
\ sits on: ppc stores native, x86/amd64/unix byte-swap through l!-be, and
\ coreboot's own dtc grades all four.
\
\ THE WALK IS THE FIRMWARE'S OWN TREE, not a fixture: `" /" find-package`,
\ then child/peer through every node and next-property through every property,
\ with `pnodename` giving the `name@unit` a node prints under `ls`. The two
\ counters exist so a track can grade the OUTCOME against dtc's parse rather
\ than trust the walk: the number of nodes and properties the firmware says it
\ wrote must equal what dtc reads back.
\
\ GETTING THE BYTES OUT is the track's business, and it differs per door: unix
\ has write-file; x86/amd64 hand `fb >phys` to QEMU's QMP pmemsave (QMP, not the
\ HMP monitor, whose parser reads a filename as an expression -- a trap this
\ repo had already recorded); ppc, whose console is pty-only, prints the buffer
\ with the firmware's own `dump` and the host parses the hex back. The grader
\ on every door is dtc, and the counts are graded against fdtdump.
\
\ Load struct.fth first (>phys, for handing the buffer to an outside observer).
\ Base is hex.
hex

d00dfeed constant fdt-magic
1 constant FDT_BEGIN_NODE   2 constant FDT_END_NODE   3 constant FDT_PROP
9 constant FDT_END
28 constant /fdt-hdr            \ 40 bytes
10 constant /fdt-rsv            \ one terminating {0,0} entry
18000 value fdt-struct-max      \ the struct block's room; strings live past it
                                \ (a VALUE so a control can shrink it and watch the refusal)
20000 constant /fdt-buf         \ what a caller must alloc-mem

variable fd-buf  variable fd-cur   \ the struct cursor
variable fd-str  variable fd-str0  \ the strings cursor and its base
variable fd-nodes  variable fd-props  variable fd-over
variable fd-soff   variable fd-ssz    \ the header's two derived offsets

\ ── stores through the struct cursor ────────────────────────────────────────
: f32! ( u -- )        fd-cur @ l!-be  4 fd-cur +! ;
: fpad ( -- )
  begin fd-cur @ 3 and while  0 fd-cur @ c!  1 fd-cur +!  repeat ;
: fbytes ( adr len -- ) dup >r fd-cur @ swap move  r> fd-cur +! ;
: fstr0 ( adr len -- ) fbytes  0 fd-cur @ c!  1 fd-cur +! ;
\ THE BOUND, asked BEFORE a write and sized by what is about to be written: the
\ struct cursor plus n bytes must stay below the strings base. A tree that does
\ not fit REFUSES, by name, rather than writing property values over its own
\ strings. (The first draft checked a fixed margin AFTER each write; one 4 KiB
\ property value would have overrun it before the check ever ran.)
: froom? ( n -- flag )  fd-cur @ + 10 +  fd-str0 @ < ;

\ ── the strings block: append a name, answer its offset ─────────────────────
: fname ( adr len -- off )
  fd-str @ fd-str0 @ -  >r
  dup >r  fd-str @ swap move  r> fd-str +!
  0 fd-str @ c!  1 fd-str +!  r> ;

\ ── one property ────────────────────────────────────────────────────────────
\ THE ROOT'S `name` IS THE ONE PROPERTY WITH NO FDT HOME. 1275 gives every node
\ a `name` and OpenBIOS's root says "OpenBiosTeam,OpenBIOS"; FDT derives node
\ names from BEGIN_NODE, requires the root's to be "", and dtc REFUSES a `name`
\ property that disagrees with the node's base name (name_properties). Every
\ other node's `name` equals its base name by construction, so only the root's
\ is skipped -- and it is skipped by name, not silently.
: root-name? ( ph name$ -- ph name$ flag )
  2dup " name" $= if 2 pick parent 0= else false then ;
: fprop ( ph name$ -- )
  root-name? if 2drop drop exit then
  2dup 2>r  rot get-package-property if 2r> 2drop exit then   ( adr len )
  dup froom? 0= if -1 fd-over !  2r> 2drop 2drop exit then     \ refuse first
  FDT_PROP f32!  dup f32!  2r> fname f32!  fbytes fpad
  1 fd-props +! ;

\ ── one node, then its children (recursive) ─────────────────────────────────
: fnode ( ph -- )
  fd-over @ if drop exit then
  40 froom? 0= if -1 fd-over ! drop exit then      \ token + a name + END_NODE
  1 fd-nodes +!
  FDT_BEGIN_NODE f32!
  dup parent 0= if 0 0 else dup pnodename then      \ the root's name is ""
  fstr0 fpad                                        ( ph )
  >r  0 0                                           ( prev$ ) ( r: ph )
  begin r@ next-property while  2dup r@ -rot fprop  repeat
  r> child                                          ( child | 0 )
  begin dup while  dup recurse  peer  repeat  drop
  FDT_END_NODE f32! ;

\ ── the whole thing: ( buf -- len ), 0 on refusal ───────────────────────────
: dt>fdt ( buf -- len )
  dup fd-buf !  0 fd-nodes ! 0 fd-props ! 0 fd-over !
  dup /fdt-hdr + /fdt-rsv 0 fill                    \ rsvmap: {0,0}
  dup /fdt-hdr + /fdt-rsv + fd-cur !
  dup fdt-struct-max + dup fd-str ! fd-str0 !
  " /" find-package 0= if drop 0 exit then  fnode
  fd-over @ if ." fdt| OVERFLOW, refused" cr drop 0 exit then
  FDT_END f32!
  ( buf )
  fd-cur @ over -  fd-soff !                        \ off_strings: right after the struct block
  fd-str @ fd-str0 @ -  fd-ssz !                    \ size_strings
  fd-str0 @  fd-cur @  fd-ssz @  move               \ the strings move down to sit there
  dup fd-cur !                                      \ ...and the header is written last
  fdt-magic f32!
  fd-soff @ fd-ssz @ + f32!                         \ totalsize
  /fdt-hdr /fdt-rsv + f32!                          \ off_dt_struct = 0x38
  fd-soff @ f32!                                    \ off_dt_strings
  /fdt-hdr f32!                                     \ off_mem_rsvmap = 0x28
  11 f32!  10 f32!  0 f32!                          \ version 17, last_comp 16, boot_cpuid_phys
  fd-ssz @ f32!                                     \ size_dt_strings
  fd-soff @ /fdt-hdr /fdt-rsv + - f32!              \ size_dt_struct (END token included)
  drop  fd-soff @ fd-ssz @ + ;

\ what the firmware says it wrote, for the track to grade against dtc
: .fdt-counts ( len -- )
  ." FDTL=" u.  ." NODES=" fd-nodes @ u.  ." PROPS=" fd-props @ u.  cr ;
