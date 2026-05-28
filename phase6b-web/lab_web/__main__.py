"""Entry point: `python -m lab_web` or the `lab-web` console script.

Usage:
    lab-web                                      # loopback only, no auth
    lab-web --port 9090
    lab-web --reload                             # dev mode

Network-exposure (requires BOTH flags — the PLAN spec):
    lab-web --host 0.0.0.0 --allow-network --auth alice:s3cr3t
                                                 # Basic Auth on all routes
    # Then put nginx/Caddy with TLS in front before exposing externally.

Optional: enable auth even on loopback (shared machines):
    lab-web --auth alice:s3cr3t                  # 127.0.0.1 + Basic Auth

SSH-forward recipe (no auth needed — tunnel is the auth layer):
    ssh -L 8080:localhost:8080 labhost
    # browse to http://localhost:8080
"""

from __future__ import annotations

import argparse
import os
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
    parser.add_argument(
        "--allow-network", action="store_true",
        help=(
            "Required when --host is not 127.0.0.1.  Explicitly acknowledges "
            "that the UI will be reachable over the network.  Must be combined "
            "with --auth USER:PASS."
        ),
    )
    parser.add_argument(
        "--auth", metavar="USER:PASS",
        default=os.environ.get("LAB_WEB_AUTH", ""),
        help=(
            "Enable HTTP Basic Auth with this credential.  Required when "
            "--allow-network is set.  May also be supplied via the "
            "LAB_WEB_AUTH=USER:PASS environment variable."
        ),
    )
    parser.add_argument("-V", "--version", action="version", version="lab-web 0.1.0")
    args = parser.parse_args()

    network_exposed = args.host != "127.0.0.1"

    # ── Enforce the spec: non-loopback requires --allow-network + --auth ──────
    if network_exposed and not args.allow_network:
        print(
            f"lab-web: error: --host {args.host!r} exposes the UI to the network.\n"
            "  Add --allow-network --auth USER:PASS to confirm this is intentional.\n"
            "  Without authentication every machine that can reach this port has full\n"
            "  destructive control over your lab resources.",
            file=sys.stderr,
        )
        return 2

    if network_exposed and args.allow_network and not args.auth:
        print(
            "lab-web: error: --allow-network requires --auth USER:PASS (or LAB_WEB_AUTH env var).\n"
            "  Refusing to start: unauthenticated network access would give anyone\n"
            "  on the network full destroy/inspect rights over all lab resources.",
            file=sys.stderr,
        )
        return 2

    # ── Parse and validate the credential ─────────────────────────────────────
    if args.auth:
        if ":" not in args.auth:
            print(
                "lab-web: error: --auth value must be USER:PASS (colon-separated).",
                file=sys.stderr,
            )
            return 2
        auth_user, _, auth_pass = args.auth.partition(":")
        if not auth_user or not auth_pass:
            print(
                "lab-web: error: --auth USER:PASS — both username and password must be non-empty.",
                file=sys.stderr,
            )
            return 2
        # Pass credentials to the app via environment variables so the
        # Basic Auth middleware in app.py picks them up at request time.
        os.environ["LAB_WEB_AUTH_USER"] = auth_user
        os.environ["LAB_WEB_AUTH_PASSWORD"] = auth_pass
        print(
            f"lab-web: Basic Auth enabled (user={auth_user!r}).",
            file=sys.stderr,
        )
    else:
        # Clear any stale env vars from a parent process.
        os.environ.pop("LAB_WEB_AUTH_USER", None)
        os.environ.pop("LAB_WEB_AUTH_PASSWORD", None)

    # ── Warn on network exposure ───────────────────────────────────────────────
    if network_exposed:
        print(
            f"lab-web: WARNING: binding to {args.host}:{args.port} — network exposed.\n"
            "  Basic Auth is active, but the connection is plain HTTP (no TLS).\n"
            "  Credentials travel in clear text unless a TLS reverse proxy is in front.\n"
            "  For internet exposure: put nginx/Caddy with TLS + stronger auth in front.",
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
