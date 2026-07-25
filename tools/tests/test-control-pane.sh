#!/usr/bin/env bash
# Run control-pane's headless tests: the pure engine + milestones unit tests (stdlib
# unittest — no pytest/deps) and the `watch` integration. One line per group + a summary.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail=0

echo "== unit tests: engine + milestones (python3 -m unittest) =="
if python3 -m unittest discover -s "$HERE" -p 'test_*.py' 2>&1; then
  echo "PASS: engine + milestones unit tests"
else
  echo "FAIL: engine + milestones unit tests"; fail=1
fi

echo "== integration: control-pane watch =="
bash "$HERE/test-watch.sh"; rc=$?
[[ $rc -eq 0 || $rc -eq 77 ]] || fail=1

echo "== integration: control-pane list + inspect (fleet) =="
bash "$HERE/test-list.sh"; rc=$?
[[ $rc -eq 0 || $rc -eq 77 ]] || fail=1

if [[ $fail -eq 0 ]]; then echo "==== control-pane: all green ===="; else echo "==== control-pane: FAILURES ===="; fi
exit $fail
