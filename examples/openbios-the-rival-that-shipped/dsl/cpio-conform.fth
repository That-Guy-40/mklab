\ cpio-conform.fth — dsl/cpio.fth's opt-in to the conformance contract (v1).
\
\ A SIDECAR, not a merge. Load struct.fth + contract.fth + cpio.fth FIRST, then
\ this. See dsl/CONTRACT.md. Hex.
hex

\ cpio-validate ( handle -- c-addr u )  the format invariant: a newc archive opens
\ on the ASCII magic "070701". newc? is a byte compare (endian-free), so this reads
\ identically on all four arches — the reason cpio's ppc row is not a swap.
: cpio-validate ( handle -- c-addr u )
  newc? if 0 0 else s" cpio: no newc magic (070701) at start" then ;

\ cpio-open ( addr len -- handle )  bind; refuse a bad magic BY NAME (return 0).
: cpio-open ( addr len -- handle )
  drop dup cpio-validate ?refused if .refusal drop 0 exit then 2drop ;

\ cpio-fields ( handle -- )  the fixed 110-byte newc header; ASCII-hex fields, so
\ the width column is 8 CHARACTERS (not bytes of an integer). Cursor mode, so the
\ layout is stated here.
: cpio-fields ( handle -- )  drop
  s" c_magic"    0  6 .field3
  s" c_ino"      6  8 .field3
  s" c_mode"     e  8 .field3
  s" c_nlink"   26  8 .field3
  s" c_filesize" 36 8 .field3
  s" c_namesize" 5e 8 .field3 ;

\ cpio-manifest ( -- )  ARCH:4/4 — a newc field is ASCII-HEX, so there is no byte
\ order to get wrong; ppc reads the same values as x86, not a swap of them.
: cpio-manifest ( -- )
  ." reads a newc cpio archive (ASCII-hex fields — no byte order to get wrong); refuses BAD-MAGIC/TRUNCATED/NO-TRAILER by name "
  arch-4/4 cr ;

s" cpio" ['] cpio-manifest register-module
