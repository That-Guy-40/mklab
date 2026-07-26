# PLAN.md — roadmap, increments, and the assumptions that died

Design rationale, thesis selection and the spike-0 results live in the root
[`OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md`](../../OPEN_FIRMWARE_NATIVE_HABITATS_LAB_PLAN.md).
This file tracks what has actually been built.

## Increment log

| # | what landed | verified by |
|---|---|---|
| 1 | `dsl/ofdiag.fth` — the diagnosis ladder, ported to OpenBIOS + a rung for device arguments | `smoke-habitat.sh ladder {sparc32,ppc}` |
| 1 | delivery: NVRAM (both tracks), media (sparc32) | `smoke-habitat.sh {nvramrc,media}` |
| 1 | the persistence asymmetry, both arms | `smoke-habitat.sh persist {sparc32,ppc}` |
| 1 | the 80-column console wall | `smoke-habitat.sh console {sparc32,ppc}` |
| 1 | `minify-fth.py`, `stage-dsl.sh`, `run-habitat.sh`, `lib-habitat.sh` | `stage-dsl.sh` |
| 2 | `dsl/patch.fth` — **IEEE 1275 7.5.3.3 implemented**, which OpenBIOS ships as `: patch ;`. Walks a colon body item-by-item so inline data (branch targets, literals, counted strings) is stepped over rather than scanned | `smoke-habitat.sh patch sparc32` |
| 2 | `dsl/tracers.fth` — boot tracers built on it, rewriting call sites the firmware provides no hook for; `untrace` is the same patch reversed | `smoke-habitat.sh autotrace {sparc32,ppc}` |
| 2 | the power-on autoboot traces itself, armed from NVRAM pre-probe | `smoke-habitat.sh autotrace` |

Status: **7 PASS on sparc32, 5 PASS + 2 justified SKIP on ppc.** ([PATCH.md](PATCH.md)
is the increment-2 write-up.)

## Assumptions this lab's own plan got wrong

Recorded in the same spirit as the sibling's list, because all four were
discovered *by running the thing*:

1. **"NVRAM is writable on both tracks — that is the result that matters."**
   (Root plan §2c, §5, §5c.) True in-session on both; **false across a reset on
   sparc32**, which is the only sense that matters for a delivery mechanism.
   `setenv` writes the in-memory `/options` property; flushing to the chip needs
   the `/nvram` package's `update-nvram` method, and `drivers/obio.c` never
   binds it on sun4m.

2. **"11 of 11 debugging words present."** (Root plan §5, question 1.) The
   tick-probe idiom `' <word> .` proves a *name resolves*. `see patch` shows
   `: patch ;`. Eight audited words are empty stubs. The x86 lab learned that
   this idiom **under**-reports at a root prompt; here it **over**-reports.
   Same idiom, opposite failure.

3. **"`.calls` · `patch` · `ctrace` — present"** (root plan §3 table, sourced by
   grepping the tree). Being *in* `forth/debugging/` and being *implemented* are
   different things.

4. **"the `ofdiag` tracers are `unknown` — depends on OpenBIOS declaring
   equivalent `defer` hooks."** (Root plan §6.) Settled: it declares **none** on
   the boot path. Not adaptable; would have to be built.

5. **A fifth ladder rung was not anticipated at all.** Native `boot-device`
   entries carry device arguments (`disk:a`, `hd:,\ppc\bootinfo.txt`), so alias
   lookup must split the head off first or everything misreports as OFDIAG-1.

## Deliberately not done yet

Listed so nobody mistakes absence for oversight. The sibling grew from three
verdicts to eight modes across ten PRs; this one picks its next step
deliberately.

- ~~**Tracers.**~~ ✅ **DONE in increment 2** via the `patch` route — see
  [PATCH.md](PATCH.md). It came in at ~90 lines rather than the ~10 estimated
  above, because stepping over inline data is most of the work. The second
  candidate route (**redefining `boot`**, on the theory that
  `boot-command evaluate` resolves by name at run time) was never needed and
  remains untested; it would in any case not have caught `$load`, which is
  called from an already-compiled body.
- **`.calls` (7.5.3.1), also a stub.** Now cheap: "which words' bodies mention
  this xt" is `patch`'s dictionary walk run over every word instead of one. The
  natural increment 3.
- **Send `patch` upstream.** It is written to be sendable — no lab-specific
  assumptions, no arch conditionals, and it shadows rather than replaces the
  stub, so a real fix means editing `forth/debugging/firmware.fs`. Nobody has
  filed it.
- **`ofscope` port** (independent of the tracers above — the *other* vocabulary
  from the x86 lab: memory and device exploration).
  `pci-map` needs `config-l@`, which OpenBIOS does not have;
  and sun4m is SBus, where PCI config space has no meaning. The PPC track has a
  real PCI tree (`pci@80000000`) and is the natural home. `mem-map` and
  `region-diff` should port on both — `/memory`, `decode-int` and `alloc-mem`
  all exist.
- **The SBus FCode track.** `Probing SBus slot 4 offset 0 / Invalid FCode start
  byte` runs on **every** sun4m boot, so FCode option ROMs have a native home
  here rather than the bolted-on PCI card the x86 lab had to build. `toke` and
  `detok` are already built by the rival lab.
- **`mac99` (New World) and `sparc64`.** Only `g3beige` and `sun4m` have been
  driven. sparc64 is interesting precisely because it is the one SPARC with PCI,
  and `arch/sparc64/openbios.c` *does* define `arch_nvram_put` — so its
  persistence answer may differ from sun4m's. Unprobed.
- **OBP diagnostics** (`test-all`, `probe-scsi`, `watch-net`) — thesis C from
  the root plan. `secmode-config` exists, so `security-mode` is at least
  present; nothing else has been checked. Given finding #2 above, check with
  `see`, not with `'`.

## Standing bias, updated

The root plan records: *"the firmware was more capable than assumed, every
time."* That held three times in the sibling lab. **In this lab it inverted
three times in one session** — every over-estimate came from a check that
confirmed a *name* or a *tree entry* rather than a *behaviour*.

The rule that covers both: **do not let the cheap check stand in for the real
one.** `'` is not `see`. `printenv` in-session is not `reset-all`. A printed
banner is not a dictionary entry.
