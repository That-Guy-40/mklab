#!/usr/bin/env bash
# Verdict: this lab's help text is DATA — no command substitution in its usage heredoc,
# and `--help` runs nothing.
#
# The checks live in tools/check-usage-is-data.sh because the defect that prompted them is
# latent in every script with an UNQUOTED heredoc delimiter (which a usage heredoc must
# have — the text interpolates $LAB_PROG), so a backtick or $(...) that lands in one will
# RUN. Phase 2 shipped exactly that for months. This file exists so the shared check runs
# inside THIS suite's run-all.sh, and therefore inside CI.
#
# Note it is NOT just "--help writes nothing to stderr". That cheap version passes a
# substitution that SUCCEEDS — `date`, $(pwd) — while the help text is silently rewritten.
# The tool proves that gap against its own fixture before it checks anything real.
#
# SCOPE, NAMED RATHER THAN ASSUMED: only preserve.sh is checked here. fabric.sh has no
# `--help` and no usage heredoc (its usage is a one-line printf), so neither section of
# the tool applies to it — passing it in would have produced a §2 failure for a file that
# simply does not have the feature, which is worse than not checking it.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "$REPO/tools/check-usage-is-data.sh" \
     "$REPO/examples/micro-cloud/preserve.sh"
