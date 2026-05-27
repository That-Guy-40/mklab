#!/usr/bin/env bash
# Validate the push subcommand: usage guard, and that it delegates correctly
# to docker push (negative case: nonexistent image → docker error, not a
# script-level crash).  No actual registry needed.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

require_docker

# Usage guard: push with no argument must die with a usage message.
expect_error "push no tag" "usage" -- push

# Push of a nonexistent local image must fail with a docker error (image not
# found / manifest unknown), not a script usage error.
bogus="lab-push-validation-nonexistent-$$:latest"
out="$("$LAB_DOCKER" push "$bogus" 2>&1)" && fail "push of bogus image should fail; got: $out" || true
# The error must come from docker, not from our script's usage guard.
if grep -qi "usage:" <<<"$out"; then
    fail "push of bogus image gave usage error instead of docker error; got: $out"
fi
note "bogus-image push correctly forwarded to docker (not a usage error)"

# Positional arg form.
out2="$("$LAB_DOCKER" push "$bogus" 2>&1)" && fail "positional push should fail; got: $out2" || true
note "positional-arg push form works"

pass "push validation OK"
