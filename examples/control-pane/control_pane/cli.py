"""control-pane watch — the headless renderer (no TUI).

Tails a node's console (a file, or stdin, or the stdout of a command) and prints a live
progress readout driven by a milestones profile, ending on a one-line verdict. This is the
proof the control pane isn't TUI-locked: the same engine a Textual widget or a web SSE feed
would use, on a plain terminal / in CI.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import tomllib

from .engine import Tracker
from .milestones import load

DEFAULT_MILESTONES = os.path.join(os.path.dirname(os.path.dirname(__file__)), "milestones.toml")


def _fleet_dir(explicit):
    """Where a lab registers its control-pane nodes. Mirrors the phase scripts'
    LAB_STATE_DIR resolution so Phase 6 and the CLI agree on one location."""
    if explicit:
        return explicit
    base = os.environ.get("LAB_STATE_DIR")
    if base:
        return os.path.join(base, "control-pane")
    if os.geteuid() == 0:
        return "/var/lib/lab-create/control-pane"
    xdg = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(xdg, "lab-create", "control-pane")


def _node_progress(node_dir, default_milestones):
    """Read one node's `node.toml`, run the engine over its console, return a dict.

    node.toml: profile = "<profile>"; console = "<path>"; [milestones = "<path>"].
    """
    name = os.path.basename(node_dir.rstrip("/"))
    with open(os.path.join(node_dir, "node.toml"), "rb") as fh:
        conf = tomllib.load(fh)
    profile = conf.get("profile", "")
    console = conf.get("console", "")
    profiles = load(conf.get("milestones", default_milestones))
    tr = Tracker(profiles.get(profile, []))
    p = tr.tick(None)  # baseline (0%, "waiting") if the console has nothing yet
    if console and os.path.isfile(console):
        with open(console, errors="replace") as fh:
            for line in fh:
                p = tr.feed(line)
    return {"name": name, "profile": profile, "console": console,
            "percent": p.percent, "label": p.label,
            "terminal": p.terminal, "stalled": p.stalled}


def _fleet_nodes(fleet):
    nodes = []
    if os.path.isdir(fleet):
        for entry in sorted(os.listdir(fleet)):
            nd = os.path.join(fleet, entry)
            if os.path.isfile(os.path.join(nd, "node.toml")):
                nodes.append(_node_progress(nd, DEFAULT_MILESTONES))
    return nodes


def cmd_list(args):
    """Enumerate the fleet's nodes with their current progress (JSON for consumers)."""
    nodes = _fleet_nodes(_fleet_dir(args.fleet))
    if args.json:
        print(json.dumps(nodes))
    else:
        for n in nodes:
            print(f"{n['name']:14} {n['percent']:3d}%  {n['profile']:8}  {n['label']}")
    return 0


def cmd_inspect(args):
    """Detail for one node: its config, its profile's milestones, and where it is now."""
    fleet = _fleet_dir(args.fleet)
    nd = os.path.join(fleet, args.node)
    if not os.path.isfile(os.path.join(nd, "node.toml")):
        sys.exit(f"control-pane: no node '{args.node}' under {fleet}")
    prog = _node_progress(nd, DEFAULT_MILESTONES)
    profiles = load(DEFAULT_MILESTONES)
    lines = [f"node:    {prog['name']}",
             f"profile: {prog['profile']}",
             f"console: {prog['console'] or '(none)'}",
             f"now:     {prog['percent']}%  {prog['label']}"
             + ("  [terminal]" if prog["terminal"] else "")
             + ("  [STALLED]" if prog["stalled"] else ""),
             "milestones:"]
    for m in profiles.get(prog["profile"], []):
        mark = "*" if m.at <= prog["percent"] else " "
        lines.append(f"  {mark} {m.at:3d}%  {m.label}"
                     + ("  (terminal)" if m.terminal else ""))
    print("\n".join(lines))
    return 0


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

    ls = sub.add_parser("list", help="enumerate the fleet's nodes + current progress")
    ls.add_argument("--fleet", default=None,
                    help="fleet dir (default: $LAB_STATE_DIR/control-pane)")
    ls.add_argument("--json", action="store_true", help="emit JSON (for Phase 6 / consumers)")
    ls.set_defaults(func=cmd_list)

    it = sub.add_parser("inspect", help="detail one node: config + milestones + where it is now")
    it.add_argument("node", help="node name")
    it.add_argument("--fleet", default=None,
                    help="fleet dir (default: $LAB_STATE_DIR/control-pane)")
    it.set_defaults(func=cmd_inspect)

    args = ap.parse_args(argv)
    return args.func(args)
