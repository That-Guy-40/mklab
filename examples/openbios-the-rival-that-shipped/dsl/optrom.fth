\ optrom.fth — a PCI expansion ROM (option ROM) as a STRUCTURE over LIVE device
\ memory, and the FCode it carries, run from there. B.3 Spike 3's original
\ subject -- the row the plan kept as UNCOVERED because "this firmware binds no
\ config-space words" and "the only FCode ROM in the repo is attached to OFW".
\ Both blockers were measured away on 2026-09-03: OpenBIOS's own PCI allocator
\ already maps AND enables every device's expansion ROM (ob_pci_configure_bar,
\ `reg == 6`), it merely never said where -- patch 55 publishes the ROM base
\ register in `reg`/`assigned-addresses` as the 1275 PCI binding lists it -- and
\ the OFW lab's ROM is vendor/device 0xffff, "any card", so it rides an e1000
\ under this firmware just as well. Patch 56 binds config-{b,w,l}@/! so the
\ property can be checked against config space rather than trusted.
\
\ THE HEADER IS LITTLE-ENDIAN (PCI Firmware Spec 3.0, 5.1.1) and it lives at the
\ MAPPED ROM BAR, so every field here is a le-dev-field: -- read through the
\ device-register backend (rb@, bytewise) at a physical address gone through
\ >virt. That is the toolkit's device form (struct-device / the VGA track)
\ aimed at a ROM instead of a framebuffer: same layer, third space.
\
\ Load struct.fth first. Base is hex.
hex

\ ── the ROM header (at the BAR) ─────────────────────────────────────────────
struct
  2 le-dev-field: rom-sig          \ 0x55AA
  2 le-dev-field: rom-fcode-off    \ +02: an Open Firmware image's FCode OFFSET
                                   \      (an x86 image keeps its init size/512 here --
                                   \      the OFW lab's build-fcode-rom.py names the trap)
  14 dev-field:   rom-reserved     \ +04..+17, opaque (never read as a scalar)
  2 le-dev-field: rom-pcir-off     \ +18: offset of the PCI Data Structure
constant /rom-hdr

\ ── the PCI Data Structure ("PCIR") ─────────────────────────────────────────
struct
  4 dev-field:    pcir-sig         \ "PCIR" -- read big-endian it IS 50434952
  2 le-dev-field: pcir-vendor      \ ffff = any card (what the OFW lab's ROM carries)
  2 le-dev-field: pcir-device
  2 le-dev-field: pcir-vpd
  2 le-dev-field: pcir-len
  1 dev-field:    pcir-rev
  3 dev-field:    pcir-class
  2 le-dev-field: pcir-imglen      \ in 512-byte units
  2 le-dev-field: pcir-coderev
  1 dev-field:    pcir-codetype    \ 0 x86 BIOS, 1 Open Firmware FCode, 2 HP PA-RISC, 3 EFI
  1 dev-field:    pcir-indicator   \ bit 7: last image in the ROM
  2 dev-field:    pcir-reserved
constant /pcir

: .codetype ( n -- )
  dup 0 = if ." x86-bios" drop exit then
  dup 1 = if ." open-firmware" drop exit then
  dup 2 = if ." hp-pa-risc" drop exit then
  dup 3 = if ." efi" drop exit then
  ." type-" u. ;

\ ── where is it? the ACTIVE package's assigned-addresses ─────────────────────
\ Walks the 5-cell entries (phys.hi phys.mid phys.lo size.hi size.lo) for the
\ one whose register is 30 (or 38, a bridge's) -- the entry patch 55 publishes.
\ Property cells are 1275 big-endian; decode-int reads them on every arch.
\ optrom-cells keeps the WHOLE entry, because the parent bus's `pci-map-in`
\ wants all three address cells; optrom-find is the phys.lo-only form.
variable op-hi  variable op-mid  variable op-lo  variable op-size
: optrom-cells ( -- -1 | 0 )
  " assigned-addresses" active-package get-package-property if 0 exit then
  begin dup 0> while                     ( adr len )
    decode-int op-hi !                   \ phys.hi
    decode-int op-mid !  decode-int op-lo !
    decode-int drop  decode-int op-size !         \ size.hi (0), size.lo
    op-hi @ ff and  dup 30 =  swap 38 =  or if
      2drop -1 exit
    then
  repeat 2drop 0 ;
: optrom-find ( -- phys size -1 | 0 )
  optrom-cells 0= if 0 exit then  op-lo @ op-size @ -1 ;

\ ── read the header at a (virtual) address; print what it is ────────────────
\ Every refusal is named: a wrong signature, a wrong PCIR signature. A listing,
\ not a guess -- an unknown code type prints its number.
: .optrom ( adr -- )
  ." optrom| sig=" dup rom-sig t@ dup u.
  aa55 <> if ." BAD-SIG" cr drop exit then
  dup dup rom-pcir-off t@ +              ( adr pcir )
  ." pcir=" dup pcir-sig t@ dup u.
  50434952 <> if ." BAD-PCIR" cr 2drop exit then
  ." vendor=" dup pcir-vendor t@ u.
  ." device=" dup pcir-device t@ u.
  ." imglen=" dup pcir-imglen t@ 200 * u.
  ." indicator=" dup pcir-indicator t@ u.
  ." type=" dup pcir-codetype t@ dup u. dup .codetype   ( adr pcir type )
  1 = if ."  fcode@" over rom-fcode-off t@ u. then      ( adr pcir )
  cr 2drop ;

\ the FCode image inside the ROM at `adr`, or 0 when it is not an Open Firmware
\ image -- so a caller cannot byte-load x86 code by accident. ( adr -- fcode | 0 )
: optrom-fcode ( adr -- fcode | 0 )
  dup rom-sig t@ aa55 <> if drop 0 exit then
  dup dup rom-pcir-off t@ +  dup pcir-sig t@ 50434952 <> if 2drop 0 exit then
  pcir-codetype t@ 1 <> if drop 0 exit then
  dup rom-fcode-off t@ + ;

\ ── the active package's ROM: report, run ───────────────────────────────────
: optrom-report ( -- )
  optrom-find 0= if ." optrom| none" cr exit then    ( phys size )
  ." optrom| phys=" over u. ." size=" u.  >virt .optrom ;

\ ── an INSTANCE CHAIN, because a card's driver is written as if it had one ──
\ Measured 2026-09-03, and it is the second thing the plan's "UNCOVERED" row was
\ really about: byte-loading a card's FCode from the `0 >` prompt gives it NO
\ current instance, so the moment the driver says `my-space` (or anything that
\ reaches its parent, `$call-parent` included) the firmware aborts with
\ "no current instance." and byte-load catches the exception -- the node ends up
\ renamed and undecorated, which looks like a half-working driver rather than a
\ missing scaffold. A real 1275 probe evaluates FCode inside an instance (the
\ `open-dev … to my-self` dance arch/{x86,amd64}/openbios.c comments on), and
\ open-dev opens EVERY node on the path -- so the chain has to reach the root.
\
\ THE FIRST VERSION BUILT ONE LEVEL, and the 2026-09-03 audit found what that
\ costs: a card behind a PCI-PCI bridge asks the BRIDGE, the bridge chains to
\ ITS parent (patch 59), and with the bridge instance's my-parent left at 0 the
\ firmware took a general protection fault instead of answering. So this walks
\ `parent` up to the root, creates an instance for each node root-first (each
\ one's my-parent is whatever my-self is at that moment), and tears them down
\ card-first. create-instance builds an instance WITHOUT calling `open`.
8 constant op-max
create op-chain op-max cells allot   \ [0] the card … [n-1] the root: phandles, then ihandles
variable op-n  variable op-made  variable op-self
: optrom-instance-out ( -- )
  op-self @ to my-self
  op-n @ op-made @ -  op-n @  ?do            \ only the ones made, card side first
    i cells op-chain + @ destroy-instance
  loop  0 op-made ! ;
: optrom-instance-in ( -- ok? )
  my-self op-self !  0 op-n !  0 op-made !
  active-package
  begin dup while                            ( ph )
    op-n @ op-max = if drop false exit then  \ deeper than op-max: refuse, by name
    dup op-n @ cells op-chain + !  1 op-n +!
    parent
  repeat drop
  op-n @ 0= if false exit then               \ no active package: nothing to build
  0 to my-self
  0 op-n @ 1- do                             \ root first, card last
    i cells op-chain + dup @ create-instance ?dup 0= if
      drop optrom-instance-out false unloop exit
    then
    dup rot !  to my-self  1 op-made +!
  -1 +loop
  true ;

\ ── map the ROM the 1275 way: the parent bus's pci-map-in ────────────────────
\ `>virt` is this lab's own translation and it is only right where the published
\ phys.lo IS a CPU address -- true on x86/amd64, FALSE on ppc, where the entry
\ carries a PCI BUS address (measured: 800a0000) that no amount of load-base
\ arithmetic turns into something `rb@` can read. The portable answer is the one
\ the binding already specifies: hand all three address cells and the size to the
\ parent bus node's `pci-map-in` method and let IT do the translation
\ (drivers/pci.c ob_pci_map → pci_bus_addr_to_host_addr). Needs an instance, so
\ it borrows the same scaffold.
\ A bus with no pci-map-in must leave us a 0, not abort the run: catch restores
\ the depth, so the six cells (four arguments + the method string) are dropped.
\
\ MAP-IN IS HALF OF A PAIR, and the first version of this file did not know it.
\ On ppc, ob_pci_map() CLAIMS the physical and virtual ranges through ofmem
\ before mapping, so a second map-in of the same region fails its claim and
\ answers -1 -- which was written up here as "call-once-and-keep, not a getter".
\ It was a leak with a nicer name: this firmware bound no `pci-map-out` at all.
\ Patch 60 binds it, and `optrom-unmap` below is its caller; a mapping taken
\ with optrom-map is released with optrom-unmap, and the ppc row of the track
\ measures both directions (a map after a release works; two maps with no
\ release in between leave the second at ffffffff).
: optrom-map ( -- virt | 0 )
  optrom-cells 0= if 0 exit then
  optrom-instance-in 0= if 0 exit then
  op-lo @ op-mid @ op-hi @ op-size @
  " pci-map-in" ['] $call-parent catch if 2drop 2drop 2drop 0 then
  optrom-instance-out ;

\ optrom-unmap ( virt -- )  give a mapping back through the parent's pci-map-out
\ (the size is the one optrom-cells found -- the same call must have preceded).
: optrom-unmap ( virt -- )
  optrom-instance-in 0= if drop exit then
  op-size @  " pci-map-out" ['] $call-parent catch if 2drop 2drop then
  optrom-instance-out ;

\ RUN IT: byte-load the FCode straight out of the live ROM into the ACTIVE
\ package -- what a 1275 probe does for every card it finds, so the card's own
\ program names the node and decorates it. Refuses a non-FCode image by name.
\ Runs INSIDE an instance (see above), so a driver that reads its own config
\ space through `my-space " config-l@" $call-parent` works here exactly as it
\ would under a probe.
: optrom-run ( -- )
  optrom-find 0= if ." optrom| none, not run" cr exit then  drop >virt
  optrom-fcode dup 0= if ." optrom| NOT-FCODE, not run" cr drop exit then
  ." optrom| byte-load fcode@" dup u. cr
  optrom-instance-in 0= if ." optrom| NO-INSTANCE" cr drop exit then
  1 byte-load
  optrom-instance-out ;

\ …and the same, from wherever the parent bus says the ROM is mapped: map-in,
\ byte-load, map-out -- the binding's own shape. The ppc row of the `optrom`
\ track runs it AFTER a map/unmap pair, so it doubles as the proof that a
\ release lets the region be mapped again. Every exit path gives the mapping
\ back. (Until the 2026-09-03 audit this word existed, unmapped nothing, and
\ was called by nothing while claiming the track checked it.)
: optrom-run-mapped ( -- )
  optrom-map dup 0= if ." optrom| NO-MAP" cr drop exit then        ( virt )
  dup optrom-fcode dup 0= if
    ." optrom| NOT-FCODE, not run" cr drop optrom-unmap exit then  ( virt fcode )
  ." optrom| byte-load fcode@" dup u. cr
  optrom-instance-in 0= if ." optrom| NO-INSTANCE" cr drop optrom-unmap exit then
  1 byte-load
  optrom-instance-out
  optrom-unmap ;

\ ── the same facts from CONFIG SPACE (patch 56), not from a property ─────────
\ A property is a record the enumerator wrote once; config space is the device
\ now. The config-addr is the first cell of the package's own reg property
\ (bus<<16 | dev<<11 | fn<<8), the form config-{b,w,l}@ take.
: my-config-addr ( -- ca )
  " reg" active-package get-package-property if 0 exit then
  decode-int nip nip ;
: optrom-cfg ( -- )
  my-config-addr
  ." cfg| id=" dup config-l@ u.           \ device<<16 | vendor
  ." rom=" 30 or config-l@ u. cr ;        \ the ROM base register, ENABLE bit included

\ flip the ROM's decode ENABLE bit through config-l! and watch the header
\ appear/vanish at the same address: a config-space WRITE with a device effect.
: optrom-disable ( -- )  my-config-addr 30 or  dup config-l@ 1 invert and  swap config-l! ;
: optrom-enable  ( -- )  my-config-addr 30 or  dup config-l@ 1 or          swap config-l! ;
: optrom-sig ( -- )
  optrom-find 0= if ." sig=none" cr exit then
  drop >virt rom-sig t@ ." sig=" u. cr ;

\ the outcome of a byte-load, read back from the tree: the card's own marker
: .fcode-marker ( -- )
  ." MARK=" " fcode-marker" active-package get-package-property
  if ." none" else type then cr ;

\ …and the config-space card's answer to "who am I?" — an integer property the
\ driver computed from its OWN config space. SHORT WORDS ON PURPOSE: the console
\ line editor truncates past ~80 columns, so the query cannot be typed inline.
: .cfg-id ( -- )
  ." CFGID=" " cfg-id" active-package get-package-property
  if ." none" else decode-int nip nip u. then cr ;

\ what my-space will answer for this node: the node's probe-addr, which patch 57
\ fills. 0 here means a card driver would read bus 0, device 0 -- the host bridge.
: .probe-addr ( -- )  ." PA=" active-package >dn.probe-addr @ u. cr ;
