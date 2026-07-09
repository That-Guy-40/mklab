"""Mutating action routes — destroy, stop."""

from __future__ import annotations

import asyncio
import hmac
import html
import logging
from urllib.parse import unquote

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from lab_web.app import CSRF_TOKEN, templates
from lab_web.routes.resources import _all_runners, _find_resource

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/actions")


def _csrf_guard(request: Request) -> bool:
    """Return True only for a same-origin request carrying our CSRF token.

    Two gates, both required:
      - F-4: HTMX sends `HX-Request: true` on every request it initiates; a
        plain cross-origin form submit would not.  Necessary but forgeable.
      - W4 (Review phase6): the request must also echo the per-process CSRF
        token (injected into `<body hx-headers>`; see app.CSRF_TOKEN).  A
        cross-origin page cannot read it, and setting a custom header
        cross-origin triggers a CORS preflight this app never approves — so
        this closes the "same-origin JS forges HX-Request" hole the old guard
        left open.  Constant-time compare so the token can't leak byte-by-byte.
    """
    if request.headers.get("HX-Request") != "true":
        return False
    token = request.headers.get("X-CSRFToken", "")
    return bool(CSRF_TOKEN) and hmac.compare_digest(token, CSRF_TOKEN)


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
