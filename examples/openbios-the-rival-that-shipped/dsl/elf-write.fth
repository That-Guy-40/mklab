\ elf-write.fth -- author a minimal, RUNNABLE ELF64 in Forth, then persist it.
\
\ THE WRITER HALF of this lab's poke story. dsl/struct.fth + dsl/elf.fth READ and
\ inspect an ELF; this file BUILDS one, byte by byte, the way ELFkickers' teensy-
\ ELF essays do (oracle/elfkickers/), and hands it to `write-file` -- the hosted-
\ firmware primitive (arch/unix/unix.c) that lets a structure the Forth assembled
\ OUTLIVE the process as a real host file. REVIEW-preboot-forth-as-a-poke-engine
\ .md G6 named the gap this closes: "the reader is still ahead of the writer."
\
\ THE SUBJECT is a 132-byte static x86-64 executable whose only act is exit(code).
\ It is the smallest thing that can be GRADED BY RUNNING IT: the host chmod+x's
\ the file the firmware wrote and the kernel's exit status must equal the value
\ authored into the `mov edi, imm32` below -- a file that runs is not a file the
\ firmware merely CLAIMS it wrote (CLAUDE.md, "assert the outcome, not the
\ mechanism"). The layout: 0x40 ELF64 header + 0x38 program header + 0x0c code.
\
\ UNIX TARGET ONLY. write-file exists only where there is a host filesystem
\ (bind in arch/unix's arch_init, not the common init.c). And every line here is
\ <= 80 columns on purpose: the unix target reads Forth from stdin through an
\ 80-column line editor that truncates past ~82 -- which is why the 133-col
\ elf.fth is staged via ISO on the QEMU targets and cannot be piped in here.
\
\ Base is HEX throughout.
hex

\ little-endian emitters: append the low N bytes of x at HERE, low byte first.
: le8  ( x -- )  ff and c, ;
: le16 ( x -- )  dup le8  8 rshift le8 ;
: le32 ( x -- )  dup le16 10 rshift le16 ;
: le64 ( x -- )  dup le32 20 rshift le32 ;

variable elf-start

\ author-exit-elf ( code -- adr len )
\ Lay the whole image at HERE and return its start and length. `code` sits at
\ the bottom of the stack throughout: each `N le8` pushes then consumes N, so
\ the net stack effect of the header is zero and `code` is still there for the
\ instruction bytes at the end.
: author-exit-elf ( code -- adr len )
  here elf-start !
  \ -- ELF64 header, 0x40 bytes --
  7f le8  45 le8  4c le8  46 le8    \ e_ident magic: 7f 'E' 'L' 'F'
  2 le8   1 le8   1 le8   0 le8     \ class=ELF64  data=LE  ver=1  osabi=SYSV
  0 le64                            \ e_ident padding (8 bytes)
  2 le16  3e le16  1 le32           \ e_type=ET_EXEC  e_machine=X86_64  e_version
  400078 le64                       \ e_entry -- code sits at vaddr 0x400078
  40 le64  0 le64  0 le32           \ e_phoff=0x40  e_shoff=0  e_flags=0
  40 le16  38 le16  1 le16          \ e_ehsize=0x40 e_phentsize=0x38 e_phnum=1
  0 le16  0 le16  0 le16            \ e_shentsize=0  e_shnum=0  e_shstrndx=0
  \ -- program header, 0x38 bytes, one PT_LOAD covering the whole file --
  1 le32  5 le32                    \ p_type=PT_LOAD  p_flags=R+X
  0 le64  400000 le64  400000 le64  \ p_offset=0  p_vaddr  p_paddr = 0x400000
  84 le64  84 le64  1000 le64       \ p_filesz=0x84 p_memsz=0x84 p_align=0x1000
  \ -- code, 0x0c bytes: mov edi,code ; mov eax,60 ; syscall --
  bf le8  dup le32                  \ mov edi, imm32  <- the authored exit code
  b8 le8  3c le8  0 le8  0 le8  0 le8   \ mov eax, 0x3c (60 = __NR_exit)
  0f le8  05 le8                    \ syscall
  drop                              \ done with `code`
  elf-start @  here elf-start @ -   \ ( adr len )
;

\ save-exit-elf ( code fname-adr fname-len -- actual-len )
\ Author the exit(code) ELF and persist it. actual-len should equal 0x84 (132).
: save-exit-elf ( code fname-adr fname-len -- actual-len )
  2>r                 \ R: fname-adr fname-len
  author-exit-elf     \ ( adr len ), consuming code
  2r>                 \ ( adr len fname-adr fname-len )
  write-file
;
