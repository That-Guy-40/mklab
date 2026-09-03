# Showcase — the preboot structure toolkit, in one boot

`./showcase-preboot-toolkit.sh` — **PASS / FAIL / SKIP**, ~40 s on KVM (measured, not guessed: 39 s wall).

Every B.3 smoke track proves one reader against one foreign oracle. This is the
other view: **one machine, one boot, four acts**, in the order a real preboot
investigation would take them. It is a demo *and* a test — every act is graded,
and the run fails if any of them does not happen.

The point of putting them together is what the last line of each act says:
**two of these are positions no hosted tool can occupy at all.**

## What it needs

```
./build-openbios.sh amd64
./build-coreboot-openbios.sh amd64
```

plus `qemu-system-x86_64`, `genisoimage`, `python3`, and `toke` — which the
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
  sha256.fth eventlog.fth`) arrive over a **CD** — nothing is compiled into the
  firmware for the occasion;
- the two **cards** carry real PCI expansion ROMs built by `toke` from
  [`fixtures/optrom/`](fixtures/optrom/README.md);
- QEMU's **monitor** is the observer from outside, used by the graded tracks.

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

```
./smoke-openbios.sh region-diff      # one verdict line
./tests/run-all.sh                   # every track
```
