"""Mutating action routes — destroy, stop."""

from __future__ import annotations

import asyncio
import html
import logging
from urllib.parse import unquote

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from lab_web.app import templates
from lab_web.routes.resources import _all_runners, _find_resource

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/actions")


def _csrf_guard(request: Request) -> bool:
    """Return True if the request looks like a legitimate HTMX call.

    F-4: HTMX sends HX-Request: true on every request it initiates.  A
    plain cross-origin form submit or fetch() from another origin would not
    include this header.  This is not a full CSRF defence (the header can be
    forged by JS on the same origin), but it meaningfully raises the bar for
    cross-origin abuse of the destroy endpoint.
    """
    return request.headers.get("HX-Request") == "true"


@router.post("/destroy/{backend}/{name:path}", response_class=HTMLResponse)
async def destroy(backend: str, name: str, request: Request) -> HTMLResponse:
    # F-4: require the HX-Request header to filter non-HTMX submissions.
    if not _csrf_guard(request):
        return HTMLResponse("Forbidden: HTMX-only endpoint.", status_code=403)

    name = unquote(name)
    runner = _all_runners(request).get(backend)
    if runner is None:
        # F-3: escape URL-derived values before embedding in HTML.
        return HTMLResponse(
            f"<p class='error'>Unknown backend: {html.escape(backend)}</p>"
        )
    resource = await asyncio.to_thread(_find_resource, runner, name)
    if resource is None:
        return HTMLResponse(
            f"<p class='error'>Resource not found: {html.escape(name)}</p>"
        )
    try:
        result = await asyncio.to_thread(runner.destroy, resource, True)
    except Exception:  # noqa: BLE001
        # F-6: log full exception server-side; return generic message to client.
        logger.exception("destroy failed for %s/%s", backend, name)
        return HTMLResponse(
            "<p class='error'>Destroy failed — see server logs.</p>"
        )
    if result.returncode == 0:
        return templates.TemplateResponse(
            request=request,
            name="partials/detail_panel.html.j2",
            context={
                "resource": None,
                "inspect_text": f"✓ {html.escape(name)} destroyed.",
                "message_class": "success",
            },
        )
    # F-6: stderr may contain internal paths; log it and return a summary.
    stderr_text = result.stderr or result.stdout or "(no output)"
    logger.warning("destroy %s/%s returned exit %d: %s",
                   backend, name, result.returncode, stderr_text[:500])
    return templates.TemplateResponse(
        request=request,
        name="partials/detail_panel.html.j2",
        context={
            "resource": resource,
            "inspect_text": f"Destroy failed (exit {result.returncode}) — see server logs.",
            "message_class": "error",
        },
    )
