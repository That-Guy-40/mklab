# POC-2 — the ok prompt that was dead on arrival (twice)

**Goal:** boot `openbios.multiboot` on bare QEMU — no GRUB, no coreboot — and
drive its prompt over serial. **Result: PASSED**, but only after fixing two
distinct pieces of bitrot in a path nobody had exercised since GRUB-legacy
days. This is the POC where the lab's thesis crystallized: *the rival that
shipped* shipped its ppc/sparc paths; the x86 QEMU-direct path quietly died,
and being alive upstream means we could fix it in C.

## Act 1 — the plan, and instant death

QEMU's `-kernel` implements the multiboot protocol itself, and the multiboot
image's own README says the dict rides as a module. So:

```console
$ qemu-system-i386 -M pc,accel=kvm -m 256 -kernel openbios.multiboot \
    -initrd openbios-x86.dict -display none -serial unix:s2.sock,server=on
KVM internal error. Suberror: 1
extra data[1]: 0x0000000000000400
```

Instant KVM emulation failure at an address near **0x400**. Under TCG: QEMU
exits silently (rc=0 — a triple fault plus `-no-reboot`). Nothing ever reached
the serial port. The failure is *before* the firmware's first instruction.

**The thinking:** if the guest dies before its own code runs, suspect the
*loader's* view of the image. Dump the multiboot header:

```console
$ python3 - <<'EOF'
...find 0x1BADB002, print the header words...
EOF
magic 0x1badb002   flags 0x10003
header_addr 0x0  load_addr 0x0  load_end_addr 0x0  bss_end_addr 0x0  entry_addr 0x0
```

**Bug #1.** Flag bit 16 is the multiboot "a.out kludge": *the address fields
in this header are valid — use them instead of ELF headers.* But
`arch/x86/multiboot.c` defines the header as a 3-word struct — magic, flags,
checksum — so the "address fields" are whatever bytes follow in the image:
zeros. A spec-compliant loader loads the image at address 0 and jumps to
entry 0. QEMU is spec-compliant. Triple fault.

The 2-word fix (clear bit 16, fix the checksum — the image is a normal ELF,
which is exactly what loaders use when the kludge bit is clear) was first
proven by binary-patching the built image, then made a source patch:

```console
$ qemu-system-i386 ... -kernel openbios.multiboot.fixed -initrd openbios-x86.dict ...
boot eax = 0x2badb002
multiboot: dictionary at 0014c000-001665c4
RAM 255 MB
Relocating to 0xff95ce0-0xffdfff7... ok
forth started.
initializing memory...done
panic: no dictionary entry point.
```

## Act 2 — the panic, and the fix that already existed

Alive — multiboot info parsed, module found, the image relocates, Forth
starts... and panics. First guess: wrong module. `openbios-x86.dict`'s
dependency file shows it holds only `arch/x86/init.fs` + the VGA FCode — the
*overlay*, not the system. The full dictionary is `openbios.dict` (its `.d`
lists every forth source in the tree). Swap it in: **same panic.**

**The thinking:** stop guessing, read the panic's producer.
`arch/x86/openbios.c` does:

```c
dict     = (unsigned char *)sys_info.dict_start;   /* raw module bounds */
dicthead = (cell)sys_info.dict_end;
last     = sys_info.dict_last;                     /* ...never set!     */
```

and `grep dict_last` shows exactly one writer: `arch/x86/builtin.c` — the
*embedded*-dictionary image. The multiboot path hands raw module bytes to the
Forth engine as if they were a live dictionary, but a `.dict` **file** starts
with a header (`"OpenBIOS"` magic, version, checksum, relocation bitmap,
`last` offset — `kernel/dict.c` has the full parser, `load_dictionary()`).
Nothing on the x86 multiboot path ever calls it, so `last` stays NULL and
`findword("initialize-of")` finds nothing.

**Bug #2 — and the poetic part:** the correct code exists *in the same repo*.
`arch/amd64/openbios.c` (the arch that only survives as a host-unix build)
does it right:

```c
dict = intdict;
dictlimit = DICTIONARY_SIZE;
load_dictionary((char *)sys_info.dict_start,
                sys_info.dict_end - sys_info.dict_start);
```

The fix is a backport from the neighboring architecture: if `dict_last` is
set (builtin image), use the embedded dictionary; else treat the module as a
file and `load_dictionary()` it. Both images compile the same `openbios.c`,
so the branch keeps the builtin/coreboot path untouched.

## Act 3 — seven

```console
$ qemu-system-i386 ... -kernel openbios.multiboot -initrd openbios.dict ...
Trying disk...
No valid state has been set by load or init-program

0 >   ok
0 > 3 4 + . 7  ok
0 > words
...
```

Under KVM and TCG both. And the spike's other question answered itself along
the way: **x86 serial input works over a plain unix socket** — the
`drive-serial-repl.py` conversation above needed no pty tricks (unlike ppc;
POC-5). One more anchor for scripting: the banner goes to the VGA console
path, so over serial the boot ends at a bare `0 > ` — expect the prompt, not
"Welcome to OpenBIOS".

## Pitfalls checklist

- **flags 0x10003 with a 3-word header** is spec-invalid; QEMU/GRUB will
  honor bit 16 and jump to 0. Trust the loader, dump the header.
- `openbios-x86.dict` is NOT the dictionary — `openbios.dict` is. The
  `<platform>` name is the decoy.
- `panic: no dictionary entry point` on x86-multiboot = `dict_last` never
  set = `load_dictionary()` never called. arch/amd64 has the reference flow.
- A triple fault under `-no-reboot` looks like a clean rc=0 QEMU exit —
  silence is not success (KVM's "internal error" is the *louder* accel here).
- The `cd X && qemu … & driver` one-liner backgrounds the whole `&&` chain —
  the foreground driver then runs in the wrong cwd and waits on a socket path
  that never appears. Absolute paths, always (OFW lab lesson, re-learned).
