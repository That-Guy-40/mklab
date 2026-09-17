\ bootparams.fth — an x86 boot-protocol (boot_params / "zero page") reader on
\ dsl/struct.fth's types (roadmap Tier 1).
\
\ A Linux x86 kernel image (bzImage) begins with the real-mode "zero page":
\ struct boot_params, whose setup_header sits at offset 0x1f1. It is what a boot
\ loader fills in and reads — the handoff the whole family is about, in its most
\ concrete x86 form. Two fixed anchors say "this is a Linux kernel":
\   boot_flag  (u16 @ 0x1fe) == 0xAA55   — the boot-sector signature
\   header     (u32 @ 0x202) == "HdrS"   — 0x53726448, the setup-header magic
\ and a great deal a loader needs: the protocol version, where the 32-bit entry
\ is (code32_start), the ramdisk window, the command-line pointer, the alignment
\ and run-time size, and a pointer to a human-readable version string.
\
\ THE POINT OF THIS READER, and why its ppc row is not decoration: EVERY field
\ here is LITTLE-ENDIAN, on every target — the x86 boot protocol is defined that
\ way. So — exactly unlike cpio.fth's ASCII-hex, which has no byte order at all —
\ there IS a byte order to get wrong here, and getting it wrong is invisible on a
\ little-endian CPU. Read through struct.fth's le-field: (never a native `l@`),
\ the "HdrS" magic is 0x53726448 on all four arches; a native read on ppc would
\ give 0x48647253 and only the big-endian row would catch it. The four-arch
\ matrix grades that ppc reads the SAME header as x86, byte for byte.
\
\ The version STRING is the strongest grade: kernel_version (u16 @ 0x20e) is a
\ pointer — the offset, less 0x200, of a NUL-terminated version string inside the
\ setup. `bp-verstr` follows it and reads the text, which `file`(1) extracts
\ independently by the same protocol; two decoders, one pointer, one string.
\
\ Refusals are BY NAME, like cpio.fth's / pe.fth's — a non-kernel is REFUSED,
\ never read wrong and reported as a kernel:
\   bp| BAD-BOOTFLAG   no 0xAA55 at 0x1fe
\   bp| BAD-HDRS       no "HdrS" at 0x202
\   bp| TRUNCATED      the buffer does not hold the setup header
\
\ Load struct.fth first, then this.
hex

\ ── the setup_header fields, at ABSOLUTE boot_params offsets, all little-endian ─
\ `<off> <width> le-field: NAME drop` — le-field: bakes the offset/width/LE into
\ the tid and returns the running offset, which we drop: these are absolute, not
\ threaded, because the setup header is a fixed map at fixed offsets. None is
\ wider than 4 bytes (the u64 fields — setup_data, pref_address — are skipped: an
\ 8-byte field would abort on the 32-bit x86/ppc cell by struct.fth's design, and
\ nothing here needs them).
1f1 1 le-field: bp-setup-sects  drop   \ u8   number of 512-byte setup sectors
1f4 4 le-field: bp-syssize      drop   \ u32  size of the 32-bit code, in paras
1fe 2 le-field: bp-boot-flag    drop   \ u16  0xAA55                    ← anchor
202 4 le-field: bp-header       drop   \ u32  "HdrS" = 0x53726448       ← anchor
206 2 le-field: bp-version      drop   \ u16  boot protocol version (e.g. 0x020f)
20e 2 le-field: bp-kver-off     drop   \ u16  version-string pointer, less 0x200
210 1 le-field: bp-loader-type  drop   \ u8   type_of_loader
211 1 le-field: bp-loadflags    drop   \ u8   loadflags
214 4 le-field: bp-code32       drop   \ u32  code32_start (32-bit entry)
218 4 le-field: bp-rd-image     drop   \ u32  ramdisk_image
21c 4 le-field: bp-rd-size      drop   \ u32  ramdisk_size
228 4 le-field: bp-cmdline-ptr  drop   \ u32  cmd_line_ptr
230 4 le-field: bp-kern-align   drop   \ u32  kernel_alignment
260 4 le-field: bp-init-size    drop   \ u32  init_size (run-time memory needed)

\ ── header state, set by bp-open ─────────────────────────────────────
variable bp-img            \ image base — boot_params begins here (file offset 0)
variable bp-end            \ image base + length

\ bp-open ( adr len -- status )  0 ok / 1 BAD-BOOTFLAG / 2 BAD-HDRS / 3 TRUNCATED
\ Bounds-check the setup header, then validate the two anchors. The window must
\ reach init_size (0x260..0x263), the last field this reader touches.
: bp-open ( adr len -- status )
  over bp-img !  over + bp-end !            ( adr )
  dup 264 + bp-end @ u> if drop 3 exit then
  dup bp-boot-flag t@ aa55     <> if drop 1 exit then
  dup bp-header    t@ 53726448 <> if drop 2 exit then
  drop 0 ;

\ ── the version string: follow kernel_version ────────────────────────
\ The string lives at bp-img + 0x200 + kernel_version; a zero pointer means the
\ image carries no version string (return 0 0, so `type` prints nothing).
: bp-verstr ( -- adr len | 0 0 )
  bp-img @ dup bp-kver-off t@        ( base off )
  dup 0= if drop drop 0 0 exit then
  200 + +  cstr ;

\ ── bootparams ( adr len -- ok? ) ─────────────────────────────────────
\ Validate the anchors, then print the fields a loader reads and the version
\ string. Refuses BY NAME and answers false on a non-kernel or a short buffer.
\ `?bootparams` is the same test as a spoken predicate for callers that only want
\ the yes/no (the UKI workbench's Spike 2 grades a `.linux` section with it).
: bootparams ( adr len -- ok? )
  bp-open
  dup 1 = if drop ." bp| BAD-BOOTFLAG" cr false exit then
  dup 2 = if drop ." bp| BAD-HDRS"     cr false exit then
  dup 3 = if drop ." bp| TRUNCATED"    cr false exit then
  drop
  bp-img @                              ( base )
  ." bp| hdrs="     dup bp-header    t@ .hx8
  ."  bootflag="    dup bp-boot-flag t@ .hx8
  ."  version="     dup bp-version   t@ .hx8  cr
  ." bp| setup_sects=" dup bp-setup-sects t@ .hx8
  ."  syssize="        dup bp-syssize      t@ .hx8
  ."  code32="         dup bp-code32       t@ .hx8  cr
  ." bp| loader="   dup bp-loader-type t@ .hx8
  ."  loadflags="   dup bp-loadflags   t@ .hx8
  ."  kern_align="  dup bp-kern-align  t@ .hx8  cr
  ." bp| rd_image=" dup bp-rd-image    t@ .hx8
  ."  rd_size="     dup bp-rd-size     t@ .hx8
  ."  cmdline_ptr=" dup bp-cmdline-ptr t@ .hx8
  ."  init_size="   dup bp-init-size   t@ .hx8  cr
  drop                                  ( )  \ done with base
  cr ." bp| version-string=" bp-verstr type cr
  ." BP-END" cr true ;

\ ?bootparams ( adr len -- flag ) — the predicate alone, no printing (bp-open's
\ ok status), for a caller grading a blob as an x86 kernel.
: ?bootparams ( adr len -- flag )  bp-open 0= ;
