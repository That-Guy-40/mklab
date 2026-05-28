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
        return Response(f"unknown backend: {backend}", status_code=404)
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
