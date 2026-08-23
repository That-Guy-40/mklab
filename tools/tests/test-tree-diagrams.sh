#!/usr/bin/env bash
# Five lines: exec the checker so it runs inside a suite, and therefore in CI.
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/check-tree-diagrams.sh" "$@"
