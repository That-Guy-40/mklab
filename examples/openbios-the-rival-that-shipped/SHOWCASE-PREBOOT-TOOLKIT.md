# Showcase — the preboot structure toolkit, in one boot

`./showcase-preboot-toolkit.sh` — **PASS / FAIL / SKIP**, ~90 s on KVM (measured, not guessed: 89 s wall with eight acts; 60.3 s with the first six).

Every B.3 smoke track proves one reader against one foreign oracle. This is the
other view: **one machine, one boot, eight acts**, in the order a real preboot
investigation would take them. It is a demo *and* a test — every act is graded,
and the run fails if any of them does not happen.

The point of putting them together is what the last line of each act says:
**two of these are positions no hosted tool can occupy at all.**

## What was built — the toolkit the showcase drives

Everything below is Forth, delivered to the firmware over a CD at the `0 >`
prompt; nothing is compiled in. Each file has a smoke track that grades it
against a **foreign oracle** — never our own reader.

| reader | what it is | oracle | act |
|---|---|---|---|
| `dsl/struct.fth` | the type layer: fields with **width and byte order**, a cursor for length-prefixed records, `>virt`/`>phys` | `readelf`, `cbfstool`, all four arches | every act |
| `dsl/cbfs.fth` | coreboot's CBFS, big-endian, walked in the mapped ROM window | `cbfstool print`, QEMU `xp` | I |
| `dsl/region.fth` + `dsl/lbregion.fth` | snapshot memory, let the firmware work, show what moved; aimed at the firmware's own coreboot-table parser (patch 58) | QEMU `xp`; three re-injected controls | II |
| `dsl/optrom.fth` | a PCI option ROM at its **live BAR**, its FCode byte-loaded from there; config space as bus-node methods (patches 55–57, 59–60) | QEMU `info pci`/`xp`, `romheaders`, one-byte controls | III |
| `dsl/sha256.fth` + `dsl/eventlog.fth` | SHA-256 as a pure function; a TCG event log authored and replayed | NIST vectors, python `hashlib`, `tpm2_eventlog`, a real edk2/swtpm log | IV |
| `dsl/fdt.fth` | the **live device tree flattened** to a v17 DTB, every field big-endian | `dtc`, `fdtdump`, `fdtget` on all four arches | V |
| `dsl/fdt-read.fth` | the **reader half**: a DTB parsed and **materialized** into the live tree | `dtc` decompiles the round trip identically on all four arches | VI |
| the firmware's own **dictionary**: `here!` refuses an overflow ([patch 66](patches/66-here-refuses-a-dictionary-overflow.patch)), `marker` with the refusals this dictionary needs ([patch 67](patches/67-marker-with-the-two-refusals-this-dictionary-needs.patch)) | not a reader — the allocator every reader lives in | `dict-limit`/`dict-used` from the running kernel, on all four arches; a marker's refusal graded against a tree the showcase itself grew | VII |
| `dsl/elf.fth` | the ELF gate: `?elf`, `?phdrs` with the gABI's ordering rule | `readelf`, `eu-elflint`, the linker's own `.hash` — and, for one clause, **no tool at all**, said so per run | VIII |

## What it needs

```
./build-openbios.sh amd64
./build-coreboot-openbios.sh amd64
```

plus `qemu-system-x86_64`, `genisoimage`, `python3`, `device-tree-compiler`
(`dtc`, `fdtdump`, `fdtget` — Act V's reader), and `toke` — which the
script builds on demand from the pinned `fcode-utils` clone `build-openbios.sh`
already made. Anything missing is a **SKIP with the reason**, never a quiet pass.

The ROM is checked against the tree before anything runs
(`tools/openbios-rom-provenance.sh`): a ROM built from an older payload would
make every act below report on firmware that is not the firmware under test.

## The setup

```
qemu-system-x86_64 -M pc -m 512 -bios coreboot.rom -nic none \
  -device e1000,romfile=fcode.rom  -device e1000,romfile=cfgcard.rom \
  -cdrom dsl.iso -serial unix:… -monitor unix:…
```

- the **firmware** is the amd64 OpenBIOS payload *inside* that coreboot ROM;
- the **readers** (`struct.fth cbfs.fth region.fth lbregion.fth optrom.fth
  sha256.fth eventlog.fth fdt.fth fdt-read.fth elf.fth`) arrive over a **CD** — with
  `IMPORT.DTB`, a tree `dtc` authors from `fixtures/fdt/import.dts` at run time, and
  `GOOD.BIN`/`BADINT.BIN`, two ELF64s [`fixtures/elf-gate/`](fixtures/elf-gate/README.md)'s builder
  authors at run time — nothing is compiled into the firmware for the occasion;
- the two **cards** carry real PCI expansion ROMs built by `toke` from
  [`fixtures/optrom/`](fixtures/optrom/README.md);
- QEMU's **monitor** is the observer from outside, used by the graded tracks —
  and its **QMP** socket is how Act V's bytes leave the guest.

Everything after the boot is typed at the `0 >` prompt over serial.

---

## ACT I — the firmware dissects the container it arrived in

```
0 > ffc01000 20 cbfs-list
cbfs| off=00000000 type=header     len=00000020 name=cbfs_master_header
cbfs| off=00000080 type=stage      len=00004a90 name=fallback/romstage
cbfs| off=00004b80 type=stage      len=0000fa02 name=fallback/ramstage
…
cbfs| off=0001b500 type=simple-elf len=00015c71 name=fallback/payload
cbfs| off=003fafc0 type=bootblock  len=00004000 name=bootblock
```

`0xffc01000` is **guest-physical flash**, derived at run time from the ROM's size
and `cbfstool layout` — QEMU maps a `-bios` ROM just under 4 GiB, and amd64 does
not relocate, so a Forth address *is* physical there.

`fallback/payload` is the firmware doing the reading.

**Graded:** the firmware's entry count must equal coreboot's own `cbfstool print`
of the same ROM on the host, and the walk must reach both `fallback/payload` and
`bootblock`.

> `cbfstool` cannot run inside the ROM it is reading. This reader can.

## ACT II — the firmware watches its own parser work

```
0 > region-selftest                 SELFTEST=1
0 > .lb-table                       LBT=1fe9e000 LBLEN=324
0 > lb-table-diff                   LBTAB=0
0 > lb-heap-diff
region| diff +1  was 0  now 10      region| diff +19  was 0  now 10
region| diff +9  was 0  now f0      region| diff +1a  was 0  now d7
region| diff +a  was 0  now 9       region| diff +1b  was 0  now 1f
region| diff +12 was 0  now 10
RANGES=2  STEP=90  HEAP=7  LAST=1b
```

The subject is `libopenbios/linuxbios_info.c` — the coreboot-table parser that
runs at init and that this lab has already patched twice (01, 39).
[Patch 58](patches/58-the-firmwares-own-walk-re-run-and-watched.patch) lets it be
**re-run on demand** into a scratch `sys_info` and watched.

Read the rows in order, because the order is the argument:

| row | what it establishes |
|---|---|
| `SELFTEST=1` | one byte **the test poked itself** is found. A diff of zero and an instrument that cannot see print the same clean run — so calibrate before aiming. |
| `LBTAB=0` | the region the parser **reads** is unchanged. `read_lbtable()` is a reader; this is the negative control. |
| `HEAP=7` | …but the allocator's **next block** changed. `convert_memmap()` mallocs and fills. **The firmware caused this.** |
| `LAST < STEP` | and only inside the `0x90` bytes it asked for — nine 16-byte `memrange`s. |

The seven changed bytes decode to the two RAM ranges of the machine QEMU was
given (`0x1000+0x9f000` and `0x100000+0x1fd71000` = 510 MiB of `-m 512`), and the
`region-diff` track reads the same guest-physical bytes back through QEMU's
monitor and requires them to agree with the firmware **byte for byte**.

**The review that scheduled this work expected the diff in the table.** It is
not there, and saying so is half of what this act is for — see the plan's
Spike 3, and [`dsl/lbregion.fth`](dsl/lbregion.fth)'s header.

## ACT III — a card's own program, run out of the card's own ROM

```
0 > dev /pci8086,1237@0/e1000@3 .fcode-marker optrom-report
MARK=none
optrom| phys=41040000 size=800
optrom| sig=aa55 pcir=50434952 vendor=ffff device=ffff imglen=800 … type=1 open-firmware fcode@40
0 > optrom-cfg optrom-run .fcode-marker
cfg| id=100e8086 rom=41040001
optrom| byte-load fcode@41040040
MARK=FCODE-FROM-CARD-RAN
0 > dev /pci8086,1237@0/e1000@4 optrom-run .cfg-id
CFGID=100e8086
```

`0x41040000` is the card's **ROM BAR** — live device memory, not a file. The
`0x55AA` header and the `PCIR` structure are parsed there through 1275's
device-register words, and then the card's FCode is `byte-load`ed **straight out
of the ROM**: its own program renames `e1000@3` to `fcode-card@3` and stamps the
marker. `MARK=none` first is not decoration — it is what stops the outcome being
pre-written.

The second card computes `cfg-id` about **itself**, from inside its own bytecode,
with `my-space` and a `" config-l@"` call to its parent bus. `0x100e8086` is
8086:100e, that slot. `0x12378086` — the host bridge — is what a card reads when
`my-space` answers 0, and it is what this firmware returned before
[patch 57](patches/57-every-probed-node-gets-its-probe-addr.patch).

## ACT IV — measured-boot arithmetic, with no TPM and no OS

```
0 > ." H_abc=" s" abc" sha256 .digest cr
H_abc=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
0 > evbuf dup evlog-author value evlen drop
0 > ." PCR0=" evbuf evbuf evlen + 40 0 evlog-replay .digest cr
PCR0=78830000e1197790a7e1884139a65721210d642ad112e6c9899a05cb214027a5
```

SHA-256 as a pure Forth function (matching NIST's vector and python's `hashlib`),
a 227-byte TCG crypto-agile event log authored in RAM, and PCR0 replayed as
`SHA256(PCR ‖ digest)` — graded against the same chain computed on the host.

**And it stays UNKNOWN.** A replay proves a log is internally consistent with a
claimed value. Whether a machine really measured those events needs a
hardware-signed quote, which nothing here can produce. That is a third verdict,
not a soft pass — the script prints it on every run.

## ACT V — the firmware hands its world over: the live tree, flattened

```
0 > /fdt-buf alloc-mem value fb  fb dt>fdt .fdt-counts
FDTL=1cde NODES=1f PROPS=d3
0 > ." FDTP=" fb >phys u. cr
FDTP=17978
```

Then, from outside: QMP `pmemsave` pulls those 7390 bytes out of guest-physical
memory, and the host runs **the device-tree compiler itself** on them:

```
$ dtc -I dtb -O dts tree.dtb          # rc 0 — 31 nodes, 211 properties
$ fdtget -t x tree.dtb /pci8086,1237@0/cfg-card@4 cfg-id
100e8086
$ grep 'fcode-card@3 {' tree.dts
		fcode-card@3 {
```

`dsl/fdt.fth` walks the firmware's own tree from `/` and writes a version-17
FDT — every field big-endian, the boot-handoff format a kernel is given. It is
the **last** act on purpose: the tree it flattens is the tree the earlier acts
just *changed*. Act III's FCode renamed `e1000@3` to `fcode-card@3` — that node
is in the blob. Act III's second card asked its own config space who it is and
published `cfg-id` — `fdtget` reads `100e8086` back out of the blob. The
evidence of the firmware's work, in the format it would hand over, read by a
tool that has never heard of this firmware.

**Graded:** `dtc` must parse it; `fdtdump`'s node and property counts must equal
the counts the firmware says it wrote; `cfg-id` must read back as `100e8086`;
`fcode-card@3` must be a node; `/memory reg` must decode (and it shows two cells
per address — the 64-bit root of patch 43).

> The bytes leave through **QMP**, not the HMP monitor: HMP reads a filename as
> an expression, a trap this repo's memory carried and the `fdt` track still
> walked into once.

## ACT VI — the firmware takes a world in: dtc's tree, ingested and round-tripped

Act V hands a tree over. This is the other direction: a tree **`dtc` authored
on the host** — `fixtures/fdt/import.dts`, compiled to a 499-byte blob as the
showcase starts, never cached — arrives over the CD, and the firmware takes it
*in*.

```
0 > load /ide@1/cdrom@0:\IMPORT.DTB
0 > load-base fdt-walk ." WALK=" . .fr-counts
WALK=-1 RNODES=4 RPROPS=d
0 > " /" find-device new-device s" imported" device-name
0 > load-base fdt>dt ." MADE=" . cr finish-device device-end
MADE=-1
0 > " /imported" find-package drop fi dt>fdt-from ." FDTIL=" u. cr
FDTIL=205
```

`fdt-walk` parses the blob and counts what `fdtdump` counts. `fdt>dt`
**materializes** it: the blob's root properties land on `/imported`, every
child becomes a `new-device`, every property a `property` — real nodes in the
live tree, the same tree Act V just flattened. Then the firmware flattens
*that subtree* again, QMP pulls it out, and `dtc` is asked the only question
that matters:

```
$ dtc -I dtb -O dts import-rt.dtb   vs   dtc -I dtb -O dts IMPORT.DTB
IDENTICAL
$ fdtget -t s import-rt.dtb / model
authored by dtc on the host, ingested by OpenBIOS
```

**In, out, and the compiler cannot tell.** Both decompiles are made *from
binary* on purpose — from a `.dts` dtc prints `[de ad be ef]`, from a blob
`<0xdeadbeef>`, for the same four bytes — so only the *tree* can differ, and
it does not. A string written by a tool on the host comes back out of a blob
this firmware built.

**Graded:** `WALK=-1` with the reader's counts equal to `fdtdump`'s; `MADE=-1`;
`dtc` parses the re-flattened subtree; the two decompiles are identical; the
model string reads back verbatim.

> What this round trip forced on the writer: FDT derives names from
> `BEGIN_NODE` and deprecates the `name` property, so `dt>fdt` skips it on every
> node — a materialized node gets one from `device-name`, and a blob dtc
> authored has none. Spike 4's counts moved when the rule became general.

---

## ACT VII — the firmware keeps its own house

Everything the earlier acts loaded, defined and grew lives in **one bump allocator**: the
dictionary. Every reader, every word typed, every device node Act VI materialized, every
property — the same array, one `here`. Two things happened to that allocator this week.

```
0 > device-end marker world              (typed BEFORE Act VI)
   …Act VI…
0 > ' world catch ." WORLD=" . cr
marker: the device tree grew after the mark -- forget refused WORLD=-2
```

OpenBIOS never had `marker`/`forget`, and a plain ANS one would be unsafe here: Act VI's
`/imported` subtree — its nodes, their two wordlist heads, every property struct, name and
value — was `allot`ed from the dictionary *above* the mark. Forgetting past it would leave the
tree pointing into space the next definition reuses. So patch 67's `marker` walks the tree
first and **refuses by name**. (The `device-end` is not decoration: Act III left a node active,
and a marker, like any word, is created *into* the active package — the first run defined
`world` in the host bridge's wordlist and Act VI's `device-end` made it invisible.)

```
0 > marker scratch  : w2 2 ;  create buf 100 allot
0 > scratch ." DUC=" dict-used u. cr
dict-used 42e48 → 42fd0 → 42e48     +392 bytes taken, every one given back; w2: $find → 0
0 > : ovp room a + allot ." OVER-END" cr ;
0 > ' ovp catch ." OVER-RC=" . cr
Dictionary space overflow: dicthead=000000000010000a dictlimit=0000000000100000 -- refused
OVER-RC=-8                            dict-used unchanged; room left 774584 of 1048576
```

A scratch marker with nothing but words above it reclaims **byte-exactly**. And an allot 10
bytes past the end is **refused**: -8 (ANS *dictionary overflow*) to the `catch`, not a byte
taken. Before patch 66 the kernel printed that same line and *continued* with `here` past the
end — on the hosted target the next `.` segfaulted the firmware (its pictured-number pad lives
at `here`); on ppc one `,` rewrote two of `console_ops`' function pointers and the prompt still
said `ok`. A refusal that takes nothing is what a firmware's allocator owes its caller.

**Graded:** `WORLD=-2` with the tree reason named; `DUC = DUA` and `DUB > DUA`; `w2` no longer
findable; `OVER-RC=-8`; exactly one overflow line; no `OVER-END`; `dict-used` unchanged across
the refused allot.

---

## ACT VIII — the ELF gate: refused on the gABI's word alone

Two ELF64s the fixture builder authors as the showcase starts, identical outside their
program-header table: `GOOD.BIN` (`PHDR INTERP LOAD LOAD`) and `BADINT.BIN`
(`PHDR LOAD INTERP LOAD`).

```
0 > : gate load-base 200 + elf-at ?elf load-size 200 - ?phdrs ;
0 > load /ide@1/cdrom@0:\GOOD.BIN   eg-good
EG-GOOD-END
0 > load /ide@1/cdrom@0:\BADINT.BIN  eg-int
CONSTRAINT: PT_INTERP after a PT_LOAD (gABI: it must precede every loadable segment)
```

The gABI says `PT_INTERP` "must precede any loadable segment entry". Then the act asks the
host's tools about the same file, **inside the act, every run**:

```
$ readelf -lW badint.elf      → silent, rc 0        (its order check names PHDR only)
$ eu-elflint badint.elf       → No errors           (it checks INTERP multiplicity, not order)
  fs/binfmt_elf.c (v6.12)     → reads PT_INTERP wherever it sits, breaks at the first
```

**No tool on this host enforces that sentence.** The firmware refuses the file on the gABI's
word alone — and the act *says so from the measurement*: the sentence it prints is chosen by
what readelf and elflint answered, so if either ever starts flagging the file, the line changes
to say the description is out of date. (Its first draft did exactly that for the wrong reason:
`tr` had left a trailing space on `No errors ` and the string compare announced a foreign
flag. The wording-from-measurement branch was itself the liar for one run.)

This fixture exists because of a question — *what can we decide about `badord.elf`?* — whose
answer was that `badord.elf` violates two clauses and the firmware only ever refused it on the
first one checked. One fixture per clause.

**Graded:** `EG-GOOD-END` printed; `PT_INTERP after a PT_LOAD` exactly once; no `EG-INT-END`;
exactly one constraint failure; the oracle sentence chosen from the run's own measurements.

---

## Where each act is proven properly

The showcase is one boot and grades what one boot can. The tracks that grade each
piece against its full oracle set, with the negative controls:

| act | track | oracle |
|---|---|---|
| I | `cbfs-live`, `cbfs`, `cbfs-payload` | coreboot's own `cbfstool`, `readelf`, QEMU `xp` |
| II | `region-diff` | QEMU `xp`; three re-injected controls (blind instrument, no `>virt`, no walk) |
| III | `optrom` | QEMU `info pci` + `xp`, `romheaders`, one-byte controls, and **ppc** |
| IV | `event-replay`, `event-real`, `event-bench` | `tpm2_eventlog`, python `hashlib`, a real edk2/swtpm log and the guest's own PCRs |
| V | `fdt` | `dtc`/`fdtdump`/`fdtget` on **all four arches**; an LE-magic control and an overflow control |
| VI | `fdt-import` | the round trip decompiles identically on **all four arches**; `BAD-MAGIC` and `BAD-TOKEN` refused by name |
| VII | `dict-budget`, `marker` | the running kernel's `dict-limit`/`dict-used` on **all four arches**; the OVER control refused with -8 taking nothing; node/method/property/active-package refusals each isolated; LIFO |
| VIII | `elf-gate` | `readelf` (order), `eu-elflint` (multiplicity), the linker's `.hash`; one fixture per gABI clause, the INTERP-order one measured to have **no foreign oracle** |

```
./smoke-openbios.sh region-diff      # one verdict line
./tests/run-all.sh                   # every track
```
