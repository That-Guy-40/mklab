#!/usr/bin/env bash
# test-smoke-optrom.sh — run smoke-openbios.sh's `optrom` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (when the x86/amd64 firmware or toke is not present) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" optrom
