\ evlog-emit-conform.fth — eventlog.fth's opt-in to the contract's NAME-emit (v1).
\
\ A SIDECAR. Load struct.fth + sha256.fth + eventlog.fth FIRST, then this. See
\ dsl/CONTRACT.md. Hex.
\
\ evlog-emit is the contract's NAME-emit for evlog: AUTHOR a whole crypto-agile TCG
\ log into `buf` (eventlog.fth's evlog-author) and return ( adr len ). Graded on a
\ ROUND TRIP (the emitted log satisfies evlog-validate); the STRONG grade — the TPM
\ community's own tpm2_eventlog reads it back — is the event-log smoke track.
hex

: evlog-emit ( buf -- adr len )  dup evlog-author ;
