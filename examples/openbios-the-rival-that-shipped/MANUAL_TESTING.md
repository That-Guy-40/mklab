# MANUAL_TESTING — exact commands + real success signatures

All transcripts below are from the verification host (Ubuntu 24.04,
qemu-system-x86_64/-ppc 8.2.2, KVM available, rootless podman), 2026-07-21.
Raw spike logs live in `~/openbios-lab/` (`drive*.log`, `smoke-*.log`,
`showcase-*.log`, `build-*.log`).

## 1. Build all targets (container)

```console
$ ./build-openbios.sh
==> applying the revival patch (idempotent)
    applied
==> building the build-box image (localhost/openbios-build)
Building OpenBIOS for x86 ... ok.
Building OpenBIOS for ppc amd64 ... ok.
==> artifacts:
/home/sqs/openbios-lab/openbios/obj-amd64/openbios-unix
/home/sqs/openbios-lab/openbios/obj-ppc/openbios-qemu.elf
/home/sqs/openbios-lab/openbios/obj-x86/openbios-builtin.elf
/home/sqs/openbios-lab/openbios/obj-x86/openbios-x86.dict
/home/sqs/openbios-lab/openbios/obj-x86/openbios.multiboot
```

Success signature: five artifact paths listed. ~2 min cold (clones openbios +
fcode-utils, pulls debian:13, builds toke), seconds warm. Re-running prints
`already applied` — the patch step is idempotent (applies, or verifies it
reverses, or errors if the tree diverged).

## 2. Coreboot ROM (cached tree ≈ 1 min)

```console
$ ./build-coreboot-openbios.sh
==> wrote guard /home/sqs/openbios-lab/coreboot-guard.sha
==> isolated config/build (.config-openbios + build-openbios/) — sibling artifacts untouched
Built emulation/qemu-i440fx (QEMU x86 i440fx/piix4)
==> guard check:
.config: OK
build/coreboot.rom: OK
.config-ofw: OK
build-ofw/coreboot.rom: OK
==> /home/sqs/linuxboot-lab/coreboot/build-openbios/coreboot.rom
```

The guard proves BOTH sibling labs' kept coreboot artifacts (linuxboot's
`.config`/`build/coreboot.rom` and the OFW lab's `.config-ofw`/
`build-ofw/coreboot.rom`) survive our isolated third build.

## 3. Smokes — one verdict each

```console
$ ./smoke-openbios.sh multiboot
  - booting multiboot (accel=kvm), driving the 0 > prompt → .../smoke-openbios-multiboot.log
PASS: OpenBIOS (multiboot) answered 7 at the 0 > prompt and listed the device tree

$ ./smoke-openbios.sh coreboot
PASS: OpenBIOS (coreboot) answered 7 at the 0 > prompt and listed the device tree

$ ./smoke-openbios.sh ppc
  - banner: OpenBIOS built on Jul 21 2026 07:09
  - distro blob: built on Apr 22 2026 09:24 — different, so the running firmware is OURS
PASS: our own openbios-ppc (built on Jul 21 2026 07:09) answered 7 at the 0 > prompt
```

```console
$ ./smoke-openbios.sh dict-identity
  - openbios.dict=104952 bytes, openbios-x86.dict=108060 bytes
  - 1/2 booting the ARCH dict → .../smoke-openbios-dict-identity.log.arch
  - 2/2 control: the BASE dict, which must NOT have them → .../smoke-openbios-dict-identity.log.base
PASS: the x86 tracks boot openbios-x86.dict (108060 bytes, the superset): /memory and /cpus
      are in the running device tree, and the base openbios.dict (104952 bytes) boots to a
      prompt WITHOUT them

$ ./smoke-openbios.sh amd64-fault
  - provoking a page fault above 4 GiB → .../smoke-openbios-amd64-fault.log
PASS: SPIKE 2 (exceptions): three page faults above the identity map, each NAMED with CR2
      and a full machine+Forth dump, each RECOVERED — the prompt answers 7 and still walks
      the device tree afterwards

$ ./smoke-openbios.sh amd64-pmem
  - 1/3 writing the store to pmem at 0x100000000 → …log.write
  -    host pmem image changed: 8a2b1f0d4c6e… → 3f77c0921ab4…
  - 2/3 fresh QEMU process, same pmem file → …log.read
  - 3/3 control: identical boot with NO nvdimm attached → …log.control
PASS: P3: … boot-file reads back as P3-PMEM, and the no-nvdimm control saw neither the
      region nor the value
```

Runtime ≈ 15–30 s each (`amd64-pmem` and the `persist*` family boot three times,
≈ 60–90 s). SKIP (77) when the image, qemu, or python3 is absent.

**The full list is what `./smoke-openbios.sh --help` prints** — read it there rather than
from this paragraph, which is a copy and can drift: `multiboot coreboot ppc nvram
dict-identity persist persist-flash floppy persist-os persist-os-flash amd64 amd64-fault
amd64-ctx amd64-pmem amd64-linux property-abi vga diagnostics client-forth`. The last five
were added 2026-08-25/26 (Spike 3; TODO §13.2's wordset probe; §13.1a's PCI + FCode track;
§13.1b's binding-failure reporter; §13.3(A)'s trampoline segments).
Measured 2026-08-26 on this host: **13 of 13 driven tracks passed** — `multiboot
dict-identity nvram amd64 amd64-fault amd64-ctx amd64-pmem amd64-linux ppc floppy
property-abi vga diagnostics`, with 0 SKIP among them. `diagnostics` is the only track
that boots **all three** arches in one run, and it is the only one that is two-sided in a
single boot: silence where silence is correct, and a must-catch fixture where it is not. It
also carries the two printf fixture sets (`7/7` and `10/10`, plus one **recorded
divergence** — `%.0d` of `0` — asserted as itself so that closing it goes red on purpose). Two of those carry the clean-prompt probe
added the same day: `amd64` asserts it (patch 19 fixed it there) and `multiboot` is its
**control**, since x86 has always passed. Measured 2026-08-23: **13 of 14 ran and
passed; the one SKIP is `coreboot`**, which has no cached ROM (rebuild it with
`./build-coreboot-openbios.sh`). The Linux showcase now takes a third flavor:
`multiboot` PASS, **`amd64` PASS (2026-08-25)**, `coreboot` SKIP for the same
ROM reason.

**2026-08-26, patch 24 (TODO §13.3(A)):** nine tracks re-run after the trampoline fix —
`client-forth multiboot dict-identity amd64 amd64-ctx property-abi vga diagnostics ppc`,
all PASS, 0 SKIP. The other six (`nvram amd64-fault amd64-pmem amd64-linux floppy
persist*`, plus `coreboot`) were **not re-run** and are UNKNOWN for that change rather
than assumed green: patch 24 touches `arch/x86/context.c` and the two loader
`*_init_program()` entry points, which none of them drives.

**2026-08-26, patch 25 (TODO §13.2(d)):** `property-abi` re-run on x86 and amd64 with its
new decode-bytes section, plus `ppc diagnostics client-forth multiboot amd64` — all PASS.
`property.fs` is shared, so all three arches were rebuilt; ppc is driven by the `ppc` and
`diagnostics` tracks, **not** by the property probe, which loads Forth off a CD and has no
ppc arm. That is a named gap, not a covered one.

**2026-08-26, patch 26 (TODO §13.2(b), and §13.2(a) decided):** `multiboot amd64 amd64-pmem
vga diagnostics ppc client-forth dict-identity property-abi` — all PASS. `amd64-pmem` is the
one that matters for (b): its store is at `0x100000000` and the new refusal does not trip on
it. (a) is **not fixed** — sign-extension would corrupt PCI addresses with bit 31 set — and
its premise is now a counter read on every boot instead of a claim.

**2026-08-27, patch 27 (TODO §13.2(c)):** `property-abi multiboot amd64 amd64-pmem vga
diagnostics ppc client-forth dict-identity` — all PASS on x86 + amd64 + ppc builds. `encode+`
now concatenates; the probe exercises **both** branches and names which one it took, because
a fix whose slow path never runs is indistinguishable from no fix.

### The negative controls, run 2026-08-23

Each fix was broken and watched to bite before being trusted:

| control | result |
|---|---|
| `set-defaults` back to a `SYSTEM-initializer` (both `init.fs`) | `persist` **FAIL**, `amd64-pmem` **FAIL** — by name, pointing at the initializer list |
| …the same break, but booting the **base** dict | `persist` **PASS** — the masking, reproduced on demand |
| `$XDICT` pointed back at `openbios.dict` | `dict-identity` **FAIL** |
| `arch/amd64/exception.c` back to the `do_nothing` return | `amd64-fault` **FAIL** — *"the fault WAS named and the prompt never came back"* |
| all restored | all four **PASS** again |

### The Spike 3 controls, run 2026-08-25

| control | result |
|---|---|
| `unsigned long type` back in `struct e820entry` | the **build** stops: *"size of array `linux_abi_e820entry_is_20_bytes` is negative"*. This is the one that matters — the runtime symptom it replaces is a correctly-running kernel emitting nothing at all |
| the `CR3` switch removed from `start_linux()` | `showcase … amd64` **FAIL** — the copy demolishes the page tables it is translated through, and the log stops one line after the handoff |
| all restored | `showcase … amd64` and `smoke … amd64-linux` **PASS** again |

**And the second control found a liar in the harness itself.** The showcase's
failure branch was `grep -aq "Linux version"` → *"kernel started but no u-root
banner"* — but the **firmware** prints `Found Linux version 6.3.0 …` the moment
it recognises the image, so that branch reported "the kernel started" about a
machine that had triple-faulted inside the loader. It is the shape this repo
keeps re-finding: a match on a string that is always present. The check is now
anchored (`^Linux version `), and a third branch distinguishes *handed off and
the kernel said nothing* — which on this path means silence, not a dead kernel.

### The help text is checked, because it is a program

`--help` on any of the five scripts prints and exits 0:

```console
$ ./smoke-openbios.sh --help
smoke-openbios.sh [TRACK]   one-verdict smoke tests against a real boot
...
```

That is guarded by [`tests/test-usage-is-data.sh`](tests/test-usage-is-data.sh),
which `exec`s the shared [`tools/check-usage-is-data.sh`](../../tools/check-usage-is-data.sh)
and is listed by path in CI. **It found five defects the day it was first
aimed here** (2026-08-25) — this lab had no `tests/` directory until then, so
the checker every phase runs against its driver had never seen these scripts.
Four exited 1 on `--help`; `build-coreboot-openbios.sh` exited **0 after
actually starting a coreboot build**. Asking a tool to describe itself should
not be the thing that does the work.

Every usage heredoc here uses a **quoted** delimiter (`<<'USAGE'`), which makes
the text structurally inert. The control shows why that is not fussiness — with
the delimiter unquoted, a backtick in the prose runs:

| | |
|---|---|
| authored | `multiboot coreboot ppc      run the ` + `` `date` `` + ` track first` |
| **printed to the reader** | `multiboot coreboot ppc      run the Tue Aug 25 12:51:53 AM EDT 2026 track first` |
| written to stderr | **nothing** |

The cheap check — *"`--help` writes nothing to stderr"* — passes that. It only
catches a command that does not *exist*; one that succeeds rewrites the
documentation silently, which is the dangerous case. The checker asks the real
question instead and names the file and line. Both controls were run: removing
a `--help` handler, and unquoting a delimiter. Restored, both go green.

### Loading Forth source off media (amd64)

Since [patch 14](patches/14-amd64-openbios-init-after-device-end.patch), a `.fth`
on the CD can be run instead of typed through the ~80-char serial truncation:

```console
0 > load /ide@1/cdrom@0:\marker.fth
Mounted iso9660
Path=/marker.fth
 ok
0 > load-base load-size evaluate
SPIKE-FORTH-LOADED
```

The file must begin with `\ ` (a Forth comment) — that is literally how
`is_forth()` recognises it (`libopenbios/forth_load.c:21`). `genisoimage -r`
lowercases names, so stage it as `MARKER.FTH` and type `marker.fth`.

**`go` works too**, since [patch 15](patches/15-forth-loader-divergence.patch):

```console
0 > go
switching to new context:
Evaluating Forth...
SPIKE-FORTH-LOADED
```

That patch is a **divergence this lab carries on purpose**. Two defects kept the
loader from ever running: the `$load` path never sets `load-state >ls.file-size`
(it records the size in a *different* variable), and `eval2` — the word
`libopenbios/initprogram.c` calls to do the evaluating — **is defined nowhere in
the tree**. Both are in arch-neutral code, so they were developed in a separate
copy of the source and regression-tested against x86 before being applied here.
Not sent upstream: nothing upstream ships needs this path. See
[TODO §13.1](../../TODO.md).

## 4. The showcase — OpenBIOS boots Linux to u-root

```console
$ ./showcase-rival-boots-linux.sh            # multiboot track (default)
  - booting multiboot (accel=kvm), one boot line at the prompt → .../showcase-multiboot.log
PASS: the rival boots Linux: OpenBIOS (multiboot) loaded kernel+initrd and reached u-root

$ ./showcase-rival-boots-linux.sh coreboot   # same one-liner, through coreboot
PASS: the rival boots Linux: OpenBIOS (coreboot) loaded kernel+initrd and reached u-root
```

Key lines inside `showcase-multiboot.log` (the full serial transcript):

```
0 > boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
[x86] Booting file '/ide@1/cdrom@0:\vmlinuz' with parameters 'console=ttyS0 initrd=...'
Found Linux version 6.3.0 ... (protocol 0x20f) (loadflags 0x1) bzImage.
Loading kernel... ok
Loading initrd... ok
Jumping to entry point...
Linux version 6.3.0 (coreboot@reproducible) ...
RAMDISK: [mem 0x1f296000-0x1fd94fff]
Run /init as init process
2026/07/21 07:18:27 Welcome to u-root!
```

Contrast with the OFW lab's showcase: **no** `memmap=`, **no** hand-staged
initrd, **no** zero-page poke — `initrd=` is parsed by the firmware, the
memory map is real, the zero page is built in C. The difference is the whole
point (POC-4). Needs `genisoimage` + a kernel/initrd pair (defaults:
`~/linuxboot-lab/payload-bzImage` + `uroot.cpio`; override `KERNEL=`/
`INITRD=`). ≈ 30–45 s under KVM.

## 5. The firmware as a Unix process (no QEMU)

```console
$ cd ~/openbios-lab/openbios
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict
0 > 3 4 + . 7  ok
0 > bye
Farewell!
```

The same IEEE 1275 Forth engine, running as your user with no emulator at all
— OpenBIOS's C-hosted design makes this possible; the frozen OFW rival (pure
self-hosting Forth) has no equivalent.

## 6. Interactive & the ppc swap-in

```console
$ ./run-openbios-qemu.sh              # multiboot, 0 > on this terminal (Ctrl-A X quits)
$ ./run-openbios-qemu.sh coreboot     # coreboot → OpenBIOS
$ ./run-openbios-qemu.sh ppc          # OUR openbios-ppc via -bios (-nographic)
$ ./run-openbios-qemu.sh amd64        # the 64-BIT firmware, NVRAM on an NVDIMM at 0x100000000
0 > 3 4 + . 7  ok
```

The `amd64` flavor, driven by hand 2026-08-23 — every line below was typed at
the prompt the tool drops you at:

```console
0 > -1 u. ffffffffffffffff  ok            \ a 64-bit cell; x86 prints ffffffff
0 > test-ctx-switch . switching to new context:
5a  ok
0 > 0 200000000 !
Unexpected Exception: page fault @ 08:0000000000101fd0
Faulting address: 0000000200000000
...
0 > 3 4 + . 7  ok                          \ ...and the prompt CAME BACK
```

Persistence, across two separate QEMU processes:

```console
0 > setenv boot-file HELLO-64-8821  ok
0 > " /nvram" " update-nvram" execute-device-method . -1  ok
                                           \ Ctrl-A X, then run the tool again
nvram: backed by pmem@0x100000000
0 > printenv boot-file
boot-file                 "HELLO-64-8821"
```

`OPENBIOS_NO_PMEM=1` is the **control**, not just an off switch — the same tool,
the same firmware, no NVDIMM:

```console
nvram: no memory at 0x100000000 -- using a volatile buffer
boot-file                 ""
```

`OPENBIOS_PMEM_IMG=<path>` picks a different store; the default
(`$OPENBIOS_WORKDIR/pmem-nvram.img`) is created on first use and kept. A fresh
image prints `nvram error detected, zapping pram` once — that is it formatting
an empty store, not a failure.

## Reproducer notes (the sharp edges)

- **The prompt is `0 > `** (the number is the stack DEPTH), banner "Welcome to
  OpenBIOS". Different anchors than OFW's `ok`.
- **x86 banner goes to the VGA path** on the multiboot track — over serial the
  boot ends at a bare `0 > `. Anchor expects on the prompt, not the banner.
  (The coreboot track *does* echo the banner to serial — anchor on `0 > `
  either way.)
- **ppc console input needs muxed stdio** (`-nographic`), NOT a `-serial
  unix:` socket — use `tools/drive-pty-repl.py` (this lab's extracted tool).
- **Device paths:** `:\file` (backslash) is a filename; `:/file` is a node
  path. `genisoimage -r` lowercases (`VMLINUZ`→`vmlinuz`).
- **Boot line ≤ ~80 chars** — the firmware input buffer drops the tail
  silently. The showcase line is **75** characters (measured 2026-08-24; this
  and POC-4 both said "exactly 78", a copied integer nobody re-counted).
- **Serial client must gate the guest**: `-serial unix:…,server=on` with wait
  ON, so the banner isn't emitted before the client connects.
- **Slow-send always** (40 ms/byte — both drive tools' default): firmware
  serial has no flow control.
- **Kill QEMU by PID**, never by pattern (house rule; the scripts comply).
- **`openbios-x86.dict` is the x86 dictionary**, not `openbios.dict` — the
  latter is the arch-less base it is built *from*, and booting it silently
  drops `arch/x86/init.fs` (no `/memory`, no `/cpus`, no `set-defaults`).
  `dict-identity` measures this on every run; POC-2 said the opposite until
  2026-08-23.
- **`1 0 /` hangs the 64-bit firmware with no exception** and that is not an
  IDT gap: `mu/mod` divides an `__int128`, so the compiler calls libgcc's
  `__udivmodti4` rather than emitting `idiv`. There is no `#DE` to catch.
- **A triple fault under `-no-reboot` looks like a clean rc=0 exit** — check
  the log for a prompt, don't trust the exit code. KVM's "internal error" is
  the louder failure mode.
- **Timestamped builds**: the banner embeds `__DATE__`/`__TIME__` — that's the
  ppc swap-in's proof (§3), so byte-identical rebuilds are not expected.
