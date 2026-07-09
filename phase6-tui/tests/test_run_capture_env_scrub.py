"""Regression (Review phase6 W2): run_capture must not leak the web UI's
Basic Auth credential into child processes.

The web UI stashes its credential in LAB_WEB_AUTH_* env vars for the auth
middleware.  The phase scripts run via `sudo` as root, so an un-scrubbed
`os.environ.copy()` would hand that secret to root children (and anything
they spawn).  run_capture now drops the three LAB_WEB_AUTH* vars from the
default child environment while leaving everything else intact.
"""

from __future__ import annotations

import sys

from lab_tui.backends.base import run_capture

_PROBE = (
    "import os;"
    "print('PASS=' + os.environ.get('LAB_WEB_AUTH_PASSWORD', 'ABSENT'));"
    "print('USER=' + os.environ.get('LAB_WEB_AUTH_USER', 'ABSENT'));"
    "print('AUTH=' + os.environ.get('LAB_WEB_AUTH', 'ABSENT'));"
    "print('KEEP=' + os.environ.get('LAB_TUI_KEEP_PROBE', 'ABSENT'))"
)


def test_web_auth_creds_scrubbed_from_child_env(monkeypatch) -> None:
    monkeypatch.setenv("LAB_WEB_AUTH_PASSWORD", "s3cr3t-DANGER-PLACEHOLDER")
    monkeypatch.setenv("LAB_WEB_AUTH_USER", "alice")
    monkeypatch.setenv("LAB_WEB_AUTH", "alice:s3cr3t-DANGER-PLACEHOLDER")
    monkeypatch.setenv("LAB_TUI_KEEP_PROBE", "kept")

    cp = run_capture([sys.executable, "-c", _PROBE])
    assert cp.returncode == 0, cp.stderr
    assert "PASS=ABSENT" in cp.stdout, "auth password leaked into child env"
    assert "USER=ABSENT" in cp.stdout, "auth user leaked into child env"
    assert "AUTH=ABSENT" in cp.stdout, "combined auth var leaked into child env"
    # A non-secret var must still propagate — we scrub the credentials, not the
    # whole environment (backends need PATH, HOME, LAB_STATE_DIR, …).
    assert "KEEP=kept" in cp.stdout, "run_capture wrongly dropped a non-secret var"


def test_explicit_env_is_passed_through_verbatim() -> None:
    # When a caller passes env= explicitly, we honour it as-is (no scrub) — the
    # scrub applies only to the default os.environ.copy() path.
    cp = run_capture([sys.executable, "-c", _PROBE], env={"LAB_WEB_AUTH": "x:y"})
    assert cp.returncode == 0
    assert "AUTH=x:y" in cp.stdout
