#!/usr/bin/env bash
# Verdict: this directory's EXIT-trap safety net fires when a test dies without a verdict,
# stays quiet when one was printed, still runs registered cleanup — and no test here can
# disarm it by installing an EXIT trap of its own.
#
# The single implementation lives in tools/check-harness-net.sh. This five-line file exists
# so the check runs inside THIS suite's run-all.sh, and therefore in CI, rather than only in
# tools/ — and so a lab added later inherits the rule instead of rediscovering it.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/tools/check-harness-net.sh" \
     "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
