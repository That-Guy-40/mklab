# `fixtures/uki/` — a small but faithful UKI for the `uki` track (Spike 2)

[`build-uki-fixture.sh`](build-uki-fixture.sh) builds a **real Unified Kernel
Image at run time** (derived, never cached — the repo's rule) with the host's own
`ukify`. Unlike [`fixtures/pe/`](../pe/README.md) — which uses the systemd stub as
a stand-in `.linux` — this UKI's `.linux` is the real-mode setup of a **real
bzImage**, so every section grades by what it *truly* is:

| section | contents | how the firmware grades it |
|---|---|---|
| `.linux` | a real x86 kernel setup (64 KiB bzImage prefix) | `?bootparams` **ACCEPTS** it; `file`(1) names it |
| `.uname` | the kernel version `ukify` detected **from `.linux`** | `== .linux`'s version — the self-consistency proof |
| `.initrd` | the newc cpio from [`fixtures/cpio/`](../cpio/) | `cpio.fth` walks it (`== cpio -itv`) |
| `.cmdline` | `root=/dev/sda1 ro quiet` | `pe-find` + `type`, `== objcopy`'s |
| `.osrel` | an os-release stanza (`ID=lab`) | `pe-find` + `type` |

**The size trick, and why it is honest:** a full bzImage is tens of MiB and will
not fit the firmware's load window, but `ukify` detects the version and writes
`.uname` from the **setup header** alone, and `?bootparams` reads only the setup
header — both live in the first 64 KiB. So `.linux` is the bzImage's 64 KiB setup
prefix: small, loadable, and a real kernel header that `file`/`?bootparams` both
accept. The bzImage is located at run time (`BZIMAGE=` overrides; the track SKIPs
if none is readable).

**The `uki` track ([`smoke-openbios.sh uki`](../../smoke-openbios.sh)) is the
reader set's first consumer** — three readers cooperating on one artifact, on
**unix, x86, amd64 and ppc**: `pe.fth` walks the section table; `.linux` is graded
a Linux kernel by `?bootparams`; `.initrd` is handed to `cpio.fth`; the text
sections read back `== objcopy`. Its headline is the **self-consistency proof**:
`ukify` wrote `.uname` *from* `.linux`'s version, so the firmware's read of
`.uname` equals the version `bootparams.fth` reads out of `.linux` equals
`file`(1)'s — one artifact, one answer.

**Controls (unix):** each grader must refuse the **wrong** section by name —
`bootparams` on `.text` → `bp| BAD-BOOTFLAG`; `cpio-walk` on `.text` →
`cpio| BAD-MAGIC`; a section handed the **wrong length** → `cpio| TRUNCATED`. A
section is graded by what it *is*, never rubber-stamped.

Rebuild by hand:

```sh
./build-uki-fixture.sh /tmp/uki.efi              # or BZIMAGE=/path/to/bzImage ./build-…
objdump -h /tmp/uki.efi                          # the section map
objcopy -O binary --only-section=.linux /tmp/uki.efi /tmp/lx && file /tmp/lx   # a real kernel
objcopy -O binary --only-section=.uname /tmp/uki.efi /dev/stdout               # == that version
```
