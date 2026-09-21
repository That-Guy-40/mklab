\ pe-write-conform.fth — pe.fth's WRITER half opting into the contract (v1).
\
\ A SIDECAR. Load struct.fth + contract.fth + pe.fth + pe-conform.fth + pe-edit.fth
\ FIRST, then this. See dsl/CONTRACT.md "Optional extensions". Hex.
\
\ pe-write is the contract's NAME-write for pe: an IN-PLACE section edit — a DELTA,
\ not a whole re-author. It is pe-edit.fth's pe-section-set under the contract name;
\ that word already refuses BY NAME before any byte moves (edit| NOT-PE / NO-SECTION
\ / OOB / TOO-BIG) and writes NOTHING on refusal, which is exactly the writer-half
\ invariant roadmap Tier 2 is about ("refuse before the irreversible step"). The
\ edit is graded on the DELTA (the named section changed, a neighbour did not) by
\ tests/test-contract-conformance.sh.
hex

: pe-write ( adr len sec-caddr sec-u new-adr new-len -- ok? )  pe-section-set ;
