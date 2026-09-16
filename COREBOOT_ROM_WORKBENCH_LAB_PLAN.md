# The coreboot ROM Workbench — a Lab Plan v1 (2026-09-14; feasibility re-measured 2026-09-16)

*Proposed **new lab**: **`coreboot-rom-workbench/`**. The repo builds coreboot ROMs in four
places and boots them, but always uses coreboot as a **substrate** — a ROM that carries a
payload so something else is the subject. This lab makes **coreboot itself the subject**: build
a ROM, take it apart, put it back together differently, boot each variant, and grade every step
against coreboot's own `cbfstool`/`ifdtool` and the boot outcome. It is the **construction**
half of a two-lab split; the **trust** half is
[`COREBOOT_VERIFIED_BOOT_LAB_PLAN.md`](COREBOOT_VERIFIED_BOOT_LAB_PLAN.md). Tracked as
[`TODO.md` §28](TODO.md#28-the-coreboot-rom-workbench--coreboot-as-the-subject-2026-09-14).*

> **Re-measured 2026-09-16, against the tree, the coreboot checkout and its built ROMs.** The
> thesis and the its-own-lab case hold. Five things the first draft could not see from a phone:
> **(1) the emulation board has no flash descriptor** — the ROM starts with `__FMAP__` at
> offset 0 and `cbfstool layout -w` lists exactly three sections (`BIOS`, `FMAP`, one
> `COREBOOT` CBFS), so `ifdtool -d` has no subject here and Spike 1 dissects FMAP + CBFS;
> **(2) Spike 0's option (B) is already half-measured in the firmware's favour** — the
> `persist-flash` tracks (patch 06) *program* QEMU's pflash through the CFI command sequence
> today, so the live self-edit's missing piece is delivering the ROM as `if=pflash,unit=0`
> instead of `-bios`, one QEMU flag; **(3) only `cbfstool` and `cbmem` are built** —
> `ifdtool`/`fmaptool` sources are present, unbuilt; **(4) of the payload matrix only
> LinuxBoot's source is checked out**; every other payload `git clone`s at build time (edk2
> with submodules), so the matrix's first measurement is what fetches *and* builds here;
> **(5) the coreboot tree is a depth-1 shallow clone at `c583b0c4`** — the "~`e95bdb7e`" pin is
> a comment in one build script and is not a commit this tree contains. §3 carries the rows.

---

## 1. Why — and why now

Everything the repo does with coreboot treats the ROM as opaque: three build scripts
(`linuxboot-uefi-kexec/build-coreboot.sh`, the rival lab's `build-coreboot-openbios.sh`,
`open-firmware-forth-to-boot/build-coreboot-ofw.sh`) drive one coreboot checkout into six
`build-*/coreboot.rom` directories, `qemu -bios coreboot.rom` boots each, and the payload inside
is what gets studied
([`linuxboot-uefi-kexec/`](examples/linuxboot-uefi-kexec/README.md) studies LinuxBoot; the
[rival lab](examples/openbios-the-rival-that-shipped/README.md) studies OpenBIOS-as-payload).
The **toolkit already reads a coreboot ROM's insides** — `dsl/cbfs.fth` walks CBFS, `cbfs-live`
walks the ROM the firmware booted from, `cbfs-write` does surgery on a CBFS image on the unix
workbench — but nothing yet **builds, modifies, and re-boots a coreboot ROM as the deliverable**,
with the boot outcome as the grade. The pieces are all on disk (a built coreboot tree with
`cbfstool`, the toolkit's readers/writers, the measured-boot fixtures). The lab is composition
plus a small amount of new plumbing, and it turns the toolkit's "firmware image assembly"
application — which the poke-elf reviews graded *"needs a backend, not an address"* — into a
real thing, because **coreboot is that backend**.

## 2. Thesis & scope

**Thesis.** A ROM is a filesystem (CBFS) inside a region map (FMAP) inside a flash-descriptor
layout, and each layer is a structure the toolkit can read, the firmware can be made to modify,
and a foreign tool (`cbfstool`, `ifdtool`, `fmaptool`) can grade. Make coreboot the subject and
the ROM becomes **editable, measurable, and re-bootable** — the "firmware you assemble" rather
than "the firmware you were handed."

**In scope:** build a minimal q35 ROM from a checked-in config (two exist:
`linuxboot-uefi-kexec/coreboot-qemu-q35-{linuxboot,pxeboot}.config`); dissect FMAP + CBFS with
the toolkit against `cbfstool`/`fmaptool` — **the flash descriptor is named absent on the
emulation board** (§3), not dissected; **CBFS surgery on a live bootable ROM**
(add a file the payload reads, replace the payload, resize/relocate, then boot it); the **payload
matrix** (one board, every payload coreboot ships); and **coreboot's own handoff record** (the
coreboot table / CBMEM / timestamps) read by the toolkit — the firmware's account of its own
work, the coreboot counterpart to "OpenBIOS describes its work to Linux."

**Out of scope (hard):** real-hardware board bring-up / raminit (QEMU is not a board — say so);
signing/verification (that is the sibling trust lab); anything that needs a real flash chip's
write-protect (also the trust lab's honesty caveat).

### 2b. Why its own lab (LOCKED)
- **Different subject, same instrument.** The toolkit is the *reader*; this lab is coreboot the
  *thing read and rebuilt*. Folding it into the rival lab would make that lab's showcase carry a
  second firmware's build story; folding it into linuxboot would bury it under that lab's
  boot-a-payload thesis. It is a consumer of both, and of the toolkit, and belongs beside them.
- **Its grade is the boot, not a track's assertion.** A modified ROM that boots (or refuses to)
  is the outcome; `cbfstool` is the second witness. That "edit → re-boot → grade" loop is a
  lab's worth of harness, not a track.
- **It is the shared backend two other things want.** The attested-boot capstone measures CBFS
  edits; the verified-boot lab signs regions this lab lays out. Building the workbench once, here,
  keeps that plumbing in one place.

## 3. Verified feasibility (measured 2026-09-16, per the family rule)
- **a real coreboot tree and a bootable q35 ROM — ✅**, with the identity corrected:
  `~/linuxboot-lab/coreboot` is a **depth-1 shallow clone at `c583b0c4`** (2026-06-19,
  `git rev-list --count HEAD` = 1). The first draft's "pinned ~`e95bdb7e`" is a *verified-at*
  comment in `linuxboot-uefi-kexec/build-coreboot.sh` and is not a commit this tree contains,
  so it cannot be checked against it. The rival lab's script sha-guards the ROM **artifacts**,
  not the tree. **First act of the lab: record the tree's identity as a fact the build refuses
  to disagree with**, the way the ROM artifacts already are. Built config:
  `CONFIG_MAINBOARD_DIR="emulation/qemu-q35"`, `CONFIG_PAYLOAD_LINUXBOOT=y`,
  `CONFIG_CONSOLE_CBMEM=y`, `CONFIG_COLLECT_TIMESTAMPS=y`; six ROMs on disk (`build`,
  `build-bench-{linux,openbios}`, `build-openbios{,-amd64}`, `build-ofw`), 16 MiB each.
- **the tools — 1 of 3 built.** `build/cbfstool` ✅ and a static `util/cbmem/cbmem` ✅ (the
  measured-boot fixtures use it). **`ifdtool` and `fmaptool` are not built** — `util/ifdtool/`
  and `util/cbfstool/fmaptool.c` are present, so Spike 1 builds them first and says so.
- **the emulation board has no flash descriptor — measured.** `coreboot.rom` begins with
  `__FMAP__` at offset 0 (an Intel descriptor would put `5A A5 F0 0F` at `0x10`; it is not
  there, and `CONFIG_HAVE_IFD_BIN` is unset), and `cbfstool layout -w` lists exactly three
  sections: `BIOS` (read-only, 16 MiB @ 0), `FMAP` (read-only, 4 KiB @ 0), `COREBOOT` (CBFS,
  16773120 @ 4096). So **`ifdtool -d` has no subject on q35**; the descriptor is a real-Intel-
  board layer and stays out of scope with raminit (§6). The layout the lab dissects is FMAP +
  one CBFS.
- the toolkit reads CBFS live in the ROM it booted from — **✅** (`cbfs-live`, amd64, at
  `0xffc01000`) — and rewrites a CBFS image graded by `cbfstool` — **✅** (`cbfs-write`, unix).
- **the firmware already programs QEMU's pflash — ✅, and it bears on Spike 0.** Two tracks
  measured the CFI seam in opposite directions: `flash-writer` proved a *bare store* to the
  window is a command, not data (the CFI sequence `0x20/0x40/0xff` in `arch/x86/openbios.c`),
  and `persist-flash`/`persist-os-flash` ([patch 06](examples/openbios-the-rival-that-shipped/patches/06-x86-nvram-cfi-flash-backing.patch))
  drive that sequence so a config variable **survives a power cycle and an OS boot** on
  `-drive if=pflash,unit=1`. The flash *driver* exists. What no track has done is aim it at
  **unit 0 — the ROM itself** — and every coreboot door today delivers the ROM with `-bios`
  (which QEMU maps read-only), not as pflash. So (B)'s reach is one QEMU flag away from being
  measurable, not "more than QEMU's pflash gives".
- coreboot emits a coreboot table + CBMEM the payload reads — **✅** (patch 58's `lb-table` /
  `lb-walk` already read the **CBMEM-forwarded** table from inside OpenBIOS; the fixtures read
  CBMEM entries from the Linux payload with `cbmem -r 54504d32`). Not yet parsed by the toolkit:
  the CBMEM **console** and **timestamps** entries (Spike 4's new work; the subject exists,
  both are configured on).
- **checked-in configs exist — ✅**: `coreboot-qemu-q35-linuxboot.config` and `-pxeboot.config`
  in `linuxboot-uefi-kexec/`, applied by `cp … .config && make olddefconfig`.
- **the payload matrix: only LinuxBoot's source is on disk.** coreboot's `Kconfig.name` choices
  are SEABIOS, SEAGRUB, GRUB2, EDK2 (what the first draft called TianoCore), FILO, LINUXBOOT,
  LINUX (a bare kernel), UBOOT, DEPTHCHARGE, BOOTBOOT, LEANEFI, SKIBOOT, plus `PAYLOAD_FILE`/
  `ELF` (how the rival lab ships OpenBIOS). `payloads/external/LinuxBoot/build/Image` is built;
  **SeaBIOS, edk2, GRUB2, FILO and U-Boot have no source checked out** — their Makefiles
  `git clone` at build time (edk2 `--recurse-submodules`). The matrix is only what fetches
  *and* builds on this host; a row that does neither is UNCOVERED **by name**.
- **UNMEASURED (kept honest):** whether `cbfstool add`/`remove`/`extract` on a *built* ROM
  yields a ROM QEMU still boots — it should, it is cbfstool's job, and `cbfs-write` already
  has cbfstool *accept* a Forth-edited image, but acceptance is not a boot. Spike 2's first
  boot is the measurement.

## 4. Why this and not a hosted tool
`cbfstool` builds and edits a ROM on the host; it **cannot be the firmware reading the ROM it
booted from**, and it is exactly the oracle this lab grades against. The uniquely-afforded thing
is the **loop**: the firmware reads its own live CBFS (`cbfs-live`), the host edits the ROM
(`cbfstool`), the edited ROM boots, and the firmware reads the change back from inside — a
round trip no single hosted tool closes. And the payload matrix (§5 Spike 3) is a *comparison*
across firmwares' handoffs that no one payload's own tooling can make.

## 5. The spikes

> **Spike 0 runs first and is a DECISION** (the family rule).

### Spike 0 — THE EDIT SURFACE (decision)
**Question.** Where does a ROM edit happen, so the grade is honest? **(A) host-side** with
`cbfstool` (the ROM is a file; edit, re-boot, and the firmware reads the change) — cheap, but the
firmware is only a *reader* of someone else's edit; **(B) firmware-side** with `cbfs-write` on the
live mapped ROM window (the firmware edits its own flash) — the uniquely-licensed thing, but the
`flash-writer` track already measured that a bare store to the CFI window is a *command* not data,
so a live self-edit needs the flash driver's program sequence, which may be more than QEMU's
pflash gives; **(C) both**, host-side as the workhorse and firmware-side as the one vivid demo.
**Criterion:** the edit the lab is *built on* must round-trip (edit → re-boot → firmware reads it
back), graded by `cbfstool`; the vivid live self-edit is a bonus, not the spine. Measure (B)'s
reach before betting on it.

**What is already measured (2026-09-16), so the decision starts further along:** the firmware
*has* the flash driver's program sequence — `persist-flash` programs pflash unit 1 through it
and the value survives a power cycle (§3). The "may be more than QEMU's pflash gives" worry is
retired: QEMU's pflash gives it, and OpenBIOS uses it. What (B) still lacks is the ROM being a
CFI part at all — the coreboot doors boot with `-bios "$ROM"`, which QEMU maps read-only, where
`-drive if=pflash,unit=0,file=coreboot.rom` would make the same bytes programmable at the same
window `cbfs-live` already reads (`0xffc01000`, amd64). So the first boot of Spike 0 is that one
flag: does the coreboot payload's `cbfs-write` **change a byte of the ROM it booted from**, and
does `cbfstool` see the change in the file afterwards? Recommended shape: **(C)**, host-side as
the spine, with (B) *measured on the first boot* rather than deferred — and the control is the
`-bios` delivery, where the same store must leave the file untouched.

### Spike 1 — dissect: FMAP + CBFS, against the oracle
Point the toolkit at a built ROM: `dsl/cbfs.fth` lists every CBFS file (offset/type/size/name)
matching `cbfstool print`; a new small `dsl/fmap.fth` reads the FMAP region map matching
`cbfstool layout -w`/`fmaptool` — on q35 that is three regions (`BIOS`, `FMAP`, `COREBOOT`), the
`__FMAP__` header at offset 0, so the reader is small and the oracle is exact. **The flash
descriptor is not a subject here** (§3: the emulation board has none; `ifdtool -d` would be
pointed at nothing) — the lab prints `DESCRIPTOR: absent on emulation/qemu-q35, by design` so a
reader learns the layer exists without the lab pretending to read it. Build `fmaptool` (and
`ifdtool`, for the print above) from the tree first; neither is built today. **Control:**
a byte flipped in the FMAP signature is refused by name; the counts match the oracle exactly.

### Spike 2 — surgery on a live bootable ROM
Three edits, boot-graded: **add** a CBFS file (`raw`) the payload reads at boot and prove it read
it (the OpenBIOS payload's `cbfs-live` already reads its own CBFS from inside, so "prove it read
it" is one listing); **replace** the payload and boot the new one; **resize/relocate** a region
and boot (or fail by name if it no longer fits) — and note the two edit levels: q35 has **one**
CBFS region, so add/replace are `cbfstool` edits *inside* `COREBOOT`, while a region resize is
an **FMAP-level** edit (the `.fmd` layout, `fmaptool`, a rebuild), which is the layer the trust
lab's region signing needs. Each graded twice: `cbfstool` accepts the image (host oracle), and
the ROM **boots to the expected outcome** (the real grade). **Control:** an edit that corrupts a
required region must make the boot fail *observably* (a named coreboot log line), not silently
hang — the CLAUDE.md "assert the outcome" rule.

### Spike 3 — the payload matrix (one board, every payload)
Coreboot's design is *hardware init, then hand off to a payload*. Build the **same q35 board**
with each payload the target supports and reach the **same target** (a shell, or
`cat /proc/version`) through each. The candidate list is coreboot's own `Kconfig.name` choices
(§3): **SeaBIOS, SeaGRUB, GRUB2, edk2, FILO, LinuxBoot (built, on disk), a bare Linux
(`PAYLOAD_LINUX`), U-Boot, depthcharge, BOOTBOOT, leanefi, skiboot**, plus **OpenBIOS as
`PAYLOAD_FILE`** (how the rival lab already ships it). **The first measurement is fetch-and-build,
not boot:** only LinuxBoot's source is checked out; every other external payload `git clone`s
at build time (edk2 with submodules, and it wants `nasm`/`iasl`), so the matrix's first column
is *did it fetch and build on this host* — under the repo's fetch rule (source is fine, prebuilt
toolchains are not) — and a payload that did not is UNCOVERED **by name** with the reason, not
dropped. One report of **what each payload does differently in the handoff**: the CBFS entry,
the console it brings up, the boot time, and (feeding the attested-boot bench) the measurement it
produces. **Control:** the payload is the only variable — identical board, identical target.

### Spike 4 — coreboot's own handoff record, read by the toolkit
Turn the toolkit around from "read the payload's structures" to "read the *firmware's* account":
the **coreboot table** (`LB_TAG_*`: the memory map, the framebuffer, the serial console, the CBMEM
location), **CBMEM** (the coreboot-managed memory the payload inherits, incl. the timestamps and
the console log), read with `dsl/struct.fth` and graded against the `cbmem` tool. **Half of this
is built:** patch 58's `lb-table`/`lb-walk` already read the CBMEM-forwarded coreboot table from
inside OpenBIOS (the `region-diff` track watches the firmware's own walk of it). The new work is
the two CBMEM entries the toolkit has not parsed — the **console** (`CONFIG_CONSOLE_CBMEM=y` in
the built config) and the **timestamps** (`CONFIG_COLLECT_TIMESTAMPS=y`) — graded against the
static `cbmem` the fixtures already run from the Linux payload (`cbmem -c`, `cbmem -t`). This is the
coreboot counterpart to the handoff notes' "the firmware describes its work to Linux" — here the
firmware describes its work to its *payload*, and the toolkit reads the description.

### Spike 5 — the dissector/editor, as the deliverable tool
Assemble Spikes 1–2 into one instrument: `rom-inspect` opens a ROM and prints its FMAP regions,
CBFS files, descriptor layout and coreboot-table summary; `rom-edit` adds/replaces/removes and
re-emits, `cbfstool` grading every result. Runs on the unix workbench (no QEMU) for inspection,
and drives the boot-graded loop for edits. **This is the "firmware image assembly" backend the
poke-elf reviews said the toolkit needed** — coreboot supplies the format, the toolkit supplies
the reader/writer, this Spike supplies the tool.

## 6. What this is NOT (scope guards)
- **Not board bring-up.** QEMU is not a board; raminit is real only on hardware. The lab studies
  the ROM's *structure and payload interface*, which QEMU exercises fully, and says the raminit
  gap out loud.
- **Not verification or signing.** Laying out regions is here; signing them is the trust lab.
- **Not a cbfstool clone.** `cbfstool` is the oracle, never re-implemented; the toolkit reads from
  *inside the firmware*, which is the thing cbfstool cannot do.
- **Not a new coreboot fork.** Configs and CBFS edits, not source patches to coreboot (unless a
  spike needs one, numbered and cataloged like the rival lab's).

## 7. Routing (at assembly, not before)
Each spike a `smoke-*.sh` track + `tests/` wrapper + `run-all.sh` entry; the payload matrix a
`showcase-*.sh`; the coreboot tree reused from `~/linuxboot-lab/` — **and its identity recorded**:
today the rival lab sha-guards the ROM *artifacts* while the tree itself is a depth-1 shallow
clone at `c583b0c4` with no pin in the repo (§3), so the lab's build refuses a tree whose
`rev-parse HEAD` it does not expect, by name. Routed in `learning-paths.toml` in `boot-and-crash` beside the linuxboot
and rival labs; a 00-INDEX row; the cross-lab coreboot-tree dependency stated.

## 8. Success signature (per spike, observable)
| spike | the line that must print | the control that must bite |
|---|---|---|
| 0 | an edit round-trips: edit → re-boot → the firmware reads it back; `cbfstool` agrees; (B) measured on the first boot: `cbfs-write` through the CFI driver changes a byte of a ROM delivered as `if=pflash,unit=0`, and `cbfstool` sees it in the file | the same store against a `-bios`-delivered ROM leaves the file untouched, named |
| 1 | FMAP (3 regions) and CBFS counts equal `cbfstool layout -w`/`fmaptool`/`cbfstool print`; `DESCRIPTOR: absent on emulation/qemu-q35, by design` printed | a flipped FMAP signature refused by name |
| 2 | a modified ROM boots to the expected outcome; `cbfstool` accepts it | a corrupt required region fails the boot *observably* |
| 3 | the same target reached through every buildable payload, one comparison report | payload the only variable; a non-building payload UNCOVERED by name |
| 4 | the coreboot table + CBMEM read from inside, matching `cbmem` | a wrong `LB_TAG` length refused, not misread |
| 5 | `rom-inspect`/`rom-edit` drive the whole loop, cbfstool-graded | a bad edit refused before the ROM is emitted |

## 9. Open questions
1. **Spike 0's edit surface** — (A)/(B)/(C)? **Narrowed 2026-09-16:** the firmware-side live
   self-edit *does* reach through QEMU's pflash — `persist-flash` programs it today through the
   CFI sequence (patch 06); `flash-writer`'s "a bare store is a command" is the same fact seen
   from the other side. What remains is whether the coreboot ROM is delivered as a CFI part
   (`if=pflash,unit=0`) rather than `-bios`; one boot answers it. Recommended (C).
2. **Which payloads fetch *and* build on this host** (Spike 3)? The candidate list is known
   (§3, coreboot's `Kconfig.name`); only LinuxBoot's source is on disk, the rest clone at build
   time. The first measurement is fetch-and-build per payload, under the repo's fetch rule;
   the matrix is only what came through, the rest UNCOVERED by name.
3. **Does this lab own the `rom-edit` tool, or does the attested-boot lab consume it** for its
   CBFS-tamper measurement? Likely owned here, consumed there — stated, not duplicated.
