"""Entry point: `python -m lab_web` or the `lab-web` console script.

Usage:
    lab-web                        # listen on 127.0.0.1:8080
    lab-web --port 9090
    lab-web --host 0.0.0.0         # WARNING: exposes to network — use behind auth
    lab-web --reload               # auto-reload on code changes (dev mode)

SSH-forward recipe (access from your laptop):
    ssh -L 8080:localhost:8080 labhost
    # then browse to http://localhost:8080
"""

from __future__ import annotations

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="lab-web",
        description="FastAPI + HTMX web UI for lab-create resources.",
    )
    parser.add_argument("--host", default="127.0.0.1",
                        help="Bind host (default 127.0.0.1 — loopback only)")
    parser.add_argument("--port", type=int, default=8080,
                        help="Bind port (default 8080)")
    parser.add_argument("--reload", action="store_true",
                        help="Auto-reload on source changes (dev mode)")
    parser.add_argument("-V", "--version", action="version", version="lab-web 0.1.0")
    args = parser.parse_args()

    if args.host != "127.0.0.1":
        print(
            "[WARNING] lab-web: binding to a non-loopback address exposes the UI "
            "to the network with NO authentication. Use a reverse proxy with auth "
            "or restrict access via firewall rules.",
            file=sys.stderr,
        )

    import uvicorn
    uvicorn.run(
        "lab_web.app:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
