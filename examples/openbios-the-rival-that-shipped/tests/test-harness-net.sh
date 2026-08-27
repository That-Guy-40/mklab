#!/usr/bin/env bash
# The EXIT-trap safety net this suite depends on, proved rather than assumed.
# One shared implementation in tools/; this execs it so the check runs inside the
# suite (and therefore CI) rather than only when someone remembers.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
exec "$(cd "$HERE/../../.." && pwd)/tools/check-harness-net.sh" "$HERE"
