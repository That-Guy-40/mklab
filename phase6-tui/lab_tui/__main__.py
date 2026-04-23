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
    parser.add_argument("-V", "--version", action="version",
                        version=f"lab-tui {__version__}")
    args = parser.parse_args()

    if args.topology is not None and not args.topology.is_file():
        print(f"lab-tui: topology file not found: {args.topology}",
              file=sys.stderr)
        return 2

    LabApp(topology_path=args.topology).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
