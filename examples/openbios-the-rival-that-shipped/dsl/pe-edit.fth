\ pe-edit.fth — in-place editing of a PE section, on dsl/pe.fth (UKI Spike 6).
\
\ The rescue arc's smallest real proof: the readers FIND a boot artifact's parts;
\ this MUTATES one, in place, at the OpenBIOS prompt. `cmdline-set` rewrites a
\ UKI's `.cmdline` (add `init=/bin/bash`, `rd.break`, `single`) without a USB
\ stick or a chroot. It is ASSEMBLY, not new machinery: the section is located by
\ pe.fth's own `pe-find-entry`/`pe-entry-of` (Spike 2's lesson), the bytes are
\ read/written with `struct.fth`'s typed field words, and the refusals read like
\ the readers' — a mutator in the same voice as the family.
\
\ SECURITY — the write is bounded on BOTH ends before a byte moves:
\   • sec-in-image? (in pe.fth) refuses a section whose raw data runs past the
\     loaded image, so a malformed PE cannot steer the write out of bounds;
\   • the capacity check refuses new content larger than SizeOfRawData, so the
\     write cannot spill into the next section.
\ On ANY refusal it writes NOTHING (refused before the move — never a partial),
\ and it names the reason, like pe-walk / cpio-walk / bootparams:
\   edit| NOT-PE       the image did not parse as a PE
\   edit| NO-SECTION   the named section is absent
\   edit| OOB          the section's raw data lies outside the loaded image
\   edit| TOO-BIG      the new content exceeds SizeOfRawData
\
\ CORRECT UNDER BOTH LOADER READINGS, and it clears stale bytes. A grown command
\ line (e.g. 24 → 32 within the section's 512-byte slack) is honored whether a
\ consumer reads to the section's VirtualSize OR to the first NUL: the edit sets
\ VirtualSize to the new length AND NUL-pads the rest of the capacity — the pad
\ also erases the old command line, so no stale tail leaks. Which the systemd stub
\ reads (Spike 6's UNKNOWN) therefore does not block a correct edit; the OVMF boot
\ (Spike 3) settles that question, not this word.
\
\ WHY THE FOUR-ARCH MATRIX STILL BITES though the byte copy is order-free: two
\ steps are little-endian and pe.fth/struct.fth do them explicitly — LOCATING the
\ section (the LE section-table walk) and WRITING VirtualSize (`sec-vsize t!`, an
\ le-l! through the typed field). A native store on ppc would byte-swap the length;
\ the matrix proves ppc writes the same header x86 does.
\
\ Load struct.fth, then pe.fth, then this.
hex

\ ── overwrite a section's bytes in place ─────────────────────────────
variable ss-src  variable ss-len  variable ss-entry  variable ss-data
: pe-section-set ( adr len caddr u new-adr new-len -- ok? )
  ss-len !  ss-src !                          ( adr len caddr u )
  peq-l !  peq-a !                            ( adr len )   \ the section name
  pe-open       if ." edit| NOT-PE"     cr false exit then
  pe-entry-of ?dup 0= if ." edit| NO-SECTION" cr false exit then   ( entry )
  dup sec-in-image? 0= if drop ." edit| OOB" cr false exit then
  dup sec-rawsize t@  ss-len @  u< if drop ." edit| TOO-BIG" cr false exit then
  ss-entry !
  ss-entry @ sec-rawoff t@ pe-img @ +  ss-data !            \ where the raw data lives
  ss-src @  ss-data @  ss-len @  move                        \ write the new bytes
  ss-data @ ss-len @ +                                        \ NUL-pad (and erase) the
  ss-entry @ sec-rawsize t@ ss-len @ -  0 fill                \ rest of the capacity
  ss-len @  ss-entry @ sec-vsize t!                           \ VirtualSize = new length
  true ;

\ cmdline-set ( adr len new-adr new-len -- ok? ) — the .cmdline wrapper. The
\ section name is a COMPILED string here (stable in the dictionary), so the
\ caller's own transient s" (the new command line, typed at the prompt) is the
\ only interpret-time one and survives to the move.
: cmdline-set ( adr len new-adr new-len -- ok? )
  s" .cmdline" 2swap pe-section-set ;
