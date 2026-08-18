#!/usr/bin/env bash
# Verdict: this phase's help text is DATA — no command substitution in its usage heredoc,
# and `--help` runs nothing.
#
# The checks live in tools/check-usage-is-data.sh because the defect that prompted them
# is latent in every driver here: each usage heredoc has an UNQUOTED delimiter (it must —
# the text interpolates $LAB_PROG), so a backtick or $(...) that lands in one will RUN.
# Phase 2 shipped exactly that for months. A copy of the check per phase would be six
# places for it to drift; this file exists so the shared one runs inside THIS suite's
# run-all.sh, and therefore inside CI.
#
# Note it is NOT just "--help writes nothing to stderr". That cheap version passes a
# substitution that SUCCEEDS — `date`, $(pwd) — while the help text is silently
# rewritten. The tool proves that gap against its own fixture before it checks anything.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$REPO/tools/check-usage-is-data.sh" \
     "$REPO/phase3-docker/lab-docker.sh"
