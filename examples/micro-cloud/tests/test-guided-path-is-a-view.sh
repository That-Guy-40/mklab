#!/usr/bin/env bash
# Verdict: §0.2's invariant holds — every guided step names a command you could type.
#
#   > The guided path is a VIEW of the raw path, never a parallel implementation.
#   > A guided step must name the exact command it runs, and that command must be
#   > invocable by hand. Delete the guided path and nothing is lost.
#
# The checks live in tools/check-guided-path-is-a-view.sh because the surfaces they cover
# are not this lab's: the TUI wizards are phase 6's, the learning paths are the catalog's,
# and the invariant is the plan's. A second copy scoped to micro-cloud would be a second
# implementation of a guard whose whole subject is "do not build a second implementation".
# This file exists so the shared check runs inside THIS suite's run-all.sh, and therefore
# inside CI.
#
# WHAT IT IS NOT. It does not execute a walkthrough — tools/wizard-walkthrough.sh does that
# for the five START_HERE documents, and is strictly stronger. It asks the narrower question
# that had never been asked of the wizards: does the command a novice is told to run
# actually exist, and does the tool's dispatch accept that verb? Asked by RUNNING the tool
# and comparing against a verb nobody has, never by grepping a `case` statement.
#
# It found a defect in itself on its first negative control, which is why the run is worth
# having: `lab-vm.sh boot` is not a verb, but that tool's help says "--secure-boot" and
# "first-boot command", and a normalisation applied to only one side of the comparison
# reported it PRESENT. The same one-sided form was in this suite's
# test-preserve-capability-table.sh, latent; both are fixed and both now carry a control
# for the shape.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "$REPO/tools/check-guided-path-is-a-view.sh"
