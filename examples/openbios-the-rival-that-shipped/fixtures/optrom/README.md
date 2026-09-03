# `fixtures/optrom/` — the FCode option ROM the `optrom` track puts on a PCI card

B.3 Spike 3's original subject: **a PCI expansion ROM read from real device memory, and the
FCode it carries run from there.** The plan kept this row as *UNCOVERED* with two blockers —
*"this firmware binds no config-space words"* and *"the only FCode ROM in the repo is attached
to OFW"*. Both were measured away on 2026-09-03 (patch 55 for the first; the second was never a
blocker: the ROM's PCIR says vendor/device `ffff`, "any card", so it rides an e1000 under
OpenBIOS exactly as it does under OFW).

| file | what |
|---|---|
| [`fcode-card.fth`](fcode-card.fth) | the 3-line FCode driver: names its node `fcode-card` and leaves `fcode-marker = FCODE-FROM-CARD-RAN` in the device tree — the proof it ran, where a probe-time program can leave one. A copy of the OFW lab's ([`open-firmware-debugs-itself/dsl/fcode-card.fth`](../../../open-firmware-debugs-itself/dsl/fcode-card.fth)), per the self-containment rule |
| [`build-fcode-rom.py`](build-fcode-rom.py) | wraps `toke`'s bytecode in a PCI expansion ROM (0x55AA header, `PCIR`, code type 1 = Open Firmware, FCode at +0x40). Also a copy, plus `--code-type N` / `--bad-sig` so the track's **controls are derived from the subject** and differ from it in exactly one byte |

The track (`../../smoke-openbios.sh optrom`) tokenises the driver with `toke` (built by
`build-openbios.sh` from `fcode-utils`), builds the ROM and its two controls, and boots
x86 and amd64 OpenBIOS with four e1000s: the FCode ROM, the same ROM re-typed as x86 BIOS
code, no ROM at all (`romfile=`), and the same ROM with a broken signature. Nothing is
vendored — every artifact is rebuilt from these two files on each run, and `romheaders`
(fcode-utils) validates the subject on the host before QEMU spends a boot on it.

**What the track proves, per arch:** the firmware finds the ROM from the node's
`assigned-addresses` (the register-`30` entry patch 55 publishes) at the address QEMU's own
`info pci` reports for BAR6; `config-l@` (patch 55) reads the same address from config
space with the ENABLE bit set, and the node's vendor/device; the PCI ROM header and PCIR
parse at the live BAR through the device-register backend, and QEMU's monitor `xp` of the
same physical bytes equals the ROM **file** on the host; `byte-load` straight out of the
ROM renames the node and stamps the marker; `config-l!` clearing the enable bit makes the
header vanish at the same address and setting it brings it back. The x86-typed control is
refused by name (`NOT-FCODE`), the signature-broken one by name (`BAD-SIG`), the ROM-less
device reports `none` and has no BAR6 in `info pci`.
