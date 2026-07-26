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

Increment 1 status: **5 PASS on sparc32, 4 PASS + 1 justified SKIP on ppc.**

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

- **Tracers.** Blocked on there being no hook to re-point. Two candidate routes,
  and they are *not* alternatives to the `ofscope` item below — that one is a
  different vocabulary entirely and would land no tracer:
  - **Implement `patch` (7.5.3.3).** OpenBIOS stubs it out, so the honest path is
    to write it in Forth over the dictionary `see` already walks (~10 lines):
    scan a colon definition's body for an xt and replace it. **Not
    per-architecture** — OpenBIOS's dictionary format is the same across its
    targets, so one implementation serves both tracks. This would be the first
    thing in this family that is **upstream-contributable Forth** rather than a
    lab-local vocabulary, and it belongs to its own increment.
  - **Redefine `boot` — UNTESTED hypothesis.** `auto-boot?` runs
    `boot-command evaluate` (`forth/system/main.fs`), and `evaluate` resolves the
    word **by name at run time**. So a redefinition of `boot` may intercept the
    power-on autoboot with no dictionary surgery at all. It would *not* catch
    `$load`, which is called from inside an already-compiled body and holds the
    old xt. Worth one boot to check before committing to the `patch` route.
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
