#!/usr/bin/env bash
# The names this lab's scripts dispatch on, and the names its docs type.
# TODO §14 Tier A guards A2 and A5. One implementation, in tools/; this execs it
# so the check runs inside this suite rather than only when someone remembers.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
exec "$REPO/tools/check-track-list.sh" "$HERE/.."
