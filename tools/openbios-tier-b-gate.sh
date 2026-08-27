#!/usr/bin/env bash
# openbios-tier-b-gate.sh <changes-result> <relevant> <tier-b-result>
#
# The one status check openbios Tier B is meant to be REQUIRED on. It always
# reports — that is its whole purpose — so it is exactly the shape that can pass
# while proving nothing, and it is written default-deny for that reason.
#
# WHY IT EXISTS. A workflow-level `on.pull_request.paths` filter stops the run
# from happening at all on a non-matching PR, so a required check never reports
# and the PR blocks forever on something that will never arrive. Instead the
# workflow always runs, a cheap `changes` job decides relevance, the expensive
# job is skipped when it is not needed, and THIS reports on behalf of all of it.
#
# THE ONLY RESULTS THAT PASS ARE THE TWO THAT WERE REASONED ABOUT. Everything
# else — a failed relevance job, a cancelled build, a combination nobody has seen
# — fails by falling through. A gate whose default is "pass" is a gate that opens
# when its own machinery breaks, and the machinery breaking is precisely when you
# need it shut.
#
# Note the third row: a relevant change that did NOT run Tier B is a FAILURE, not
# a pass. That is the gating logic having broken silently, which otherwise looks
# identical to a PR that legitimately needed nothing.
set -uo pipefail

if [[ $# -ne 3 ]]; then
    cat >&2 <<'USAGE'
usage: openbios-tier-b-gate.sh <changes-result> <relevant> <tier-b-result>

  changes-result   result of the relevance job: success|failure|cancelled|skipped
  relevant         its verdict: true|false  (empty when that job did not finish)
  tier-b-result    result of the build+boot job: success|failure|skipped|cancelled

Exits 0 only for the two combinations that are known-good; anything else exits 1.
USAGE
    exit 2
fi

CHANGES="$1" RELEVANT="$2" TIER_B="$3"
echo "changes=$CHANGES relevant=$RELEVANT tier-b=$TIER_B"

case "$CHANGES/$RELEVANT/$TIER_B" in
    success/true/success)
        echo "PASS: a path Tier B depends on changed, and Tier B built the firmware and booted it"
        exit 0 ;;
    success/false/skipped)
        echo "PASS: nothing Tier B depends on changed, so it was not run — this is the filter working, not a silence"
        exit 0 ;;
    success/true/skipped)
        echo "::error::a relevant change did NOT run Tier B — the gating logic is broken, and a broken filter looks exactly like a PR that needed nothing"
        exit 1 ;;
    *)
        echo "::error::refusing to pass on an unreasoned combination: changes=$CHANGES relevant=$RELEVANT tier-b=$TIER_B"
        echo "This gate is default-deny. If this combination is legitimate, add it as a row"
        echo "above with a reason, and add it to tools/tests/test-openbios-tier-b-relevance.sh."
        exit 1 ;;
esac
