#!/usr/bin/env python3
# decode-cmdline.py — the FOREIGN decoder for the cmdline-ptr track's phys-0 dump.
#
# One implementation, two callers (never re-implemented — the repo's rule):
#   • build-cmdline-ptr-fixture.sh calls it to VERIFY the QEMU capture before it
#     ships the fixture (a bad capture must fail the build, not ship as truth);
#   • smoke-openbios.sh's `cmdline-ptr` track calls it as the ORACLE — an
#     independent Python `struct` decode of the same bytes the Forth walks, so
#     the grade is not the firmware grading itself.
#
# The dump is guest physical memory captured from address 0, so cmd_line_ptr — a
# physical address the (foreign) QEMU -kernel loader set — is a DIRECT OFFSET into
# the file. boot_params is located by the SAME two anchors bootparams.fth uses:
#   boot_flag  u16 @ bp+0x1fe == 0xAA55
#   header     u32 @ bp+0x202 == "HdrS" (0x53726448)
# then cmd_line_ptr is u32 @ bp+0x228 and cmdline_size is u32 @ bp+0x238, both LE.
#
# Default: print the NUL-terminated command line cmd_line_ptr names, verbatim.
# --json:  print {bp_off, cmd_line_ptr, cmdline_size, cmdline} for the builder.
import json, struct, sys

def find_boot_params(data):
    # first paragraph-aligned boot_params (every real loader aligns it), matching
    # the Forth's cle-find-bp; fall back to any offset if none is 16-aligned.
    hits = []
    start = 0
    while True:
        i = data.find(b"HdrS", start)
        if i < 0:
            break
        bp = i - 0x202
        if bp >= 0 and data[bp + 0x1fe:bp + 0x200] == b"\x55\xaa":
            hits.append(bp)
        start = i + 1
    for bp in hits:
        if bp % 0x10 == 0:
            return bp
    return hits[0] if hits else None

def decode(path):
    data = open(path, "rb").read()
    bp = find_boot_params(data)
    if bp is None:
        sys.exit("decode-cmdline: no boot_params (HdrS + 0xAA55) in the dump")
    cmd_ptr = struct.unpack_from("<I", data, bp + 0x228)[0]
    cmd_sz = struct.unpack_from("<I", data, bp + 0x238)[0]
    if not (0 < cmd_ptr < len(data)):
        sys.exit(f"decode-cmdline: cmd_line_ptr 0x{cmd_ptr:08x} is outside the "
                 f"0x{len(data):x}-byte dump — the pointer does not resolve")
    raw = data[cmd_ptr:].split(b"\x00", 1)[0]
    return bp, cmd_ptr, cmd_sz, raw.decode("latin1")

def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    paths = [a for a in args if not a.startswith("--")]
    if len(paths) != 1:
        sys.exit("usage: decode-cmdline.py [--json] <dump.bin>")
    bp, cmd_ptr, cmd_sz, cmdline = decode(paths[0])
    if as_json:
        print(json.dumps({"bp_off": bp, "cmd_line_ptr": cmd_ptr,
                          "cmdline_size": cmd_sz, "cmdline": cmdline}))
    else:
        sys.stdout.write(cmdline)

if __name__ == "__main__":
    main()
