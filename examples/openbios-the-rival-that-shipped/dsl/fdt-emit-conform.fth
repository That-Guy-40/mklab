\ fdt-emit-conform.fth — fdt.fth's opt-in to the contract's NAME-emit (v1).
\
\ A SIDECAR. Load struct.fth + fdt.fth FIRST, then this. See dsl/CONTRACT.md. Hex.
\
\ fdt-emit is the contract's NAME-emit for fdt: AUTHOR a whole flattened device tree
\ into `buf` by walking the LIVE tree (fdt.fth's dt>fdt) and return ( adr len ) — or
\ ( adr 0 ) if the walk refused (OVERFLOW). Graded on a ROUND TRIP (the emitted DTB
\ satisfies fdt-validate); the STRONG grade — dtc/fdtdump accept it — is the fdt track.
hex

: fdt-emit ( buf -- adr len )  dup dt>fdt ;
