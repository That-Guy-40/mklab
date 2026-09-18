\ cpio-edit.fth — in-place editing of a FILE inside a cpio (UKI Spike 10).
\
\ The "deeper" rescue edit: not the command line, not the whole initrd, but a
\ CONFIG BLOB inside the initramfs — the /etc/fstab / crypttab / root= that is
\ blocking boot. cpio.fth's `cpio-find` already locates the member's bytes; this
\ overwrites them IN PLACE with a SAME-LENGTH replacement, the way pe-edit.fth's
\ pe-section-set overwrites a PE section. Same-length only: growing a member would
\ shift every later member and the trailer — that is a rebuild, not an in-place
\ edit, so a length change is refused rather than silently corrupting the archive.
\
\ SECURITY: cpio-find bounds the member's data to the archive (adr..adr+len), so
\ the write cannot leave it; and requiring new-len == the member's size means the
\ overwrite is exactly the bytes cpio-find measured — no spill. Refuses BY NAME,
\ writing NOTHING:
\   cpio| NO-MEMBER    the named file is not in the archive
\   cpio| LEN-CHANGE   the replacement is a different length (needs a rebuild)
\
\ Load struct.fth, then cpio.fth, then this.
hex

variable cpp-src  variable cpp-len
: cpio-patch ( adr len max caddr u new-adr new-len -- ok? )
  cpp-len !  cpp-src !                       ( adr len max caddr u )
  cpio-find                                  ( data-adr size | 0 0 )
  over 0= if 2drop ." cpio| NO-MEMBER"  cr false exit then   ( data size )
  dup cpp-len @ <> if 2drop ." cpio| LEN-CHANGE" cr false exit then  ( data size )
  drop                                       ( data )   \ size == cpp-len
  cpp-src @  swap  cpp-len @  move            \ overwrite the member's bytes
  true ;
