#!/usr/bin/env bash
# test-smoke-elf-sweep.sh — run smoke-openbios.sh's `elf-sweep` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (a QEMU or a firmware not built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" elf-sweep
