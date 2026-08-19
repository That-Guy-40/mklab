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
# SCOPE, NAMED RATHER THAN ASSUMED: preserve.sh and micro-cloud.sh are checked here —
# both build their help with `cat <<EOF` and an UNQUOTED delimiter, which they have to,
# because the text interpolates a path. fabric.sh is deliberately absent: it has no
# `--help` and no usage heredoc (its usage is a one-line printf), so neither section of
# the tool applies to it — passing it in would have produced a §2 failure for a file that
# simply does not have the feature, which is worse than not checking it.
#
# run-privileged-demo.sh joined when it moved out of /tmp (LEDGER L10-12): its usage
# interpolates $0, so the delimiter cannot be quoted either.
#
# micro-cloud.sh joined the list with slice 10. Its usage names $SPEC_REL, so the delimiter
# cannot be quoted, so a backtick or $(...) landing in that text later would RUN — and would
# run silently, rewriting the help rather than failing it. That is the whole reason this
# check exists, and a new file with the feature and no check is how it gets missed.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "$REPO/tools/check-usage-is-data.sh" \
     "$REPO/examples/micro-cloud/preserve.sh" \
     "$REPO/examples/micro-cloud/micro-cloud.sh" \
     "$REPO/examples/micro-cloud/run-privileged-demo.sh"
