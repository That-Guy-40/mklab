"""P6B-2: the vendored assets' recorded provenance must match the bytes on disk.

The README names vendoring as the supply-chain mitigation, so the vendored files
need an origin anyone can check. A record nobody verifies is the *other* half of
the same problem — it drifts, and then it is confidently wrong. These tests are
what make static/PROVENANCE.md a record rather than a comment.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

import pytest

_STATIC = Path(__file__).resolve().parent.parent / "lab_web" / "static"
_PROVENANCE = _STATIC / "PROVENANCE.md"


def _recorded() -> dict[str, str]:
    """Parse the sha256 column out of the provenance table: {filename: digest}."""
    out: dict[str, str] = {}
    for line in _PROVENANCE.read_text().splitlines():
        m = re.match(r"\|\s*`([^`]+)`\s*\|.*?\|\s*`?([0-9a-f]{64})`?\s*\|", line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def test_provenance_file_exists() -> None:
    assert _PROVENANCE.is_file(), (
        "static/PROVENANCE.md is missing — the vendored JS would again have no recorded "
        "version, URL, retrieved date or digest, while the README calls vendoring the "
        "supply-chain mitigation"
    )


def test_every_vendored_asset_is_recorded() -> None:
    recorded = _recorded()
    on_disk = {p.name for p in _STATIC.iterdir() if p.suffix in {".js", ".css"}}
    missing = on_disk - set(recorded)
    assert not missing, (
        f"vendored asset(s) with no provenance entry: {sorted(missing)}. "
        "A new file must be added to static/PROVENANCE.md in the same commit."
    )


@pytest.mark.parametrize("name", sorted(_recorded()))
def test_recorded_digest_matches_the_bytes(name: str) -> None:
    """The record must not outlive its subject.

    If an asset is refreshed without updating the table, this fails by name — which
    is the whole point of writing the digest down.
    """
    path = _STATIC / name
    assert path.is_file(), f"{name} is recorded in PROVENANCE.md but not present"
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    assert actual == _recorded()[name], (
        f"REGRESSION: {name} does not match its recorded sha256.\n"
        f"  recorded: {_recorded()[name]}\n"
        f"  actual:   {actual}\n"
        "Either the file was refreshed without updating static/PROVENANCE.md, or it "
        "was modified in place. Update the table in the same commit as the file."
    )


def test_htmx_version_in_the_bytes_matches_the_record() -> None:
    """htmx states its own version, so the record can be checked against the file.

    `sse.js` deliberately has no equivalent assertion: its version is NOT recoverable
    from what is on disk, which is exactly why PROVENANCE.md records it as unknown
    rather than assuming it matches htmx's.
    """
    blob = (_STATIC / "htmx.min.js").read_text(errors="replace")
    m = re.search(r'version:"([0-9.]+)"', blob)
    assert m, "htmx.min.js no longer carries a version string; update this test and the record"
    assert m.group(1) in _PROVENANCE.read_text(), (
        f"htmx.min.js reports version {m.group(1)}, which does not appear in "
        "static/PROVENANCE.md — the record and the bytes disagree"
    )
