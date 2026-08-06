#!/usr/bin/env bash
# Verdict: this directory's EXIT-trap safety net fires when a test dies without a
# verdict, stays quiet when one was printed, still runs registered cleanup — and no
# test here can disarm it by installing an EXIT trap of its own.
#
# THIS LAB IS WHERE THE DEFECT WAS FOUND. On 2026-08-06, 23 of these 36 tests had
# replaced lib.sh's net with `trap 'cleanup_sandboxes' EXIT` (bash keeps ONE EXIT trap
# per shell) and could therefore die with no verdict line at all; 11 more re-inlined it
# and printed FAIL twice for one failure. MANUAL_TESTING.md §18 has the write-up.
#
# The checks were written here first and then moved to tools/check-harness-net.sh when
# phases 1-5 and micro-linux turned out to need the same ones — a copy per directory is
# one more place for the check to drift. This file stays so the check runs inside THIS
# suite's run-all.sh, which a tools/-only test would not.
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/tools/check-harness-net.sh" \
     "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
