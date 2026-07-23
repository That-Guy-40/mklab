# MANUAL_TESTING — exact commands + real success signatures

Transcripts below are from the verification host (Ubuntu 24.04,
`qemu-system-ppc` 8.2.2, KVM available, rootless podman), 2026-07-22. Client
binaries, ISOs, and logs live in `~/openbios-clients-lab/` (override with
`OPENBIOS_CLIENTS_WORKDIR`).

## 1. Build the clients (container)

```console
$ ./build-client.sh all hello
==> building the client build-box image (localhost/openbios-clients-build)
==> ppc: hello-ppc (big-endian, entered by stock qemu-system-ppc)
  Data:                2's complement, big endian
  Machine:             PowerPC
  Entry point address: 0x1000000
==> x86: hello-x86 (runs only after the Phase-3 revival)
  Machine:             Intel 80386
  Entry point address: 0x2006e2
==> artifacts in /home/<you>/openbios-clients-lab:
  hello-ppc
  hello-x86
```

Success signature: both `Entry point address` lines, ppc entry at the load base
`0x1000000` (`_start` pinned there). First run builds the lean cross-toolchain
image (~30 s, `docker.io/debian:13` + apt); warm builds are seconds. No
OpenBIOS build is involved — the ppc client runs on the *stock* firmware.

## 2. Phase-1/2 smokes — one verdict per program

`smoke-client.sh [ppc|x86] [program]` builds (if needed), stages a CD, and drives
`boot cd:\NAME.;1`, expecting each program's success marker. `SKIP` (77) if
`python3`/`qemu-system-ppc`/`genisoimage` is absent or the program doesn't exist.

### hello (rung 1)

```console
$ ./smoke-client.sh ppc hello
  - booting stock qemu-system-ppc + our hello CD, driving boot cd:\HELLO.;1 → …/smoke-client-ppc-hello.log
PASS: OpenBIOS-ppc loaded our C client 'hello' and it answered Hello world! over the IEEE 1275 client interface
```

The client's own output, from the log:

```
0 > boot cd:\HELLO.;1  >> switching to new context:
Hello world!  --  an OpenBIOS client program, calling back into the firmware.
clib proof: 6 * 7 = 42, or in hex 0x2a
EXIT
1 >
```

`switching to new context:` = the firmware entering our `_start`; the
`clib proof` line = `put_udec`/`put_hex` round-tripping through the firmware's
`write` service; `EXIT` → `1 >` = `main` returned and the firmware took control
back. Runtime ≈ 15–25 s.

### memtest (rung 3)

```console
$ ./smoke-client.sh ppc memtest
  - booting stock qemu-system-ppc + our memtest CD, driving boot cd:\MEMTEST.;1 → …/smoke-client-ppc-memtest.log
PASS: OpenBIOS-ppc loaded our C client 'memtest' and it ran the RAM tester to a clean PASS over the IEEE 1275 client interface
```

```
0 > boot cd:\MEMTEST.;1  >> switching to new context:
OpenBIOS memtest client -- a RAM tester with no OS, served by the firmware.
  /memory reports 256 MiB of RAM
  claimed 4 MiB at 0xf858000
  address test ......... ok
  pattern 0x0 ... ok
  pattern 0xffffffff ... ok
  pattern 0xaaaaaaaa ... ok
  pattern 0x55555555 ... ok
  walking-bit test ..... ok
memtest: PASS -- all patterns verified
EXIT
1 >
```

`256 MiB` matches `-m 256` (the `/memory` "reg" walk); `claimed … at 0xf858000`
is the firmware's `claim` service answering. Runtime ≈ 5–15 s under TCG; the
smoke reports a specific `REGRESSION:` if it ever prints `memtest: FAIL` (that
would mean the clib claim/verify path broke — emulated RAM does not fail).

### edit (rung 4 — interactive)

```console
$ ./smoke-client.sh ppc edit
  - booting stock qemu-system-ppc + our edit CD, driving boot cd:\EDIT.;1 → …/smoke-client-ppc-edit.log
PASS: OpenBIOS-ppc loaded our C client 'edit' and it ran a tiny interactive editor (typed, backspaced, Ctrl-X saved) over the IEEE 1275 client interface
```

The smoke *types* at the editor — `hellX`, then Backspace (`\x7f`), then `o`,
then Ctrl-X (`\x18`) — so the buffer ends `hello`. Raw console stream (escapes
left in, so you can see the painting):

```
[4;1H> hellX o[2J[H[1;1Hedit: wrote 5 chars: hello
```

`[4;1H> ` positions the prompt; `hellX` is typed; `\b \b` rubs out the `X`; `o`
lands; Ctrl-X ends the loop; `[2J[H` clears; and the plain marker
`edit: wrote 5 chars: hello` confirms the buffer. Every keystroke went in through
the firmware `read` service, every glyph out through `write`. Try it by hand:
`./run-client-qemu.sh ppc edit`, type, Ctrl-X to save. See
[POC-5](POC-5-EDITOR.md).

### ppc from a hard disk (POC-7)

The stock `qemu-system-ppc` also loads a client off an **ext2 hard disk** — its
*native* ext2 reader (no firmware build), via `boot hd:\<prog>`:

```console
$ ./smoke-client.sh ppc hello disk
  - booting stock qemu-system-ppc + our hello on an ext2 hard disk, driving 'boot hd:\hello' → …
PASS: OpenBIOS-ppc loaded our C client 'hello' from an ext2 hard disk and it answered Hello world! over the IEEE 1275 client interface

$ ./smoke-client.sh ppc emacs disk        # the editor too, off the disk
PASS: OpenBIOS-ppc loaded our C client 'emacs' from an ext2 hard disk …
```

By hand: `./run-client-qemu.sh ppc hello disk`, then `boot hd:\hello`. The
gotcha: **backslash, NO comma** — `boot hd:,\hello` returns "No valid state" on a
superfloppy. ppc `disk-fat` SKIPs (ppc has no FAT reader). Full story:
[POC-7](POC-7-DISK-BOOT.md).

### emacs (rung 4 — the finale, MULTI-line)

```console
$ ./smoke-client.sh ppc emacs
  - booting stock qemu-system-ppc + our emacs CD, driving boot cd:\EMACS.;1 → …/smoke-client-ppc-emacs.log
PASS: OpenBIOS-ppc loaded our C client 'emacs' and it ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited) over the IEEE 1275 client interface
```

The smoke types `MEOW`, then **Enter** (a line split — the op `edit.c` can't do),
then `PURR` on the new second line, then `C-x C-c`. On exit the editor clears the
screen and dumps the buffer as plain text; the tail of the log:

```
emacs: 11 lines, 437 chars
| MEOW
| PURRclib-emacs -- a MicroEMACS-style editor running as an OpenBIOS client (no OS).
| 
|   Move    C-f forward  C-b back   C-n next-line  C-p prev-line
...
```

`| MEOW` on its **own** line and `PURR` on the **next** is the proof that Enter
split one line into two (the verdict asserts `^| MEOW$` and `| PURR`). Mid-run,
the reverse-video mode line tracks the cursor across the split —
`-- clib-emacs -- L1 C5  10 lines *` before Enter, `L2 C1  11 lines *` after
(line count 10→11, cursor to the head of the new line). Try it by hand:
`./run-client-qemu.sh ppc emacs` — type, `C-x C-s` to save, `C-x C-c` to exit.
See [POC-6](POC-6-MICROEMACS.md).

## 3. Interactive — run it by hand

```console
$ ./run-client-qemu.sh ppc hello
==> at the 0 > prompt, type:   boot cd:\HELLO.;1     (Ctrl-A X quits)
>> OpenBIOS 1.1 [Apr 22 2026 09:24]
...
0 > boot cd:\HELLO.;1
Hello world!  --  an OpenBIOS client program, calling back into the firmware.
```

A human types at the muxed stdio with no trouble; the flow-control caveat only
bites scripted drivers.

## x86 — the revived firmware runs the same clients

Unlike ppc (which needs no firmware build at all), x86 needs the revival — six
repairs on top of the rival lab's eight. Build it once, then the same smokes run:

```console
$ ./build-firmware-x86.sh
==> applying this lab's client-path patch (idempotent)
    applied
==> rebuilding OpenBIOS for x86
ok.
==> artifacts:
/home/sqs/openbios-lab/openbios/obj-x86/openbios.dict
/home/sqs/openbios-lab/openbios/obj-x86/openbios.multiboot

$ ./smoke-client.sh x86 hello
PASS: revived OpenBIOS-x86 loaded our C client 'hello' and it answered Hello world! over the IEEE 1275 client interface

$ ./smoke-client.sh x86 memtest
PASS: revived OpenBIOS-x86 loaded our C client 'memtest' and it ran the RAM tester to a clean PASS over the IEEE 1275 client interface

$ ./smoke-client.sh x86 edit
PASS: revived OpenBIOS-x86 loaded our C client 'edit' and it ran a tiny interactive editor (typed, backspaced, Ctrl-X saved) over the IEEE 1275 client interface

$ ./smoke-client.sh x86 emacs
PASS: revived OpenBIOS-x86 loaded our C client 'emacs' and it ran a MicroEMACS-style multi-line editor (typed, split a line with Enter, C-x C-c saved-and-exited) over the IEEE 1275 client interface
```

The x86 `emacs` buffer dump is **byte-for-byte identical** to ppc's
(`emacs: 11 lines, 437 chars`, `| MEOW`, `| PURR…`): the multi-line line-split
lands the same under x86's rebased-GDT segments as it does on ppc.

Interactive by hand: `./run-client-qemu.sh x86 emacs`. x86 has **no `boot cd:`
shortcut** for a client — it's a **two-step** load at the `0 >` prompt, each on
its own line:

```
" /ide@1/cdrom@0:\emacs" $load     ← reads the ELF + sets load-state → prints "ok"
go                                 ← ENTERS the client; the editor paints here
```

`$load` alone only stages the image and returns you to `0 >`; the editor does not
start until `go`. (Typing anything else at the prompt in between just feeds the
Forth interpreter — e.g. `sdsd → undefined word`.)

**Ctrl-A gotcha — how to type emacs's `C-a` under `-serial mon:stdio`.** The
launcher (and the smoke) mux the QEMU monitor onto stdio, so QEMU reserves
**`Ctrl-A`** as its own escape prefix (`Ctrl-A X` quits, `Ctrl-A C` → monitor).
A bare `Ctrl-A` therefore never reaches the editor, and emacs's *beginning-of-line*
appears dead. To send a **literal** `Ctrl-A` (`0x01`) through to the client, press
the prefix twice — **`Ctrl-A` `Ctrl-A`** (QEMU also accepts `Ctrl-A` then `a`);
the second press means "pass this byte through," the same convention GNU `screen`
uses for its own `Ctrl-A`. Every other binding (`C-e`, `C-f`, `C-k`, `C-x C-c`, …)
is unaffected — `Ctrl-A` is the only hijacked key. The headless smoke sidesteps
this entirely by never binding `C-a` in its drive sequence.

### From a hard disk instead of a CD (POC-7)

The client `load` path is medium-agnostic — the same client boots off an **ext2
hard disk**. Pass `disk` as the 3rd arg; the smoke stages a classic-ext2 image
(`stage-disk.sh`, populated with `debugfs`, no root) and loads from
`/ide@0/disk@0`:

```console
$ ./smoke-client.sh x86 hello disk
  - booting revived OpenBIOS-x86 + our hello on an ext2 hard disk, driving $load /ide@0/disk@0 + go → …
PASS: revived OpenBIOS-x86 loaded our C client 'hello' from an ext2 hard disk and it answered Hello world! over the IEEE 1275 client interface

$ ./smoke-client.sh x86 emacs disk
PASS: revived OpenBIOS-x86 loaded our C client 'emacs' from an ext2 hard disk and it ran a MicroEMACS-style multi-line editor (…) over the IEEE 1275 client interface
```

Interactive by hand: `./run-client-qemu.sh x86 emacs disk`
(`" /ide@0/disk@0:\emacs" $load` then `go`). Three gotchas make this work — **ext2
not FAT** (grubfs ships with no FAT driver), a **classic-ext2 layout** (modern
`mke2fs` defaults break the GRUB-0.97 driver), and a **backslash path** (a forward
slash is eaten by the device-path parser). Full story: [POC-7](POC-7-DISK-BOOT.md).
`disk` on **ppc** SKIPs — mac99's device tree differs and is left as a future spike.

**FAT too (`disk-fat`) — needs the FAT-enabled firmware.** `build-firmware-x86.sh`
now flips `CONFIG_FSYS_FAT=true`; after that rebuild, a FAT disk loads like ext2:

```console
$ ./build-firmware-x86.sh              # (enables FAT, then)
$ ./smoke-client.sh x86 hello disk-fat
PASS: revived OpenBIOS-x86 loaded our C client 'hello' from a FAT hard disk and it answered Hello world! over the IEEE 1275 client interface
```

On a *stock-config* firmware a FAT image fails **silently** (`state-valid` stays
`0`, no error) — so `disk-fat`'s failure line hints at the rebuild. ext2 needs no
rebuild; FAT does.

The x86 success signature at the prompt, driven by hand:

```
0 > " /ide@1/cdrom@0:\hello" $load  ok
0 > go switching to new context:
Hello world!  --  an OpenBIOS client program, calling back into the firmware.
clib proof: 6 * 7 = 42, or in hex 0x2a
EXIT
1 >
```

Note x86 has no `boot cd:` shortcut for a client: `$load` then `go`. The load
line is long enough that the firmware's flow-control-free serial input drops
characters without `drive-pty-repl.py --echo-gate` — the smoke passes it.
Story of all six repairs: [POC-4](POC-4-X86-REVIVAL.md).

## Reproducer notes (the sharp edges)

- **Plain ISO9660, never RockRidge.** `genisoimage -R` makes OpenBIOS's `dir`
  die with `out of malloc memory` + `Stack Underflow`. The smoke builds a plain
  ISO (`-V CLIENT`, no `-R`) with an uppercase name.
- **The `.;1` version suffix is mandatory** at the prompt (`boot cd:\HELLO.;1`);
  the bare name gives `No valid state has been set by load or init-program`.
- **`boot cd:…`, not `-kernel`.** `-kernel` reaches `_start` but hangs — it's
  the raw-Linux path, and the client's memory is never `claim`ed/mapped. The
  device `boot` goes through OpenBIOS's own ELF loader, which maps it.
- **ppc console input needs a real terminal** (muxed stdio); a bare
  `-serial unix:` socket delivers nothing, so the smoke drives QEMU through
  `tools/drive-pty-repl.py` (the pty driver).
- **`x86 $load` stages, `go` runs** — two separate prompt commands; the editor
  only appears on `go`. And under the `-serial mon:stdio` mux, **`Ctrl-A` is
  QEMU's escape**, so type emacs's `C-a` as `Ctrl-A` `Ctrl-A` (see the x86
  emacs section above).
- **The prompt is `0 >`** (stack depth) and the default base is **hex** — same
  as the rival lab. Scripted checks anchor on the literal `Hello world!`, not on
  a number the firmware might print in hex.
- **`hello-ppc` links `_start` at the load base `0x01000000`** (linker script +
  `-ffunction-sections`); the firmware enters a `-kernel` at the base and
  `boot cd:` at `e_entry`, and pinning `_start` keeps both correct.
