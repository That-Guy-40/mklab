#!/usr/bin/env bash
# test-smoke-uki.sh — run smoke-openbios.sh's `uki` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (no ukify, binutils, file, GNU cpio, genisoimage, a QEMU, the systemd EFI
# stub, a readable bzImage, or a firmware not built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" uki
