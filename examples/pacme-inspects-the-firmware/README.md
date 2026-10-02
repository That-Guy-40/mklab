# pacme inspects the firmware — GNU poke as a live, graded inspector of a running OpenBIOS

GNU poke's acme-style UI (**pacme**) is a structured binary inspector. This lab points it
not at a captured file but at a **running OpenBIOS firmware's own bytes**, live, over a seam —
and grades every structured view against the toolkit's Forth reader of the *same* bytes. It is
the interactive, live sibling of the [`pe.pk` host oracle](../../UKI_WORKBENCH_LAB_PLAN.md#4a-the-pe-oracle-gnu-pokes-pepk)
the UKI workbench adopted: two independent readers on one live buffer, now with a UI.

**The full design and rationale live in the plan:**
[`DESIGN-NOTES-pacme-a-live-firmware-inspector.md`](../../DESIGN-NOTES-pacme-a-live-firmware-inspector.md)
(TODO §32). This lab operationalizes it. It is a host-side sibling of, and consumes, the OpenBIOS
toolkit in [`../openbios-the-rival-that-shipped/`](../openbios-the-rival-that-shipped/) — its
firmware, its serial driver, and its `dsl/` readers (the grader for later spikes).

**The framing is LOCKED (design note §1): pacme runs on the HOST, not in the firmware.**
Porting poke *into* OpenBIOS is closed twice over — libpoke is a parser + JIT + GC + bignum +
pickle system assuming POSIX (reimplementing it is reimplementing poke), and it is **GPLv3**
while OpenBIOS is **GPLv2-only** (the same license wall GRUB 2 and `pe.pk` hit). Aggregation
across a socket is not linking, so running poke beside QEMU is not a workaround — it is what
pacme already is (a screen manager over pokelets talking to `poked` over a Unix socket), and it
is the only shape that is both legal and sane. The lab's deliverable is **the bridge + the
grading**, not a new reader.

## Status — Spike 3-full (the interactive acme UI), verified

The interactive tmux UI is **built from source and GRADED headlessly** — the strand the lab
deferred because "we do not verify a TUI." [`build-pacme.sh`](build-pacme.sh) builds pacme (its
pokelets + launcher) into a lab-local prefix, and [`smoke-pacme-ui.sh`](smoke-pacme-ui.sh) drives
the real UI with [`tools/ttydrive`](../../tools/ttydrive): launch pacme, trigger Layout 2 (a
`plet-repl` pane + a `plet-out` pane), type a poke read into the REPL, and read the value off the
**plet-out pane**. The grade is the lab's standing discipline, now through the UI: three readers of
one live-flattened device tree agree — the Forth `dsl/fdt.fth` produced the DTB, `fdt.pk` reads its
header headless, and the **pacme UI's** magic (`d00dfeed`) and totalsize match both. Control: the
UI read one field over is not the magic (position-specific). **The UI is graded against the toolkit,
never trusted as its own oracle.** Honest boundary (UNKNOWN≠PASS): this measures the UI's *data
path* (REPL → poked → plet-out); pixel layout, colors and ergonomics stay a by-hand judgement (see
[`MANUAL_TESTING.md`](MANUAL_TESTING.md)). pacme links no libpoke — it runs beside `poked` on the
host, the standing GPLv3 wall.

## Status — Spike 5 (live RAM), verified live

poke now reads **and edits the running firmware's RAM**, over a bespoke **gdbstub IO device** —
closing the lab's last `SNAPSHOT`-only boundary ([`smoke-pacme-live-ram.sh`](smoke-pacme-live-ram.sh)).
libpoke lets an embedding program register a *foreign* IOD (`pk_register_iod`), and QEMU's own
gdbstub answers memory reads/writes for the **live** guest; so [`gdb-iod.c`](gdb-iod.c) — built as
`pokegdb` by [`build-gdb-iod.sh`](build-gdb-iod.sh), against a byte-exact, attributed
[`vendor/libpoke.h`](vendor/README.md) — makes poke's `pread`/`pwrite` into gdb `m`/`M`
packets to a running OpenBIOS. The grade is three-way and then some: the firmware writes a nonce,
we **locate it in physical RAM by scanning** a `pmemsave` dump (a Forth address is *not* a physical
one on x86 OpenBIOS — the ofmem offset is real, so we never assume), and poke-over-gdbstub, the QMP
`xp` oracle, and the firmware all agree. Then the live-vs-snapshot split: the firmware overwrites
the cell and the **same** poke reader sees the new value through the gdbstub IOD (LIVE) while a
snapshot *file* still reads the old one (SNAPSHOT). Finally poke **writes** a value that QMP
confirms in live guest RAM and the firmware reads back from its own buffer — the RAM analogue of
Spike 4's edit-live. **Honest boundary:** this holds because OpenBIOS x86 runs with CR0.PG=0 (no
paging), so a gdb linear address *is* the guest-physical one and equals QMP `xp`; the IOD makes no
translation claim, the gdbstub is a QEMU debug transport (`-gdb`, a lab instrument), x86 only, and
libpoke is GPLv3 — host-side, never linked into the firmware.

## Status — Spike 4 (edit live), verified live

poke **edits** a value in the running firmware's NVRAM store over the bridge, and the firmware
**reads it** on its next boot — the editor side of the store note's survives-and-is-observed test
([`smoke-pacme-edit.sh`](smoke-pacme-edit.sh)). Spike 0 measured that a writable export of the
in-use IDE node is *refused*; this spike resolves the write path: attach the node with
**`share-rw=on`** (the device permits a second writer) and the writable export is **accepted**.
poke edits `boot-file=A`→`B` in the LIVE store; a fresh boot reads exactly `B`, nothing zapped (a
same-length value edit keeps the OFW nvram partition valid). The edit is LIVE (poke writes a
running QEMU's node over NBD); the firmware observes it at its next boot — NVRAM's access model,
stated. **Controls bite:** without `share-rw` the writable export is refused (the Spike-0 hazard —
the write path is permission-gated, not a free-for-all behind QEMU's back); an out-of-bounds poke
write is refused before any byte lands (refuse before the irreversible step).

## Status — PR2: Spike 2 (pickle vs the Forth toolkit) + the contract's NAME-live, verified live

Spike 2 points a GNU poke **pickle** at a firmware structure and grades every field against
the toolkit's Forth `dsl/` reader of the same bytes **and** a foreign oracle — three readers, one
artifact — across three subjects, and lands the contract's last extension, **`NAME-live`**:

- **`smoke-pacme-fdt.sh` (FDT — LIVE).** Our [`fdt.pk`](fdt.pk), the firmware's `dsl/fdt.fth`, and
  `fdtdump` decode OpenBIOS's own live device tree (flattened via `dt>fdt`) and agree on
  magic/totalsize/off_dt_struct. **`fdt-live`** (the contract's `NAME-live`, in
  `../openbios-the-rival-that-shipped/dsl/fdt-conform.fth`) re-flattens the live tree each call:
  a property added in the firmware grows the live re-read while an independent snapshot does not —
  the live-vs-snapshot distinction, graded (and the conformance checker now implements the liveness
  label + this behavioral grade). Controls bite: `fdt.pk` refuses a flipped-magic blob; a static
  `fdt-live` fails the live grade.
- **`smoke-pacme-pe.sh` (PE — HOST-ONLY).** poke's **shipped** `pe.pk`, `dsl/pe.fth`, and `objdump`
  agree on a UKI's COFF header (machine `8664`, section count); the PE-signature invariant refuses a
  flipped `PE\0\0`. A static file, so no live handle — stated.
- **`smoke-pacme-cbfs.sh` (CBFS — HOST-ONLY).** Our [`cbfs.pk`](cbfs.pk), `dsl/cbfs.fth`, and
  coreboot's `cbfstool` agree on the ROM's first CBFS entry (name + length); `cbfs.pk` refuses a
  non-`LARCHIVE` mapping. Big-endian metadata — the complement to PE's little-endian.

**`NAME-live` lands with its consumer, not as a stub:** the one genuinely live firmware structure
with a `dsl/` reader is the FDT, so `fdt-live` is where the contract's live handle earns its keep.
pe/cbfs are static-file (`HOST-ONLY`) grades — their live forms (a running UKI, flash CBFS) are the
gdbstub-IOD seam (Spike 5), stated not hidden.

## Status — PR1: the bridge is chosen and the seam is proven (Spikes 0 + 1), verified live

Measured end to end on this host (OpenBIOS x86 under QEMU/KVM, GNU poke 4.0):

- **Spike 0 — the bridge, DECIDED ([`bridge.sh`](bridge.sh)).** A running OpenBIOS session holds
  its NVRAM in a real block **node** (the IDE store the `persist` track boots). QEMU's QMP
  `block-export-add type=nbd` exposes that **live** node; poke opens `nbd+unix:///…` and reads the
  bytes the firmware just wrote. Honesty label: **`LIVE: block-only`**. The FILE surface (the
  backing image / a `pmemsave` snapshot) is the `SNAPSHOT` fallback; the gdbstub IOD for live RAM
  is Spike 5 (**now built** — see the Spike 5 status above).
  - **The one hazard, MEASURED not assumed:** a **writable** export of the in-use node is
    **refused** — *"Permission conflict on node '#blockN': permissions 'write' are both required …
    and unshared by block device 'ide1-hd1'."* So Spike 4 (edit live) cannot be a naive writable
    export behind QEMU's back; its honest shape is *pause the guest* or *route the edit through the
    guest's own store words*. The decision is settled by QEMU's block-permission system, not by us.
- **Spike 1 — the seam is faithful ([`smoke-pacme-seam.sh`](smoke-pacme-seam.sh)).** poke, reading
  the live IDE NVRAM over the NBD bridge, sees the firmware's own nonce bytes **byte-for-byte equal
  to `od`** of the store — the seam carries data faithfully before any pickle interprets it. **The
  control bites:** poke's read is also compared against a one-byte-flipped span and must mismatch,
  so the equality is a real byte comparison, not a tautology (and the assertion was watched to fail
  on an off-by-one read).

Teardown is **by PID** (the socket path is in QEMU's argv, so a pattern-kill would match QEMU
itself — the repo's standing rule). Both scripts SKIP by name without poke / qemu / the firmware.

## What this lab is NOT (scope guards, from the design note §6)

- **Not poke inside the firmware.** libpoke stays a host process; nothing GPLv3 is linked into the
  GPLv2 image.
- **Not a poke or pacme fork.** Stock `poked` + stock pokelets; the pickles are ours, the engine is
  upstream's.
- **Confined to the workbench's own QEMU** — owned bytes only (this lab's firmware session, its own
  images and sockets). Defensive, emulated, own machine.
- **Not a debugger for the firmware's code** — it reads/edits *structured firmware data*; gdb-for-code
  is the [`open-firmware-debugs-itself`](../open-firmware-debugs-itself/) lab's axis.

## The tracks this lab defines

| track | what it proves | the control that must bite |
|---|---|---|
| [`bridge.sh`](bridge.sh) (Spike 0) | the bridge chosen (NBD, live block-only); the writable-export hazard measured (refused) | the node must be real — an empty node-name would refuse for the wrong reason (fixed; the refusal is the true permission conflict) |
| [`smoke-pacme-seam.sh`](smoke-pacme-seam.sh) (Spike 1) | poke's bytes over the seam == `od` of the live store | poke's read vs a one-byte-flipped span must MISMATCH (and the equality fails on an off-by-one read) |
| [`smoke-pacme-fdt.sh`](smoke-pacme-fdt.sh) (Spike 2, FDT + NAME-live) | `fdt.pk` == `dsl/fdt.fth` == `fdtdump` on the live DTB; `fdt-live` re-reads a tree change | flipped-magic blob refused by `fdt.pk`; a static `fdt-live` fails the live grade (snap==live) |
| [`smoke-pacme-pe.sh`](smoke-pacme-pe.sh) (Spike 2, PE) | shipped `pe.pk` == `dsl/pe.fth` == `objdump` on a UKI's COFF header | a flipped `PE\0\0` refused by the signature invariant |
| [`smoke-pacme-cbfs.sh`](smoke-pacme-cbfs.sh) (Spike 2, CBFS) | `cbfs.pk` == `dsl/cbfs.fth` == `cbfstool` on the ROM's first entry | a non-`LARCHIVE` mapping refused by `cbfs.pk` |
| [`smoke-pacme-edit.sh`](smoke-pacme-edit.sh) (Spike 4) | poke edits `boot-file=A`→`B` in the LIVE NVRAM store (share-rw NBD); a fresh boot reads `B` | unshared node → writable export refused (Spike-0 hazard); an out-of-bounds poke write refused before it lands |
| [`smoke-pacme-span.sh`](smoke-pacme-span.sh) (Spike 3-lite) | poke's field byte-span (`'offset`/`'size`) == `dsl/fdt.fth`'s field-offset table — poke and the toolkit agree on *where* each field lives | the span one field over does not read the magic (spans are position-specific) |
| [`smoke-pacme-live-ram.sh`](smoke-pacme-live-ram.sh) (Spike 5) | `pokegdb` reads a firmware-written nonce in LIVE RAM (== QMP `xp`); a snapshot file stays at N1 while the live handle re-reads N2; poke writes N3 and QMP + the firmware both see it | a read one page over does not find the nonce; a vacuous "live" cannot pass (live==N2 ∧ snap==N1 ∧ N1≠N2) |
| [`smoke-pacme-ui.sh`](smoke-pacme-ui.sh) (Spike 3-full) | pacme's UI (built by [`build-pacme.sh`](build-pacme.sh), driven by `tools/ttydrive`) shows magic + totalsize for the live-flattened device tree, equal to `fdt.pk`'s headless reading and the spec's `d00dfeed` | the UI read one field over (offset 4) is not the magic; the plet-out pane must actually carry the value (ttydrive `wait`, not assumed) |

## All spikes landed

Every spike in the design note's plan (0, 1, 2, 3-lite, **3-full**, 4, 5) is **built and graded**.
What remains is not a spike but a *by-hand judgement*: the pacme UI's visual ergonomics (layout,
colours, interactive feel) — which a person evaluates with the manual drive in
[`MANUAL_TESTING.md`](MANUAL_TESTING.md). Everything machine-checkable is checked.

## Layout

```
pacme-inspects-the-firmware/
├── README.md               this file
├── PLAN.md                 PR1 coverage vs. the deferred spikes (links the design note)
├── MANUAL_TESTING.md       the ! commands + success signatures
├── deps.sh                 name + CHECK the external deps (poke required; pacme = Spike 3)
├── lib-bridge.sh           the seam: launch OpenBIOS + QMP NBD export + poke read + teardown-by-PID
├── bridge.sh               Spike 0 — the bridge DECISION + the writable-export hazard, measured
├── smoke-pacme-seam.sh     Spike 1 — poke's bytes over the seam == the firmware's own bytes
├── fdt.pk                  Spike 2 — our DTB pickle (big-endian); cbfs.pk — our CBFS pickle
├── cbfs.pk                 (pe.pk is poke's shipped pickle — no authoring)
├── smoke-pacme-fdt.sh      Spike 2 (FDT + NAME-live) — fdt.pk == dsl/fdt.fth == fdtdump; fdt-live LIVE
├── smoke-pacme-pe.sh       Spike 2 (PE, HOST-ONLY) — pe.pk == dsl/pe.fth == objdump on a UKI
├── smoke-pacme-cbfs.sh     Spike 2 (CBFS, HOST-ONLY) — cbfs.pk == dsl/cbfs.fth == cbfstool
├── smoke-pacme-edit.sh     Spike 4 — poke edits the LIVE NVRAM store; a fresh boot reads the edit
├── smoke-pacme-span.sh     Spike 3-lite — poke's field byte-span == the toolkit's field layout
├── gdb-iod.c               Spike 5 — `pokegdb`: a libpoke embed with a gdbstub-backed IO device
├── build-gdb-iod.sh        Spike 5 — compile pokegdb (links the shipped libpoke.so; no -dev needed)
├── smoke-pacme-live-ram.sh Spike 5 — poke reads+edits the firmware's LIVE RAM (gdb m/M, QMP oracle)
├── build-pacme.sh          Spike 3-full — build pacme from source into a lab-local prefix (no sudo)
├── smoke-pacme-ui.sh       Spike 3-full — pacme's tmux UI driven by ttydrive, graded vs the toolkit
└── vendor/                 byte-exact, attributed libpoke.h (the one header pokegdb needs)
```

## Running it

```sh
./deps.sh                                             # readiness (install poke if MISSING)
OPENBIOS_WORKDIR=~/openbios-lab ./bridge.sh           # Spike 0: the bridge + the hazard
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-seam.sh # Spike 1: the seam is faithful
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-fdt.sh  # Spike 2 (FDT) + NAME-live
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-pe.sh   # Spike 2 (PE)
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-cbfs.sh # Spike 2 (CBFS)
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-edit.sh # Spike 4 (edit live)
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-span.sh # Spike 3-lite (field spans)
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-live-ram.sh # Spike 5 (live RAM via gdbstub IOD)
./build-pacme.sh                                      # Spike 3-full: build pacme from source
OPENBIOS_WORKDIR=~/openbios-lab ./smoke-pacme-ui.sh   # Spike 3-full (the tmux UI, graded)
```

Each prints exactly one `PASS:`/`FAIL:`/`SKIP:` line. Needs GNU poke (`sudo apt-get install -y
poke`), `qemu-system-x86_64`, and a built OpenBIOS x86 firmware
(`../openbios-the-rival-that-shipped/build-openbios.sh x86`). See [`MANUAL_TESTING.md`](MANUAL_TESTING.md).
