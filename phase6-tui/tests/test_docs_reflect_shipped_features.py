"""Regression (Review phase6 T1): docs must not advertise shipped features
as unshipped.

README.md and SHOWCASE.md previously said the five create wizards and
console attach were "deferred to v0.2" — while both were fully implemented
and tested.  The danger is an auditor concluding "no wizard ⇒ no
TOML-generation surface" and skipping the code that writes specs.  This
guard fails if that stale claim ever returns.
"""

from __future__ import annotations

from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent


def test_wizard_modules_actually_ship() -> None:
    # The doc guard below is only meaningful because these exist.
    wiz = _ROOT / "lab_tui" / "screens" / "wizards"
    missing = [f"phase{n}.py" for n in range(1, 6) if not (wiz / f"phase{n}.py").exists()]
    assert not missing, f"expected create wizards are missing: {missing}"


def test_docs_do_not_claim_shipped_features_are_deferred() -> None:
    for doc in ("README.md", "SHOWCASE.md"):
        text = (_ROOT / doc).read_text().lower()
        assert "deferred to v0.2" not in text, (
            f"{doc} still claims features are 'deferred to v0.2' — the create "
            "wizards and console attach ship in v0.1; update the doc."
        )
