#!/usr/bin/env bash
# test-smoke-region-diff.sh — run smoke-openbios.sh's `region-diff` track here.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (when a coreboot ROM is absent or predates the tree) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" region-diff
