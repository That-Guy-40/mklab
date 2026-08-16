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


# ── P6-2: every wizard emitter must route through _toml_str ────────────────────
#
# ~30 emitted values across the five wizards go through the escaper. Exactly one
# did not — phase3's `volumes`, on the line after `ports` (which does) and beside
# env values (which do), phase-4 volumes (which do) and phase-5 profiles (which do).
#
# A multi-line paste into a single-line field is an ACKNOWLEDGED, reachable input —
# it is what the escaper's own docstring was written about — so the hostile value
# here is a realistic one, not a contrived attack string.

def _render_phase3(**fields) -> str:
    """Render the phase-3 wizard's TOML with the given field values.

    `generate_toml` reads each field through `self._val("f-<name>", self)`, so a
    stub `_val` is all that is needed — no Textual app, no event loop.
    """
    from lab_tui.screens.wizards.phase3 import DockerServiceWizard

    w = object.__new__(DockerServiceWizard)
    w._val = lambda ident, _owner=None: fields.get(ident[2:], "")  # strip "f-"
    return DockerServiceWizard.generate_toml(w)


def test_phase3_volumes_are_escaped_like_their_siblings() -> None:
    """The generated file must PARSE, and must not gain a key nobody wrote."""
    import tomllib

    hostile = '/tmp:/data"\nprivileged = true\nx = "'
    spec = _render_phase3(lab="l", svc="s", image="alpine", vols=hostile)
    parsed = tomllib.loads(spec)          # raises if the emitter broke the file
    svc = parsed["service"][0]
    assert "privileged" not in svc, (
        "REGRESSION: a hostile `volumes` value closed the quote and injected a SPEC KEY. "
        "phase3.py's volumes emitter is the one of ~30 that skipped _toml_str — its own "
        "siblings (ports on the line above, env values, phase-4 volumes) all escape."
    )
    assert svc["volumes"] == [hostile], (
        f"the value did not round-trip; got {svc.get('volumes')!r}"
    )


def test_phase3_ports_still_escaped_control() -> None:
    """Control: the sibling that always escaped must keep doing so."""
    import tomllib

    hostile = '8080:80"\nprivileged = true\nx = "'
    spec = _render_phase3(lab="l", svc="s", image="alpine", ports=hostile)
    parsed = tomllib.loads(spec)
    assert "privileged" not in parsed["service"][0]
