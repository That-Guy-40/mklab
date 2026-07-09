"""Regression (Review phase6 T3): _toml_str must produce VALID TOML for any
input, including control characters.

The wizard writes generated TOML to disk without re-parsing.  The earlier
_toml_str escaped only `\\` and `"`, so a pasted newline/tab in a single-line
field wrote a syntactically broken basic string (masked in the live preview
as "(invalid input)").  Every value must now round-trip through tomllib.
"""

from __future__ import annotations

import tomllib

from lab_tui.screens.wizards.base import _toml_str


def _roundtrip(val: str) -> str:
    """Embed val via _toml_str, parse it back, return the parsed value."""
    return tomllib.loads(f'x = "{_toml_str(val)}"\n')["x"]


def test_quotes_and_backslashes_still_roundtrip() -> None:
    for v in ['say "hi"', "back\\slash", 'both a "quote" and a \\ backslash']:
        assert _roundtrip(v) == v


def test_control_characters_produce_valid_toml() -> None:
    # The heart of T3: these used to write invalid TOML.
    for v in ["line1\nline2", "tab\tsep", "carriage\rreturn",
              "nul\x00byte", "bell\x07x", "delete\x7fx"]:
        assert _roundtrip(v) == v, f"failed to round-trip {v!r}"


def test_newline_is_escaped_not_emitted_literally() -> None:
    out = _toml_str("a\nb")
    assert "\n" not in out, "a literal newline breaks a single-line basic string"
    assert "\\n" in out
