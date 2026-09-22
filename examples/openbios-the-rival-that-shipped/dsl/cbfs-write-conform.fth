\ cbfs-write-conform.fth — cbfs.fth's WRITER half opting into the contract (v1).
\
\ A SIDECAR. Load struct.fth + contract.fth + cbfs.fth + cbfs-conform.fth +
\ cbfs-write.fth FIRST, then this. See dsl/CONTRACT.md "Optional extensions". Hex.
\
\ cbfs-write is the contract's NAME-write for cbfs: a SAME-LENGTH in-place overwrite
\ of a named entry's content (built on cbfs-write.fth's cbfs-find, the same walk the
\ reader was graded on), refusing BY NAME before any byte moves — cbfs| NO-ENTRY (no
\ such entry) / cbfs| LEN-CHANGE (a different length would shift every later entry, the
\ (empty) marker and the master header — a rebuild, not an in-place edit) — and writing
\ NOTHING on refusal. Same shape as cpio-write (a member) and pe-write (a section).
\ Graded on the DELTA (the named entry's content changed, a sibling's did not) by
\ tests/test-contract-conformance.sh; the STRONG grade — coreboot's own cbfstool accepts
\ the whole patched image — is the cbfs-write smoke track (a foreign oracle, never our
\ reader), since a parser and a writer wrong the same way agree.
hex

variable cbw2-src   variable cbw2-len
: cbfs-write ( rb max name-a name-l new-a new-l -- ok? )
  cbw2-len !  cbw2-src !                 ( rb max name-a name-l )
  cbfs-find                              ( cadr clen -1 | 0 0 0 )
  0= if 2drop ." cbfs| NO-ENTRY" cr false exit then           ( cadr clen )
  dup cbw2-len @ <> if 2drop ." cbfs| LEN-CHANGE" cr false exit then
  drop  cbw2-src @  swap  cbw2-len @  move  true ;            \ overwrite the content
