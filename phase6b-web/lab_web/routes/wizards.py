"""Wizard routes — form → live preview → save. They generate; they never execute.

§0.2: *"Wizards generate; they never execute. This is already true of the five that exist
and it is why a novice cannot destroy anything with one — the worst case is a text file."*
That sentence is the security model of this whole surface, so it is worth being precise
about what these three routes can do:

    GET  /wizards                 list what is available (read-only)
    GET  /wizards/{phase}         render the form (read-only)
    POST /wizards/{phase}/preview render the TOML for the values typed so far (writes NOTHING)
    POST /wizards/{phase}/save    write ONE file under the repo, and return the commands
                                  you would type next

The save route is the only one that touches the filesystem, and the only thing it can
produce is a text file. It does not invoke a driver, and it never will: the hint it returns
names the commands so that a reader runs them on the raw path, which is the whole point of
the guided path being a view.

WHERE THE PATH IS ALLOWED TO POINT, AND WHY THE CHECK IS NOT A PREFIX MATCH
--------------------------------------------------------------------------
A save path arrives from the browser. `resolve()` first, THEN compare against the repo root
with `relative_to` — a raw `startswith` is defeated by `..` and by a sibling directory whose
name shares a prefix (`/repo-evil` starts with `/repo`). Symlinks are resolved by the same
call, so a link inside the repo pointing out of it cannot smuggle a write past the gate.
"""

from __future__ import annotations

import hmac
import logging
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from lab_web import wizards as wiz
from lab_web.app import CSRF_TOKEN, templates

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/wizards")

# The repo root: lab_web/routes/wizards.py → lab_web → phase6b-web → repo.
REPO_ROOT = Path(__file__).resolve().parents[3]


def _csrf_guard(request: Request) -> bool:
    """Same two gates the mutating action routes use — see routes/actions.py."""
    if request.headers.get("HX-Request") != "true":
        return False
    token = request.headers.get("X-CSRFToken", "")
    return bool(CSRF_TOKEN) and hmac.compare_digest(token, CSRF_TOKEN)


def _values(form: dict[str, str], fields: list[wiz.Field]) -> dict[str, object]:
    """Form data narrowed to the fields the wizard actually declared.

    An unchecked checkbox is simply absent from an HTML form submission, so it is defaulted
    to False rather than read — and anything the browser sent that is NOT a declared field is
    dropped. A wizard can then only ever generate from its own inputs, which is what keeps
    `generate_toml` the single description of a spec.
    """
    out: dict[str, object] = {}
    for f in fields:
        if f.kind == "checkbox":
            out[f.id] = f.id in form
        else:
            out[f.id] = form.get(f.id, "")
    return out


@router.get("", response_class=HTMLResponse)
@router.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    found = wiz.discover()
    items = [{"phase": k, "title": wiz.title_of(v)} for k, v in sorted(found.items())]
    return templates.TemplateResponse(
        request=request, name="partials/wizard_list.html.j2",
        context={"wizards": items},
    )


@router.get("/{phase}", response_class=HTMLResponse)
async def form(phase: str, request: Request) -> HTMLResponse:
    cls = wiz.discover().get(phase)
    if cls is None:
        return HTMLResponse("Unknown wizard.", status_code=404)
    return templates.TemplateResponse(
        request=request, name="partials/wizard_form.html.j2",
        context={"phase": phase, "title": wiz.title_of(cls),
                 "fields": wiz.fields_of(cls),
                 "save_path": wiz.default_save_path(cls, {})},
    )


@router.post("/{phase}/preview", response_class=HTMLResponse)
async def preview(phase: str, request: Request) -> HTMLResponse:
    if not _csrf_guard(request):
        return HTMLResponse("Forbidden: HTMX-only endpoint.", status_code=403)
    cls = wiz.discover().get(phase)
    if cls is None:
        return HTMLResponse("Unknown wizard.", status_code=404)
    form_data = dict(await request.form())
    fields = wiz.fields_of(cls)
    toml = wiz.generate_toml(cls, _values(form_data, fields))
    return templates.TemplateResponse(
        request=request, name="partials/wizard_preview.html.j2",
        context={"toml": toml, "saved": None, "hint": None, "error": None},
    )


@router.post("/{phase}/save", response_class=HTMLResponse)
async def save(phase: str, request: Request) -> HTMLResponse:
    if not _csrf_guard(request):
        return HTMLResponse("Forbidden: HTMX-only endpoint.", status_code=403)
    cls = wiz.discover().get(phase)
    if cls is None:
        return HTMLResponse("Unknown wizard.", status_code=404)

    form_data = dict(await request.form())
    fields = wiz.fields_of(cls)
    values = _values(form_data, fields)
    toml = wiz.generate_toml(cls, values)

    raw = (form_data.get("save_path") or "").strip()
    if not raw:
        raw = wiz.default_save_path(cls, values)

    target = (REPO_ROOT / raw).resolve()
    try:
        rel = target.relative_to(REPO_ROOT)
    except ValueError:
        # Refuse by NAME. "invalid path" sends the reader looking; this says what the rule is.
        return templates.TemplateResponse(
            request=request, name="partials/wizard_preview.html.j2",
            context={"toml": toml, "saved": None, "hint": None,
                     "error": f"refusing to write outside the repository: {raw}"},
        )
    if target.suffix != ".toml":
        return templates.TemplateResponse(
            request=request, name="partials/wizard_preview.html.j2",
            context={"toml": toml, "saved": None, "hint": None,
                     "error": f"a wizard writes a spec, so the name must end in .toml: {raw}"},
        )

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(toml, encoding="utf-8")
    except OSError as exc:
        return templates.TemplateResponse(
            request=request, name="partials/wizard_preview.html.j2",
            context={"toml": toml, "saved": None, "hint": None,
                     "error": f"could not write {rel}: {exc}"},
        )

    logger.info("wizard %s wrote %s", phase, rel)
    return templates.TemplateResponse(
        request=request, name="partials/wizard_preview.html.j2",
        context={"toml": toml, "saved": str(rel), "error": None,
                 "hint": wiz.run_hint(cls, values, Path(rel))},
    )
