#!/usr/bin/env bash
# Verdict: this lab's help text is DATA — no command substitution in any usage
# heredoc, and `--help` runs nothing.
#
# WHY THIS FILE EXISTS AT ALL. Until 2026-08-25 this lab had no tests/ directory,
# so nothing here was ever aimed at tools/check-usage-is-data.sh — and when it
# finally was, all five scripts came back UNKNOWN: `--help` exited 1 on four of
# them (they take a positional flavor and fell through to the usage-error path)
# and, on build-coreboot-openbios.sh, exited 0 having ACTUALLY STARTED A
# COREBOOT BUILD. Asking a tool to describe itself is not supposed to be the
# thing that does the work.
#
# "I could not check this" is not "this is fine" — that is the whole reason the
# checker reports an unusable --help as a defect rather than skipping it, and
# the reason the gap was visible at all once someone ran it.
#
# The checks live in tools/check-usage-is-data.sh, not here: a copy per lab is
# one more place for it to drift from the thing it is checking. This file exists
# so the shared one runs from CI (.github/workflows/ci.yml lists it by path,
# alongside the other example-lab guards).
#
# It is `exec`, not a call: the checker owns its own verdict line, its own EXIT
# net and its own §0 self-controls — 13 fixtures it must classify correctly
# BEFORE it is allowed to look at a real file, because a scan that matches
# nothing and a scan that is broken print the same green tick.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
LAB="$REPO/examples/openbios-the-rival-that-shipped"

# Named individually rather than globbed. A glob silently covers whatever
# happens to be on disk, so a new script would be checked without anyone
# deciding it should be — and, worse, a RENAMED one would quietly stop being
# checked while this file still looked complete.
exec "$REPO/tools/check-usage-is-data.sh" \
     "$LAB/build-openbios.sh" \
     "$LAB/build-coreboot-openbios.sh" \
     "$LAB/run-openbios-qemu.sh" \
     "$LAB/smoke-openbios.sh" \
     "$LAB/showcase-rival-boots-linux.sh"
