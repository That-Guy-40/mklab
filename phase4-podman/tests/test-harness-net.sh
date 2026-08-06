#!/usr/bin/env bash
# Verdict: this directory's EXIT-trap safety net fires when a test dies without a
# verdict, stays quiet when one was printed, still runs registered cleanup — and no
# test here can disarm it by installing an EXIT trap of its own.
#
# The checks live in tools/check-harness-net.sh because every tests/ directory in this
# repo carries the same net, and a copy per directory is one more place for it to
# drift. This file exists so the check runs inside THIS suite's run-all.sh (and so
# inside CI), which a tools/-only test would not.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/tools/check-harness-net.sh" \
     "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
