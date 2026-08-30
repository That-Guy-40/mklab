#!/usr/bin/env bash
# test-smoke-rmw-fields.sh — run smoke-openbios.sh's `rmw-fields` track.
#
# THE DRIVER STAYS THE SINGLE IMPLEMENTATION (TODO §14, item 3). This wrapper is
# here so run-all.sh covers every track — and with it the suite's ran/listed ratio
# and its by-name reporting of what skipped — not so a track is implemented twice.
exec "$(dirname -- "${BASH_SOURCE[0]}")/../smoke-openbios.sh" rmw-fields
