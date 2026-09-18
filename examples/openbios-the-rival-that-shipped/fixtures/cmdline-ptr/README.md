# `fixtures/cmdline-ptr/` — a foreign, phys-0 `boot_params` dump for the `cmdline-ptr` track (Spike 7a)

The `cmdline-ptr` track ([`smoke-openbios.sh cmdline-ptr`](../../smoke-openbios.sh))
edits the x86 kernel command line that `boot_params`' **`cmd_line_ptr`** (u32 @0x228)
names — the classic-kernel rescue seam — with [`dsl/bootparams-edit.fth`](../../dsl/bootparams-edit.fth),
on unix, x86, amd64 and ppc.

**Why the fixture cannot be a bzImage.** `cmd_line_ptr` is a *runtime* field: it is
**zero on disk**. Only a bootloader ever sets it, and it sets it in RAM. So there is
no on-disk value to read, and minting the zero-page ourselves and reading it back
would be a **round trip that hides a symmetric offset error** (the repo's rule). The
fixture is therefore **guest physical memory captured from a real bootloader** —
QEMU's own `-kernel` loader — **dumped from address 0**, so `cmd_line_ptr` (a physical
address QEMU chose) is a **direct offset into the dump**: no pointer rebasing, nothing
about the field under test re-authored by us. QEMU set the pointer *and* wrote the
command-line buffer; we only pass the `-append` string, so the reader
([`bootparams-edit.fth`](../../dsl/bootparams-edit.fth)) and the oracle
([`decode-cmdline.py`](decode-cmdline.py)) are different programs.

The three scripts, derived at run time, never cached:

- [`capture-bootparams.py`](capture-bootparams.py) — launches QEMU with a real
  bzImage and a sentinel `-append`, lets its `linuxboot` option ROM run (the zero page
  is built **after** reset, so `-S` shows nothing), then QMP `stop` + `pmemsave` guest
  physical memory from 0. It polls on a widening schedule so a slow CI runner still
  catches the window, verifies the dump with `decode-cmdline.py`, and reaps QEMU by
  PID. Measured layout: `boot_params` @ `0x10000`, `cmd_line_ptr` @ `0x20000`,
  `cmdline_size` `0x7ff`.
- [`decode-cmdline.py`](decode-cmdline.py) — the **foreign decoder**, one
  implementation for two callers: the builder uses it to verify the capture, and the
  track uses it as the ORACLE (an independent `struct` decode of the same bytes the
  Forth walks). It locates `boot_params` by `bootparams.fth`'s own anchors
  (`0xAA55` @ +0x1fe, `HdrS` @ +0x202) and follows `cmd_line_ptr` as a direct offset.
- [`build-cmdline-ptr-fixture.sh`](build-cmdline-ptr-fixture.sh) — orchestrates the
  capture and emits, into its output dir: **`CMDPTR.BIN`** (the dump, **trimmed** to
  `cmd_line_ptr + ROOM` so that *both* bounds controls bite — `CMDLINE-OOB` past the
  image end and `CMDLINE-TOO-BIG` past `cmdline_size` need distinct sizes, which
  requires `ROOM < cmdline_size`), **`CMDLINE-PTR.FTH`** (the rescue command line as a
  compiled `rescue-cmdline` word, plus the two control sizes derived from the capture),
  and **`sentinel.txt`** / **`rescue.txt`** (the read/edit oracle strings). It exits
  `77` when no bzImage is present, which the track turns into a SKIP.

**Grade.** The firmware follows `cmd_line_ptr` to the sentinel, rewrites it in place to
the rescue line (`init=/bin/bash single`), and re-reads it; on unix the written-back
dump is decoded by `decode-cmdline.py` — the edit is real in the bytes, not the
firmware's own read-back. **Controls** (unix), each refused by name with nothing
written: a line past `cmdline_size` → `bp| CMDLINE-TOO-BIG`, past the image end →
`bp| CMDLINE-OOB`, a zeroed pointer → `bp| NO-CMDLINE`; the command line is unchanged
after all three.

**Boundary (Spike 7b, UNKNOWN).** That the edit reaches a *booted* kernel's
`/proc/cmdline` needs a bootloader that consumes this edit; this lab's firmware does not
boot a bzImage from a prompt edit, so that half is honestly UNKNOWN — the runtime loop
the toolkit *does* close is the UKI `.cmdline` path (Spike 6, under OVMF).

Rebuild by hand:

```sh
# needs qemu-system-x86_64, python3, and a readable bzImage
./build-cmdline-ptr-fixture.sh /tmp/cmdptr [/path/to/bzImage]
python3 decode-cmdline.py /tmp/cmdptr/CMDPTR.BIN     # prints the sentinel
head -5 /tmp/cmdptr/CMDLINE-PTR.FTH                  # the compiled rescue line + controls
```
