# POC-2 — the firmware runs your C program (ppc)

**Goal:** prove the shipped OpenBIOS client interface actually enters a
freestanding C client and services its `write`. **Result: PASSED.** A C
program, loaded from a CD by the *stock* `qemu-system-ppc` firmware, printed to
the console by calling *back* into that firmware — no operating system anywhere.
This is the whole lab's thesis in one line.

## The thinking

PowerPC is where the client interface is *supposed* to work, because on ppc the
client interface **is** the OS boot ABI — it's how yaboot, and Linux, and the
BSDs get entered. `arch/ppc/qemu/context.c`'s `arch_init_program` says so
outright, per the IEEE 1275 PPC binding:

```c
/* r5 = client interface handler */
ctx->regs[REG_R5] = (unsigned long)of_client_callback;
```

So a plain C `_start(residual, entry, client_interface_handler, ...)` receives
the callback in `r5` and can immediately turn around and call the firmware.
`of1275.c`'s `_start` does exactly that: `of1275_server = client_interface_handler`,
then `main()`. If this works, the mechanism is real and the lab is viable. It
does — the only friction is *how you hand the firmware the file*.

## The load path, the hard way (three findings)

Getting the client into the guest and run took pinning down three sharp edges,
all now baked into `smoke-client.sh`:

1. **Plain ISO9660 — not RockRidge.** A `genisoimage -R` disc makes OpenBIOS's
   `dir` blow up:

   ```
   0 > dir cd:\  >> out of malloc memory (fc9c824)!  Stack Underflow.
   ```

   Drop `-R`; a plain ISO9660 with an uppercase 8.3 name is read fine.

2. **The `.;1` version suffix is mandatory.** ISO9660 stores `HELLO` as
   `HELLO.;1`. Without the suffix the firmware finds nothing and `go` reports
   no state; *with* it, the file loads:

   ```
   0 > boot cd:\HELLO         No valid state has been set by load or init-program
   0 > boot cd:\HELLO.;1      >> switching to new context:  ...
   ```

3. **`boot`, not `-kernel`.** `qemu-system-ppc -kernel <client>` loads the bytes
   and even jumps to `_start`, but then hangs: `-kernel` is the raw-Linux path,
   which drops the image at a physical address the firmware never `claim`ed or
   mapped for a client. `boot cd:…` goes through OpenBIOS's own ELF loader,
   which claims/maps the region and enters via the client interface. Use the
   device.

## The live command + transcript

```console
$ ./smoke-client.sh ppc
  - booting stock qemu-system-ppc + our client CD, driving boot cd:\HELLO.;1
PASS: OpenBIOS-ppc loaded our C client and serviced its write() over the IEEE 1275 client interface (Hello world!)
```

Inside the log — the client's own output, arriving over the callback:

```
0 > boot cd:\HELLO.;1  >> switching to new context:
Hello world!  --  an OpenBIOS client program, calling back into the firmware.
clib proof: 6 * 7 = 42, or in hex 0x2a
EXIT
1 >
```

Three things worth noticing. **"switching to new context:"** is the firmware
handing control to our `_start`. The **"clib proof"** line means `put_udec` and
`put_hex` — our whole "standard library" — round-tripped through the firmware's
`write` service and came back right. And **`EXIT` → `1 >`**: `main` returned,
`_start` called `of1275_exit`, the firmware took control back and reprinted its
prompt (now at stack depth 1). A clean out-and-back through the client
interface. (ppc console input rides the muxed stdio, not a socket — so the
smoke drives it through `tools/drive-pty-repl.py`, the pty driver the rival lab
extracted.)

## Why this is the easy arch (and what x86 will cost)

ppc works because its client entry-glue was never allowed to rot — QEMU boots
it constantly. x86 is the opposite: the `of_client_interface` dispatcher is
compiled in but **handed to no one** (`arch/x86/context.c` never sets it up),
and two more x86-only paths are bitrotted on top. That's Phase 3 — the revival
capstone, now done — all six repairs in
`patches/01-x86-client-revival.patch` (POC-4). The satisfying
part of the lab is watching the same `hello.c` that just ran on ppc come alive
on x86 once the firmware is fixed to hand it the callback.

## Pitfalls checklist

- Plain ISO9660 only; `-R` (RockRidge) crashes the firmware's `dir`.
- The `.;1` ISO9660 version suffix is required at the prompt.
- `boot cd:…`, never `-kernel`, for a client (mapping/claim).
- ppc console input needs a real terminal (muxed stdio); a `-serial unix:`
  socket receives nothing — drive it with the pty tool.
- The banner/prompt is `0 >` (stack depth) and the default base is hex — same
  as the rival lab; scripted checks stay base-agnostic (`Hello world!`, not a
  computed number the firmware might print in hex).
