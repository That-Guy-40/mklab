#!/usr/bin/env bash
# test-smoke-launcher.sh — run smoke-openbios.sh's `launcher` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (no QEMU, or a firmware not built) and exit code stand. The track drives
# the SHIPPED run-openbios-qemu.sh on a pty — the command a human types.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" launcher
