"""FastAPI application factory and lifespan."""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from lab_tui.backends import ALL_BACKENDS

_HERE = Path(__file__).resolve().parent
templates = Jinja2Templates(directory=str(_HERE / "templates"))

# Register a custom filter: make a resource name safe for use as an HTML id
# or SSE event name (replace anything non-alphanumeric with "-").
import re as _re
templates.env.filters["safe_id"] = lambda s: _re.sub(r"[^a-zA-Z0-9]", "-", str(s))


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Initialise one runner per backend once; keep them on app.state so
    # every request handler can access them without re-instantiation.
    app.state.runners = {b.name: b() for b in ALL_BACKENDS}
    yield
    # No teardown needed — runners are stateless wrappers around subprocesses.


app = FastAPI(
    title="lab-create web UI",
    version="0.1.0",
    docs_url="/docs",
    redoc_url=None,
    lifespan=lifespan,
)

app.mount("/static", StaticFiles(directory=str(_HERE / "static")), name="static")

from lab_web.routes import resources, actions, stream  # noqa: E402  (after app is defined)

app.include_router(resources.router)
app.include_router(actions.router)
app.include_router(stream.router)
