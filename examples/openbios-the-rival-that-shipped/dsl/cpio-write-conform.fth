\ cpio-write-conform.fth — cpio.fth's WRITER half opting into the contract (v1).
\
\ A SIDECAR. Load struct.fth + contract.fth + cpio.fth + cpio-conform.fth +
\ cpio-edit.fth FIRST, then this. See dsl/CONTRACT.md. Hex.
\
\ cpio-write is the contract's NAME-write for cpio: a SAME-LENGTH in-place edit of
\ one member's bytes (cpio-edit.fth's cpio-patch), refusing BY NAME before any byte
\ moves (cpio| NO-MEMBER / LEN-CHANGE — a length change is a rebuild, not an
\ in-place edit) and writing NOTHING on refusal. Graded on the DELTA (the named
\ member changed, a sibling did not) by tests/test-contract-conformance.sh.
hex

: cpio-write ( adr len max caddr u new-adr new-len -- ok? )  cpio-patch ;
