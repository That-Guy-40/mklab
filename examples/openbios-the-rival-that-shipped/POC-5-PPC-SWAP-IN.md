# POC-5 — you compiled the firmware your emulator ships

**Goal:** build our own `openbios-ppc` and prove QEMU boots *ours*, not its
bundled blob. **Result: PASSED.** The cheapest spike and the most satisfying:
no bugs, just a build-date banner that closes the loop the whole lab has been
drawing.

## The thinking

Every other track here is x86, where OpenBIOS's paths had rotted (POC-2, -4).
PowerPC is the opposite: it's the arch QEMU exercises on every boot, so it
*works* — which makes it the perfect place to demonstrate the lab's headline
claim materially rather than rhetorically. `/usr/share/qemu/openbios-ppc` on
this host is built from this exact repo. If we build the `qemu-ppc` target
(POC-1) and pass it with `-bios`, QEMU runs our compile instead of its own.
The proof is the one thing that differs between two builds of the same
source: the **timestamp** the banner bakes in.

## The one input quirk (why this needs the pty tool)

OpenBIOS-ppc's console input works on QEMU's **muxed stdio** (`-nographic`)
but **not** on a bare `-serial unix:` socket — a finding inherited verbatim
from the OFW lab's OpenBIOS teaser (its MANUAL_TESTING §6). So `drive-serial-
repl.py` can't type here; it can only watch. This spike is what motivated
extracting **`tools/drive-pty-repl.py`** — its sibling that forks the target
onto a real pty and converses there. (The pty tool had its own birth bug: an
argparse `REMAINDER` positional greedily swallowed the `--expect`/`--send`
flags, so every run "passed" in zero steps while the child exec'd `--timeout`.
Fixed by splitting on `--` by hand and failing loudly on empty steps — the
kind of bug that hides *inside a passing test*, which is worse than a failing
one.)

## The live commands

```console
$ ./build-openbios.sh ppc        # switch-arch qemu-ppc && make → obj-ppc/openbios-qemu.elf
$ strings obj-ppc/openbios-qemu.elf         | grep -m1 'OpenBIOS 1'   # OpenBIOS 1.1 [%s]
$ strings /usr/share/qemu/openbios-ppc      | grep -m1 'OpenBIOS 1'   # OpenBIOS 1.1 [%s]  — same source
```

Same format string; the `%s` is filled at runtime with `__DATE__ __TIME__`.
Boot each and read the filled banner:

```console
$ python3 tools/drive-pty-repl.py drive-ppc.log --timeout 60 \
    --expect "Welcome to OpenBIOS" --expect "0 > " --send '3 4 + .\r' --expect "7 " \
    -- qemu-system-ppc -bios obj-ppc/openbios-qemu.elf -nographic -vga none
```

```
OURS:   Welcome to OpenBIOS v1.1 built on Jul 21 2026 07:09
DISTRO: Welcome to OpenBIOS v1.1 built on Apr 22 2026 09:24     (qemu-system-ppc, no -bios)
0 > 3 4 + . 7  ok
```

Two different build dates, same source tree, same `3 4 + . → 7`. The firmware
QEMU shipped, recompiled by us and swapped in — and it still answers.
`smoke-openbios.sh ppc` bakes this comparison into a verdict (and a
`REGRESSION:` guard that fails if the two dates ever match, which would mean
the `-bios` swap silently didn't take).

## Why stop here (the scope call)

The plan deliberately capped the ppc track at swap-in + prompt. Booting a full
OS on ppc under our firmware would mean sourcing a 32-bit PowerPC kernel —
Debian dropped the port, so it's a real sub-project — for a demonstration the
x86 tracks already make (POC-4). The "money shot" is that the banner is ours;
a ppc Linux boot would be a different lab. Documented as a natural follow-on,
not smuggled in half-done.

## Pitfalls checklist

- ppc console input needs muxed stdio; a `-serial unix:` socket receives
  nothing. Use the pty driver.
- The banner date is `__DATE__`-baked — that's the whole proof; don't
  `strip`-normalize builds or the distinction vanishes.
- Compare against the *running* distro blob's banner (boot it), not a
  `strings` grep — the date is assembled at runtime, not stored as one literal.
- The sparc targets build too, but this host has no `qemu-system-sparc*`; the
  RUNBOOK mentions them as an aside, and the lab claims nothing it can't run.
