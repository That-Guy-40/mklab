\ eventlog.fth — a TCG PC Client crypto-agile measured-boot event log reader/author
\ in OpenBIOS Forth (B.3 Spike 1a — the STRUCTURE, no crypto yet).
\
\ ALL LITTLE-ENDIAN — the deliberate complement to CBFS's big-endian (cbfs.fth): the
\ same Spike-0 cursor walks both, so ppc byte-swaps HERE (through le-l@) while it read
\ CBFS native, and the LE arches read this native. One reader, opposite byte orders,
\ the arch matrix earning its keep from the other side.
\
\ Layout (TCG PC Client Platform Firmware Profile), a `binary_bios_measurements`:
\   HEADER  = one legacy TCG_PCR_EVENT carrying a TCG_EfiSpecIdEvent that DECLARES
\             the digest algorithms in use:
\               pcrIndex:u32, eventType:u32(=EV_NO_ACTION 3), digest[20], eventSize:u32,
\               event = { "Spec ID Event03\0"(16), platformClass:u32, verMinor:u8,
\                         verMajor:u8, errata:u8, uintnSize:u8, numberOfAlgorithms:u32,
\                         [algorithmId:u16, digestSize:u16]×n, vendorInfoSize:u8, vendorInfo }
\   ENTRIES = TCG_PCR_EVENT2, crypto-agile:
\               pcrIndex:u32, eventType:u32,
\               digests = { count:u32, [algorithmId:u16, digest[size(algId)]]×count },
\               eventSize:u32, event[eventSize]
\
\ There is no entry count: a walk runs until it reaches the end of the log buffer.
\ Load struct.fth FIRST, then this.
hex

4 1 0 type: u32le                 \ 4-byte LITTLE-endian (order 1 = LE)
2 1 0 type: u16le                 \ 2-byte LITTLE-endian

\ digest size for a TPM2 algorithm id (crypto-agile). The sizes are what let the
\ walk SKIP a digest of an algorithm it does not otherwise care about; an unknown
\ id returns -1 so the caller stops rather than desyncing every later entry on a
\ guessed width.
: alg-digest-size ( algid -- n )
  dup 04 = if drop 14 exit then   \ TPM_ALG_SHA1   = 20
  dup 0b = if drop 20 exit then   \ TPM_ALG_SHA256 = 32
  dup 0c = if drop 30 exit then   \ TPM_ALG_SHA384 = 48
  dup 0d = if drop 40 exit then   \ TPM_ALG_SHA512 = 64
  drop -1 ;

\ a small event-type registry (the context-keyed name table the poke-elf note
\ flagged). Unknown types print their hex — a listing, not a guess.
: .ev-type ( type -- )
  dup 00 = if ." prebootcert" drop exit then
  dup 01 = if ." post-code  " drop exit then
  dup 03 = if ." no-action  " drop exit then
  dup 04 = if ." separator  " drop exit then
  dup 05 = if ." action     " drop exit then
  dup 06 = if ." event-tag  " drop exit then
  dup 07 = if ." crtm-contnt" drop exit then
  dup 08 = if ." crtm-versn " drop exit then
  dup 0a = if ." ipl        " drop exit then
  dup 80000001 = if ." efi-var-drv" drop exit then
  dup 80000002 = if ." efi-var-cfg" drop exit then
  dup 80000007 = if ." efi-action " drop exit then
  dup 8000000a = if ." efi-pfw-blb" drop exit then
  dup 80000006 = if ." efi-bootsvc" drop exit then
  ." ev-" u. ;

\ ── the header: skip it, returning the address of the first TCG_PCR_EVENT2 ──
\ The header's digest field is a FIXED 20 bytes (legacy SHA1 slot), regardless of
\ the crypto-agile algorithms it goes on to declare — a detail worth stating,
\ because reading it as a crypto-agile digest set is the obvious wrong turn.
: evlog-skip-header ( adr -- first-event2 )
  >rec
  u32le t@+ drop                  \ pcrIndex (0)
  u32le t@+ drop                  \ eventType (EV_NO_ACTION)
  14 vbytes drop                  \ the 20-byte legacy digest slot
  u32le t@+ vbytes drop           \ eventSize, then the SpecId event body
  rec@ ;

\ ── one crypto-agile entry at the cursor: print it, advance past it ──
\ Reads the digest set by its declared algorithm ids so a multi-bank log (SHA1 +
\ SHA256, as edk2 emits) is walked correctly, not by assuming one 32-byte digest.
variable ev-pcr  variable ev-type  variable ev-size  variable ev-dcount
: .event2 ( -- )
  u32le t@+ ev-pcr !
  u32le t@+ ev-type !
  u32le t@+ ev-dcount !
  ." evt| pcr=" ev-pcr @ .
  ."  type=" ev-type @ .ev-type
  ."  digests=" ev-dcount @ .
  ev-dcount @ 0 ?do
    u16le t@+                     ( algid )
    alg-digest-size dup 0< if ." !BADALG" cr drop exit then
    vbytes drop                   \ skip this digest
  loop
  u32le t@+ ev-size !             \ eventSize
  ev-size @ vbytes drop           \ skip the event data
  ."  size=" ev-size @ . cr ;

\ ── walk the whole log from `adr`, bounded by end address `end` ──
\ Stops when the cursor reaches (or passes) end. `max` bounds it too, so a length
\ that overruns cannot loop forever reading garbage past the buffer.
: evlog-list ( adr end max -- )
  >r                              ( adr end ) ( r: max )
  swap evlog-skip-header          ( end first )  \ cursor now at first event2, rec set
  >rec                            ( end )
  r>                              ( end max )
  begin
    over rec@ >  over 0>  and     ( end max flag )   \ cursor<end AND max>0
  while
    .event2
    1-                            ( end max-1 )
  repeat
  2drop ." EVLOG-END" cr ;

\ ── authoring (Spike 1a WRITE direction — structure, not crypto) ──────────────
\ The firmware composes a whole crypto-agile log through the SAME cursor the reader
\ was graded on (every multi-byte field a LITTLE-endian store, u32le/u16le t!+),
\ then write-file persists it and coreboot's neighbour — no, TPM's tool — reads it:
\ tpm2_eventlog is the foreign oracle. For 1a the digests are placeholder fills (a
\ constant byte per entry): tpm2_eventlog validates STRUCTURE, and 1b replaces the
\ fills with a real SHA-256 chain for the replay. Load-bearing point: a log the
\ firmware authors must parse under tpm2_eventlog exactly as edk2's own would.
: c!+   ( b -- )       rec@ c!  1 +rec ;
: >w32  ( u -- )       u32le t!+ ;
: >w16  ( u -- )       u16le t!+ ;
: >wfill ( byte n -- ) dup >r  rec@ swap rot fill  r> +rec ;   \ n bytes of `byte`
: >wbytes ( src n -- ) dup >r  rec@ swap move      r> +rec ;   \ copy n bytes in

\ "Spec ID Event03\0" — 16 bytes, the crypto-agile log's required signature.
create ev-sig  53 c, 70 c, 65 c, 63 c, 20 c, 49 c, 44 c, 20 c,
               45 c, 76 c, 65 c, 6e c, 74 c, 30 c, 33 c, 00 c,

\ author the header at the cursor: one EV_NO_ACTION carrying a TCG_EfiSpecIdEvent
\ that declares SHA-256 (algId 0x0b, digestSize 0x20). eventSize of the body is
\ 16 + 4 + 4 + 4 + 4 + 1 = 0x21 (sig, platformClass, ver4, numAlg, one (alg,size),
\ vendorInfoSize), exactly what tpm2_eventlog reads back as EventSize 33.
: >evlog-header ( -- )
  0 >w32  3 >w32                  \ pcrIndex 0, EV_NO_ACTION
  0 14 >wfill                     \ 20-byte legacy digest, zeroed
  21 >w32                         \ eventSize (0x21)
  ev-sig 10 >wbytes               \ signature
  0 >w32                          \ platformClass
  0 c!+ 2 c!+ 0 c!+ 8 c!+         \ verMinor, verMajor, errata, uintnSize
  1 >w32                          \ numberOfAlgorithms
  0b >w16  20 >w16                \ (sha256, 32)
  0 c!+ ;                         \ vendorInfoSize = 0

\ address of the LAST-authored entry's eventSize field — so a test can re-store it
\ big-endian and prove tpm2_eventlog rejects the byte-order slip (the negative
\ control the little-endian format demands; a value tpm2_eventlog then reads as a
\ huge event that overruns the log).
variable ev-size-adr

\ author ONE crypto-agile entry: pcr, eventType, a 32-byte SHA-256 digest filled
\ with `dbyte`, and a 4-byte event payload `ev`. ( pcr type dbyte ev -- )
: >evlog-entry ( pcr type dbyte ev -- )
  >r >r                           ( pcr type ) ( r: ev dbyte )
  swap >w32 >w32                  \ pcrIndex, eventType   (swap: type under pcr)
  1 >w32                          \ digest count = 1
  0b >w16  r> 20 >wfill           \ (sha256, 32×dbyte)
  rec@ ev-size-adr !              \ remember where eventSize goes
  4 >w32  r> >w32 ;               \ eventSize 4, then the event payload

\ author a minimal 3-entry log into `buf`; return its byte length. The digests are
\ distinct constant fills so 1b's replay (and its flip-one-byte negative control)
\ has something to bite on. ( buf -- len )
: evlog-author ( buf -- len )
  dup >rec
  >evlog-header
  0 08 11 deadbeef >evlog-entry   \ pcr0 EV_S_CRTM_VERSION, digest 0x11
  0 01 22 cafebabe >evlog-entry   \ pcr0 EV_POST_CODE,      digest 0x22
  1 04 33 00000000 >evlog-entry   \ pcr1 EV_SEPARATOR,      digest 0x33
  rec@ swap - ;
