# MANUAL_TESTING — exact commands + real success signatures

All transcripts below are from the verification host (Ubuntu 24.04,
qemu-system-x86_64/-ppc 8.2.2, KVM available, rootless podman). Raw spike logs
live in `~/openbios-lab/` (`drive*.log`, `smoke-*.log`, `showcase-*.log`,
`build-*.log`).

**This file is a RECORD, and it is dated per entry rather than as a whole** —
the sections below run from 2026-07-21 to 2026-08-30. Re-running an entry will
not reproduce it byte for byte, and that is not a defect: build stamps, dictionary
sizes and timings move. What must stay true is that the command still exists, the
success signature is still reachable, and any **count or present-tense claim** is
re-derived rather than copied. Audited end-to-end 2026-08-30; what that found is
in the entries themselves, and one of them (§5) had been false since 2026-08-26.

## 1. Build all targets (container)

```console
$ ./build-openbios.sh
==> applying the revival patch (idempotent)
    applied
==> building the build-box image (localhost/openbios-build)
Building OpenBIOS for x86 ... ok.
Building OpenBIOS for ppc amd64 ... ok.
==> artifacts:
/home/sqs/openbios-lab/openbios/obj-amd64/openbios-unix
/home/sqs/openbios-lab/openbios/obj-ppc/openbios-qemu.elf
/home/sqs/openbios-lab/openbios/obj-x86/openbios-builtin.elf
/home/sqs/openbios-lab/openbios/obj-x86/openbios-x86.dict
/home/sqs/openbios-lab/openbios/obj-x86/openbios.multiboot
```

Success signature: five artifact paths listed. ~2 min cold (clones openbios +
fcode-utils, pulls debian:13, builds toke), seconds warm. Re-running prints
`already applied` — the patch step is idempotent (applies, or verifies it
reverses, or errors if the tree diverged).

## 2. Coreboot ROM (cached tree ≈ 1 min)

```console
$ ./build-coreboot-openbios.sh
==> wrote guard /home/sqs/openbios-lab/coreboot-guard.sha
==> isolated config/build (.config-openbios + build-openbios/) — sibling artifacts untouched
Built emulation/qemu-i440fx (QEMU x86 i440fx/piix4)
==> guard check:
.config: OK
build/coreboot.rom: OK
.config-ofw: OK
build-ofw/coreboot.rom: OK
==> /home/sqs/linuxboot-lab/coreboot/build-openbios/coreboot.rom
```

The guard proves BOTH sibling labs' kept coreboot artifacts (linuxboot's
`.config`/`build/coreboot.rom` and the OFW lab's `.config-ofw`/
`build-ofw/coreboot.rom`) survive our isolated third build.

## 3. Smokes — one verdict each

```console
$ ./smoke-openbios.sh multiboot
  - booting multiboot (accel=kvm), driving the 0 > prompt → .../smoke-openbios-multiboot.log
PASS: OpenBIOS (multiboot) answered 7 at the 0 > prompt and listed the device tree

$ ./smoke-openbios.sh coreboot
PASS: OpenBIOS (coreboot) answered 7 at the 0 > prompt and listed the device tree

$ ./smoke-openbios.sh ppc
  - banner: OpenBIOS built on Jul 21 2026 07:09
  - distro blob: built on Apr 22 2026 09:24 — different, so the running firmware is OURS
PASS: our own openbios-ppc (built on Jul 21 2026 07:09) answered 7 at the 0 > prompt
```

```console
$ ./smoke-openbios.sh dict-identity
  - openbios.dict=104952 bytes, openbios-x86.dict=108060 bytes   # 2026-07-21; see below
  - 1/2 booting the ARCH dict → .../smoke-openbios-dict-identity.log.arch
  - 2/2 control: the BASE dict, which must NOT have them → .../smoke-openbios-dict-identity.log.base
PASS: the x86 tracks boot openbios-x86.dict (108060 bytes, the superset): /memory and /cpus
      are in the running device tree, and the base openbios.dict (104952 bytes) boots to a
      prompt WITHOUT them

$ ./smoke-openbios.sh amd64-fault
  - provoking a page fault above 4 GiB → .../smoke-openbios-amd64-fault.log
PASS: SPIKE 2 (exceptions): three page faults above the identity map, each NAMED with CR2
      and a full machine+Forth dump, each RECOVERED — the prompt answers 7 and still walks
      the device tree afterwards

$ ./smoke-openbios.sh amd64-pmem
  - 1/3 writing the store to pmem at 0x100000000 → …log.write
  -    host pmem image changed: 8a2b1f0d4c6e… → 3f77c0921ab4…
  - 2/3 fresh QEMU process, same pmem file → …log.read
  - 3/3 control: identical boot with NO nvdimm attached → …log.control
PASS: P3: … boot-file reads back as P3-PMEM, and the no-nvdimm control saw neither the
      region nor the value
```

Runtime ≈ 15–30 s each (`amd64-pmem` and the `persist*` family boot three times,
≈ 60–90 s). SKIP (77) when the image, qemu, or python3 is absent.

**The two dictionary sizes above are a 2026-07-21 reading and have since moved**
— `106064` and `109172` on 2026-08-30, because every patch that adds Forth grows
both. The *invariant* is what the track actually asserts and what is worth
remembering: `openbios-x86.dict` is the **superset**, larger than the arch-less
`openbios.dict` it is built from by the size of `arch/x86/init.fs`, and only the
superset boots with `/memory` and `/cpus` present. `dict-identity` derives both
numbers on every run; do not compare against the integers printed here.

**The full list is what `./smoke-openbios.sh --help` prints** — read it there, and
**not from this file.** The copy that used to sit here named 19 tracks against the
30 the driver dispatches, having missed ten additions (`coreboot-amd64
memory-available pmem-writer flash-writer mmio-writer struct-layer struct-array
struct-device elf-methods rmw-fields`) plus `unix`. It carried the words *"this
is a copy and can drift"* the whole time, which turned out to be a prediction
rather than a caveat: measured 2026-08-30, it had drifted by ten.

Two checks make the list unnecessary to copy, and both are cheaper than
maintaining one: `tools/check-track-list.sh` asserts the driver's dispatch, its
usage list and its `--help` agree with each other, and
`tests/test-every-track-has-a-wrapper.sh` fails if any track ships without a
`tests/test-smoke-<track>.sh`. Ask those, not this paragraph.
Measured 2026-08-26 on this host: **13 of 13 driven tracks passed** — `multiboot
dict-identity nvram amd64 amd64-fault amd64-ctx amd64-pmem amd64-linux ppc floppy
property-abi vga diagnostics`, with 0 SKIP among them. `diagnostics` is the only track
that boots **all three** arches in one run, and it is the only one that is two-sided in a
single boot: silence where silence is correct, and a must-catch fixture where it is not. It
also carries the two printf fixture sets (`7/7` and `10/10`, plus one **recorded
divergence** — `%.0d` of `0` — asserted as itself so that closing it goes red on purpose). Two of those carry the clean-prompt probe
added the same day: `amd64` asserts it (patch 19 fixed it there) and `multiboot` is its
**control**, since x86 has always passed. Measured 2026-08-23: **13 of 14 ran and
passed; the one SKIP is `coreboot`**, which has no cached ROM (rebuild it with
`./build-coreboot-openbios.sh`). The Linux showcase now takes a third flavor:
`multiboot` PASS, **`amd64` PASS (2026-08-25)**, `coreboot` SKIP for the same
ROM reason.

**2026-08-26, patch 24 (TODO §13.3(A)):** nine tracks re-run after the trampoline fix —
`client-forth multiboot dict-identity amd64 amd64-ctx property-abi vga diagnostics ppc`,
all PASS, 0 SKIP. The other six (`nvram amd64-fault amd64-pmem amd64-linux floppy
persist*`, plus `coreboot`) were **not re-run** and are UNKNOWN for that change rather
than assumed green: patch 24 touches `arch/x86/context.c` and the two loader
`*_init_program()` entry points, which none of them drives.

**2026-08-26, patch 25 (TODO §13.2(d)):** `property-abi` re-run on x86 and amd64 with its
new decode-bytes section, plus `ppc diagnostics client-forth multiboot amd64` — all PASS.
`property.fs` is shared, so all three arches were rebuilt; ppc is driven by the `ppc` and
`diagnostics` tracks, **not** by the property probe, which loads Forth off a CD and has no
ppc arm. That is a named gap, not a covered one.

**2026-08-26, patch 26 (TODO §13.2(b), and §13.2(a) decided):** `multiboot amd64 amd64-pmem
vga diagnostics ppc client-forth dict-identity property-abi` — all PASS. `amd64-pmem` is the
one that matters for (b): its store is at `0x100000000` and the new refusal does not trip on
it. (a) is **not fixed** — sign-extension would corrupt PCI addresses with bit 31 set — and
its premise is now a counter read on every boot instead of a claim.

**2026-08-27, patch 27 (TODO §13.2(c)):** `property-abi multiboot amd64 amd64-pmem vga
diagnostics ppc client-forth dict-identity` — all PASS on x86 + amd64 + ppc builds. `encode+`
now concatenates; the probe exercises **both** branches and names which one it took, because
a fix whose slow path never runs is indistinguishable from no fix.

**2026-08-27, patch 28 (TODO §13.3(D)):** `vga multiboot amd64 property-abi nvram amd64-pmem
client-forth diagnostics ppc dict-identity` — all PASS on x86 + amd64 + ppc builds. The `vga`
track went **red on the fix** first, because it asserted the defective `QEMU,VGA@0`; that is
the good-news failure a characterization test exists to produce, and it now asserts `@2`.
Its `screen`-alias UNKNOWN, printed on every run since 2026-08-26, is now an assertion.

**2026-08-27, patches 29–30 (TODO §13.3(C) and most of §13.3(E)):** `diagnostics vga
property-abi multiboot amd64 ppc client-forth nvram dict-identity amd64-pmem` — all PASS on
x86 + amd64 + ppc builds. `diagnostics` went **red on the (C) fix** because it pinned ppc's
divergent d-zero line; it now expects one line for all three arches. `printf-edges` moved
from 12/12 to 14/14 with the `%n` and `%llx` cases, and `test-eword-report` is a second
must-catch fixture beside `test-feval-report`.

**2026-08-27, patch 31 (TODO §16):** `property-abi multiboot amd64 vga diagnostics ppc
client-forth nvram dict-identity amd64-pmem` — all PASS on x86 + amd64 + ppc builds.
`property-abi` gained the storage checkpoint: `int!` and `string!` write where the caller
says, with **`here` unchanged**. Two controls isolate the two halves — one bumps `here`
while the bytes stay right, the other corrupts the bytes while `here` stays put — because
neither assertion is sufficient alone.

**2026-08-27, patch 32 (TODO §16, the cursor):** same ten tracks, all PASS. `property-abi`
now also composes three fields at a caller-chosen address with `int!+` and reads them back
with the stock `decode-int`. Its stride control is the instructive one — a wrong stride
leaves **field one correct** and only corrupts what follows, which is why the assertions
cover fields two and three.

**2026-08-27, `pmem-writer` (TODO §16, third deliverable):** a new track — three 1275-encoded
ints written by `int!+` to an **NVDIMM at `0x100000000`**, read back with the stock
`decode-int`, and then found byte-for-byte in the host's backing file by `od` **after QEMU
exited**. Its control aims the identical probe at ordinary RAM: every firmware-side
assertion passes and only the host-file one fails, which is the point — two firmware words
agreeing with each other cannot say where the bytes went.

**2026-08-27, `flash-writer` (TODO §16, scope):** a second new track, and its verdict is
**no** — a CFI part is not a store-to seam. The corrected window reads an erased part's
`ff ff ff` (the no-flash control reads `0 0 0`, so that is a measurement), three `int!+`
stores leave both the array and the host image untouched, and storing at the **uncorrected**
`ffbe0000` reads back convincingly as `c0 ff ee` — into RAM, nowhere near the chip. Run with
`persist-flash pmem-writer property-abi multiboot amd64 diagnostics`, all PASS.

**2026-08-27, `mmio-writer` (TODO §16, third seam):** 1000 `int!` stores into the legacy VGA
aperture at `0xb8000` put **167,685 blue pixels** on the display — read by QEMU's
`screendump`, an observer the firmware cannot fake — where the pre-write dump and the
no-write control each hold **0**, with `here` unchanged. Two first attempts failed
instructively: the console paints the same screen and **scrolls**, so a four-character write
vanished before the next prompt; and a raw image diff is swamped by console echo, so the
assertion counts a colour the console never produces. **Not a PCI BAR** — QEMU reports the
VGA BAR0 unassigned, which is TODO §0.6c.

**2026-08-27, patch 33 (TODO §0.6c):** the first memory BAR was being assigned address `0`,
on **both** arches. Fixed by giving `default_pci_host` a `.pci_mem_base`; `BAR0` now lands at
`0x40000000`. The change moves **every PCI memory address on x86 and amd64**, so the whole
sweep is the assertion: `vga property-abi mmio-writer pmem-writer flash-writer amd64
multiboot diagnostics ppc nvram amd64-pmem dict-identity client-forth` — 13 of 13 PASS, and
§13.2(a)'s `a-signbit-boot` guard is still `0` because the base was chosen with bit 31 clear.

**2026-08-27, patch 34 (TODO §0.6d):** the PCI bus never declared its cell counts, so
`my-#acells` was **2** where the C side wrote **3** — a silent stack shift that faulted
`" screen" open-dev` on both arches. The `vga` track had only ever checked that the alias
*resolved*; it now asserts `AC=3`, `OD=<ihandle>`, `FB=40000000` and **no exception in the
log**, and removing the two property writes fails it by name. Shared code, so ppc was rebuilt
and run: `vga property-abi mmio-writer pmem-writer flash-writer amd64 multiboot diagnostics
ppc nvram amd64-pmem dict-identity client-forth amd64-ctx` — 14 of 14 PASS.

**2026-08-27, `mmio-writer` upgraded:** with §0.6c and §0.6d fixed, the track now aims at the
**live PCI BAR** as well as the legacy aperture — `[00 …] → [c0 ff ee 01 c0 ff ee 01]` at
`0x40000000`, read by QEMU's monitor (`xp`) rather than `screendump`. The display cannot
answer that one: the VGA is in 640×480 compat mode scanning the legacy aperture, so a real
store into the linear framebuffer is invisible on screen. Two outside observers, each chosen
for what it can actually see.

**2026-08-29, `struct-layer` (REVIEW G2, the type layer):** a new track, and the first thing
it found was that **the review had the starting point wrong**. G2 says `create ... does>` is
"sitting unused" and the definer is the work; OpenBIOS already ships `struct` and `field`
(`forth/bootstrap/bootstrap.fs:1570`) and they work at the untouched prompt — `struct 4 field
a 2 field b 1 field c constant size` gives `size`=7 and offsets 0/4/6. What was missing is
**width and byte order**, which [`dsl/struct.fth`](dsl/struct.fth) adds in ~60 lines.

Run: `./smoke-openbios.sh struct-layer`. Both arches, one boot each:

```
  - subject: openbios.multiboot — ELF64 magic=464c457f class=2 type=2 machine=3e entry=101d70 size=21af8 (host, from the bytes)
  - amd64: layout 0x10, offsets 0/4/8/a/c; int!→BE field deadbeef, le-l!→LE field cafebabe,
           cross-read bebafeca/efbeadde; t! 11223344 → memory [44 33 22 11]; t-adr le-l! → 55667788;
           ELF64 magic=464c457f type=2 machine=3e entry=101d70 size=21af8; 8-byte view → 101d70
  - x86:   …identical… ; 8-byte view → T-ERR-narrow-cell
```

*(2026-08-30: the probe's layout now reports **0x18**, not `0x10` — a field was
added to it when `elf-methods` split `e_abiversion` out. The offsets and every
value above are unchanged. The total is the probe's own size, not an ELF fact.)*

The two checkpoints are different questions. **(1)** a named field reads back `deadbeef` /
`cafebabe` written by `int!` and `le-l!` — words that know nothing about the layer. **(2)** a
typed store puts `11223344` into memory as `44 33 22 11`, and a **bare** `le-l!` through the
field's own address is equally the write: no map/modify/poke-back, because a field yields the
bytes rather than a copy of them (review §P1).

**The arch split is itself a control.** Every row is identical on x86 except the last: an
8-byte field on a 32-bit cell **refuses by name** (`T-ERR-narrow-cell`) where amd64 answers
`101d70` and agrees with the same bytes read as two 4-byte halves. Truncating there would
have been the LIED rung — right in its low half, silently wrong above bit 31 — which is
exactly the defect TODO 13.2(b) found in `l!-be`.

### The G2 controls, run 2026-08-29

Seven injections, seven bites. **The seventh is the one that earned its place**, and it was
written only after injection 4 exposed a weakness in the assertions themselves: three rows
asserted that a refusal **printed its name**, which is the mechanism. The outcome of a
refusal is that the operation *did not complete* — so each refusing word now ends on its own
`G2?-END` marker and the assertion is that marker's **absence**.

| injection | result |
|---|---|
| `le-field:` compiled as big-endian | **FAIL** — *"a little-endian field over bytes written by `le-l!` reads bebafeca, not cafebabe"* (checkpoint 1 fires before the order control, which is correct: an independent writer catches an order defect directly) |
| the definer's running offset never advances | **FAIL** — *"the pattern layout is 0x0 bytes, not 0x10"* |
| the narrow-cell guard inverted, so x86 truncates instead of refusing | **FAIL** — *"an 8-byte field on a 32-bit cell returned '101d70' instead of refusing"* |
| `t-width-err` returns 0 after naming the width | **FAIL** — but via `rc=124`: the leftover stack means the prompt never prints `0 > ` again. A real bite, on the wrong row |
| `t-adr` off by one | **FAIL** — *"field p-be sits at offset 1, not 0"* |
| the probe's cross-read uses the **same** order (as if `l@-be` and `le-l@` were one accessor) | **FAIL** — *"the order bit is not selecting an accessor, so every round trip above proves only that one accessor is its own inverse"* — the row that exists for exactly this |
| `t-width-err` names the width, **balances the stack**, and returns a number | **FAIL** — *"printed T-ERR-width and then ran to G2O-END — the message is right and the operation completed anyway"*. This is the case the printed-name assertion would have passed |

**2026-08-30, `struct-array` and `struct-device` (REVIEW G2's last two gaps).**
Arrays walk the ELF64 program-header table of the amd64 firmware's own boot
image; both arches, every element against host ground truth, graded by a sum the
firmware derives.

Asking for the *device* half turned up **patch 49**: IEEE 1275 §5.3.7.2's six
device-register words had bodies containing **no words at all**. Measured at the
prompt before anything was written —

```
b8000 c@   -> 41       (the byte just written there)
b8000 rb@  -> b8000    at depth 1
42 b8002 rb!           left depth 2 having stored nothing
```

— and `table.fs:390-395` binds FCode tokens `0x230`-`0x235` to exactly these, so
it presents as a **stack shift inside a driver**, not a wrong value.

**The two arches disagree, on purpose:**

```
- amd64: … typed device array painted 2000 cells — physical 0xb8000 reads
         [0x41 0x1f 0x41 0x1f …] and the screen shows 158445 blue pixels against 0 with no paint
- x86:   … the typed device write to b8000 is a FALSE POSITIVE here: Forth reads back 1f41 while
         physical 0xb8000 holds [0x30 0x07 0x20 0x07 0x3e 0x07 0x20 0x07] (the console's own prompt)
         and the screen shows 0 blue. arch/x86 rebases, so b8000 is not the aperture
```

That x86 row is asserted **positively**, not skipped — it is the cheap check
lying in the same run as the arch where it tells the truth, and it is the same
trap `flash-writer` met at `0xffbe0000`.

### The G8 controls, run 2026-08-30

| injection | result |
|---|---|
| `array:` ignores the index (`@ * +` → `@ drop drop`) | **FAIL** — *"program header 1 reads … type=1 off=1000 … where the host reads … type=4 off=1020"* |
| the ehdr layout drifts by 2 bytes | **FAIL** — *"the layout declares 0x3e bytes and the file's own `e_ehsize` reads 0x0"* — the drift moved the very field that catches it |
| the 8-byte device-field refusal returns a number instead of aborting | **FAIL** — *"named the refusal and then ran to GD-WIDE-END"* |
| **all six** register words reverted to empty | **FAIL**, but via `rc=124` — 4000 stores leaking two cells each overflow the Forth stack. That is the write half's real failure mode, and it never reaches the named row |
| **only `rb@`** reverted to empty | **FAIL** — *"'addr rb@' returned 14c68, which is the ADDRESS it was given"*. The headline row, firing by name |

**Coverage note:** patch 49 changes shared Forth that goes into the coreboot
payload, so both cached ROMs went stale and their tracks correctly SKIPped as
**UNKNOWN** by sha — the provenance guard doing its job. Rebuilding both with
`./build-coreboot-openbios.sh` and `… amd64` closed them: 34/34 listed tests
ran, 27/27 boot tracks, 0 skipped, 0 failed.

**Re-measured 2026-08-30 (do not copy these forward):** `36/36 listed tests ran
(matching the 36 test files on disk) — 36 passed, 0 skipped, 0 failed`, `of which
boot tracks: 29/29`. The `34/34, 27/27` above was the reading on 2026-08-30
*before* `elf-methods` and `rmw-fields`; it is kept because it is dated, and the
newer line is here because a count is a cache. `run-all.sh` prints the ratio on
every run — read it there. (`unix`, added later the same day, makes it 37/37 and
30/30.)

### The `rmw-fields` controls, run 2026-08-30

`t-set`/`t-clr`/`t-tog` (mudge's `aux@ or aux!`, generalised) and the `control:`
verbs. **Every positive row is paired with a bare `t!` that destroys the
neighbour**, because "it set the bit" is otherwise satisfied by a word that
clobbered everything else.

| injection | result |
|---|---|
| `t-set` written as a bare store (drops the old value) | **FAIL** — the neighbour bit 7 is gone: `01` where `81` was wanted |
| `t-clr` without the `invert` | **FAIL** — ANDing with the raw mask clears everything *but* the bit |
| `t-tog` implemented with `or` | **FAIL** — two toggles no longer round-trip |
| `enabled?` with `0=` instead of `0<>` | **FAIL** — the query is inverted while the bits are right |
| `disable` mapped to `t-set` | **FAIL** — `81` where `80` was wanted |

**2026-08-30, the BIG-endian row (added after review).** The track proved the
byte-order half with a little-endian field only — and `field:`, the 1275-**native**
big-endian order, was exercised at **width 1**, where byte order is a no-op. So
`l@-be`/`l!-be` had never run under `t-set` at all. The new row is the mirror:
bytes must come out `[ff 0 0 1]` against the LE row's `[1 0 0 ff]`.

Its control is the one worth keeping, because it shows *which* assertion is
load-bearing. With an order-blind width-4 accessor injected (`if le-l@ else le-l@
then`, same for the store), **both value rows still pass** —

```
rb-init=ff000000   rb-set=ff000001     <- the round trip is intact
rb-bytes=1 0 0 ff                      <- the only row that fires
```

— because a read and a write that are wrong *in the same way* agree with each
other. A round trip proves the accessors are consistent, not correct; only an
assertion that looks at the bytes underneath can tell.

### The negative controls, run 2026-08-23

Each fix was broken and watched to bite before being trusted:

| control | result |
|---|---|
| `set-defaults` back to a `SYSTEM-initializer` (both `init.fs`) | `persist` **FAIL**, `amd64-pmem` **FAIL** — by name, pointing at the initializer list |
| …the same break, but booting the **base** dict | `persist` **PASS** — the masking, reproduced on demand |
| `$XDICT` pointed back at `openbios.dict` | `dict-identity` **FAIL** |
| `arch/amd64/exception.c` back to the `do_nothing` return | `amd64-fault` **FAIL** — *"the fault WAS named and the prompt never came back"* |
| all restored | all four **PASS** again |

### The Spike 3 controls, run 2026-08-25

| control | result |
|---|---|
| `unsigned long type` back in `struct e820entry` | the **build** stops: *"size of array `linux_abi_e820entry_is_20_bytes` is negative"*. This is the one that matters — the runtime symptom it replaces is a correctly-running kernel emitting nothing at all |
| the `CR3` switch removed from `start_linux()` | `showcase … amd64` **FAIL** — the copy demolishes the page tables it is translated through, and the log stops one line after the handoff |
| all restored | `showcase … amd64` and `smoke … amd64-linux` **PASS** again |

**And the second control found a liar in the harness itself.** The showcase's
failure branch was `grep -aq "Linux version"` → *"kernel started but no u-root
banner"* — but the **firmware** prints `Found Linux version 6.3.0 …` the moment
it recognises the image, so that branch reported "the kernel started" about a
machine that had triple-faulted inside the loader. It is the shape this repo
keeps re-finding: a match on a string that is always present. The check is now
anchored (`^Linux version `), and a third branch distinguishes *handed off and
the kernel said nothing* — which on this path means silence, not a dead kernel.

### The help text is checked, because it is a program

`--help` on any of the five scripts prints and exits 0:

```console
$ ./smoke-openbios.sh --help
smoke-openbios.sh [TRACK]   one-verdict smoke tests against a real boot
...
```

That is guarded by [`tests/test-usage-is-data.sh`](tests/test-usage-is-data.sh),
which `exec`s the shared [`tools/check-usage-is-data.sh`](../../tools/check-usage-is-data.sh)
and is listed by path in CI. **It found five defects the day it was first
aimed here** (2026-08-25) — this lab had no `tests/` directory until then, so
the checker every phase runs against its driver had never seen these scripts.
Four exited 1 on `--help`; `build-coreboot-openbios.sh` exited **0 after
actually starting a coreboot build**. Asking a tool to describe itself should
not be the thing that does the work.

Every usage heredoc here uses a **quoted** delimiter (`<<'USAGE'`), which makes
the text structurally inert. The control shows why that is not fussiness — with
the delimiter unquoted, a backtick in the prose runs:

| | |
|---|---|
| authored | `multiboot coreboot ppc      run the ` + `` `date` `` + ` track first` |
| **printed to the reader** | `multiboot coreboot ppc      run the Tue Aug 25 12:51:53 AM EDT 2026 track first` |
| written to stderr | **nothing** |

The cheap check — *"`--help` writes nothing to stderr"* — passes that. It only
catches a command that does not *exist*; one that succeeds rewrites the
documentation silently, which is the dangerous case. The checker asks the real
question instead and names the file and line. Both controls were run: removing
a `--help` handler, and unquoting a delimiter. Restored, both go green.

### Loading Forth source off media (amd64)

Since [patch 14](patches/14-amd64-openbios-init-after-device-end.patch), a `.fth`
on the CD can be run instead of typed through the ~80-char serial truncation:

```console
0 > load /ide@1/cdrom@0:\marker.fth
Mounted iso9660
Path=/marker.fth
 ok
0 > load-base load-size evaluate
SPIKE-FORTH-LOADED
```

The file must begin with `\ ` (a Forth comment) — that is literally how
`is_forth()` recognises it (`libopenbios/forth_load.c:21`). `genisoimage -r`
lowercases names, so stage it as `MARKER.FTH` and type `marker.fth`.

**`go` works too**, since [patch 15](patches/15-forth-loader-divergence.patch):

```console
0 > go
switching to new context:
Evaluating Forth...
SPIKE-FORTH-LOADED
```

That patch is a **divergence this lab carries on purpose**. Two defects kept the
loader from ever running: the `$load` path never sets `load-state >ls.file-size`
(it records the size in a *different* variable), and `eval2` — the word
`libopenbios/initprogram.c` calls to do the evaluating — **is defined nowhere in
the tree**. Both are in arch-neutral code, so they were developed in a separate
copy of the source and regression-tested against x86 before being applied here.
Not sent upstream: nothing upstream ships needs this path. See
[TODO §13.1](../../TODO.md).

### The `region-diff` track — a change the FIRMWARE caused (B.3 Spike 3)

Needs both coreboot ROMs (`./build-coreboot-openbios.sh x86` and `amd64`); each
is checked against the tree's payload first, so a stale ROM is a SKIP, not a
green run about other firmware.

```console
$ ./smoke-openbios.sh region-diff
  - x86 provenance: the ROM carries this tree's payload (d9a72f3a5e40)
  - x86: SELFTEST=1 QUIET=0 | lb-table 0x1fe9e000+0x324 LBTAB=0 | RANGES=2 STEP=0x90 HEAP=0x7 LAST=0x1b RAW=0x0
  - x86: QEMU reads 0x1f at guest-physical 0x1fe42913+0x1b (the firmware said 0x1f); the bytes
    decode to RAM 0x1000+0x9f000 and 0x100000+0x1fd71000 = 510 MiB
  - amd64 provenance: the ROM carries this tree's payload (2d8b8fcebf55)
  - amd64: SELFTEST=1 QUIET=0 | lb-table 0x1fe9e000+0x324 LBTAB=0 | RANGES=2 STEP=0x90 HEAP=0x7 LAST=0x1b RAW=0x7
PASS: B.3 Spike 3 (region diff, plan §9's last unmet line): a REGION DIFF SHOWS A
      FIRMWARE-CAUSED CHANGE, on x86 and amd64 …
```

**Read `RAW` across the two arches — that pair is the point.** It is the same
bytes snapshotted at the **physical** address with **no `>virt`**: `0` on x86,
where the GDT rebase means the snapshot landed on other memory that read back
convincingly, and `0x7` — identical to the `>virt` path — on amd64, where
`virt_offset` is 0 and there is no trap to bite. One number alone would be
ambiguous; the pair is not.

`LBTAB=0` is the negative control and it also **retracts the review's premise**:
`read_lbtable()` is a reader, so the region it walks does not change. The write
is one level down, in `convert_memmap()`'s `malloc`.

### The `region-diff` controls, run 2026-09-03

Three, each re-injected into a fresh build and watched to bite:

| broken | what fired |
|---|---|
| `region-diffs` returns `0` unconditionally | `FAIL: … SELFTEST=0, not 1 — one byte poked by the test itself was not seen …` |
| `region-snap` drops its `>virt` | `FAIL: … HEAP=0 … SELFTEST=1 above means the instrument works, so this is about the subject` |
| `lb-walk` skips `read_lbtable()` | `FAIL: … lb-walk returned 0 RAM ranges … the parser did not run` |

The middle row is the one worth reading twice: the message points at the
**subject** rather than the instrument, and it can only do that because
`SELFTEST` is asserted first.

### The audit of #388/#389, run 2026-09-03 — what it found and how each was watched to bite

Two PRs, read line by line and then measured. Four defects, none visible in a green run:

| found | how it presented | fix | the row that now guards it |
|---|---|---|---|
| **patch 56 stopped one bus level short** — `ob_pci_bridge_node` had no config methods | a card *behind* a `pci-bridge`: `probe-addr` right (`10800`), ROM header fine, global `config-l@` fine, **`cfg-id=none`** from the card's own bytecode | patch 59: the bridge chains config space to its parent, as it already chained `pci-map-in` | `optrom` boots a bridged card on x86 and amd64 and requires `CFGID=100e8086` at `PA=10800` |
| **no `pci-map-out` at all** — #388 had named the symptom *"call-once-and-keep"* | on ppc `ob_pci_map()` claims the range through ofmem; a second `map-in` gets `ffffffff` | patch 60: `pci-map-out` = `ofmem_release()`; `optrom-unmap`; `optrom-run-mapped` releases on every path | ppc row: `MAP=800a0000`, released, `MAPX=800a0000` again + `MARK`; two unreleased map-ins → `MAPY=ffffffff` (the control) |
| **the instance scaffold built one level** | with patch 59 in, the bridged card **GPF'd the firmware** — the bridge chained `$call-parent` into an instance whose `my-parent` was 0 | `optrom-instance-in` walks `parent` to the root and creates every instance root-first | the same bridged row — it fired once, for real, on the one-level scaffold |
| **`optrom-run-mapped` was dead code** claiming "the track checks" it | zero callers, never unmapped | it is the ppc row's byte-load now | `MARK` after `optrom-run-mapped` |

Smaller: the ppc leg matched `"> "` and threw away the stack-depth assertion (`0 > ` now — the depth was 0 on all nine prompts, so it costs nothing); the region-diff monitor dump was 32 bytes while `LAST` can land anywhere in `STEP` (256 now — a real disagreement past byte 31 would have been a bash arithmetic error with no verdict); `region-snapv` leaked the old buffer on growth; `forth_lb_table` searched twice per call; the PASS text had unescaped inner quotes that bash word-split silently.

### The `fdt` track — the live device tree, flattened, graded by `dtc` (B.3 Spike 4)

Needs `device-tree-compiler` (`dtc`, `fdtdump`, `fdtget`) and all three firmwares
plus the hosted one. Four doors, one grader:

```console
$ ./smoke-openbios.sh fdt
  - unix: dtc parses it; fdtdump: 21 nodes, 43 properties == the firmware's NODES/PROPS; /chosen stdin = 536890280 (1777 bytes)
  - unix controls: the LE-magic blob is refused ('incorrect magic'); a 0x100-byte struct bound makes dt>fdt refuse with OVERFLOW and answer 0
  - x86: dtc parses it; fdtdump: 30 nodes, 146 properties == the firmware's NODES/PROPS; /memory reg = 0 654336 1048576 535691264 (5167 bytes)
  - amd64: dtc parses it; fdtdump: 29 nodes, 143 properties == …; /memory reg = 0 0 0 654336 0 1048576 0 535691264 (5124 bytes)
  - ppc: dtc parses it; fdtdump: 46 nodes, 235 properties == …; /memory reg = 0 134217728 (9089 bytes)
  - four doors, four different trees …
PASS: B.3 Spike 4 (FDT): the firmware's LIVE device tree, flattened by dsl/fdt.fth …
```

Read the amd64 `/memory reg` beside the x86 one: **two cells per address** on
amd64 is patch 43's root `#address-cells 2`, visible in the blob. And ppc's
`0 134217728` is the machine's 128 MiB — the `Memory: 128M` banner, as data.

By hand, on the hosted firmware (every line ≤ 80 columns — the stdin line editor
truncates past ~82, and the first draft of `dsl/fdt.fth` had an 85-column `fpad`
that came back as `rep: undefined word` with a cascade behind it):

```console
$ { cat dsl/struct.fth dsl/fdt.fth; printf '/fdt-buf alloc-mem value fb\nfb dt>fdt dup .fdt-counts\nfb swap s" out.dtb" write-file . cr\nbye\n'; } \
    | ~/openbios-lab/openbios/obj-amd64/openbios-unix ~/openbios-lab/openbios/obj-amd64/openbios-unix.dict | grep -a FDTL
FDTL=6f1 NODES=15 PROPS=2b
$ dtc -I dtb -O dts out.dtb | head -12
/dts-v1/;

/ {
	#address-cells = <0x01>;

	aliases {
		hd = "/unix/block/disk";
	};

	openprom {
		device_type = "BootROM";
		model = "OpenFirmware 3";
```

The one property the writer skips, by name, is `name` — on every node since
Spike 5. It was found on the **root**: OpenBIOS says `OpenBiosTeam,OpenBIOS`,
FDT's root base name must be `""`, and `dtc` refuses the disagreement
(`name_properties`); the round trip then made the rule general, because FDT
derives names from `BEGIN_NODE` and deprecates the property.

### The `fdt-import` track — the reader half: dtc's blob ingested, round-tripped (B.3 Spike 5)

```console
$ ./smoke-openbios.sh fdt-import
  - subject (a): …/fixtures/fdt/import.dts → dtc → 499-byte blob, 4 nodes / 13 properties per fdtdump
  - unix: dtc's blob ingested (4 nodes, 13 props as fdtdump counts), re-flattened, and dtc decompiles the round trip IDENTICALLY; the firmware's own 25-node/58-prop blob reads back with the same counts
  - unix controls: an LE magic → BAD-MAGIC, 0; a token of 7 → BAD-TOKEN, 0 — the reader refuses by name, it does not guess
  - x86: … IDENTICALLY …
  - amd64: … IDENTICALLY …
  - ppc: … IDENTICALLY …
PASS: B.3 Spike 5 (FDT, the reader half) …
```

**Why the reference is decompiled from the blob, not from the `.dts`.** The
first comparison diffed against `dtc -I dts -O dts import.dts` and showed two
lines: `bytes = [de ad be ef]` vs `bytes = <0xdeadbeef>`, `list = "one", "two"`
vs `"one\0two"`. Same bytes — from a source file dtc knows the author's form,
from a blob it guesses. Deriving both sides from binary is what makes
*identical* a statement about the tree.

Getting bytes out of the emulated arches: **QMP** `pmemsave`, not the HMP
monitor's — HMP reads its *filename* as an expression (`invalid char 't' in
expression`, the `t` of `/tmp`), which this repo's memory already recorded and
which still cost a run. ppc's console is pty-only, so its row prints the buffer
with the firmware's own `dump` (16 bytes a line, a double space mid-line) and
the host parses it back — 10314 of 10314 bytes.

## 4. The showcase — OpenBIOS boots Linux to u-root

```console
$ ./showcase-rival-boots-linux.sh            # multiboot track (default)
  - booting multiboot (accel=kvm), one boot line at the prompt → .../showcase-multiboot.log
PASS: the rival boots Linux: OpenBIOS (multiboot) loaded kernel+initrd and reached u-root

$ ./showcase-rival-boots-linux.sh coreboot   # same one-liner, through coreboot
PASS: the rival boots Linux: OpenBIOS (coreboot) loaded kernel+initrd and reached u-root
```

Key lines inside `showcase-multiboot.log` (the full serial transcript):

```
0 > boot /ide@1/cdrom@0:\vmlinuz console=ttyS0 initrd=/ide@1/cdrom@0:\uroot.img
[x86] Booting file '/ide@1/cdrom@0:\vmlinuz' with parameters 'console=ttyS0 initrd=...'
Found Linux version 6.3.0 ... (protocol 0x20f) (loadflags 0x1) bzImage.
Loading kernel... ok
Loading initrd... ok
Jumping to entry point...
Linux version 6.3.0 (coreboot@reproducible) ...
RAMDISK: [mem 0x1f296000-0x1fd94fff]
Run /init as init process
2026/07/21 07:18:27 Welcome to u-root!
```

Contrast with the OFW lab's showcase: **no** `memmap=`, **no** hand-staged
initrd, **no** zero-page poke — `initrd=` is parsed by the firmware, the
memory map is real, the zero page is built in C. The difference is the whole
point (POC-4). Needs `genisoimage` + a kernel/initrd pair (defaults:
`~/linuxboot-lab/payload-bzImage` + `uroot.cpio`; override `KERNEL=`/
`INITRD=`). ≈ 30–45 s under KVM.

### The other showcase — the whole toolkit in ONE boot

[`showcase-preboot-toolkit.sh`](showcase-preboot-toolkit.sh), documented in
[SHOWCASE-PREBOOT-TOOLKIT.md](SHOWCASE-PREBOOT-TOOLKIT.md). Where the showcase
above ends in an OS, this one never leaves the firmware: five acts at the `0 >`
prompt of the amd64 payload booted from a coreboot ROM, with two FCode
option-ROM cards on the bus and every `dsl/` reader delivered over a CD.

```console
$ ./showcase-preboot-toolkit.sh
  - firmware: the amd64 payload of …/coreboot.rom (the ROM carries this tree's payload)
  - cards: fcode-card.fth and fcode-card-cfg.fth → toke → 2048- and 2048-byte PCI option ROMs
  - the ROM is 4194304 bytes → QEMU maps it at 0xffc00000; its CBFS region begins at 0xffc01000

══ ACT I — the firmware dissects the container it arrived in ══
     0 > ffc01000 20 cbfs-list
     cbfs| off=0001b500 type=simple-elf len=00015c71 name=fallback/payload
  - 12 entries read out of guest-PHYSICAL flash by the firmware itself
     NO HOSTED TOOL CAN BE HERE: cbfstool cannot run inside the ROM it is reading.

══ ACT II — the firmware watches its own parser work ══
  - SELFTEST=1 — one byte poked by us, one difference found
  - LBTAB=0 — unchanged. read_lbtable() is a READER; this is the negative control
  - the bump allocator advanced 0x90 bytes and 7 of them changed, all inside that block

══ ACT III — a card's own program, run out of the card's own ROM ══
     optrom| byte-load fcode@41040040
  - MARK=FCODE-FROM-CARD-RAN — the card's own bytecode ran and stamped the node
  - CFGID=100e8086 — the second card asked its own PCI config space who it is

══ ACT IV — measured-boot arithmetic, with no TPM and no OS ══
  - a TCG crypto-agile event log authored in RAM: 227 bytes
  - PCR0 = the same extend chain computed on the host: SHA256(PCR ‖ digest), twice
     UNKNOWN, and it stays UNKNOWN …

══ ACT V — the firmware hands its world over: the live tree, flattened ══
  - FDTL=1cde NODES=1f PROPS=d3 — the firmware's own count of what it wrote
  - QMP pmemsave pulled 7390 bytes out of the guest at 0x17978
  - dtc parses it: 31 nodes, 211 properties — equal to the firmware's own count
  - 100e8086 — Act III's card, asking who it is, answered INTO the tree; dtc's own fdtget reads it back
  - …and fcode-card@3, the node Act III's FCode renamed, is a node in the blob
     THIS IS THE HANDOFF FORMAT: what a kernel would be given.

PASS: the B.3 preboot structure toolkit, end to end, in ONE boot …
```

**It is graded, not narrated.** Every act asserts its outcome and the run exits
1 if one does not happen — verified 2026-09-03 by making `lb-walk` a no-op,
which produced `FAIL: ACT II: HEAP=0 …` instead of a prettier transcript.
≈ 45 s under KVM (measured 2026-09-03: 44.6 s wall, one boot, five acts).

## 5. The firmware as a Unix process (no QEMU)

```console
$ cd ~/openbios-lab/openbios
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict
Welcome to OpenBIOS v1.1 built on Aug 30 2026 11:26
  Type 'help' for detailed information

0 > 3 4 + . 7  ok
0 > bye
Farewell!
```

The same IEEE 1275 Forth engine, running as your user with no emulator at all —
OpenBIOS's C-hosted design makes this possible; the frozen OFW rival (pure
self-hosting Forth) has no equivalent.

**This entry is the reason the audit happened, and it is worth reading as a
case rather than a command.** It was documented from 2026-07-21 and driven by
*nothing* — no track, no runner, no CI arm. [Patch
26](patches/26-encode-int-refuses-what-four-bytes-cannot-hold.patch) falsified it
on 2026-08-26 and the file went on asserting it for four days, until
[§3](#3-smokes--one-verdict-each) was verified by running it instead of reading
it.

**What was actually wrong, because the obvious answer is the wrong one.** The
symptom was `encode-int: value does not fit in the 4 bytes 1275 encodes an
integer into`, and patch 26's gate sits in `l!-be` — a *general* four-byte
big-endian store — so it reads as a mis-scoped refusal that should be narrowed to
`encode-int`. Measured instead: **all five trips come through `int!`**, the 1275
property encoder, and none through a raw `l!-be`. Narrowing it would have changed
nothing, and weakening it would only have restored the silent truncation patch 26
removed. The gate was never the bug.

The bug was **where the memory was**. `/chosen`'s `stdin`/`stdout` are ihandles
(`forth/admin/iocontrol.fs:42,76`); 1275 encodes an integer into four bytes
(5.3.5.1); and at run time `pointer2cell` is a plain cast
(`include/kernel/stack.h:35` — `Makefile.target` defines
`NATIVE_BITWIDTH_EQUALS_HOST_BITWIDTH` for every target), so on this one target
an ihandle **is** a host pointer. glibc placed the 4 MiB arena above 4 GiB and
`encode-int` correctly refused.
[Patch 50](patches/50-unix-arena-below-4g.patch) maps the arena and the
dictionary **below** 4 GiB — where the QEMU firmwares (`0x400000`, `0x4000000`)
have always been — and refuses by name if it cannot:

```console
0 > stdin @ u. 20004ba8  ok
0 > start-mem @ u. 20000000  ok
```

**A correction, recorded because the wrong version was published first.** This
entry briefly claimed that "one page of slack either side is a finding, not
padding" — that something in initialisation read eight bytes below the arena and
every other target absorbed it silently. **There is no such read.** It was
introduced by the fix itself: `main()` ended with `free(memory)`/`free(dict)`, and
those had just become `mmap` regions, so glibc read its chunk header at `p-8`.
The SIGSEGV and the later `free(): invalid pointer` were one bug in two costumes,
one page apart. `free_below_4g()` (a `munmap`) is the fix; the slack is gone; and
the control is that with **no** guard page and a correct deallocator the session
runs clean.

What sustained the wrong story is worth more than the bug: the panic dump prints
`pc=…(dict+0xa0a0)`, which resolves to `bye` — but **that field is the firmware's
Forth PC global, not the faulting instruction**. `bye` was just the last word to
run before `main()` called `free()`. A stale record read as if it described the
present moment. A gdb access-watchpoint on `memory-8` in the shipped build never
fires, which is what settled it. See [TODO §18(d)](../../TODO.md#d-closed-2026-08-30--it-was-never-a-firmware-bug-it-was-free-on-an-mmapd-pointer).

`./smoke-openbios.sh unix` now drives all of this on every run, and asserts the
**property** rather than the boot: `stdin`, `stdout` and `start-mem` are read
back from the prompt and must each fit in four bytes, which is the value
`encode-int` is handed. Its control is the revert — put the arena back on the
heap and the track fails by name, *"never printed its banner, so initialisation
did not complete"*.

**And the exit status now means something** (TODO §18(b),
[patch 51](patches/51-unix-exit-status-reports-the-forth.patch)). `main()` used to
`return 0` whatever the Forth had done, so the halt above reported *success* to
the shell — a false success, which outranks an honest failure. Three obvious
C-side signals cannot tell the two apart, and the reason is that `bye` and an
uncaught `throw` unwind **identically** (`0 rdepth!` either way). So the flag sits
on the deliberate path: `bye` sets `of-left-cleanly`, and `arch/unix` reads it
through `feval()`. Measured:

```console
$ printf '3 4 + .\nbye\n' | obj-amd64/openbios-unix obj-amd64/openbios-unix.dict; echo $?
… Farewell!
0
$ # with the arena forced back above 4 GiB, so initialisation aborts:
openbios-unix: the Forth engine was left WITHOUT `bye` -- initialisation did not complete.
1
```

A missing flag is **UNKNOWN**, not a failure: the C side says so by name and keeps
the old status. *(Measure it without a pipeline — `printf … | openbios-unix | tail`
makes `PIPESTATUS[0]` the status of `printf`, which reads 0 whatever the firmware
did. That nearly produced a wrong verdict here.)*

## 6. Interactive & the ppc swap-in

```console
$ ./run-openbios-qemu.sh              # multiboot, 0 > on this terminal (Ctrl-A X quits)
$ ./run-openbios-qemu.sh coreboot     # coreboot → OpenBIOS
$ ./run-openbios-qemu.sh ppc          # OUR openbios-ppc via -bios (-nographic)
$ ./run-openbios-qemu.sh amd64        # the 64-BIT firmware, NVRAM on an NVDIMM at 0x100000000
0 > 3 4 + . 7  ok
```

The `amd64` flavor, driven by hand 2026-08-23 — every line below was typed at
the prompt the tool drops you at:

```console
0 > -1 u. ffffffffffffffff  ok            \ a 64-bit cell; x86 prints ffffffff
0 > test-ctx-switch . switching to new context:
5a  ok
0 > 0 200000000 !
Unexpected Exception: page fault @ 08:0000000000101fd0
Faulting address: 0000000200000000
...
0 > 3 4 + . 7  ok                          \ ...and the prompt CAME BACK
```

Persistence, across two separate QEMU processes:

```console
0 > setenv boot-file HELLO-64-8821  ok
0 > " /nvram" " update-nvram" execute-device-method . -1  ok
                                           \ Ctrl-A X, then run the tool again
nvram: backed by pmem@0x100000000
0 > printenv boot-file
boot-file                 "HELLO-64-8821"
```

`OPENBIOS_NO_PMEM=1` is the **control**, not just an off switch — the same tool,
the same firmware, no NVDIMM:

```console
nvram: no memory at 0x100000000 -- using a volatile buffer
boot-file                 ""
```

`OPENBIOS_PMEM_IMG=<path>` picks a different store; the default
(`$OPENBIOS_WORKDIR/pmem-nvram.img`) is created on first use and kept. A fresh
image prints `nvram error detected, zapping pram` once — that is it formatting
an empty store, not a failure.

## 7. The firmware AUTHORS a file the host runs (write-file, TODO §20)

The hosted `openbios-unix` could read a host file and never write one. `write-file`
([patch 54](patches/54-unix-write-file-authors-a-host-file.patch), bound
hosted-only in `arch/unix`) is the writer half of this lab's poke story, and
[`dsl/elf-write.fth`](dsl/elf-write.fth) uses it to hand-author a runnable ELF.
The verdict is not that the firmware *claims* it wrote an ELF — it is that the
**kernel runs the file** and exits with the code the Forth authored.

```console
$ ./smoke-openbios.sh file-writer
  - primitive: 4 authored bytes reached ok.bin, and write-file returned 4
  - authored exit(0x7) → the kernel ran the file and it exited 7
  - authored exit(0x2a) → the kernel ran the file and it exited 42
  - host 'file' agrees: ELF 64-bit LSB executable, x86-64, version 1 (SYSV),
  - readelf agrees: entry point 0x400078, the vaddr the Forth authored
  - ELFkickers elfls agrees (independent decoder): x86-64, one PT_LOAD at 0x400000
  - negative control: an unopenable path returns -1, names itself, and creates nothing
PASS: TODO §20: the hosted firmware AUTHORED a runnable file and the host RAN it …
```

By hand, so you can see the whole loop (run from a scratch dir; keep the line short):

```console
$ cd /tmp/authortest
$ { cat .../dsl/elf-write.fth; printf '\n42 s" a.out" save-exit-elf . cr\nbye\n'; } \
    | ~/openbios-lab/openbios/obj-amd64/openbios-unix \
      ~/openbios-lab/openbios/obj-amd64/openbios-unix.dict
   … 0 > … save-exit-elf . cr 84  ok      # 0x84 = 132 bytes written
   0 > bye  Farewell!
$ chmod +x a.out && ./a.out; echo "exit=$?"
exit=42                                    # the value authored in Forth, run by the kernel
$ oracle/elfkickers/elfls/elfls a.out      # a decoder that is not this repo's
a.out* (Intel x86-64)
 0 B r-s     0    84 00400000
```

The differential oracle builds from the vendored subset —
`make -C oracle/elfkickers/elfrw && make -C oracle/elfkickers/elfls` — and its
provenance (commit, license, per-file sha256) is in
[`oracle/elfkickers/README.md`](oracle/elfkickers/README.md).

## Reproducer notes (the sharp edges)

- **The prompt is `0 > `** (the number is the stack DEPTH), banner "Welcome to
  OpenBIOS". Different anchors than OFW's `ok`.
- **x86 banner goes to the VGA path** on the multiboot track — over serial the
  boot ends at a bare `0 > `. Anchor expects on the prompt, not the banner.
  (The coreboot track *does* echo the banner to serial — anchor on `0 > `
  either way.)
- **ppc console input needs muxed stdio** (`-nographic`), NOT a `-serial
  unix:` socket — use `tools/drive-pty-repl.py` (this lab's extracted tool).
- **Device paths:** `:\file` (backslash) is a filename; `:/file` is a node
  path. `genisoimage -r` lowercases (`VMLINUZ`→`vmlinuz`).
- **`openbios-unix` reads stdin through an 80-column line editor** — a piped
  source line truncates past ~82 (measured 2026-09-01: 81 survive, 83 cut), which
  is why the 133-col `dsl/elf.fth` is staged via ISO on the QEMU targets and
  cannot be fed to the unix target, and why every line of `dsl/elf-write.fth` is
  ≤80. A long absolute path inside an `s" …"` pushes the verb off the end; run
  the firmware from the target's directory and name the file with a bare name.
- **Boot line ≤ ~80 chars** — the firmware input buffer drops the tail
  silently. The showcase line is **75** characters (measured 2026-08-24; this
  and POC-4 both said "exactly 78", a copied integer nobody re-counted).
- **Serial client must gate the guest**: `-serial unix:…,server=on` with wait
  ON, so the banner isn't emitted before the client connects.
- **Slow-send always** (40 ms/byte — both drive tools' default): firmware
  serial has no flow control.
- **Kill QEMU by PID**, never by pattern (house rule; the scripts comply).
- **`openbios-x86.dict` is the x86 dictionary**, not `openbios.dict` — the
  latter is the arch-less base it is built *from*, and booting it silently
  drops `arch/x86/init.fs` (no `/memory`, no `/cpus`, no `set-defaults`).
  `dict-identity` measures this on every run; POC-2 said the opposite until
  2026-08-23.
- **`1 0 /` hangs the 64-bit firmware with no exception** and that is not an
  IDT gap: `mu/mod` divides an `__int128`, so the compiler calls libgcc's
  `__udivmodti4` rather than emitting `idiv`. There is no `#DE` to catch.
- **A triple fault under `-no-reboot` looks like a clean rc=0 exit** — check
  the log for a prompt, don't trust the exit code. KVM's "internal error" is
  the louder failure mode.
- **Rebuild the firmware and the coreboot ROMs go stale** — and `build-openbios.sh`
  now tells you so at the moment it happens (TODO §17.6), rather than leaving you
  to meet it later as a SKIP:

  ```
  ==> NOTE: build-openbios/coreboot.rom no longer carries this firmware.
      ./smoke-openbios.sh coreboot will SKIP until you run:
          ./build-coreboot-openbios.sh x86
  ```

  It is a note, not a failure: rebuilding firmware without rebuilding a ROM is
  ordinary, and only matters if you then expect the coreboot tracks to run.
- **Timestamped builds, and how to turn that off** (TODO §17.5, corrected
  2026-08-29). The banner does **not** come from `__DATE__`/`__TIME__`:
  `Makefile.target` generates `obj-<arch>/forth/version.fs` from
  `date +'%b %e %Y %H:%M'` and compiles it into the dictionary. It is
  load-bearing — the ppc swap-in's proof (§3) is that banner — so it is not
  removed. Set `SOURCE_DATE_EPOCH` to pin it:

  ```sh
  SOURCE_DATE_EPOCH=1700000000 ./build-openbios.sh x86   # stamps "Nov 14 2023 22:13"
  ```

  Success signature, from
  [`tools/openbios-check-reproducible.sh`](../../tools/openbios-check-reproducible.sh)
  (**five** container builds, minutes each — two per arch, plus the unset-epoch
  negative control — deliberately **not** in `run-all.sh`):

  ```
  - x86: byte-identical across two builds, stamped 'Nov 14 2023 22:13' (3 artifacts)
  - amd64: byte-identical across two builds, stamped 'Nov 14 2023 22:13' (3 artifacts)
  - control: with SOURCE_DATE_EPOCH unset, x86's openbios-x86.dict differs … (12 bytes)
  PASS: TODO 17.5 measured rather than asserted …
  ```

- **Is the tree we measure the tree the record defines?** (TODO §17.5's last
  sentence, measured 2026-08-30.) The lab's tree is not stored anywhere — it is
  *defined* as the pinned commit plus [`patches/TESTED-TREE.patch`](patches/TESTED-TREE.patch),
  while the working copy under `~/openbios-lab/` has been patched, rebuilt and
  hand-edited for weeks. §17.5 said the two building identical bytes was a claim
  the lab *could* make; nobody had made it.

  ```console
  $ tools/openbios-check-cold-tree.sh examples/openbios-the-rival-that-shipped
    - source: 722/722 files sha256-identical — the pin plus TESTED-TREE.patch regenerates the working tree exactly
    - controls: a one-byte perturbation compares unequal; the two arches' dictionaries differ
    - reach: of the 6 artifacts, the two openbios.multiboot loaders do NOT embed the dictionary — a Forth-source
      change is witnessed by the .dict and openbios-builtin.elf only, a C-source change by all of them
  PASS: TODO §17.5's last sentence measured rather than asserted: … 6/6 artifacts byte-for-byte identical across x86 and amd64 …
  ```

  A cold clone plus four container builds (~6 min here), so it is **not** in
  `run-all.sh`. **The negative control was run and watched to bite** — a copy of
  the working tree with one line appended to `forth/bootstrap/bootstrap.fs`:

  ```console
  $ OPENBIOS_WORKDIR=/tmp/negctl tools/openbios-check-cold-tree.sh examples/openbios-the-rival-that-shipped
    - the COLD tree and the DEV tree are NOT the same source: 1 file(s) differ (cold has 722, dev has 722) — an edit
      lives in the working copy that no patch records … ./forth/bootstrap/bootstrap.fs
    - x86/openbios-x86.dict differs … by 50665 byte(s) — expected, given the source difference reported above
  FAIL: 5 cold-tree problem(s) — see the lines above
  ```

  That is the defect the check exists for, and it is silent otherwise: both
  trees build and both boot. **The control also found three bugs in the checker**
  — the artifact message originally read *"the sources are identical, so a third
  source of non-determinism has appeared"* in the very run whose source half had
  just reported them different; `cmp -l` was leaking `EOF on <file>` to stderr;
  and one edited file was counted as two, `diff` emitting a `<` and a `>` for the
  same path. None was visible in the passing run.
- **Both arches are byte-reproducible with the epoch pinned** (patch 48 closed
  the second cause: the bootstrap was baking **host-arena pointers** into the
  image, and `arch/x86` only escaped because `pointer2cell` subtracts
  `base_address` at narrower widths). The last line is the **negative control** —
  a build with the variable *unset*, watched to differ — and the checker refuses
  to pass without it, because "identical" and "compared nothing" print the same.
