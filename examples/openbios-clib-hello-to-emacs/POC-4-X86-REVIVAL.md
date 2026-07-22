# POC-4 — reviving the x86 client ABI (partial: fix #1 landed, load path open)

**Goal:** make the *same* C clients that run on ppc (POC-2, POC-3) run on x86 —
the capstone. **Result: PARTIAL, and honestly so.** The core ABI gap is fixed
in C and builds; a second, deeper x86 bug in the firmware's file-load path is
diagnosed but not yet cracked, so `smoke-client.sh x86` still `SKIP`s. This
page documents exactly what is done, what is not, and the two gotchas that made
the difference between "looks broken" and "is broken." Completing it is a
focused follow-up, not a claim this lab makes prematurely.

## The thinking

On ppc the client interface is the OS boot ABI, so it never rotted (POC-2). On
x86 it is a museum, and reviving it turns out to be *two* independent repairs:

1. **The firmware never hands a launched client the callback.** The dispatcher
   `of_client_interface()` (all 25 services) is compiled into the x86 image, but
   `arch/x86/context.c`'s `arch_init_program` sets up an elf-boot `eax`/`ebx` and
   *nothing else* — where ppc plants the callback in `r5`, x86 plants it nowhere.
2. **The firmware can't load a plain ELF from a device in the first place.** The
   generic `load` path leaves load-base empty, so there is nothing for a fixed
   client-entry to even enter.

Fix #1 is done. Fix #2 is the open blocker.

## Fix #1 — plant the client interface (DONE, builds)

x86 has no `r5`, so the five client-entry arguments go on the client's stack,
where its `_start(residual, entry, cif, args, argslen)` reads them. The context
gains 5 param slots and, for a plain-ELF client (file-type `elf`, not
`elf-boot`), `param[2]` is set to `&of_client_interface`
([`patches/00-x86-cif-plant.patch`](patches/00-x86-cif-plant.patch)). It builds
and installs cleanly (+64 bytes) — the exact x86 analog of ppc's one-liner. It
cannot be *demonstrated* yet only because fix #2 blocks getting a client loaded.

## Fix #2 — the file-load path (OPEN, diagnosed)

At the x86 prompt:

```
0 > load /ide@1/cdrom@0:\hello
 ok
0 > load-base l@ u. 0            \ nothing was read to load-base
0 > state-valid @ u. 0           \ so `go` has nothing to run
```

Instrumenting the firmware (rebuild, boot, read the trace) showed the load
reaches **none** of the loaders you'd expect — not `dlabel_load`
(`packages/disk-label.c`), not `iso9660_files_load` (`fs/iso9660/iso9660_fs.c`),
not the generic `load()` (`libopenbios/load.c`). Yet a *direct* `open-dev` on
the very same path returns a valid ihandle. The divergence lives somewhere in
the disk-label → `interpose` → filesystem-package wiring, and it has not
surrendered to a quick fix. (The earlier spike's guess — an
`if (type != FILE) PUSH(...)` missing a `return` in the iso9660 methods — is a
real latent defect but is *not* what bites here, because those methods are never
reached.)

## The two gotchas (why "broken" was hard to see)

These cost the most time and are the transferable lesson of this POC:

- **On x86 multiboot, `printk` and the banner go to the VGA path, not the
  serial.** The interactive `0 >` prompt, command echo, and `.`/`u.` output are
  on serial (that is what you drive), but firmware `printk` is not — so the first
  instrumented builds printed their debug into the void. Switch firmware debug to
  **`forth_printf`** (the forth console = serial) to see it. Corollary, and the
  good news for the eventual fix: a *client's* `write` goes through `/chosen`
  stdout, which **is** the serial — so once a client loads, its output will show
  up exactly where the smoke looks for it.
- **The serial console drops characters on long input lines** (no flow control).
  A one-line colon definition of any length arrives corrupted (`load-base` came
  through as `lo` → "undefined word"), which makes interactive forth tracing
  unreliable. Keep probes to short commands, or drive with deliberate pacing;
  don't trust a long `: t … ;` you typed at the prompt.

## Why defer (the scope call)

Fix #2 is genuine firmware archaeology in a 2003-era x86 load path that no one
has exercised for loading a plain client since the zImage era. That is a focused
session of its own — worth doing right, not worth faking. The honest state is:
**the client ABI is revived (fix #1); the file-load that would feed it is the
remaining capstone work.** `smoke-client.sh x86` `SKIP`s with a pointer here
until it is green. Everything on ppc (POC-2, POC-3) is unaffected and remains
the working proof that the mechanism is real.

## Pitfalls checklist

- x86 `printk` → VGA; use `forth_printf` for serial-visible firmware debug.
- Long serial input drops chars — short probes only.
- A client's `write` → `/chosen` stdout → **serial** (so the smoke's grep will
  work once a client loads).
- `open-dev` succeeding is *not* proof the `load` word will load — they diverge
  on x86, and that divergence is fix #2.
- Don't ship the x86 track green until a client actually prints on serial; a
  built firmware is not a working one.
