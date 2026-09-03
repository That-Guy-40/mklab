#!/usr/bin/env bash
# test-smoke-cbfs-live.sh — run smoke-openbios.sh's `cbfs-live` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (when the amd64 coreboot ROM or its cbfstool is not built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" cbfs-live
