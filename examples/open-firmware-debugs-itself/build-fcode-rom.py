#!/usr/bin/env python3
"""build-fcode-rom.py — wrap a tokenized FCode image in a PCI expansion ROM.

Built to the contract READ OUT OF THE FIRMWARE, not out of the spec sheet —
`dev/pcibus.fth` `locate-fcode` (657) / `fcode-image?` (616) validate exactly:

  ROM+0x00  le16 == 0xaa55                     the signature
  ROM+0x02  le16 == OFFSET TO THE FCODE IMAGE   <-- OFW-specific! On an x86
                                                option ROM this field is the
                                                image SIZE/512. OFW reads it as
                                                an offset and adds it to the ROM
                                                base. Put a size here and it
                                                jumps into garbage.
  ROM+0x18  le16 == offset to the PCI Data Structure
  PCIR+0x00 "PCIR"
  PCIR+0x04 le16 vendor id  -- must match the device's, OR be 0xffff
  PCIR+0x06 le16 device id  -- must match the device's, OR be 0xffff
  PCIR+0x14 u8   code type  == 1   (Open Firmware FCode)
  PCIR+0x15 u8   indicator  0x80 = last image (else it walks to the next one)

0xffff/0xffff is "always accept" in fcode-image?, so the ROM does not need to
know which card it rides on — one artifact works on any QEMU PCI device.
"""
import struct, sys

fcode = open(sys.argv[1], "rb").read()
out = sys.argv[2]

PCIR_OFF, FCODE_OFF = 0x1C, 0x40

# The firmware trusts the FCode image's own be32 length field; sanity-check it
# here so a truncated .fc is caught on the host, not as a mystery hang in QEMU.
assert fcode[0] == 0xF1, f"not an FCode image (first byte {fcode[0]:#x}, want 0xf1)"
declared = struct.unpack(">I", fcode[4:8])[0]
assert declared == len(fcode), f"FCode length field {declared} != file size {len(fcode)}"

rom = bytearray(FCODE_OFF)
rom[0x00:0x02] = b"\x55\xaa"
struct.pack_into("<H", rom, 0x02, FCODE_OFF)      # offset to FCode, NOT size
struct.pack_into("<H", rom, 0x18, PCIR_OFF)

pcir = bytearray(0x18)
pcir[0x00:0x04] = b"PCIR"
struct.pack_into("<H", pcir, 0x04, 0xFFFF)        # vendor: always-accept
struct.pack_into("<H", pcir, 0x06, 0xFFFF)        # device: always-accept
struct.pack_into("<H", pcir, 0x0A, 0x18)          # PCIR structure length
pcir[0x0C] = 0x00                                 # PCIR revision
pcir[0x0D:0x10] = b"\x00\x00\xff"                 # class code (ff = misc)
pcir[0x14] = 0x01                                 # code type 1 = Open Firmware
pcir[0x15] = 0x80                                 # last image
rom[PCIR_OFF:PCIR_OFF + 0x18] = pcir

rom += fcode
# PCI expansion ROMs are read through a power-of-two BAR; pad so QEMU maps it.
size = 1
while size < len(rom):
    size <<= 1
size = max(size, 2048)
struct.pack_into("<H", rom, PCIR_OFF + 0x10, size // 512)   # image len in blocks
rom += b"\x00" * (size - len(rom))

open(out, "wb").write(rom)
print(f"wrote {out}: {len(rom)} bytes "
      f"(FCode {len(fcode)} B at +{FCODE_OFF:#x}, PCIR at +{PCIR_OFF:#x})")
