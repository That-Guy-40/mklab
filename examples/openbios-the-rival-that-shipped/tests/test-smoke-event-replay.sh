#!/usr/bin/env bash
# test-smoke-event-replay.sh — run smoke-openbios.sh's `event-replay` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track; it `exec`s the driver, whose verdict,
# SKIP (when tpm2_eventlog, QEMU or a firmware is not present) and exit code stand.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" event-replay
