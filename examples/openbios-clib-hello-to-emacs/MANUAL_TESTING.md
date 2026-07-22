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

## 4. x86 track (Phase 3 — not yet)

```console
$ ./build-client.sh x86 hello     # builds fine (Intel 80386 EXEC)
$ ./smoke-client.sh x86
SKIP: x86 client track needs the firmware revival (Phase 3) — see PLAN.md / patches/00-x86-cif-plant.patch
```

The x86 binary compiles today; it only *runs* once the firmware is fixed to
hand a client the callback. That revival is the lab's capstone — fix #1 is
`patches/00-x86-cif-plant.patch`; see [PLAN.md](PLAN.md) §Phase 3.

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
- **The prompt is `0 >`** (stack depth) and the default base is **hex** — same
  as the rival lab. Scripted checks anchor on the literal `Hello world!`, not on
  a number the firmware might print in hex.
- **`hello-ppc` links `_start` at the load base `0x01000000`** (linker script +
  `-ffunction-sections`); the firmware enters a `-kernel` at the base and
  `boot cd:` at `e_entry`, and pinning `_start` keeps both correct.
