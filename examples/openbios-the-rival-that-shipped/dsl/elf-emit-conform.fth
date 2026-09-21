\ elf-emit-conform.fth — elf-write.fth's opt-in to the contract's NAME-emit (v1).
\
\ A SIDECAR. Load struct.fth + elf.fth + elf-write.fth FIRST, then this. See
\ dsl/CONTRACT.md "Optional extensions". Hex.
\
\ elf-emit is the contract's NAME-emit for elf: AUTHOR a whole artifact's bytes
\ (elf-write.fth's author-exit-elf — a 132-byte static x86-64 exit(code) ELF) and
\ return ( adr len ). The conformance checker grades it on a ROUND TRIP — the emitted
\ bytes satisfy elf-validate — which catches an emit the reader cannot read; the
\ STRONG correctness grade (a foreign decoder RUNS the file) is the file-writer smoke
\ track (oracle/elfkickers), since a writer and reader wrong the same way agree.
hex

: elf-emit ( code -- adr len )  author-exit-elf ;
