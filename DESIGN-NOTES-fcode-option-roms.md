# FCode Option ROMs — What a Card's Own Program Can Do, and What It Must Not — Design Notes

*Discussion draft, 2026-09-13. Not a lab plan yet: what FCode delivered through a PCI
expansion ROM was *for*, what the rival lab can now do with it (Act III already runs one),
the one-ROM-two-firmwares portability demonstration expanded into a plan, and — the part
worth the most care — a **Thunderstrike-class option-ROM compromise proven in the emulator
and then prevented**, graded on
[`CLAUDE.md`](CLAUDE.md)'s chaos ladder. Tracked as
[`TODO.md` §25](TODO.md#25-fcode-option-roms--portability-and-the-malicious-card-2026-09-13);
sibling of the boot-handoff and filesystem notes, same shape: measure first, seams as build
items, grade by outcome, every attack met by a control that bites.*

---

## 0. What FCode was for

An expansion card in an Open Firmware machine carries **its own driver in its ROM**, written
in FCode — tokenised Forth, CPU-independent bytecode. At bus-probe the firmware finds the
ROM, checks the PCI expansion-ROM header for **code type 1 (Open Firmware)**, and
`byte-load`s the FCode into its own Forth interpreter. That bytecode does three jobs, and the
rival lab's Act III already does the first two on a QEMU e1000:

- **Self-description.** The card creates its own device-tree node — name, `reg`,
  `compatible`, interrupts — so the firmware and the OS learn the card without a built-in
  driver. Act III's `fcode-card.fth` renames its node; `fcode-card-cfg.fth` reads its own
  config space and publishes `cfg-id`.
- **Methods the firmware can call.** A disk controller's FCode defines `open`/`read`/`seek`/
  `load`, so the firmware boots from a controller it has never heard of; a framebuffer's
  defines the display methods; a NIC's defines packet `read`/`write` under the firmware's
  TFTP. *This is the reason Open Firmware machines booted from third-party cards.*
- **Device initialisation for the firmware's use.** Mode-setting a framebuffer, waking a
  controller. The firmware still assigns BARs and enumerates the bus; the OS still loads its
  own driver afterward. FCode is not the OS driver — it is *enough* device to boot.

The design goal was **portability**: one ROM ran on SPARC, PowerPC Mac and PCI x86 Open
Firmware, because the interpreter is the firmware's and the bytecode is architecture-neutral.
A PC BIOS option ROM is real-mode x86 hooking interrupt vectors; UEFI's answer is a PE
driver (or the almost-unused EFI Byte Code). The cost of running a card's code in the
firmware's interpreter is that **it runs with the firmware's full privilege** — which is the
Thunderstrike attack surface (§4).

## 1. What is already on disk

| piece | where | state |
|---|---|---|
| `toke` — Forth → FCode tokeniser | `fcode-utils`, built by `build-openbios.sh` | ✅ |
| `detok` — FCode → Forth **detokeniser**, the host oracle | `fcode-utils`, same build | ✅ |
| `romheaders` — validates a PCI expansion ROM on the host | `fcode-utils` | ✅ |
| a PCI-expansion-ROM wrapper (`0x55AA`, `PCIR`, code type, FCode at +0x40; `--code-type`, `--bad-sig` controls) | [`fixtures/optrom/build-fcode-rom.py`](examples/openbios-the-rival-that-shipped/fixtures/optrom/README.md) and the OFW lab's `build-fcode-rom.py` | ✅ two copies, per self-containment |
| a card that names its node (`fcode-card.fth`) and one that reads its own config space (`fcode-card-cfg.fth`) | `fixtures/optrom/` | ✅ Act III |
| the firmware reaching a live ROM BAR, config space as a bus-node method, `my-space`, the probe addr, bridges, unmap | patches 55–62 | ✅ |
| `byte-load ( addr xt -- )` — run tokens from a buffer | `forth/device/feval.fs:63`, stock | ✅ |
| the dictionary's refusals — `here!` refuses overflow (66), `marker`/`forget` with the tree-grew refusal (67), `dict-limit`/`dict-used` (63) | patches 63, 66, 67 | ✅ the defences §4 grades |
| an FCode ROM attached to **OFW** (`build-fcode-rom.sh`, `dsl/fcode-card.fth`) | `open-firmware-debugs-itself/` | ✅ the other half of §3 |

So every idea below composes existing artifacts; the new work is fixtures, tracks and (for
§4's prevention) one or two firmware patches in the classes patches 66/67 already opened.

## 2. What can be done with it — six, graded by what they demonstrate

- **A card the firmware cannot boot from becomes bootable** (the headline "what FCode was
  for"). QEMU's `ivshmem`/`edu` device exposes a BAR that is host memory; an FCode ROM on it
  that defines `open`/`read`/`seek`/`load` over that BAR is a **block device**, and the
  filesystem packages of the sibling note interpose above it. The host writes a disk image
  into the shared region, the firmware `load`s a file from a device it has **no built-in
  driver** for, and the host's copy of the image is the oracle. **No firmware patch.**
- **One ROM, two implementations** — §3, expanded below.
- **The card's word reaches Linux.** Act V flattens the tree the card renamed; the boot-
  handoff note hands that tree to the kernel on x86 (`SETUP_DTB`). A card's self-description,
  authored in bytecode, read back from `/proc/device-tree` — a claim no other x86 firmware
  makes.
- **A rogue option ROM, graded on the ladder** — §4, the part to spend effort on.
- **The toolkit delivered as a driver.** FCode can `evaluate` source, so a card whose program
  installs the readers at probe time is a third delivery door beside the CD and NVRAM; the
  habitats lab's **SBus FCode** track (`Invalid FCode start byte` on every sun4m boot) is its
  native home.
- **Emitting FCode in-firmware.** Today only host `toke` tokenises; no FCode *assembler*
  exists anywhere. A small emitter in Forth closes the loop authored-tokens → `byte-load`
  without the host, with `detok` as its oracle. Lowest priority, most OF-native.

## 3. One ROM, two implementations — the portability proof, planned

**The claim to prove, in one sentence:** the *same FCode bytes*, tokenised once, run
unmodified under two independent IEEE-1275 implementations — Mitch Bradley's OFW (the
debugs-itself lab) and OpenBIOS (the rival lab) — because the bytecode is the interface, not
the firmware. This is the cheapest strong evidence for the whole family's thesis, and it
needs no new firmware and no new driver: both labs already attach an FCode ROM to an e1000.

**Why it is not already done:** the two labs build the ROM *separately* — the OFW lab from
its `dsl/fcode-card.fth`, the rival lab from its copy — so nothing today asserts the **bytes
are identical** or that one blob boots on both. The self-containment rule keeps two copies of
the source; the portability claim needs one *artifact* driven twice.

**The subject:** one `.fc` file, tokenised **once** by the shared `toke`, wrapped **once** by
the shared `build-fcode-rom.py` into one `.rom`. Its FCode must be written to the common
subset both firmwares implement — `device-name`, `my-space`, `$call-parent " config-l@"`,
leaving `fcode-marker`/`cfg-id` in the tree — which Act III's cards already are. The one blob
is then attached to:

- `qemu-system-x86_64`/`-i386` with **OpenBIOS** (rival lab, `-device e1000,romfile=`),
- `qemu-system-ppc` with **OpenBIOS** (rival lab, the stock swap-in door),
- the **OFW** emu ROM (debugs-itself lab, `-bios emuofw.rom` + the e1000),
- and, if the SBus track lands, sun4m **OFW-on-SPARC**'s native slot with the same source
  re-tokenised (SBus FCode is a different ROM header, so that row is "same source, re-wrapped"
  and says so).

**The oracles, three of them, none the firmware under test:**
1. `detok` on the host prints the Forth the bytes decode to — **the same listing for the one
   blob**, proving what is being run is what was authored.
2. `romheaders` validates the PCI wrapper before any boot.
3. **The device tree after `byte-load`, on each firmware**, read back the way each allows
   (`.properties`/`dev` at the prompt; and via the handoff note's `SETUP_DTB` into
   `/proc/device-tree` on the OpenBIOS-x86 Linux door) — `fcode-card` is a node and
   `fcode-marker`/`cfg-id` read identically, or the divergence is named.

**What the measurement is expected to find — written down first, per the standing bias:**
the two firmwares will **not** be byte-identical in what they *accept around* the FCode. OFW
and OpenBIOS differ in which FCode tokens they implement (the optrom README already measured
one: `config-l@` has no FCode number on either, so the card routes through `$call-parent`,
which is `0x209` on both — that one *does* match). The honest result is a **token-coverage
table**: for each word the card uses, its FCode number and whether each firmware's
interpreter has it, with `detok`'s view as the reference. A word one firmware lacks is the
portability claim's real edge, named — not a failure, the *finding*.

**Build:** `fixtures/fcode-portable/` with one `card.fth`, a builder that tokenises and wraps
**once** and stamps the blob's sha256; a `fcode-portable` track (in whichever lab owns the
cross-firmware harness — likely the rival lab, which has both QEMU doors) that boots every
firmware above with that one blob, asserts `detok` agrees, the marker is in each tree, and
emits `fcode-tokens.toml` (per word: number, present-on-OFW, present-on-OpenBIOS). Controls:
the `--bad-sig` and `--code-type` ROMs refused by name on **both** firmwares (portability of
the *refusal* too); a word deliberately outside the common subset must fail on the firmware
that lacks it and the track must **name which**, not just go red.

**Success signature:** one `.rom`, one `detok` listing, `fcode-card` a node with the same
`fcode-marker`/`cfg-id` under OFW-x86, OpenBIOS-x86, OpenBIOS-ppc; the token table emitted;
the two controls refused on both; any common-subset gap named per firmware.

## 4. The malicious card — prove a Thunderstrike-class compromise, then prevent it

**Framing, up front and non-negotiable.** This is a **defensive** exercise in an **emulator**:
reproduce the *class* of a publicly documented (2015) firmware attack against code the lab
builds and runs itself, so the repo can then **build and measure the prevention**. It is the
chaos row [`CLAUDE.md`](CLAUDE.md) asks for — a layer (a card's unsandboxed bytecode) nobody
has watched fall over — and it is graded on the ABSORBED → … → LIED ladder. Nothing here
targets a real machine, a real vendor's ROM, or a signed production firmware; the "exploit" is
FCode this lab authors, run against this lab's own OpenBIOS in QEMU with no KVM. The
deliverable is the **prevention and its proof**, not the attack.

**What Thunderstrike was, in one paragraph.** Trammell Hudson's 2015 work (Thunderstrike, then
Thunderstrike 2) showed a Mac's Thunderbolt/PCI **Option ROM runs in firmware context before
any OS**, with enough privilege to **write the platform's own boot flash** and make itself
persistent and self-propagating. The root cause is the one §0 names as FCode's cost: a card's
code runs with the firmware's full authority, and nothing checked what the ROM was allowed to
do. FCode is the *same shape* — `byte-load`ed bytecode with the run of the dictionary and
every device method — so OpenBIOS is a faithful, safe place to reproduce the *mechanism*.

**The four things a hostile FCode ROM can attempt, each an injection point on the ladder,
each with the observer that grades it and the control that must bite:**

| # | what the card's FCode attempts | rung if unprevented | outside observer | already defended? |
|---|---|---|---|---|
| A | **exhaust/overrun the dictionary** — `here` past `dict-limit` (fill it, then one more `,`) | pre-66: the kernel printed the overflow line and **continued** into `console_ops`/`x86_nvram_backend` — a write past the arena, the LIED shape | `dict-used` before/after; the neighbour bytes via `xp` | **yes, patch 66** — `here!` refuses with -8, taking nothing; this row is the *regression proof* |
| B | **clobber a firmware function pointer** — a typed store to a known `console_ops`/method address, the OpenBIOS analogue of "write the boot flash" | STRANDED/LIED: the prompt still says `ok`, the next call is hijacked | `xp` of the pointer before/after; the hijacked word's behaviour; QEMU `screendump` if it is the console | **partly** — §13.3's stack-shift patches show the shape; **no gate stops a *deliberate* typed store to firmware .text/.data** |
| C | **persist across boot** — write the malicious payload into a backing store the firmware reads at power-on (`nvramrc`, an IDE sector, the pmem region — the store table, §2.5 of the fs note) so it re-arms without the card | LIED across boots — the §1-of-CLAUDE.md "record that outlives its subject", weaponised | the host image/`od` after exit; a second boot **with the card removed** still compromised | **no** — this is the persistence half of Thunderstrike and the row with the most to teach |
| D | **spread** — a card whose FCode, once running, writes the *same* payload into a **second** card's writable ROM BAR (or the shared-memory device of §2) | LIED + propagation | the second device's bytes on the host; a boot with only the second card | **no** — Thunderstrike 2's self-propagation, in miniature |

**Prove first (the attack rows), in the emulator, each authored by the lab:**
- A is already a control in the `marker`/`dict-budget` tracks — reuse it as chaos row A and
  state that patch 66 is the prevention that already shipped.
- B: an FCode fixture `evil-ptr.fth` that computes a firmware pointer's address (from the
  running dictionary, the way `dict-budget` reads `dict-limit`) and stores to it; the observer
  is `xp` and the hijacked word. **Scope the fault** (CLAUDE.md): store to a pointer the track
  *owns* and can restore, or to a value the tree never uses, so the whole firmware does not go
  down and mask the grade.
- C: `evil-persist.fth` writes a marker payload into `nvramrc` (or an IDE sector via the P1
  backing), then the harness **reboots with `romfile=` removed** and greps for the marker —
  proving the payload re-armed from the store, not the card. The store is one the §2.5 table
  says survives (IDE sectors/pmem; *not* the memory-backed NVRAM chips, which is why that
  correction matters here).
- D: `evil-spread.fth` writes into a second `edu`/`ivshmem` device's region; the observer is
  that device's host-side bytes and a boot with only the second device present.

**Then prevent — and this is the deliverable.** Each prevention is a patch in a class this
lab already carries, graded by the *same* observer showing the attack now ABSORBED:

1. **Refuse writes to firmware .text/.data** (defends B). A guard in the device-register
   store path (`rb!`/`rl!`/`int!`) — or in `here!`'s neighbour, patch 66's home — that refuses
   a store whose target lies in `[_start,_end)` of the firmware image, by name, taking
   nothing. The measured hazard patch 66 found (a `,` rewriting `console_ops`) is exactly this
   class. **Control:** the legitimate framebuffer/`b8000` store of the `mmio-writer`/`vga`
   tracks must still land — the guard refuses firmware memory, not device memory.
2. **Gate `byte-load` of an option ROM behind a policy** (defends B/C/D at the source). Before
   `byte-load`ing a card's FCode, the firmware **measures it** (`sha256`, the toolkit's own)
   and checks the digest against a provenance list the ROM build stamped — the
   [ELF-gate](ELF_GATE_AND_BOOT_LADDER_LAB_PLAN.md) Spike-5 pattern (`build-id` vs the
   provenance record), applied to FCode. An unlisted card is **refused before it runs**, named,
   and the event authored into the TCG log (`dsl/eventlog.fth`) so the refusal is *attestable*.
   **Control:** the known-good Act III card runs; the same card with one byte flipped is
   refused and the log shows it.
3. **A "no option-ROM execution" build switch** (defends all four, bluntly). The coreboot/UEFI
   real-world mitigation is "don't run option ROMs"; the OpenBIOS analogue is a config flag
   that skips `byte-load` of code-type-1 ROMs entirely, publishing the node from the PCIR
   header alone. **Control:** with the flag off, Act III runs; with it on, the card is
   enumerated but its FCode never executes, and the `optrom` track's marker is **absent** —
   the ROM is data, not code.
4. **Measured boot notices persistence** (defends C, detection not prevention). The boot
   counter/event-log seam (handoff note §2.5/§3): a payload that re-armed from a store changes
   the replayed PCR, and the bench (`event-bench`) shows the compromised boot's log differing
   from the clean one in exactly the entry the payload touched — "replay the log, see what
   differs", pointed at malware.

**Grading, on the ladder:** each attack row is run **unprevented** (must reach its critical
rung — LIED/STRANDED — or the attack fixture is broken and says so), then **prevented** (must
reach ABSORBED, refused by name before the irreversible step). A prevention that turns an
attack HALTED rather than ABSORBED is reported as the intermediate rung, not punished. The
**no-fault control** is the known-good Act III card, which must run green through every
prevention — a gate that also blocks the legitimate card is the "verifier that passes when the
artifact is missing" bug this repo has hit before.

## 5. What this is NOT (scope guards)

- **Not an attack on any real firmware, vendor ROM, or signed image.** Emulated OpenBIOS the
  lab built, in QEMU, no KVM; every "malicious" ROM is FCode this lab authors and tokenises.
- **Not a weaponisable artifact.** The fixtures demonstrate a *class* (unprivileged bytecode
  reaching firmware state); they are scoped to pointers/stores the track owns, and the
  deliverable is the prevention. No fixture targets a real platform's flash-write sequence.
- **Not a signature/trust scheme beyond the lab's anchor.** Prevention 2 measures against a
  provenance list the ROM build stamps on the host (the ELF-gate anchor), not a hardware root
  of trust; the note says so, as the ELF-gate plan does.
- **Not a new firmware where a config flag suffices.** Prevention 3 is a switch; preventions 1
  and 2 are small guards in patch 66's class. None is a rewrite.

## 6. A sequence, if this becomes a plan

| step | the line that must print | needs |
|---|---|---|
| S0 | `fcode-portable`: one `.rom`, `detok` agrees, `fcode-card` a node under OFW-x86, OpenBIOS-x86, OpenBIOS-ppc; token table emitted; both controls refused on both | §3; the two labs' QEMU doors |
| S1 | the shared-memory card boots a file the firmware has no driver for; host image is the oracle | §2 item 1; `edu`/`ivshmem` |
| A | chaos row A: the dictionary-overflow card reaches LIED on a pre-66 build and ABSORBED (refused -8, nothing taken) on head | patch 66, reused |
| B | `evil-ptr` hijacks an owned pointer unprevented (`xp` shows it); prevention 1 refuses the firmware-memory store by name; the framebuffer store still lands | prevention 1 |
| C | `evil-persist` re-arms from a surviving store with the card removed; prevention 2 refuses the unlisted card before `byte-load` and logs it; measured boot shows the differing PCR | preventions 2 + 4; §2.5 store |
| D | `evil-spread` writes a second device unprevented; prevention 3 (no-ROM-exec) leaves the node enumerated and the marker absent | prevention 3 |

**Sequence:** S0 (portability, harmless, first) → S1 → A (already defended, the regression
anchor) → B → C → D, preventions interleaved so every attack row is immediately followed by
its ABSORBED proof.

## 7. Open questions

1. **Which lab owns the cross-firmware harness (§3)?** The rival lab has both OpenBIOS doors
   and `build-openbios.sh` builds `fcode-utils`; the OFW ROM lives in debugs-itself. Likely the
   rival lab drives, depending on the OFW emu ROM as a built artifact — a cross-lab dependency
   to state, not hide.
2. **`edu` vs `ivshmem` for the shared-memory block device (§2/S1, D)?** `edu` is in-tree and
   tiny; `ivshmem` is a real BAR of host memory and closer to a disk. Measure which QEMU builds
   ship on the runners.
3. **Does prevention 1 belong at `here!`, in the device-register store words, or both?** The
   measured hazards (a `,` past the arena; a typed device store) sit in two places; the guard
   may need to as well.
4. **How much of Thunderstrike 2's self-spread (D) is worth building** versus naming as the
   logical end of the ladder once A–C and their preventions are proven? Propagation adds a
   second device and little new *prevention* — 1–3 already stop it — so it may be an
   UNCOVERED-by-name row rather than a built one.
