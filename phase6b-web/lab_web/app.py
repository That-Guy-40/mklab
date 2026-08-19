"""FastAPI application factory and lifespan."""

from __future__ import annotations

import base64
import hmac
import logging
import os
import posixpath
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

# W3 (Review phase6): a per-process CSRF token.  Pages served by this process
# echo it on every HTMX request via `hx-headers` (see base.html.j2); the
# state-changing routes verify it with a constant-time compare.  This upgrades
# the CSRF defence from "HX-Request header present" (forgeable by same-origin
# JS) to a secret only this process's own pages carry.  A fresh token per
# process is sufficient for the single-user, no-session closed-lab model.
CSRF_TOKEN = secrets.token_urlsafe(32)

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

# W3: expose the CSRF token to every template (rendered into <body hx-headers>).
templates.env.globals["csrf_token"] = CSRF_TOKEN


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


def _is_static_path(path: str) -> bool:
    # W4 (Review phase6): normalise BEFORE the prefix test so a crafted
    # `/static/../actions/...` (which Starlette would route to the control
    # plane, not the static mount) cannot skip auth by starting with the raw
    # "/static/" bytes.  normpath collapses the `..`, so only genuine
    # /static assets are exempted.
    norm = posixpath.normpath(path)
    return norm == "/static" or norm.startswith("/static/")


@app.middleware("http")
async def basic_auth(request: Request, call_next) -> Response:
    # /static/* is unauthenticated so the browser can fetch CSS/JS/font assets
    # without a separate auth round-trip on every page load.  Nothing under
    # /static/ is user-supplied — it's vendored htmx, sse.js, and style.css.
    if _is_static_path(request.url.path):
        return await call_next(request)
    if _basic_auth_check(request.headers.get("Authorization")):
        return await call_next(request)
    return Response(
        status_code=401,
        content="Authentication required.",
        headers={"WWW-Authenticate": 'Basic realm="lab-create"'},
    )


# ── P6-1: Host validation — the anti-DNS-rebinding gate ───────────────────────
#
# The security model rested on two pillars: "loopback only, no auth needed — the
# SSH tunnel is the auth layer", and a per-process CSRF token whose docstring
# reasons that "a cross-origin page cannot read it".  Both are true of a
# GENUINELY cross-origin attacker.  Neither survives DNS REBINDING, which makes
# the attacker SAME-ORIGIN: the user visits evil.example, whose DNS record flips
# to 127.0.0.1, and the browser then sends requests here carrying
# `Host: evil.example` while treating the responses as same-origin — so the page
# can READ the token out of <body hx-headers> and echo it back.
#
# The CSRF guard is not broken and not bypassed by that; it is SATISFIED.  It
# defends the threat it was built for and is inert against this one.  What the
# attack reaches is `runner.destroy(resource, True)`, which for two backends is a
# `sudo …/lab-chroot.sh destroy -- <name> --force`.
#
# The suite was unwitting evidence: conftest.py used base_url="http://test", so
# every web test already sent a foreign Host and nothing noticed.  That base_url
# is now a loopback one, and a test asserts the foreign Host is refused.
#
# Registered AFTER basic_auth in this file on purpose: Starlette inserts each
# `@app.middleware` at the head of the stack, so the LAST registered runs FIRST.
# This must run before auth, so an unauthenticated foreign-Host probe cannot even
# reach the credential comparison.
_DEFAULT_ALLOWED_HOSTS = frozenset({"localhost", "127.0.0.1", "[::1]", "::1"})


def _allowed_hosts() -> frozenset[str] | None:
    """Allowed Host values, or None meaning "any" (see __main__.py).

    Read per request rather than cached at import, matching the auth middleware
    above and for the same reason: __main__.py sets the env var in this process
    before uvicorn.run(), and the tests mutate it between requests.
    """
    raw = os.environ.get("LAB_WEB_ALLOWED_HOSTS", "")
    if raw.strip() == "*":
        return None
    extra = {h.strip().lower() for h in raw.split(",") if h.strip()}
    return frozenset(_DEFAULT_ALLOWED_HOSTS | extra)


def _host_ok(host_header: str | None) -> bool:
    allowed = _allowed_hosts()
    if allowed is None:
        return True
    if not host_header:
        return False  # HTTP/1.1 requires Host; a missing one is not a loopback client
    host = host_header.split(",")[0].strip().lower()
    if host.startswith("["):  # [::1] or [::1]:8080
        close = host.find("]")
        name = host[: close + 1] if close != -1 else host
    elif host.count(":") == 1:  # name:port  (a bare IPv6 has more colons)
        name = host.rsplit(":", 1)[0]
    else:
        name = host
    return name in allowed


@app.middleware("http")
async def trusted_host(request: Request, call_next) -> Response:
    if _host_ok(request.headers.get("host")):
        return await call_next(request)
    return Response(
        status_code=400,
        content=(
            "Invalid Host header.\n\n"
            "This UI is bound to loopback and only answers requests addressed to it "
            "by a loopback name. A request carrying a different Host is either "
            "misrouted or a DNS-rebinding attempt.\n"
            "If you are reaching it through a proxy or a custom name, set "
            "LAB_WEB_ALLOWED_HOSTS to that name (comma-separated), or run with "
            "--allow-network --auth USER:PASS.\n"
        ),
        media_type="text/plain",
    )


# F-15 / W5: security response headers on EVERY response.  Registered *after*
# basic_auth so it is the OUTER middleware — it therefore also decorates the
# 401 that basic_auth short-circuits (previously the 401 escaped bare).
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


from lab_web.routes import resources, actions, stream, wizards  # noqa: E402

app.include_router(resources.router)
app.include_router(actions.router)
app.include_router(stream.router)
app.include_router(wizards.router)
