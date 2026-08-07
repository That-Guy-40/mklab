#!/usr/bin/env bash
# Verdict: this directory's EXIT-trap safety net fires when a test dies without a
# verdict, stays quiet when one was printed, still runs registered cleanup — and no test
# here can disarm it by installing an EXIT trap of its own.
#
# netboot/tests got a lib.sh on 2026-08-07, later than everywhere else. Both defects the
# shared checker hunts were present here: the one test in the directory carried its own
# inline `trap … EXIT` (which would have replaced any net it was later given), and that
# trap treated rc=1 as a normal quiet exit — so a `die` inside sign-payload.sh would have
# ended the run with a bare status and no verdict line.
#
# The single implementation lives in tools/. This five-line file exists so the check runs
# inside THIS suite's run-all.sh, and therefore in CI, rather than only in tools/.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/tools/check-harness-net.sh" \
     "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
