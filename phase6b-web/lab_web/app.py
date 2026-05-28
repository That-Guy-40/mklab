"""FastAPI application factory and lifespan."""

from __future__ import annotations

import logging
import re as _re
from contextlib import asynccontextmanager
from pathlib import Path

import jinja2
from fastapi import FastAPI, Request
from fastapi.responses import Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from lab_tui.backends import ALL_BACKENDS

logger = logging.getLogger(__name__)

_HERE = Path(__file__).resolve().parent

# F-1: explicitly enable autoescaping for .html.j2 files.  Jinja2Templates
# uses select_autoescape() with its defaults, which only matches .html/.htm/.xml
# — NOT .html.j2.  Every template variable was rendered raw, enabling stored
# XSS via container labels (resource.name, display_name, svc, inspect_text, …).
templates = Jinja2Templates(
    env=jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(_HERE / "templates")),
        autoescape=jinja2.select_autoescape(
            enabled_extensions=("html.j2", "html", "htm", "xml"),
        ),
    )
)

# Register a custom filter: make a resource name safe for use as an HTML id
# or SSE event name (replace anything non-alphanumeric with "-").
# F-13: the filter is now actually used in templates (log panel id attribute).
templates.env.filters["safe_id"] = lambda s: _re.sub(r"[^a-zA-Z0-9]", "-", str(s))


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.runners = {b.name: b() for b in ALL_BACKENDS}
    yield


# F-14: docs_url disabled by default; set LAB_WEB_DEV=1 to re-enable.
import os as _os
_docs_url = "/docs" if _os.getenv("LAB_WEB_DEV") else None

app = FastAPI(
    title="lab-create web UI",
    version="0.1.0",
    docs_url=_docs_url,
    redoc_url=None,
    lifespan=lifespan,
)

app.mount("/static", StaticFiles(directory=str(_HERE / "static")), name="static")


# F-15: security response headers on every response.
@app.middleware("http")
async def add_security_headers(request: Request, call_next) -> Response:
    resp = await call_next(request)
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "same-origin"
    # CSP allows scripts only from 'self' (vendored htmx/sse.js in /static/).
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; "
        "script-src 'self'; "
        "style-src 'self' 'unsafe-inline';"  # inline styles used by Textual-style theming
    )
    return resp


from lab_web.routes import resources, actions, stream  # noqa: E402

app.include_router(resources.router)
app.include_router(actions.router)
app.include_router(stream.router)
