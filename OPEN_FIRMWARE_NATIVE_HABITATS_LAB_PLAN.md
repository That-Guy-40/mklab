# Open Firmware's Native Habitats — Design Plan v2

> **v2 (2026-07-26): merged.** This was the SPARC/OpenBoot plan. A spike 0 on
> **PowerPC** then showed it is mechanically near-identical to SPARC, so the two
> are **one lab with two tracks** — Sun and Apple — rather than two labs.
> `PPC_OPENFIRMWARE_LAB_PLAN.md` is folded in here and removed.

> **Status**: Draft v1 — proposed 2026-07-26, immediately after
> [`examples/open-firmware-debugs-itself/`](examples/open-firmware-debugs-itself/README.md)
> landed (PRs #59–#69). This would be the **fourth** lab in the IEEE 1275 family
> and the first on the architecture where Open Firmware actually shipped in
> production for two decades.
>
> **Decisions locked (this session):**
> - **TWO TRACKS, ONE LAB: Sun SPARC + Apple PowerPC.** Both are places Open
>   Firmware actually shipped, both spiked green, and both share a mechanism
>   (see [§2c](#2c-why-sparc-and-ppc-are-one-lab-locked)). The comparison between
>   them is the lab's centrepiece, not an appendix.
> - **This is its OWN LAB — a sibling, not a track inside an existing one.** It
>   gets its own `examples/` directory, README, smokes and catalog entries. See
>   [§2b](#2b-why-its-own-lab-locked) for why, which spike 0 has since reinforced.
> - **Spike 0 runs first, before any lab structure is committed.** That pattern
>   has now paid for itself twice in this family — it retired the "2015 tree vs
>   modern toolchain" terror in the OFW lab, and it overturned three of the
>   debugs-itself plan's own assumptions.
> - **The lab is OpenBIOS-on-SPARC, and says so plainly.** Sun's OpenBoot is
>   proprietary and cannot be built or shipped; see the naming trap below.
>
> **✅ SPIKE 0 IS GREEN ON BOTH TRACKS** (2026-07-26 — SPARC [§5](#5-spike-0--result-green),
> PPC [§5c](#5c-spike-0-ppc--result-green)). **NVRAM is writable on both**, which is
> the result that matters: the x86 lab's two open limitations become demonstrable
> here, on either track.
>
> **✅ BUILT — increment 1 has landed** as
> [`examples/open-firmware-native-habitats/`](examples/open-firmware-native-habitats/README.md)
> (5 PASS on sparc32, 4 PASS + 1 justified SKIP on ppc). ⚠️ **Building it
> falsified four of this plan's own claims** — the NVRAM line immediately above
> among them. Each is corrected in place below and listed together in the lab's
> [PLAN.md](examples/open-firmware-native-habitats/PLAN.md#assumptions-this-labs-own-plan-got-wrong).
> Every one came from a check that confirmed a *name* or a *tree entry* rather
> than a *behaviour*.

## 1. Why — and why now

The family currently has three labs, all on x86/ppc:

| lab | what it is |
|---|---|
| [`open-firmware-forth-to-boot/`](examples/open-firmware-forth-to-boot/README.md) | Bradley's **OFW**, frozen Dec 2015 — the `ok` prompt, fixed live |
| [`openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/README.md) | **OpenBIOS**, the maintained reimplementation — QEMU's ppc/sparc default |
| [`openbios-clib-hello-to-emacs/`](examples/openbios-clib-hello-to-emacs/README.md) | **client programs** — C binaries calling the firmware back |
| [`open-firmware-debugs-itself/`](examples/open-firmware-debugs-itself/README.md) | a **Forth DSL** for boot forensics, memory, and FCode reverse engineering |

All four run Open Firmware somewhere it was a curiosity. **This lab goes where it
shipped** — two places, in fact. **Sun** put an `ok` prompt on every SPARC box for
two decades, and **Apple** shipped Open Firmware on every PowerMac from 1994 to
the Intel transition, reachable by holding **Cmd-Opt-O-F** at the chime. Device paths look like the real thing, `boot
disk:a` / `boot net` mean what the manuals say, and FCode option ROMs on SBus and
PCI cards were a shipping product, not a lab exercise.

## 2. The naming trap (a third one for the family)

The family already teaches **OFW ≠ OpenBIOS**. This adds **OpenBIOS ≠ OpenBoot**:

- **OpenBoot** — Sun's (now Oracle's) proprietary IEEE 1275 firmware. Shipped on
  SPARC hardware for ~20 years. **Cannot be built or redistributed**; obtainable
  only as ROM images off real machines. This lab does not use it.
- **OpenBIOS** — the independent open reimplementation of the same standard, and
  **what `qemu-system-sparc` boots**. This is what the lab builds and drives.
- **Apple's Open Firmware** — the ROM in a real PowerMac. Also proprietary, also
  unobtainable. The PPC track runs OpenBIOS on Apple-modelled machines
  (`g3beige`, `mac99`), which reproduces Apple's *device tree and boot policy*
  without being Apple's code.
- **OFW** — Bradley's original. **Has no SPARC support at all**: its `cpu/` tree
  is `arm i8051 mips ppc x86`. So this cannot be a port of the debugs-itself
  lab's firmware; it is a port of its *vocabularies*.

The lab must be explicit that the `ok` prompt it shows is *standards-identical*
to the one on a Sun box, and *not* Sun's code.

## 2b. Why its own lab (LOCKED)

**A fifth sibling in `examples/` — now covering two architectures — not a third
flavor bolted onto
[`open-firmware-debugs-itself/`](examples/open-firmware-debugs-itself/README.md).**

The family grows by siblings and always has: the OFW lab spawned the rival lab,
which spawned the clients lab, which spawned debugs-itself. Each time the reason
was the same — a genuinely different thesis deserves its own front door rather
than another flag on someone else's.

Spike 0 turned that from a stylistic preference into a technical one. This is not
"the same lab with `sparc` added to the flavor list":

| | debugs-itself (emu / coreboot) | this lab |
|---|---|---|
| firmware | **OFW** (Bradley's, frozen 2015) | **OpenBIOS** (maintained, C-hosted Forth) |
| console | serial **socket** works | **pty only** — `-serial unix:` gives *zero bytes* |
| prompt | `ok` | `0 >` (stack depth) |
| bus | PCI | **SBus** (sparc32) / PCI (sparc64) |
| NVRAM | **dead** — `setenv` fails | **works** — `setenv` sticks |
| vocabularies | native | **port as a design, not verbatim** — same names, different stack effects |

Every one of those rows breaks an assumption baked into the sibling's scripts.
`smoke-dsl.sh`'s `boot_and_drive` hardcodes a serial socket and `--expect "ok"`;
its `PREFIX` mechanism assumes a flavor differs only by media path and one repair.
Making it absorb a pty-driven, `0 >`-prompted, differently-implemented firmware
would mean rewriting the harness around a case that shares almost nothing — and
would blur a lab that already grew from three verdicts to eight modes across ten
PRs.

**Consequences of the lock:**
- Its own `examples/<name>/` with README · RUNBOOK · MANUAL_TESTING · PLAN, its
  own smoke script, its own vocabularies (adapted, not copied).
- Its own 00-INDEX row and `learning-paths` step (see [§8](#8-routing-at-assembly-not-before)).
- **Cross-links both ways**, the way this family always does: the debugs-itself
  README gains a "the same DSL, on the architecture where it shipped →" pointer,
  and this lab's README credits the vocabularies' origin and links back.
- **Name candidate:** `openbios-the-native-habitats` (alternatives:
  `openbios-where-it-shipped`, `open-firmware-native-habitats`) — plural, because
  it is two tracks now. Settle at assembly, exactly as
  `open-firmware-debugs-itself` was.

What it explicitly does **not** mean: no forking of the sibling's scripts for the
sake of it. Anything genuinely general — the smoke shape, the `--echo-gate`
doctrine, `check-oracle.sh`'s inside-vs-outside pattern — gets *reused* or, if it
proves reusable a third time, promoted to `tools/` the way
[`drive-pty-repl.py`](tools/drive-pty-repl.py) was.

## 2c. Why SPARC and PPC are one lab (LOCKED)

§2b argues this lab is not a *flavor of the x86 one*, because every axis differs.
Applying that same test to **SPARC vs PPC** gives the opposite answer, so they
belong together:

| | SPARC (sun4m) | PPC (g3beige) |
|---|---|---|
| firmware | OpenBIOS 1.1 **stock blob** | OpenBIOS 1.1 **stock blob** |
| console | **pty only** | **pty only** |
| prompt / base | `0 >` / hex | `0 >` / hex |
| NVRAM `setenv` | ⚠️ **in-session only** — see below | **works, and persists** |
| `boot-device` | **a list** | **a list** |
| bus | SBus (no PCI) | PCI + mac-io |
| idiom | Sun | Apple |

They differ in **topology and idiom**, not in **mechanism**. Everything the
harness cares about — how you drive the console, what the prompt looks like,
whether NVRAM works — is identical. One harness, one set of adapted vocabularies,
a `--track` argument, exactly the shape `smoke-dsl.sh` already uses for flavors.

**And the comparison is the payoff.** The same `why-no-boot` question has three
shapes across the family, and all three defaults are **lists** — precisely the
structure that word walks:

| | `boot-device` default | device idiom |
|---|---|---|
| **x86** (the sibling lab) | `disk net` | `/pci/pci-ide@1,1/ide@1/cdrom@0` |
| **SPARC** | `disk:a disk` | SBus; `/iommu/sbus/…` |
| **PPC** | `hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT` | `/pci@80000000/mac-io@10/…`, ADB, CUDA, ESCC |

Splitting that across two labs would bury the best thing the evidence supports.

## 3. Verified feasibility (checked 2026-07-26, before writing this)

**The introspection toolkit the DSL depends on exists in OpenBIOS.** This was the
main risk — OpenBIOS is a C-hosted Forth kernel and could have been too minimal.
It is not; there is a whole `forth/debugging/` tree:

| word | source |
|---|---|
| `see` | `forth/debugging/see.fs` — a real decompiler |
| `debug` | `forth/debugging/fcode.fs`, `forth/debugging/firmware.fs` |
| `words` | `forth/lib/vocabulary.fs` |
| `.calls` · `patch` · `ctrace` | `forth/util/util.fs` · `debugging/firmware.fs` · `debugging/client.fs` |
| **`nvramrc`** | **`forth/admin/nvram.fs`** + `forth/system/main.fs` |

> ⚠️ **This table over-reports, and the row above is the one that is wrong.**
> It was built by grepping the tree. `.calls` and `patch` are **empty stubs** —
> `: .calls ( xt -- ) ;` at `forth/debugging/firmware.fs:30`, confirmed from the
> running firmware with `see`. So are `dl`, `$sift`, `sifting`, and all five
> `nvedit`/`nvstore`/`nvquit`/`nvrecover`/`nvrun` script-editor words. `see`,
> `words`, `dump`, `debug` and `nvramrc` are real. **Being in
> `forth/debugging/` and being implemented are different things.**

**NVRAM is implemented for both SPARC targets** (`arch/sparc32/openbios.c`,
`arch/sparc64/openbios.c`), and `config/scripts/switch-arch` offers
`sparc sparc32 sparc64`.

> ⚠️ **Also wrong, in the sense that matters.** The *chip* is emulated and the
> Forth side exists, but on sun4m nothing binds the two: `drivers/obio.c:168`
> builds a bare `/obio/eeprom` node and never calls `nvram_init()`, so there is
> no `update-nvram` method to flush a `setenv` with, and the write is lost at
> reset. Apple gets the binding via `drivers/macio.c`. See the lab's
> [DELIVERY.md](examples/open-firmware-native-habitats/DELIVERY.md).

**The emulator is packaged but not installed** — `qemu-system-sparc` /
`qemu-system-sparc64`, candidate `1:8.2.2+ds-0ubuntu1.17`.

### Why the NVRAM line is the interesting one — ⚠ REVISED, the original argument is dead

**This argument no longer holds, and the honest thing is to say so rather than
quietly restate it.** The plan originally read:

> The debugs-itself lab shipped with two documented limitations, and both are
> NVRAM-shaped: `nvramrc` is **dead on the x86 emu build**, and the **warm-reboot
> path is unreachable** there. If NVRAM works on SPARC, a sibling lab can
> demonstrate both — turning two "correct by reading, unprovable by running" notes
> into runnable verdicts. *That is the single strongest argument for building this.*

Both premises turned out to be **false**, and the x86 lab has since closed both
itself (see
[`NVRAM-ON-X86.md`](examples/open-firmware-debugs-itself/NVRAM-ON-X86.md)):

- NVRAM was never missing. `cpu/x86/basefw.bth:58` floads the entire confvar
  stack; only the backing store was unbound. `\ create pseudo-nvram` was
  **commented out**, one line away, deliberately and with a written rationale.
- `nvramrc` now **executes at startup** on x86, and a **real warm reboot is
  traced**. Closing the second one also needed a *second, independent* fix —
  emu's own `startup` never calls `copy-reboot-info` — which had nothing to do
  with NVRAM at all.

So "only a SPARC sibling can demonstrate these" is simply not true any more.

**What survives, and it is a better argument.** The distinction is not *whether*
these mechanisms can be demonstrated, but whether they are **native**:

| | SPARC / PPC | x86 emu |
|---|---|---|
| NVRAM | a **real device** — SPARC NVRAM/TOD chip, PPC `nvram@60000` | a **file on an attached floppy** |
| availability | present at power-on, always | opt-in build switch, upstream ships it **off** |
| upstream's view | the normal case | *"not particularly useful for real hardware platforms"* — Bradley, `config.fth` |
| cost to reach it | none | 3 source edits, a rebuild, an isolated ROM, `-fda` |

That is the same shape as the EFI comparison the x86 lab landed on: UEFI keeps
variables in an **SPI-flash region** (QEMU's `OVMF_VARS.fd` is *pflash*), the same
species of device as SPARC's and PPC's. **OFW-on-x86 is the odd one out** — the
only one of the four borrowing a filesystem because the platform gives firmware no
NV region it can own.

So the sibling lab's case rests on **native vs. bolted-on**, plus the topology and
idiom differences already locked in §2b/§2c — not on a capability gap that no
longer exists. Weaker than the original claim, and true, which the original was
not.

## 4. The open decision — which thesis

Not chosen. Spike 0 is designed to decide it.

### A · "The native habitat" — *provisionally favoured*
Port the vocabularies to prove **a Forth DSL travels across implementations**, and
exploit working NVRAM to demonstrate what the x86 lab could only reason about:
`nvramrc` running before autoboot, and a warm reboot actually traced. Authentic
device paths and `boot disk:a` / `boot net` throughout.
*Strongest if spike 0 shows NVRAM writable and `see`/`debug` usable.*

### B · "Two buses, one standard"
Make **sparc32 (SBus) vs sparc64 (PCI)** the spine. Forces an SBus walker
alongside `pci-map` and makes bus divergence the lesson.
*Strongest if `see`/`debug` disappoint but the device trees are rich — the lab
then leans on `ofscope` rather than on introspection.*

### C · "OpenBoot archaeology"
Lead with the Sun-era operator experience: OBP diagnostics (`test-all`,
`probe-scsi`, `watch-net`), `security-mode`, the banner, FCode on SBus cards.
*Richest historically, but depends on OpenBIOS implementing those OBP extensions
— entirely unverified, and the most likely to disappoint.*

## 5. Spike 0 (SPARC) — RESULT: **GREEN**

Run 2026-07-26 against the **stock** QEMU blob (`/usr/share/qemu/openbios-sparc32`,
OpenBIOS v1.1 built Apr 22 2026) — no firmware build required. First contact:

```text
Probing SBus slot 4 offset 0
Invalid FCode start byte              ← SBus FCode probing is LIVE
CPUs: 1 x FMI,MB86904
Welcome to OpenBIOS v1.1 built on Apr 22 2026 09:24
Trying disk:a...
0 >
```

| # | question | answer |
|---|---|---|
| 1 | word inventory | ~~**11 of 11 present**~~ — ⚠️ **over-reported.** The tick probe (`' <word> .`) proves a *name resolves*; `see patch` shows `: patch ;`. `.calls` and `patch` are stubs. The x86 lab found this idiom **under**-reports at a root prompt; here it **over**-reports. Same idiom, opposite failure. |
| 2 | **NVRAM writable?** | ~~**YES.**~~ ⚠️ **Half right.** `setenv` sticks *within the session* — but `printenv` reads back the in-memory `/options` property, so that is not evidence of non-volatility. Across a **reset**, sun4m loses it entirely; only Apple persists (and only via the `/nvram` package's `update-nvram` **method**). |
| 3 | console | **pty only.** `-serial unix:` yields **zero bytes** — no output at all, worse than the ppc input-only quirk. Use `-nographic` + [`tools/drive-pty-repl.py`](tools/drive-pty-repl.py). |
| 4 | prompt / base | prompt is **`0 >`** (stack depth); base is **hex** (`5 6 * .` → `1e`) — the same trap the OFW lab teaches. |

### The decisive result

```text
0 > setenv use-nvramrc? true  ok
0 > printenv use-nvramrc?
use-nvramrc?              "true"          ← it STUCK
0 > setenv boot-device disk:a  ok
boot-device               "disk:a"        ← was "disk:a disk"
```

No *"Out of NVRAM environment space"*, no *"Unimplemented package interface
procedure"* — the two failures that shaped the x86 lab. **Both of its documented
limitations become demonstrable here**, and `main.fs:42` already evaluates
`nvramrc` at startup, so pre-autoboot code needs no dropin at all.

### Bonus findings

- **The environment is authentically Sun.** `printenv` lists `boot-device
  "disk:a disk"`, `ttya-mode "9600,8,n,1,-"`, `output-device "ttya"`,
  `selftest-#megs`, `screen-#rows`, `tpe-link-test?` — the real OBP variable names.
- **SBus FCode probing runs at boot** (*"Probing SBus slot 4… Invalid FCode start
  byte"*), so the FCode track has a native home rather than a bolted-on PCI card.
- **`see` decompiles**, though more roughly than OFW's — control-flow indentation
  is mangled but the source is recoverable and readable.
- ⚠️ **Same names, different implementations.** OpenBIOS's `expand-alias` is built
  on `/aliases` + `find-dev` + `get-package-property` and has **different stack
  effects** from OFW's. The vocabularies therefore port **as a design, not
  verbatim** — which is a *better* lesson for the lab: a vocabulary is portable,
  its implementation is not. Budget adaptation, not copying.

### Gate decision → **thesis A, "the native habitat"**

Evidence-backed rather than chosen on taste: NVRAM works (A's payoff is real),
the introspection toolkit is complete (A's port is viable), and the environment
is authentically Sun (A's framing is honest). **B** stays available as a later
track once an SBus walker exists; **C** remains unverified — `secmode-config`
exists in `forth/admin/nvram.fs`, so `security-mode` is at least *present*, but no
OBP diagnostic (`test-all`/`probe-scsi`/`watch-net`) has been probed.

## 5b. Spike 0's original definition (kept for the record)

One or two boots of **stock** `qemu-system-sparc` (no build required — QEMU ships
an OpenBIOS blob), answering four questions:

1. **Word inventory.** Port [`probe-dictionary.sh`](examples/open-firmware-debugs-itself/probe-dictionary.sh)'s
   tick-probe idiom (`' <word> .` — looks up without executing, syncs on the
   prompt so a missing word cannot stall the drive). Confirm `see`, `debug`,
   `words`, `.calls`, `patch` are **in the dictionary**, not merely in the tree.
   ⚠️ Apply the correction that lab learned the hard way: a root-prompt probe
   **under-reports**; widen the search order before believing a negative.
2. **NVRAM writability** — the decisive one:
   ```
   ok " testval" " test-var" $setenv
   ok " test-var" $getenv
   ok printenv use-nvramrc?
   ```
   Writable ⇒ thesis **A**, and both x86 limitations become demonstrable.
3. **Console drivability.** OpenBIOS-ppc is known to take input on muxed stdio but
   **not** on a bare `-serial unix:` socket (found in the OFW lab, and why
   [`tools/drive-pty-repl.py`](tools/drive-pty-repl.py) exists). Determine which
   SPARC needs, and whether `--echo-gate` applies.
4. **Prompt shape and base.** OpenBIOS prompts `0 >` (stack depth), not `ok`.
   Every expect anchor in the ported vocabularies changes accordingly.

**Gate:** the answers pick the thesis and scope. A clean negative on NVRAM would
retire thesis A and is itself worth writing down.

## 5c. Spike 0 (PPC) — RESULT: **GREEN**

Stock blob (`/usr/share/qemu/openbios-ppc`, OpenBIOS 1.1 built Apr 22 2026),
default machine **g3beige** (Heathrow PowerMac, PowerPC,750). No build required.
The boot sequence announces the lineage by itself:

```text
>> CPU type PowerPC,750
Trying hd:,\\:tbxi...              ← Apple's BLESSED system file (HFS+ type 'tbxi')
Trying hd:,\ppc\bootinfo.txt...    ← the CHRP boot script
Trying hd:,%BOOT...
0 >
```

**NVRAM — writable**, same as SPARC:

```text
0 > printenv boot-device
boot-device   "hd:,\\:tbxi hd:,\ppc\bootinfo.txt hd:,%BOOT"
0 > setenv boot-device hd:,\\:tbxi  ok
boot-device   "hd:,\\:tbxi"                                    ← it STUCK
0 > setenv use-nvramrc? true  ok
```

The reason is visible in the tree: **NVRAM is a real device node** —
`nvram → /pci@80000000/mac-io@10/nvram@60000`.

**Device pathing — authentically Apple.** `dev / ls` gives a CHRP tree
(`pci@80000000`, `rom@ff800000`, `memory@0`); `/aliases` is PowerMac hardware:

| alias | path |
|---|---|
| `via-cuda` | `/pci@80000000/mac-io@10/via-cuda` — the CUDA power/ADB controller |
| `adb-keyboard` · `adb-mouse` | `…/via-cuda/adb/…` — **Apple Desktop Bus** |
| `nvram` | `/pci@80000000/mac-io@10/nvram@60000` |
| `ttya` · `scca` | `/pci@80000000/mac-io@10/escc/ch-a` — the Zilog **ESCC** |
| `cd` · `cdrom` · `ide0` | `/pci@80000000/mac-io@10/ata-3@21000/cdrom@0` |
| `mac-io` | `/pci@80000000/mac-io@10` — the Heathrow ASIC |

**PCI exists here**, unlike sparc32's SBus — so `ofscope`'s `pci-map` has a real
target on this track that the SPARC track cannot give it.

Console **pty only**, prompt **`0 >`**, base **hex** — identical to SPARC.
`' see .` and `' nvramrc .` both resolve. Curiosity for later: the firmware
prints **`milliseconds isn't unique.`** during startup — a redefinition warning
from its own boot.

⚠️ **Thesis-overlap constraint for this track.** Two labs already use ppc — the
[rival lab](examples/openbios-the-rival-that-shipped/README.md) as a **build**
story (it compiles `openbios-ppc` and proves the running blob is *ours*) and the
[clients lab](examples/openbios-clib-hello-to-emacs/README.md) as a
**client-interface** story. This track must stay a **device-tree, NVRAM and
boot-policy** story, or it has no reason to exist. `mac99` (New World) is
**unprobed**; only `g3beige` has been driven.

## 6. What ports, and what does not

| from the debugs-itself lab | portability |
|---|---|
| `ofdiag` diagnosis ladder | ✅ **DONE** — contracts are OFW-identical, so no `catch` is needed here either, and the `expand-alias` flag trap ports verbatim. Needed **one new rung**: native `boot-device` entries carry device *arguments*, so alias lookup must split the head off first |
| `ofdiag` tracers | ❌ **SETTLED: cannot port.** OpenBIOS declares **no `defer` on its boot path** at all — nothing in `$load`, `boot`, or around `open-dev`. There is nothing to re-point. The standard's own answer is `patch` (7.5.3.3), which is a stub, so the honest route is to *implement* it first |
| `ofscope` `pci-map` | **PPC track yes** (`pci@80000000`); SPARC track **sparc64 only** — sun4m is **SBus**, where `config-l@` has no meaning |
| `ofscope` `mem-map`/`region-diff` | **likely** — `/memory` + `dump`/`c@` are standard |
| `nopage.fth` | **needs rework** — `lines/page` is an OFW internal; find OpenBIOS's equivalent |
| the smoke harness shape | **fully** — one verdict, EXIT-trap net, `--echo-gate` discipline |
| FCode track | **strong fit** — SBus/PCI FCode ROMs were real here; `toke`/`detok` already built |

## 7. Risks

- **`qemu-system-sparc` not installed** → author-run `apt install`. Everything is
  blocked on it.
- **OpenBIOS's `see`/`debug` are different implementations** from OFW's. They
  exist; their *usefulness* is unverified. Spike 0 decides.
- **No real-hardware ground truth.** QMP remains the oracle, as in the sibling lab
  ([`check-oracle.sh`](examples/open-firmware-debugs-itself/check-oracle.sh)).
- **sparc32 has no PCI**, so a straight `ofscope` port covers only sparc64 unless
  an SBus walker is written.
- **Scope creep.** The sibling lab grew from three verdicts to eight modes across
  ten PRs. Pick one thesis, ship it, extend deliberately.

## 7b. The risk nobody listed: getting the vocabulary IN

Not anticipated anywhere above, and it became the built lab's spine. **OpenBIOS
has no `fload`**, and its `dl` (7.5.2 serial download) is an empty stub — so
before any vocabulary could be tested, the delivery had to be invented. The
answer is asymmetric in a way that makes the two-track lab better than planned:

| door | SPARC | PPC |
|---|---|---|
| `-prom-env nvramrc=…` (QEMU writes the chip at machine init) | ✅ | ✅ |
| `setenv nvramrc` + flush + reset, from the prompt | ❌ no binding | ✅ |
| media — `load cdrom:\FILE` + `load-base load-size evaluate` | ✅ | ❌ no filesystem compiled at all |
| type it at the prompt | ❌ 80-column wall | ❌ same |

**No single door works on both**, and the two machines fail on opposite ones.
Full derivation in [DELIVERY.md](examples/open-firmware-native-habitats/DELIVERY.md).

## 8. Routing (at assembly, not before)

New labs must land in **both** catalogs or CI fails. Per the lesson from the
sibling: an `examples/` subdir counts as a routable lab unit **only once it has a
`README.md`**, so pre-assembly work can live there without tripping
`tools/paths.py --check`. At assembly: a `00-INDEX.md` row, a `boot-and-crash`
step (after `open-firmware-debugs-itself/`), membership in `close-to-the-metal`,
then `paths.py render && paths.py --check` and `link_check.py` — both green.

## 9. Standing bias to correct for

Recorded because it held three times in the sibling lab: **the firmware was more
capable than assumed, every time.** `map?` was thought to need an unavailable
assembler (the assembler was in the ROM); the single-step debugger was called
unsmokeable (it has a line-oriented mode); baking the DSL into the ROM was thought
to require disturbing a sibling lab's artifact (one manifest line and an isolated
clone). When this plan says "probably not supported", treat that as a hypothesis
to test cheaply, not a conclusion.

⚠️ **Update after building increment 1: in this lab the bias INVERTED, three
times in one session.** Every over-estimate above came from a check that
confirmed a *name* (`' patch`), a *tree entry* (`grep forth/debugging/`), or a
*same-session read-back* (`setenv` then `printenv`) instead of a behaviour. The
rule that covers both labs: **do not let the cheap check stand in for the real
one.** `'` is not `see`. `printenv` in-session is not `reset-all`. A printed
banner is not a dictionary entry.
