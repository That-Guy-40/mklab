#!/usr/bin/env bash
# test-smoke-cbfs-write.sh — run smoke-openbios.sh's `cbfs-write` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (when openbios-unix or the derived cbfstool is not built) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" cbfs-write
