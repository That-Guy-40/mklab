"""Mutating action routes — destroy, stop."""

from __future__ import annotations

import asyncio
from urllib.parse import unquote

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from lab_web.app import templates
from lab_web.routes.resources import _all_runners, _find_resource

router = APIRouter(prefix="/actions")


@router.post("/destroy/{backend}/{name:path}", response_class=HTMLResponse)
async def destroy(backend: str, name: str, request: Request) -> HTMLResponse:
    name = unquote(name)
    runner = _all_runners(request).get(backend)
    if runner is None:
        return HTMLResponse(f"<p class='error'>Unknown backend: {backend}</p>")
    resource = await asyncio.to_thread(_find_resource, runner, name)
    if resource is None:
        return HTMLResponse(f"<p class='error'>Resource not found: {name}</p>")
    result = await asyncio.to_thread(runner.destroy, resource, True)
    if result.returncode == 0:
        return templates.TemplateResponse(
            request=request,
            name="partials/detail_panel.html.j2",
            context={
                "resource": None,
                "inspect_text": f"✓ {name} destroyed.",
                "message_class": "success",
            },
        )
    return templates.TemplateResponse(
        request=request,
        name="partials/detail_panel.html.j2",
        context={
            "resource": resource,
            "inspect_text": result.stderr or result.stdout or "(no output)",
            "message_class": "error",
        },
    )
