#!/usr/bin/env bash
# Five lines: exec the checker, so it runs inside the tools suite (and therefore CI)
# rather than only when someone remembers to type it. Same shape as its siblings.
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/check-bzimage-detection.sh" "$@"
