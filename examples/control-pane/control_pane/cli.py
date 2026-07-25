"""control-pane watch — the headless renderer (no TUI).

Tails a node's console (a file, or stdin, or the stdout of a command) and prints a live
progress readout driven by a milestones profile, ending on a one-line verdict. This is the
proof the control pane isn't TUI-locked: the same engine a Textual widget or a web SSE feed
would use, on a plain terminal / in CI.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time

from .engine import Tracker
from .milestones import load

DEFAULT_MILESTONES = os.path.join(os.path.dirname(os.path.dirname(__file__)), "milestones.toml")


def _lines(args):
    """Yield console lines from --exec CMD, a file, or stdin ('-')."""
    if args.exec:
        proc = subprocess.Popen(args.exec, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, bufsize=1)
        try:
            for line in proc.stdout:
                yield line
        finally:
            proc.terminate()
    elif args.source in (None, "-"):
        for line in sys.stdin:
            yield line
    else:
        with open(args.source) as fh:
            for line in fh:
                yield line


def _render(profile, p):
    filled = p.percent // 5
    bar = "#" * filled + "-" * (20 - filled)
    tag = " (STALLED)" if p.stalled else (" (done)" if p.terminal else "")
    print(f"[{p.percent:3d}%] [{bar}] {profile}: {p.label}{tag}  | {p.last_line}", file=sys.stderr)


def cmd_watch(args):
    profiles = load(args.milestones)
    if args.profile not in profiles:
        sys.exit(f"control-pane: no profile '{args.profile}' in {args.milestones} "
                 f"(have: {', '.join(profiles) or 'none'})")
    tr = Tracker(profiles[args.profile], stall_timeout=args.stall)
    last = None
    for line in _lines(args):
        p = tr.feed(line, now=time.monotonic())
        newly_stalled = p.stalled and (last is None or not last.stalled)
        if p.advanced or newly_stalled:
            _render(args.profile, p)
        last = p
        if p.terminal:
            break

    if last and last.terminal:
        print(f"control-pane: {args.profile} reached '{last.label}' ({last.percent}%) — done")
        return 0
    if last and last.stalled:
        print(f"control-pane: {args.profile} STALLED at '{last.label}' ({last.percent}%)")
        return 1
    label = last.label if last else "waiting"
    percent = last.percent if last else 0
    print(f"control-pane: {args.profile} ended at '{label}' ({percent}%) "
          f"without a terminal milestone")
    return 1


def main(argv=None):
    ap = argparse.ArgumentParser(prog="control-pane",
                                 description="A headless-first live control surface for labs.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("watch", help="tail a console and render live progress from a profile")
    w.add_argument("source", nargs="?", default="-",
                   help="console log file, or '-' for stdin (default)")
    w.add_argument("--profile", required=True, help="milestone profile (e.g. install, ramdisk)")
    w.add_argument("--milestones", default=DEFAULT_MILESTONES,
                   help="path to milestones.toml (default: the lab's)")
    w.add_argument("--exec", nargs=argparse.REMAINDER,
                   help="run this command and tail its output instead of a file/stdin")
    w.add_argument("--stall", type=float, default=None, metavar="SEC",
                   help="mark stalled after SEC with no forward progress (live streams)")
    w.set_defaults(func=cmd_watch)
    args = ap.parse_args(argv)
    return args.func(args)
