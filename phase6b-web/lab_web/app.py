"""FastAPI application factory and lifespan."""

from __future__ import annotations

import base64
import hmac
import logging
import os
import re as _re
import secrets
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


# ── HTTP Basic Auth (PLAN spec / audit F-7) ───────────────────────────────────
# Credentials are read from env vars set by __main__.py.  When both vars are
# unset, the middleware is a no-op (loopback-only default).  When set, every
# request except /static/* must present a matching Authorization header.
#
# Security notes:
#   - hmac.compare_digest is used for the comparison so timing attacks cannot
#     leak the credential a character at a time.
#   - The 401 response carries WWW-Authenticate: Basic so browsers show the
#     login dialog instead of a blank page.
#   - /static/* is exempt so CSS/scripts load on the login page itself.
#   - We deliberately do NOT cache the env-var values at module import time:
#     the test suite mutates them between requests, and __main__.py sets them
#     before uvicorn.run() in the same process, so reading on each request is
#     correct and has negligible cost.
def _basic_auth_check(authorization: str | None) -> bool:
    user = os.environ.get("LAB_WEB_AUTH_USER", "")
    password = os.environ.get("LAB_WEB_AUTH_PASSWORD", "")
    if not user or not password:
        return True  # auth disabled — pass through
    if not authorization or not authorization.startswith("Basic "):
        return False
    try:
        decoded = base64.b64decode(authorization[6:].strip()).decode("utf-8")
    except (ValueError, UnicodeDecodeError):
        return False
    sep = decoded.find(":")
    if sep < 0:
        return False
    got_user, got_pass = decoded[:sep], decoded[sep + 1:]
    # Constant-time comparison on both fields so neither length nor content leaks.
    user_ok = hmac.compare_digest(got_user.encode(), user.encode())
    pass_ok = hmac.compare_digest(got_pass.encode(), password.encode())
    return user_ok and pass_ok


@app.middleware("http")
async def basic_auth(request: Request, call_next) -> Response:
    # /static/* is unauthenticated so the browser can fetch CSS/JS/font assets
    # without a separate auth round-trip on every page load.  Nothing under
    # /static/ is user-supplied — it's vendored htmx, sse.js, and style.css.
    if request.url.path.startswith("/static/"):
        return await call_next(request)
    if _basic_auth_check(request.headers.get("Authorization")):
        return await call_next(request)
    return Response(
        status_code=401,
        content="Authentication required.",
        headers={"WWW-Authenticate": 'Basic realm="lab-create"'},
    )


from lab_web.routes import resources, actions, stream  # noqa: E402

app.include_router(resources.router)
app.include_router(actions.router)
app.include_router(stream.router)
