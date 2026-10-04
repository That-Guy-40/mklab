#!/usr/bin/env bash
# tools/lib/bzimage.sh — ONE definition of "is this file an x86 bzImage?", so the
# callers that need it (the UKI/bootparams/cmdline-ptr fixture builders and the
# uki-workbench + rival smoke tracks) cannot drift apart. Sourced, never executed.
#
# WHY THIS FILE EXISTS. The detection used to be copy-pasted into six scripts as
# `file -b "$f" | grep -q 'Linux kernel x86 boot executable bzImage'`. file(1)
# grew a comma — file-5.46 prints `...executable, bzImage, version …` — and the
# literal match silently stopped matching, so every one of those scripts reported
# "no bzImage" with a valid kernel in hand and SKIPped (#500). Six copies meant
# six places to fix and six places for the next drift to hide; one function plus
# the guard in tools/tests/test-bzimage-detection.sh (which both proves this
# pattern against real file(1) wording AND refuses a re-inlined copy) is the fix.
#
# THE PATTERN is deliberately `Linux kernel x86.*bzImage`, not the exact phrase:
# it matches BOTH the old wording (`…executable bzImage`) and the new
# (`…executable, bzImage`), so it survives the wording drift that caused #500 and
# will not re-break on the next one, while staying specific — only file(1)'s
# bzImage line carries both `Linux kernel x86` and `bzImage`.
is_bzimage() { [[ -r "$1" ]] && file -b "$1" 2>/dev/null | grep -q 'Linux kernel x86.*bzImage'; }
