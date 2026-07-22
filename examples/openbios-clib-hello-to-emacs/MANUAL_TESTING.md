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

## 2. Phase-1 smoke — ppc hello (one verdict)

```console
$ ./smoke-client.sh ppc
  - booting stock qemu-system-ppc + our client CD, driving boot cd:\HELLO.;1 → …/smoke-client-ppc.log
PASS: OpenBIOS-ppc loaded our C client and serviced its write() over the IEEE 1275 client interface (Hello world!)
```

Runtime ≈ 15–25 s. `SKIP` (77) if `python3`, `qemu-system-ppc`, or
`genisoimage` is absent; the smoke auto-builds `hello-ppc` if missing.

The client's own output, from `smoke-client-ppc.log`:

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
back. All of it is the IEEE 1275 client interface firing on a real machine.

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
