#!/usr/bin/env bash
# Five lines: exec the checker, so it runs inside a suite (and therefore CI) rather than
# only when someone remembers to type it. Same shape as every tests/test-usage-is-data.sh.
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/check-doc-verbs.sh" "$@"
