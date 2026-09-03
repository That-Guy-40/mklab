#!/usr/bin/env bash
# test-smoke-cbfs-payload.sh — run smoke-openbios.sh's `cbfs-payload` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (when a ROM/cbfstool or a firmware is not built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" cbfs-payload
