"""Resource browser routes — full page and HTMX partials."""

from __future__ import annotations

import asyncio
from collections import defaultdict
from urllib.parse import unquote

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse

from lab_web.app import templates
from lab_tui.backends.base import BackendRunner, Resource

router = APIRouter()

_UNLABELLED = "(unlabelled)"


def _all_runners(request: Request) -> dict[str, BackendRunner]:
    return request.app.state.runners


async def _gather_resources(
    runners: dict[str, BackendRunner],
) -> dict[str, dict[str, list[Resource]]]:
    """Run list_resources() on every available backend (in a thread pool)."""
    grouped: dict[str, dict[str, list[Resource]]] = defaultdict(
        lambda: defaultdict(list)
    )
    for backend_name, runner in runners.items():
        try:
            available = await asyncio.to_thread(runner.is_available)
            if not available:
                continue
            resources = await asyncio.to_thread(runner.list_resources)
        except Exception:  # noqa: BLE001
            continue
        for r in resources:
            grouped[r.lab or _UNLABELLED][r.backend].append(r)
    return grouped


def _find_resource(runner: BackendRunner, name: str) -> Resource | None:
    try:
        for r in runner.list_resources():
            if r.name == name:
                return r
    except Exception:  # noqa: BLE001
        pass
    return None


# ── full page ──────────────────────────────────────────────────────────────

@router.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    runners = _all_runners(request)
    grouped = await _gather_resources(runners)
    unavailable = [
        n for n, runner in runners.items()
        if not await asyncio.to_thread(runner.is_available)
    ]
    return templates.TemplateResponse(
        request=request,
        name="base.html.j2",
        context={"groups": grouped, "unavailable": unavailable},
    )


# ── polling partial: the resource tree tbody (refreshed by hx-trigger) ────

@router.get("/partials/resources", response_class=HTMLResponse)
async def partial_resources(request: Request) -> HTMLResponse:
    grouped = await _gather_resources(_all_runners(request))
    return templates.TemplateResponse(
        request=request,
        name="partials/resources.html.j2",
        context={"groups": grouped},
    )


# ── detail panel: fetched on row click ────────────────────────────────────

@router.get("/resources/{backend}/{name:path}", response_class=HTMLResponse)
async def detail_panel(backend: str, name: str, request: Request) -> HTMLResponse:
    name = unquote(name)
    runner = _all_runners(request).get(backend)
    if runner is None:
        return HTMLResponse(f"<p class='error'>Unknown backend: {backend}</p>")
    resource = await asyncio.to_thread(_find_resource, runner, name)
    if resource is None:
        return HTMLResponse(f"<p class='error'>Resource not found: {name}</p>")
    inspect_text = await asyncio.to_thread(runner.inspect, resource)
    return templates.TemplateResponse(
        request=request,
        name="partials/detail_panel.html.j2",
        context={"resource": resource, "inspect_text": inspect_text},
    )


# ── log tail partial ──────────────────────────────────────────────────────

@router.get("/partials/log/{backend}/{name:path}", response_class=HTMLResponse)
async def partial_log(backend: str, name: str, request: Request) -> HTMLResponse:
    """Return the SSE-connected log-tail fragment, swapped into #log-content."""
    name = unquote(name)
    runner = _all_runners(request).get(backend)
    resource = await asyncio.to_thread(_find_resource, runner, name) if runner else None
    if resource is None or not resource.log_command:
        return HTMLResponse("<span class='error'>No log available.</span>")
    return templates.TemplateResponse(
        request=request,
        name="partials/log_tail.html.j2",
        context={"resource": resource},
    )


# ── JSON API ───────────────────────────────────────────────────────────────

@router.get("/api/v1/resources")
async def api_resources(request: Request, lab: str | None = None) -> JSONResponse:
    """Return all resources as JSON.  Optional ?lab=<name> filter."""
    out: list[dict] = []
    for backend_name, runner in _all_runners(request).items():
        try:
            available = await asyncio.to_thread(runner.is_available)
            if not available:
                continue
            resources = await asyncio.to_thread(runner.list_resources, lab)
        except Exception:  # noqa: BLE001
            continue
        for r in resources:
            out.append({
                "backend": r.backend,
                "name": r.name,
                "lab": r.lab,
                "svc": r.svc,
                "type": r.type,
                "status": r.status,
                "display_name": r.display_name,
                "has_console": bool(r.console_command),
                "has_logs": bool(r.log_command),
            })
    return JSONResponse({"schema_version": 1, "resources": out})


@router.get("/api/v1/resources/{backend}/{name:path}")
async def api_resource_detail(
    backend: str, name: str, request: Request
) -> JSONResponse:
    name = unquote(name)
    runner = _all_runners(request).get(backend)
    if runner is None:
        return JSONResponse({"error": f"unknown backend: {backend}"}, status_code=404)
    resource = await asyncio.to_thread(_find_resource, runner, name)
    if resource is None:
        return JSONResponse({"error": f"not found: {name}"}, status_code=404)
    inspect_text = await asyncio.to_thread(runner.inspect, resource)
    return JSONResponse({
        "schema_version": 1,
        "backend": resource.backend,
        "name": resource.name,
        "lab": resource.lab,
        "type": resource.type,
        "status": resource.status,
        "inspect": inspect_text,
    })
