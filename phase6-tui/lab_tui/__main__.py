"""Entry point: `python -m lab_tui` or the `lab-tui` console script."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from lab_tui import __version__
from lab_tui.app import LabApp


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="lab-tui",
        description="Textual TUI surfacing LAB_CREATE_V2 phase scripts.",
    )
    parser.add_argument(
        "--topology", type=Path, default=None,
        help="Open the topology screen with this lab.toml pre-loaded.",
    )
    parser.add_argument(
        "--serve", metavar="[HOST:]PORT", nargs="?", const="8080",
        help=(
            "Serve the TUI over HTTP via `textual serve` so it's accessible "
            "in a browser (uses WebSockets + xterm.js). "
            "Default port 8080; use --serve 0.0.0.0:8080 to bind all interfaces."
        ),
    )
    parser.add_argument("-V", "--version", action="version",
                        version=f"lab-tui {__version__}")
    args = parser.parse_args()

    if args.serve is not None:
        import shutil
        import subprocess
        textual_bin = shutil.which("textual")
        if textual_bin is None:
            print(
                "lab-tui: 'textual' CLI not found — "
                "is textual installed in this environment?",
                file=sys.stderr,
            )
            return 1
        # textual serve accepts --port and --host separately; parse combined arg.
        host, _, port = args.serve.rpartition(":")
        cmd = [textual_bin, "serve", "lab_tui.app:LabApp"]
        if port:
            cmd += ["--port", port]
        if host:
            cmd += ["--host", host]
        return subprocess.run(cmd).returncode

    if args.topology is not None and not args.topology.is_file():
        print(f"lab-tui: topology file not found: {args.topology}",
              file=sys.stderr)
        return 2

    LabApp(topology_path=args.topology).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
