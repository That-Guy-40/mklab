#!/usr/bin/env bash
# Verdict: this lab's help text is DATA — no command substitution in its usage heredoc,
# and `--help` runs nothing.
#
# The checks live in tools/check-usage-is-data.sh because the defect is latent in every
# driver in this repo: a usage heredoc's delimiter has to be UNQUOTED (the text
# interpolates $LAB_PROG), so a backtick or $(...) landing in one will RUN. Phase 2
# shipped exactly that for months and every reader was silently handed the wrong help.
#
# It matters more than usual here: this driver's help names a mirror URL and a preseed
# directive, which is precisely the kind of text someone reaches for a backtick to format.
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec "$REPO/tools/check-usage-is-data.sh" \
     "$REPO/examples/air-gapped-install/airgap.sh"
