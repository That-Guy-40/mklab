"""Phase 6b web wizards — §8.2's first gap, closed as a VIEW rather than a port.

The assertions here are mostly about one thing: that this surface has no opinions of its
own. §0.2 says the guided path is a view of the raw path, and §4.1 says *a wrapper that
reimplements logic is a clone in disguise* — so the interesting question is not "does the
form render", it is "is any of this a second description of a spec?"

Hence `test_the_web_toml_is_byte_identical_to_the_tui_toml` and
`test_the_form_is_the_tui_wizards_own_fields`: both compare against the TUI wizard rather
than against a fixture written here. A fixture would go stale exactly when the wizard
changed, which is the moment these tests exist for.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from lab_web import wizards as wiz
from lab_web.app import CSRF_TOKEN


def _hx(**extra: str) -> dict[str, str]:
    return {"HX-Request": "true", "X-CSRFToken": CSRF_TOKEN, **extra}


# ── the adapter ──────────────────────────────────────────────────────────────

def test_every_tui_wizard_is_offered_by_the_web() -> None:
    """DERIVED from the package, so a wizard added to the TUI cannot be silently missing.

    A hand-written list here would make "the web has wizards" true and "the web has THE
    wizards" quietly false — and nothing would say so, which is the failure mode the whole
    view/implementation split exists to prevent.
    """
    import importlib
    import lab_tui.screens.wizards as pkg
    from lab_tui.screens.wizards.base import WizardModal

    expected = set()
    for mod_path in sorted(Path(pkg.__file__).parent.glob("*.py")):
        if mod_path.stem in ("__init__", "base"):
            continue
        mod = importlib.import_module(f"lab_tui.screens.wizards.{mod_path.stem}")
        for attr in dir(mod):
            cls = getattr(mod, attr)
            if (isinstance(cls, type) and issubclass(cls, WizardModal)
                    and cls is not WizardModal and cls.__module__ == mod.__name__):
                expected.add(mod_path.stem)

    assert set(wiz.discover()) == expected
    assert "phase7" in expected, "the microVM wizard should be discoverable"


def test_the_form_is_the_tui_wizards_own_fields() -> None:
    """Every control the TUI declares appears here, with the TUI's own caption.

    Compared against `compose_form()` itself — not against a list of ids typed into this
    test, which would pass while the two drifted.
    """
    from textual.widgets import Checkbox, Input, Select

    cls = wiz.discover()["phase7"]
    obj = object.__new__(cls)
    declared = [w.id for w in obj.compose_form()
                if isinstance(w, (Input, Select, Checkbox)) and getattr(w, "id", None)]
    assert [f.id for f in wiz.fields_of(cls)] == declared

    by_id = {f.id: f for f in wiz.fields_of(cls)}
    assert by_id["f-name"].kind == "text"
    assert by_id["f-name"].label == "Name *"
    assert by_id["f-memory"].kind == "select"
    assert ("256M", "256M") in by_id["f-memory"].options
    assert by_id["f-memory"].default == "256M"
    assert by_id["f-mmds"].kind == "checkbox"


def test_the_web_toml_is_byte_identical_to_the_tui_toml() -> None:
    """The load-bearing assertion of this whole surface.

    Two descriptions of a phase-7 microVM — one in Textual, one in Jinja — would drift, and
    the day they did, one of them would generate specs the tool rejects while its own tests
    stayed green. So the web calls the wizard's generator, and this proves it: the same
    values through both paths must produce the same bytes.
    """
    cls = wiz.discover()["phase7"]
    values = {"f-name": "api1", "f-kernel": "/k/vmlinux", "f-rootfs": "/r/api1.ext4",
              "f-memory": "512M", "f-vcpus": "2", "f-tap": "mc-api1",
              "f-ip": "10.71.0.11", "f-mmds": True}

    web = wiz.generate_toml(cls, values)

    obj = object.__new__(cls)
    with patch.object(cls, "_val", staticmethod(lambda w, s: values.get(w, "") if not isinstance(values.get(w), bool) else "")), \
         patch.object(cls, "_sel", staticmethod(lambda w, s: values.get(w, ""))), \
         patch.object(cls, "_chk", staticmethod(lambda w, s: values.get(w, False) is True)):
        tui = obj.generate_toml()

    assert web == tui


def test_an_unchecked_box_is_false_not_absent() -> None:
    """HTML omits unchecked boxes entirely. Read naively that is "no value", and a wizard
    that then wrote nothing for a boolean would differ from the TUI, where the box is
    explicitly False."""
    cls = wiz.discover()["phase7"]
    assert "mmds" not in wiz.generate_toml(cls, {"f-name": "a"})
    assert "mmds    = true" in wiz.generate_toml(cls, {"f-name": "a", "f-mmds": True})


# ── the routes ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_the_list_and_form_render(client) -> None:
    r = await client.get("/wizards")
    assert r.status_code == 200
    assert "phase7" in r.text

    r = await client.get("/wizards/phase7")
    assert r.status_code == 200
    assert 'name="f-name"' in r.text
    assert 'name="f-memory"' in r.text
    assert 'name="f-mmds"' in r.text
    # The default the TUI declares must be the one preselected here.
    assert 'value="256M" selected' in r.text


@pytest.mark.asyncio
async def test_an_unknown_wizard_is_404_not_a_traceback(client) -> None:
    assert (await client.get("/wizards/phase99")).status_code == 404


@pytest.mark.asyncio
async def test_preview_writes_nothing(client, tmp_path) -> None:
    """§0.2: wizards generate, they never execute — and preview does not even save."""
    r = await client.post("/wizards/phase7/preview",
                          data={"f-name": "api1", "f-memory": "512M"}, headers=_hx())
    assert r.status_code == 200
    assert "[[microvm]]" in r.text
    assert 'name    = &#34;api1&#34;' in r.text or 'name    = "api1"' in r.text
    assert "wrote" not in r.text


@pytest.mark.asyncio
async def test_preview_and_save_require_the_csrf_token(client) -> None:
    """Same gate the mutating action routes use. `save` writes a file, so it is mutating."""
    for path in ("/wizards/phase7/preview", "/wizards/phase7/save"):
        r = await client.post(path, data={"f-name": "x"})
        assert r.status_code == 403, f"{path} accepted a request with no CSRF token"
        r = await client.post(path, data={"f-name": "x"},
                              headers={"HX-Request": "true", "X-CSRFToken": "wrong"})
        assert r.status_code == 403, f"{path} accepted a WRONG CSRF token"


@pytest.mark.asyncio
async def test_save_writes_the_spec_and_returns_the_commands(client, tmp_path,
                                                             monkeypatch) -> None:
    import lab_web.routes.wizards as routes
    monkeypatch.setattr(routes, "REPO_ROOT", tmp_path)

    r = await client.post("/wizards/phase7/save",
                          data={"f-name": "api1", "f-kernel": "/k", "f-rootfs": "/r",
                                "f-memory": "256M", "f-vcpus": "1",
                                "save_path": "examples/microvm-api1.toml"},
                          headers=_hx())
    assert r.status_code == 200
    written = tmp_path / "examples" / "microvm-api1.toml"
    assert written.is_file()
    assert "[[microvm]]" in written.read_text()
    # The hint is the raw path, named. Delete the guided path and nothing is lost.
    assert "lab-fc.sh" in r.text
    assert "preflight" in r.text


@pytest.mark.asyncio
async def test_save_refuses_to_escape_the_repository(client, tmp_path,
                                                     monkeypatch) -> None:
    """A save path comes from the browser.

    `..` is the obvious case; the sibling-prefix one (`/repo-evil` starts with `/repo`) is
    why the check resolves and compares with `relative_to` instead of `startswith`.
    """
    import lab_web.routes.wizards as routes
    repo = tmp_path / "repo"
    repo.mkdir()
    (tmp_path / "repo-evil").mkdir()
    monkeypatch.setattr(routes, "REPO_ROOT", repo)

    for bad in ("../escape.toml", "../repo-evil/x.toml", "/etc/evil.toml"):
        r = await client.post("/wizards/phase7/save",
                              data={"f-name": "a", "save_path": bad}, headers=_hx())
        assert r.status_code == 200
        assert "refusing to write outside the repository" in r.text, f"accepted {bad}"
    assert not list((tmp_path / "repo-evil").iterdir())
    assert not (tmp_path / "escape.toml").exists()


@pytest.mark.asyncio
async def test_save_refuses_a_name_that_is_not_a_spec(client, tmp_path,
                                                      monkeypatch) -> None:
    """A wizard writes a spec. Letting it write `.bashrc` inside the repo would make "the
    worst case is a text file" a much less comforting sentence."""
    import lab_web.routes.wizards as routes
    monkeypatch.setattr(routes, "REPO_ROOT", tmp_path)
    r = await client.post("/wizards/phase7/save",
                          data={"f-name": "a", "save_path": "examples/evil.sh"},
                          headers=_hx())
    assert r.status_code == 200
    assert "must end in .toml" in r.text
    assert not (tmp_path / "examples" / "evil.sh").exists()


@pytest.mark.asyncio
async def test_a_typed_value_cannot_become_markup(client) -> None:
    """F-1's autoescaping, asserted on this surface rather than assumed from it.

    Everything in the preview pane is user-typed by construction, so if autoescaping were
    ever lost for .html.j2 again this is where it would show first.
    """
    r = await client.post("/wizards/phase7/preview",
                          data={"f-name": "<script>alert(1)</script>"}, headers=_hx())
    assert r.status_code == 200
    assert "<script>alert(1)</script>" not in r.text
    assert "&lt;script&gt;" in r.text
