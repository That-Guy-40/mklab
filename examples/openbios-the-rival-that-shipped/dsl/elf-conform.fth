\ elf-conform.fth — dsl/elf.fth's opt-in to the conformance contract (v1).
\
\ A SIDECAR, not a merge: elf.fth stays standalone-loadable (struct.fth only, and
\ the elf-methods track loads exactly that), and this file — after struct.fth +
\ contract.fth + elf.fth — adds the contract's required core. See dsl/CONTRACT.md.
\
\ THE INVARIANTS ARE NOT RE-LISTED. elf-validate runs elf.fth's OWN ?elf64 — the
\ same word the elf-methods track drives to abort with want=/got= — through the
\ struct.fth reason seam (`validate`), which turns chk's abort into a returned,
\ named reason and back again. One invariant list, two behaviours; no drift. Hex.
hex

\ elf-validate ( handle -- c-addr u )  bind the buffer, then return ?elf64's first
\ failing constraint as a NAMED reason (or 0 0 when valid). ELF64 header invariants;
\ ?phdrs (which needs a file size) stays the caller's separate call, as in elf.fth.
: elf-validate ( handle -- c-addr u )  elf-at  ['] ?elf64 validate ;

\ elf-open ( addr len -- handle )  bind; refuse a bad ELF magic BY NAME (return 0).
\ The full header invariants are elf-validate; open is the magic gate, as the
\ contract specifies. handle is the buffer base (elf.fth binds it via @elf).
: elf-open ( addr len -- handle )
  drop dup elf-at                ( addr )
  @elf e_magic t@ 464c457f <> if
    drop ." REFUSED: elf: bad ELF magic (want 7f 'E' 'L' 'F')" cr 0 exit
  then ;                         ( addr )

\ elf-fields ( handle -- )  the ELF64 header, each field's offset/width read from
\ its OWN struct.fth type-id (' name >body), never restated here.
: elf-fields ( handle -- )  drop
  s" e_magic"    ['] e_magic    >body .field
  s" e_class"    ['] e_class    >body .field
  s" e_data"     ['] e_data     >body .field
  s" e_type"     ['] e_type     >body .field
  s" e_machine"  ['] e_machine  >body .field
  s" e_entry"    ['] e_entry-lo >body .field
  s" e_phoff"    ['] e_phoff-lo >body .field
  s" e_shoff"    ['] e_shoff-lo >body .field
  s" e_ehsize"   ['] e_ehsize   >body .field
  s" e_phnum"    ['] e_phnum    >body .field
  s" e_shnum"    ['] e_shnum    >body .field
  s" e_shstrndx" ['] e_shstrndx >body .field ;

\ elf-manifest ( -- )  ARCH:4/4 — byte order is declared PER FIELD (le-field:), so
\ the reader is correct on all four arches for a little-endian ELF64; a big-endian
\ one it refuses by name rather than misread (elf.fth's E2 limit). NOT ELF32 unless
\ dsl/elf32.fth is also loaded (elf.fth's `hook` names it absent).
: elf-manifest ( -- )
  ." reads ELF64 (header/phdrs/sections + load-base/vaddr>off); NOT ELF32 unless dsl/elf32.fth loaded; NOT big-endian (refused by name) "
  arch-4/4 cr ;

s" elf" ['] elf-manifest register-module
