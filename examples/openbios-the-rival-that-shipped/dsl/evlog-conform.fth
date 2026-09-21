\ evlog-conform.fth — dsl/eventlog.fth's opt-in to the conformance contract (v1).
\
\ A SIDECAR, not a merge. LOAD ORDER: struct.fth + contract.fth + sha256.fth +
\ eventlog.fth FIRST, then this. eventlog.fth's evlog-replay references sha256, and
\ this Forth aborts a colon definition that names a word it cannot find — so
\ sha256.fth must precede eventlog.fth even for the reader (eventlog.fth says so).
\ See dsl/CONTRACT.md. Hex.
hex

\ evlog-validate ( handle -- c-addr u )  the format invariant: a crypto-agile TCG
\ log opens with a TCG_EfiSpecIdEvent whose 16-byte signature is "Spec ID Event03\0"
\ — at offset 0x20 (pcrIndex:4 + eventType:4 + legacy digest:20 + eventSize:4). That
\ signature IS the magic; eventlog.fth already carries the bytes as `ev-sig`.
: evlog-validate ( handle -- c-addr u )
  20 + 10  ev-sig 10  $= if 0 0
  else s" evlog: not a crypto-agile log (missing 'Spec ID Event03' signature)" then ;

\ evlog-open ( addr len -- handle )  bind; refuse a bad signature BY NAME (return 0).
: evlog-open ( addr len -- handle )
  drop dup evlog-validate ?refused if .refusal drop 0 exit then 2drop ;

\ evlog-fields ( handle -- )  the FIXED prefix of a crypto-agile TCG_PCR_EVENT2
\ entry; the digest set and event payload are length-driven (walked, not fixed).
: evlog-fields ( handle -- )  drop
  s" pcrIndex"    0  4 .field3
  s" eventType"   4  4 .field3
  s" digestCount" 8  4 .field3 ;

\ evlog-manifest ( -- )  ARCH:4/4 — the log is LITTLE-endian (the deliberate
\ complement to CBFS's big-endian): the same cursor walks both, so ppc byte-swaps
\ here where it read CBFS native. The SHA-256 PCR replay (evlog-replay) proves the
\ log is internally consistent; the hardware-signed quote stays UNKNOWN, not PASS.
: evlog-manifest ( -- )
  ." reads + replays a crypto-agile TCG event log (little-endian); PCR replay proves internal consistency, the AK quote stays UNKNOWN (not PASS) "
  arch-4/4 cr ;

s" evlog" ['] evlog-manifest register-module
