#!/usr/bin/env python3
"""build-elf-gate-fixtures.py — the subjects for smoke-openbios.sh's `elf-gate` track.

Four SYNTHETIC ELF64 files that differ from each other in nothing but their
program-header TYPE words, so a refusal can only be about ordering:

  good.elf    PT_PHDR, PT_INTERP, PT_LOAD, PT_LOAD   -- the gABI order
  badord.elf  PT_LOAD, PT_PHDR,   PT_INTERP, PT_LOAD -- PHDR (and INTERP) after a LOAD
  baddup.elf  PT_PHDR, PT_INTERP, PT_INTERP, PT_LOAD -- INTERP twice
  badint.elf  PT_PHDR, PT_LOAD,   PT_INTERP, PT_LOAD -- INTERP after a LOAD, PHDR fine

badint isolates the gABI's INTERP clause: badord moves PHDR and INTERP together,
so the firmware's refusal fires on PHDR first and the INTERP branch of ?ph-order
was never exercised by any fixture (found 2026-09-05). Measured the day it was
added: readelf is SILENT on badint (its order check names PHDR only), eu-elflint
says "No errors" (it checks no order), and the kernel's loader reads PT_INTERP
wherever it sits -- so that clause is refused on the gABI's word alone, and the
track says so per run rather than assuming it.

Every PT_LOAD fits inside the file, so ?phdrs64's EXISTING check (a segment past
EOF) is satisfied by all three: whatever it refuses, it refuses for the new
reason.  The gABI: "PT_PHDR ... may occur only once, if at all, and must
precede any loadable segment entry"; the same sentence for PT_INTERP.

Plus elf_hash: the SysV ABI symbol-hash function, transliterated from the
spec, printed for a list of names so the firmware's Forth can be graded against
it -- and, when a C toolchain is present, checked against the LINKER's own
placement: `ld --hash-style=sysv` writes a .hash section, and a symbol name is
reachable from bucket[elf_hash(name) % nbucket] only if this hash agrees with
the linker's.  That check is the oracle for the oracle.

Usage: build-elf-gate-fixtures.py <outdir> [--names NAME...] [--ladder ARCH VADDR OVL]...
Writes <outdir>/{good,badord,baddup,badint}.elf and prints "NAME HASH" lines (hex).

THE LADDER SETS (B.4 Spike 0, 2026-09-05). `--ladder ARCH VADDR OVL` writes
<outdir>/ladder-ARCH/{good,badord,baddup,badint,badtrunc,badmem,badovl,badentry}.elf
in the class, byte order and machine the named firmware door actually LOADS --
x86: ELF32 LSB EM_386; amd64: ELF64 LSB EM_X86_64; ppc: ELF32 MSB EM_PPC -- so
that `load` of the bare file reaches the C loader's gate instead of being
inspected as data. good.elf is RUNNABLE: its body is real code at e_entry (x86
and amd64 write 'R' to COM1 and `ret` onto the return address the firmware
plants; ppc is a single `blr`), placed at VADDR, which the caller chooses clear
of the firmware. Every bad file differs from good.elf in ONE clause, and the
script prints "LADDER ARCH NAME LO HI": the half-open byte range every
differing byte must fall in, for the track to check with cmp -l:

  badord    LOAD PHDR INTERP LOAD        PHDR after a LOAD          (the table)
  baddup    PHDR INTERP INTERP LOAD      INTERP twice               (the table)
  badint    PHDR LOAD INTERP LOAD        INTERP after a LOAD        (the table)
  badtrunc  LOAD#2's p_filesz/p_memsz reach past the end of the file (its phdr)
  badmem    LOAD#2's p_memsz < p_filesz                              (its phdr)
  badovl    LOAD#2 placed on OVL's page -- the firmware's own address (its phdr)
            (OVL is the firmware's ENTRY POINT; the segment keeps p_offset ==
            p_vaddr mod p_align, so no hosted tool has anything to say about it)
  badentry  e_entry outside every PT_LOAD                            (e_entry)
"""
import struct, sys, os, subprocess, tempfile, shutil

EHSZ, PHSZ = 64, 56

def elf64(types):
    """A minimal ELF64 LE: header, len(types) phdrs, and 0x100 bytes of body."""
    phoff = EHSZ
    body_off = phoff + PHSZ * len(types)
    filesz = body_off + 0x100
    e = bytearray(b'\x7fELF' + bytes([2, 1, 1, 0]) + b'\0' * 8)
    e += struct.pack('<HHIQQQIHHHHHH', 2, 0x3e, 1, 0x401000, phoff, 0,
                     0, EHSZ, PHSZ, len(types), 64, 0, 0)
    assert len(e) == EHSZ
    for i, t in enumerate(types):
        # PT_LOAD segments cover the body; PHDR points at the table; INTERP at 8 body bytes
        if t == 1:   # a LOAD covering the WHOLE file, headers included (readelf wants PHDR inside a LOAD)
            off, fsz, va = 0, filesz, 0x401000
        elif t == 6:
            off, fsz, va = phoff, PHSZ * len(types), 0x401000 + phoff
        else:
            off, fsz, va = body_off, 8, 0x401000 + body_off
        e += struct.pack('<IIQQQQQQ', t, 4, off, va, va, fsz, fsz, 0x1000)
    e += b'/bin/sh\0' + b'\0' * (0x100 - 8)
    assert len(e) == filesz
    return bytes(e)

def elf_hash(name):
    """SysV ABI, Figure 5-13, verbatim."""
    h = 0
    for c in name.encode():
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g:
            h ^= g >> 24
        h &= ~g & 0xffffffff
    return h

def linker_check(names):
    """Build a .so exporting `names`, parse its SysV .hash, and require that every
    name is reachable from the bucket elf_hash() selects.  Returns (checked, msg)."""
    cc = shutil.which('cc') or shutil.which('gcc')
    if not cc:
        return (False, 'no cc: the linker cross-check did not run')
    d = tempfile.mkdtemp()
    try:
        src = os.path.join(d, 'x.c')
        with open(src, 'w') as f:
            for n in names:
                f.write('int %s(void) { return 1; }\n' % n)
        so = os.path.join(d, 'x.so')
        r = subprocess.run([cc, '-shared', '-fPIC', '-nostdlib', '-Wl,--hash-style=sysv',
                            '-o', so, src], capture_output=True, text=True)
        if r.returncode:
            return (False, 'cc failed: ' + r.stderr.strip().splitlines()[-1][:120])
        b = open(so, 'rb').read()
        shoff, = struct.unpack_from('<Q', b, 40)
        shent, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
        secs = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shent) for i in range(shnum)]
        stroff = secs[shstrndx][4]
        def sname(s):
            o = stroff + s[0]; return b[o:b.index(b'\0', o)].decode()
        by = {sname(s): s for s in secs}
        if '.hash' not in by:
            return (False, 'the linker wrote no .hash section')
        hs = by['.hash']; dynsym = secs[hs[6]]; dynstr = secs[dynsym[6]]
        nb, nc = struct.unpack_from('<II', b, hs[4])
        buckets = struct.unpack_from('<%dI' % nb, b, hs[4] + 8)
        chains = struct.unpack_from('<%dI' % nc, b, hs[4] + 8 + 4 * nb)
        def symname(i):
            o = dynstr[4] + struct.unpack_from('<I', b, dynsym[4] + i * 24)[0]
            return b[o:b.index(b'\0', o)].decode()
        for n in names:
            i = buckets[elf_hash(n) % nb]
            while i and symname(i) != n:
                i = chains[i]
            if not i:
                return (False, 'symbol %s is NOT reachable from bucket elf_hash%%%d — this hash disagrees with the linker' % (n, nb))
        return (True, 'ld --hash-style=sysv: all %d names reachable from the bucket elf_hash() selects (nbucket=%d)' % (len(names), nb))
    finally:
        shutil.rmtree(d)


# ── the ladder sets: the class each firmware door loads, with a runnable body ──
LADDER = {
    #        e_class e_data e_machine  code at e_entry
    'x86':   (1, 1, 3,    bytes.fromhex('66baf803b052eec3')),  # mov dx,0x3f8; mov al,'R'; out dx,al; ret
    'amd64': (2, 1, 0x3e, bytes.fromhex('66baf803b052eec3')),  # the same bytes mean the same in long mode
    'ppc':   (1, 2, 20,   bytes.fromhex('4e800020')),          # blr -- lr is the return address the firmware planted
}
CODE_OFF = 0x10   # the body starts with the 8-byte INTERP string; code follows at +0x10

def ladder_image(arch, vaddr, ovl, variant):
    """One ELF of the door's own class. variant selects the single clause it breaks."""
    cls, data, machine, code = LADDER[arch]
    en = '<' if data == 1 else '>'
    ehsz, phsz = (52, 32) if cls == 1 else (64, 56)
    types = {'badord': [1, 6, 3, 1], 'baddup': [6, 3, 3, 1], 'badint': [6, 1, 3, 1]}.get(variant, [6, 3, 1, 1])
    phoff = ehsz
    body = phoff + phsz * len(types)
    filesz = body + 0x100
    entry = vaddr + body + CODE_OFF
    if variant == 'badentry':
        entry = vaddr + 0x100000          # inside no PT_LOAD
    e = bytearray(b'\x7fELF' + bytes([cls, data, 1, 0]) + b'\0' * 8)
    if cls == 1:
        e += struct.pack(en + 'HHIIIIIHHHHHH', 2, machine, 1, entry, phoff, 0, 0, ehsz, phsz, len(types), 40, 0, 0)
    else:
        e += struct.pack(en + 'HHIQQQIHHHHHH', 2, machine, 1, entry, phoff, 0, 0, ehsz, phsz, len(types), 64, 0, 0)
    assert len(e) == ehsz
    nload = 0
    for t in types:
        if t == 1:
            nload += 1
            off, fsz, msz, va = 0, filesz, filesz, vaddr
            if nload == 2:                # every one-clause segment defect lives in LOAD#2
                if variant == 'badtrunc':
                    fsz += 0x100; msz += 0x100
                elif variant == 'badmem':
                    msz = fsz - 0x10
                elif variant == 'badovl':
                    # ONE clause only: keep p_offset == p_vaddr (mod p_align), or elflint
                    # flags the alignment congruence and the fixture violates two rules
                    # (measured 2026-09-05: "file offset and virtual address not module
                    # of alignment"). The page of OVL, plus the body's offset in the
                    # file, still lands inside the firmware for any OVL past its first
                    # page -- and the caller hands us its ENTRY POINT.
                    off, fsz, msz, va = body, 8, 8, (ovl & ~0xfff) + (body & 0xfff)
        elif t == 6:
            off, fsz, msz, va = phoff, phsz * len(types), phsz * len(types), vaddr + phoff
        else:
            off, fsz, msz, va = body, 8, 8, vaddr + body
        if cls == 1:
            e += struct.pack(en + 'IIIIIIII', t, off, va, va, fsz, msz, 7, 0x1000)
        else:
            e += struct.pack(en + 'IIQQQQQQ', t, 7, off, va, va, fsz, msz, 0x1000)
    b = bytearray(b'/bin/sh\0' + b'\0' * (0x100 - 8))
    b[CODE_OFF:CODE_OFF + len(code)] = code
    e += b
    assert len(e) == filesz
    # the byte range the variant is allowed to differ from good.elf in
    if variant == 'badentry':
        lo, hi = 24, 24 + (4 if cls == 1 else 8)
    elif variant in ('badtrunc', 'badmem', 'badovl'):
        lo, hi = phoff + 3 * phsz, phoff + 4 * phsz
    else:
        lo, hi = phoff, body
    return bytes(e), lo, hi

LADDER_VARIANTS = ('good', 'badord', 'baddup', 'badint', 'badtrunc', 'badmem', 'badovl', 'badentry')

def write_ladder(out, arch, vaddr, ovl):
    d = os.path.join(out, 'ladder-' + arch)
    os.makedirs(d, exist_ok=True)
    for v in LADDER_VARIANTS:
        img, lo, hi = ladder_image(arch, vaddr, ovl, v)
        open(os.path.join(d, v + '.elf'), 'wb').write(img)
        print('LADDER %s %s %d %d' % (arch, v, lo, hi))

if __name__ == '__main__':
    out = sys.argv[1]
    argv = sys.argv[2:]
    while '--ladder' in argv:
        i = argv.index('--ladder')
        arch, vaddr, ovl = argv[i + 1], int(argv[i + 2], 0), int(argv[i + 3], 0)
        if arch not in LADDER:
            sys.exit('--ladder: unknown door %r (one of %s)' % (arch, ' '.join(LADDER)))
        write_ladder(out, arch, vaddr, ovl)
        del argv[i:i + 4]
    sys.argv[2:] = argv
    names = sys.argv[sys.argv.index('--names') + 1:] if '--names' in sys.argv else \
        ['a', 'abc', 'hello_world', 'supercalifragilistic', 'Z3foov']
    os.makedirs(out, exist_ok=True)
    for fn, types in (('good.elf', [6, 3, 1, 1]), ('badord.elf', [1, 6, 3, 1]), ('baddup.elf', [6, 3, 3, 1]),
                      ('badint.elf', [6, 1, 3, 1])):
        open(os.path.join(out, fn), 'wb').write(elf64(types))
    ok, msg = linker_check(names)
    print('LINKER %s %s' % ('OK' if ok else 'UNKNOWN', msg))
    for n in names:
        print('%s %08x' % (n, elf_hash(n)))
