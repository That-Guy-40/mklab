#!/usr/bin/env python3
"""build-elf-gate-fixtures.py — the subjects for smoke-openbios.sh's `elf-gate` track.

Three SYNTHETIC ELF64 files that differ from each other in nothing but their
program-header TYPE words, so a refusal can only be about ordering:

  good.elf    PT_PHDR, PT_INTERP, PT_LOAD, PT_LOAD   -- the gABI order
  badord.elf  PT_LOAD, PT_PHDR,   PT_INTERP, PT_LOAD -- PHDR/INTERP after a LOAD
  baddup.elf  PT_PHDR, PT_INTERP, PT_INTERP, PT_LOAD -- INTERP twice

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

Usage: build-elf-gate-fixtures.py <outdir> [--names NAME...]
Writes <outdir>/{good,badord,baddup}.elf and prints "NAME HASH" lines (hex).
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

if __name__ == '__main__':
    out = sys.argv[1]
    names = sys.argv[sys.argv.index('--names') + 1:] if '--names' in sys.argv else \
        ['a', 'abc', 'hello_world', 'supercalifragilistic', 'Z3foov']
    os.makedirs(out, exist_ok=True)
    for fn, types in (('good.elf', [6, 3, 1, 1]), ('badord.elf', [1, 6, 3, 1]), ('baddup.elf', [6, 3, 3, 1])):
        open(os.path.join(out, fn), 'wb').write(elf64(types))
    ok, msg = linker_check(names)
    print('LINKER %s %s' % ('OK' if ok else 'UNKNOWN', msg))
    for n in names:
        print('%s %08x' % (n, elf_hash(n)))
