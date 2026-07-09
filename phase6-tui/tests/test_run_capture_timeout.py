"""Regression (Review phase6 S1): run_capture must not hang forever.

A wedged phase script or an unresponsive engine daemon used to pin the
caller indefinitely — and in the web UI that call runs in an
`asyncio.to_thread` worker, so enough stuck calls exhaust the threadpool
and wedge uvicorn.  run_capture now kills the child after `timeout` and
surfaces a distinct non-zero exit (TIMEOUT_RC) instead of blocking.
"""

from __future__ import annotations

import sys
import time

from lab_tui.backends.base import DEFAULT_TIMEOUT, TIMEOUT_RC, run_capture


def test_hung_command_is_killed_and_surfaced() -> None:
    slow = [sys.executable, "-c", "import time; time.sleep(30)"]
    start = time.monotonic()
    cp = run_capture(slow, timeout=0.5)
    elapsed = time.monotonic() - start
    assert cp.returncode == TIMEOUT_RC, "a timed-out command must report TIMEOUT_RC (124)"
    assert "timed out" in cp.stderr
    assert elapsed < 10, "run_capture must return promptly after the timeout, not hang"


def test_normal_completion_is_unaffected() -> None:
    cp = run_capture([sys.executable, "-c", "print('hi')"], timeout=10)
    assert cp.returncode == 0
    assert "hi" in cp.stdout


def test_default_timeout_is_set() -> None:
    # A finite default is what protects callers that don't pass `timeout=`
    # (every backend calls run_capture(argv) with no explicit timeout).
    assert isinstance(DEFAULT_TIMEOUT, (int, float)) and DEFAULT_TIMEOUT > 0
