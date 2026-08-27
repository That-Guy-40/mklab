#!/usr/bin/env bash
# The patch series against itself and against the build.
# TODO §14 Tier A guards A3 and A4. One implementation, in tools/; this execs it
# so the check runs inside this suite rather than only when someone remembers.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
exec "$REPO/tools/check-patch-hygiene.sh" "$HERE/.."
