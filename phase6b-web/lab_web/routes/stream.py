"""SSE streaming routes — log tails."""

from __future__ import annotations

import asyncio
import html
from urllib.parse import unquote

from fastapi import APIRouter, Request
from fastapi.responses import Response, StreamingResponse

from lab_web.routes.resources import _all_runners, _find_resource

router = APIRouter(prefix="/stream")

_SSE_HEADERS = {
    "Cache-Control": "no-cache",
    "X-Accel-Buffering": "no",   # disable nginx buffering for SSE
}


@router.get("/logs/{backend}/{name:path}")
async def stream_logs(backend: str, name: str, request: Request) -> Response:
    """Stream a resource's log tail as Server-Sent Events.

    Each log line is emitted as an SSE `data:` message.  The HTMX log-tail
    partial listens with `hx-ext="sse"` and appends each line to the panel.

    Clients receive:
        data: <span class="log-line">escaped log text</span>\\n\\n

    Connection is held open until the client disconnects or the log process
    exits (e.g. the resource is destroyed).
    """
    name = unquote(name)
    runner = _all_runners(request).get(backend)
    if runner is None:
        # P6-3 (W1, third file): escape the URL-derived value, and declare a
        # media type. A bare Response with no media_type sends NO Content-Type at
        # all, so the browser is left to guess — which is exactly the condition
        # `X-Content-Type-Options: nosniff` exists to make safe, and exactly the
        # condition not to rely on. `actions.py` and `resources.py` both escape
        # the identical strings; this file was the one W1's fix did not reach.
        return Response(
            f"unknown backend: {html.escape(backend)}",
            status_code=404,
            media_type="text/plain",
        )
    resource = await asyncio.to_thread(_find_resource, runner, name)
    if resource is None or not resource.log_command:
        return Response("no log available for this resource", status_code=404)

    async def generate():
        proc = await asyncio.create_subprocess_exec(
            *resource.log_command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        try:
            async for raw_line in proc.stdout:  # type: ignore[union-attr]
                if await request.is_disconnected():
                    break
                line = raw_line.decode("utf-8", errors="replace").rstrip()
                escaped = html.escape(line)
                yield f"data: <span class='log-line'>{escaped}</span>\n\n"
        finally:
            # F-8: always wait for the subprocess to exit after terminating it
            # so it doesn't accumulate as a zombie in the process table.
            try:
                proc.terminate()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(proc.wait(), timeout=5.0)
            except (asyncio.TimeoutError, ProcessLookupError):
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass

    return StreamingResponse(generate(), media_type="text/event-stream",
                             headers=_SSE_HEADERS)


@router.get("/progress/{backend}/{name:path}")
async def stream_progress(backend: str, name: str, request: Request) -> Response:
    """Server-push a resource's boot/install progress as SSE.

    Re-reads the resource on a short cadence and emits an HTML progress-bar
    fragment each time (the control-pane inventory source carries `percent` in
    `extra`).  Ends when the node reaches its terminal milestone, goes stalled,
    disappears, or the client disconnects — so a terminal node emits once.
    """
    name = unquote(name)
    runner = _all_runners(request).get(backend)
    if runner is None:
        # P6-3 (W1, third file): escape the URL-derived value, and declare a
        # media type. A bare Response with no media_type sends NO Content-Type at
        # all, so the browser is left to guess — which is exactly the condition
        # `X-Content-Type-Options: nosniff` exists to make safe, and exactly the
        # condition not to rely on. `actions.py` and `resources.py` both escape
        # the identical strings; this file was the one W1's fix did not reach.
        return Response(
            f"unknown backend: {html.escape(backend)}",
            status_code=404,
            media_type="text/plain",
        )

    async def generate():
        while True:
            if await request.is_disconnected():
                break
            resource = await asyncio.to_thread(_find_resource, runner, name)
            if resource is None or "percent" not in resource.extra:
                yield "data: <span class='progress-gone'>no progress for this resource</span>\n\n"
                break
            e = resource.extra
            pct = int(e.get("percent", 0))
            label = html.escape(str(e.get("label", "")))
            cls = "stalled" if e.get("stalled") else ("done" if e.get("terminal") else "")
            frag = (f"<div class='progress'><div class='progress-bar {cls}' "
                    f"style='width:{pct}%'></div>"
                    f"<span class='progress-label'>{pct}% {label}</span></div>")
            yield f"data: {frag}\n\n"
            if e.get("terminal") or e.get("stalled"):
                break
            await asyncio.sleep(2.0)

    return StreamingResponse(generate(), media_type="text/event-stream",
                             headers=_SSE_HEADERS)
