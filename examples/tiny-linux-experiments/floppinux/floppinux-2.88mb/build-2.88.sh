#!/usr/bin/env bash
# Convenience wrapper: build/boot FLOPPINUX as a 2.88 MB extended-density floppy.
#
# Exactly equivalent to running the parent builder with the size knob set:
#     FLOPPY_KB=2880 ../build-floppinux.sh "$@"
#
# All subcommands pass through (build | pack | boot | test | clean), so:
#     ./build-2.88.sh build      # full build → a 2.88 MB floppinux.img
#     ./build-2.88.sh pack       # re-pack the floppy at 2.88 MB (after a build)
#     ./build-2.88.sh test       # headless serial boot
#
# NOTE: there is a single $OUT/floppinux.img shared with the parent lab; building
# here REPLACES it with the 2.88 MB image (bzImage/rootfs are size-independent).
exec env FLOPPY_KB=2880 "$(dirname -- "${BASH_SOURCE[0]}")/../build-floppinux.sh" "$@"
