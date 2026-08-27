#!/usr/bin/env bash
# test-smoke-amd64-linux.sh — run smoke-openbios.sh's `amd64-linux` track under this suite.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track — and with it the suite's ran/listed ratio
# and its by-name reporting of what skipped — not so a track is implemented twice.
# It `exec`s: the verdict line, the SKIP when the firmware is not built, and the
# exit code are all the driver's, which is what keeps one place to type a track by
# hand and one place for it to be wrong.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" amd64-linux
