#!/usr/bin/env bash
# test-smoke-cmdline-ptr.sh — run smoke-openbios.sh's `cmdline-ptr` track here.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (no python3, genisoimage, a QEMU, a readable bzImage, or a firmware not
# built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" cmdline-ptr
