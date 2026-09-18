#!/usr/bin/env bash
# test-smoke-cmdline-edit.sh — run smoke-openbios.sh's `cmdline-edit` track here.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (no ukify, binutils, genisoimage, a QEMU, the systemd EFI stub, or a
# firmware not built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" cmdline-edit
