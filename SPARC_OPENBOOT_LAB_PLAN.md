# SPARC / OpenBoot Lab — Design Plan v1

> **Status**: Draft v1 — proposed 2026-07-26, immediately after
> [`examples/open-firmware-debugs-itself/`](examples/open-firmware-debugs-itself/README.md)
> landed (PRs #59–#69). This would be the **fourth** lab in the IEEE 1275 family
> and the first on the architecture where Open Firmware actually shipped in
> production for two decades.
>
> **Decisions locked (this session):**
> - **Spike 0 runs first, before any lab structure is committed.** That pattern
>   has now paid for itself twice in this family — it retired the "2015 tree vs
>   modern toolchain" terror in the OFW lab, and it overturned three of the
>   debugs-itself plan's own assumptions.
> - **The lab is OpenBIOS-on-SPARC, and says so plainly.** Sun's OpenBoot is
>   proprietary and cannot be built or shipped; see the naming trap below.
>
> **Open decision — the thesis is NOT chosen yet.** Three candidates are set out
> in [§4](#4-the-open-decision--which-thesis); spike 0 is specifically designed to
> produce the evidence that picks between them.
>
> **Blocked on one author-run step:** `sudo apt install qemu-system-sparc`
> (packaged at `1:8.2.2+ds-0ubuntu1.17`, the same QEMU as everything else here).
> The agent's Bash tool cannot sudo.

## 1. Why — and why now

The family currently has three labs, all on x86/ppc:

| lab | what it is |
|---|---|
| [`open-firmware-forth-to-boot/`](examples/open-firmware-forth-to-boot/README.md) | Bradley's **OFW**, frozen Dec 2015 — the `ok` prompt, fixed live |
| [`openbios-the-rival-that-shipped/`](examples/openbios-the-rival-that-shipped/README.md) | **OpenBIOS**, the maintained reimplementation — QEMU's ppc/sparc default |
| [`openbios-clib-hello-to-emacs/`](examples/openbios-clib-hello-to-emacs/README.md) | **client programs** — C binaries calling the firmware back |
| [`open-firmware-debugs-itself/`](examples/open-firmware-debugs-itself/README.md) | a **Forth DSL** for boot forensics, memory, and FCode reverse engineering |

All four run Open Firmware somewhere it was a curiosity. **SPARC is the native
habitat** — `ok` prompts on Sun hardware were how a generation of people first
met firmware that answers back. Device paths look like the real thing, `boot
disk:a` / `boot net` mean what the manuals say, and FCode option ROMs on SBus and
PCI cards were a shipping product, not a lab exercise.

## 2. The naming trap (a third one for the family)

The family already teaches **OFW ≠ OpenBIOS**. This adds **OpenBIOS ≠ OpenBoot**:

- **OpenBoot** — Sun's (now Oracle's) proprietary IEEE 1275 firmware. Shipped on
  SPARC hardware for ~20 years. **Cannot be built or redistributed**; obtainable
  only as ROM images off real machines. This lab does not use it.
- **OpenBIOS** — the independent open reimplementation of the same standard, and
  **what `qemu-system-sparc` boots**. This is what the lab builds and drives.
- **OFW** — Bradley's original. **Has no SPARC support at all**: its `cpu/` tree
  is `arm i8051 mips ppc x86`. So this cannot be a port of the debugs-itself
  lab's firmware; it is a port of its *vocabularies*.

The lab must be explicit that the `ok` prompt it shows is *standards-identical*
to the one on a Sun box, and *not* Sun's code.

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

**NVRAM is implemented for both SPARC targets** (`arch/sparc32/openbios.c`,
`arch/sparc64/openbios.c`), and `config/scripts/switch-arch` offers
`sparc sparc32 sparc64`.

**The emulator is packaged but not installed** — `qemu-system-sparc` /
`qemu-system-sparc64`, candidate `1:8.2.2+ds-0ubuntu1.17`.

### Why the NVRAM line is the interesting one

The debugs-itself lab shipped with **two documented limitations, and both are
NVRAM-shaped**:

1. `nvramrc` — the *canonical* Open Firmware answer to running code before
   autoboot — is **dead on the x86 emu build** (`setenv` → *Out of NVRAM
   environment space*), which is why that lab had to reach for a `banner-` dropin
   instead.
2. The **warm-reboot path is unreachable** there, because `reboot?` is set only
   from the NVRAM variable `reboot-command`, which cannot be written
   (`$setenv` → *Unimplemented package interface procedure*). The lab closed that
   hole *by construction* and stated honestly that it could not demonstrate it.

If NVRAM works on SPARC, **a sibling lab can demonstrate both** — turning two
"correct by reading, unprovable by running" notes into runnable verdicts. That is
the single strongest argument for building this.

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

## 5. Spike 0 — the gate (first work, after the apt install)

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

## 6. What ports, and what does not

| from the debugs-itself lab | portability |
|---|---|
| `ofdiag` diagnosis ladder | **likely** — `expand-alias`/`find-package`/`open-dev` are standard 1275. Verify the flag conventions; OFW's `expand-alias` flag means "an alias *was* expanded", not "success" |
| `ofdiag` tracers | **unknown** — depends on OpenBIOS declaring equivalent `defer` hooks. OFW's `?show-device`/`load-started` are its own |
| `ofscope` `pci-map` | **sparc64 only** — sun4m is **SBus**; `config-l@` has no meaning there |
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
