#!/usr/bin/env bash
# Verdict: no patch here leaves arch/{x86,amd64} without saying which arches were tested.
#
# WHY THIS EXISTS. On 2026-08-25 the lab applied its first arch-neutral patch
# (15-forth-loader-divergence.patch, libopenbios/initprogram.c). That file is built
# unconditionally for EVERY arch and this lab builds ppc — but the ppc track had not been
# run when the PR was opened. It passed when it was finally run, so nothing broke. The
# point is that nothing would have SAID so: the gap was caught by a person asking whether
# the ppc tree was being polluted, and a safeguard that depends on someone thinking to ask
# is not a safeguard.
#
# The rule is therefore a check and not a habit. tools/check-patch-scope.sh proves itself
# on 8 fixtures before it looks at a real patch, grandfathers the pre-rule patches BY NAME
# WITH REASONS rather than by a date cutoff, and states on every run that sparc is reachable
# from these shared files and untestable here — so "all three named" can never be misread
# as "all arches covered".
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "$REPO/tools/check-patch-scope.sh" \
     "$REPO/examples/openbios-the-rival-that-shipped/patches"
