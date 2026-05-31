#!/usr/bin/env python3
"""link_check.py — doc cross-link validator + file-reference/impact mapper.

Two jobs, both aimed at safely cleaning up / reorganizing files (especially
under examples/) without leaving dangling references behind:

  1. LINK VALIDATION  — parse every Markdown doc for links and flag the ones
     whose target doesn't exist on disk.  Catches the classic "renamed a file,
     forgot a link in the README/INDEX" rot.  Handles inline links
     `[text](path)` and reference definitions `[id]: path`.  External URLs
     (http/https/mailto/…) and pure `#anchor` links are skipped.  (`[[ ]]` is
     NOT treated as a link — here it's TOML/bash/regex syntax, not a wiki link.)

  2. REFERENCE / IMPACT MAP — for every file under a tracked dir (default:
     examples/), grep the WHOLE repo for textual references to its *basename*
     (so it catches `[x](examples/foo.toml)`, `--config examples/foo.toml`,
     a bare `foo.toml` in prose/scripts, etc.).  Reports:
       - ORPHANS   : tracked files nothing else references (safe-ish to drop),
       - IMPACT    : per-file, every place that would need editing if you
                     rename/move/delete it.

Why basename-grep and not just the INDEX?  Because references live in many
places — examples/00-INDEX.md, each subsystem's README/SHOWCASE, scripts, other
TOMLs.  "Not in INDEX" does NOT mean "unused" (e.g. the micro-linux *-tiny /
*-baked TOMLs are documented in micro-linux/README.md, not 00-INDEX.md).

Usage:
  tools/link_check.py                      # full report: broken links + orphans
  tools/link_check.py --impact foo.toml    # who references foo.toml? (rename/del prep)
  tools/link_check.py --impact micro-linux # substring: every micro-linux* file's refs
  tools/link_check.py --links-only         # just validate Markdown links (CI gate)
  tools/link_check.py --orphans-only       # just list unreferenced tracked files
  tools/link_check.py --json               # machine-readable

Exit status: non-zero if broken links are found (so it can gate CI / a commit).
Defaults: --root = the git repo (parent of this script's tools/ dir),
          --track = examples/, scan = the whole repo (minus .git and VCS noise).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# ── What counts as a doc / a scannable text file ────────────────────────────
DOC_SUFFIXES = {".md", ".markdown"}
# Reference scanning reads these as text; everything else (images, qcow2, …) is
# skipped.  Extensionless files (scripts like `init`, `mlbuild`) are included.
TEXT_SUFFIXES = {
    ".md", ".markdown", ".txt", ".toml", ".sh", ".py", ".cfg", ".conf",
    ".yaml", ".yml", ".ini", ".env", ".ks", ".cfg", ".service", ".container",
    ".json", ".ipxe", ".script", "",  # "" = no extension
}
# Directories we never descend into (only used by the non-git fallback walk;
# in a git repo we let .gitignore decide via `git ls-files`).
PRUNE_DIRS = {".git", ".github", "__pycache__", ".mypy_cache", "node_modules", ".venv", "out", "dist", "build"}
# Never read a file larger than this for text scanning (refs we care about are
# tiny).  Safety net against an in-tree text blob; binaries are skipped anyway.
MAX_READ = 4 * 1024 * 1024

# Link targets that are not local paths.
EXTERNAL_RE = re.compile(r"^(?:[a-z][a-z0-9+.-]*:|//|#|mailto:)", re.I)

# Inline Markdown link:  [text](target "optional title")
INLINE_LINK_RE = re.compile(r"\[(?:[^\]]*)\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+[^)]*)?\)")
# Reference definition:  [id]: target "optional title"
REF_DEF_RE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(<[^>]+>|\S+)")
# Code fences (``` or ~~~) and inline-code spans (`...`).  Links shown *inside*
# code are illustrative markdown source / shell commands, not navigational
# links — validating them yields false positives (e.g. a doc quoting
# "`[`x`](x)`" as an example), so we skip code when extracting links.
FENCE_RE = re.compile(r"^\s*(```|~~~)")
INLINE_CODE_RE = re.compile(r"`[^`]*`")
# NOTE: we deliberately do NOT treat `[[name]]` as a wiki link.  In this repo
# `[[ ]]` means TOML array-of-tables (`[[service]]`, `[[vm]]`), a bash `[[ test ]]`,
# or a regex class (`[[:space:]]`) — never a doc link.  Markdown `[text](path)`
# (and reference defs) are the only cross-links used here.


def find_repo_root(start: Path) -> Path:
    """Walk up from `start` until a .git dir is found; fall back to start."""
    for p in [start, *start.parents]:
        if (p / ".git").exists():
            return p
    return start


def list_files(root: Path) -> list[Path]:
    """Every file that matters: git-tracked + untracked-but-not-ignored, so
    .gitignore (e.g. build output under out/) is respected automatically.
    Falls back to a pruned filesystem walk outside a git checkout."""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--cached", "--others",
             "--exclude-standard", "-z"],
            capture_output=True, check=True, text=True,
        ).stdout
        files = [root / r for r in out.split("\0") if r]
        return [f for f in files if f.is_file()]
    except (subprocess.CalledProcessError, FileNotFoundError):
        return [p for p in root.rglob("*")
                if p.is_file()
                and not any(part in PRUNE_DIRS for part in p.relative_to(root).parts)]


def read_text(p: Path) -> str | None:
    """Read a file as UTF-8 text; return None if it looks binary/oversized."""
    try:
        if p.stat().st_size > MAX_READ:
            return None
        data = p.read_bytes()
    except OSError:
        return None
    if b"\x00" in data[:8192]:  # crude binary sniff
        return None
    return data.decode("utf-8", errors="replace")


def strip_anchor(target: str) -> str:
    """Drop a #fragment and surrounding <> from a link target."""
    target = target.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    return target.split("#", 1)[0]


def extract_links(text: str):
    """Yield (lineno, raw_target, kind) for every link-like in a doc."""
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        # Blank out inline-code spans so a link quoted as example markdown
        # (URL part wrapped in backticks) isn't mistaken for a real link.
        clean = INLINE_CODE_RE.sub(" ", line)
        for m in INLINE_LINK_RE.finditer(clean):
            yield lineno, m.group(1), "inline"
        md = REF_DEF_RE.match(clean)
        if md:
            yield lineno, md.group(1), "refdef"


def validate_links(root: Path, docs: list[Path]):
    """Return a list of broken-link dicts."""
    broken = []
    for doc in docs:
        text = read_text(doc)
        if text is None:
            continue
        for lineno, raw, kind in extract_links(text):
            target = strip_anchor(raw)
            if not target or EXTERNAL_RE.match(target):
                continue  # external URL / pure anchor
            # Resolve relative to the doc's directory.
            resolved = (doc.parent / target).resolve()
            # Allow trailing-slash dir links.
            if resolved.exists():
                continue
            # Some links are written repo-root-relative; try that too.
            alt = (root / target).resolve()
            if alt.exists():
                continue
            broken.append(_b(root, doc, lineno, target, kind, "target not found"))
    return broken


def _b(root, doc, lineno, target, kind, why):
    return {
        "doc": str(doc.relative_to(root)),
        "line": lineno,
        "target": target,
        "kind": kind,
        "why": why,
    }


def build_reference_index(root: Path, tracked: list[Path], scan: list[Path]):
    """For each tracked file, find every external reference (by basename).

    Returns {tracked_rel: [{"file":.., "line":.., "text":..}, ...]}.
    A reference is any line in a scanned text file (other than the tracked
    file itself) that contains the tracked file's basename.
    """
    # Pre-read scanned files once.
    scan_lines: list[tuple[Path, list[str]]] = []
    for f in scan:
        if f.suffix.lower() not in TEXT_SUFFIXES and f.suffix != "":
            continue
        text = read_text(f)
        if text is None:
            continue
        scan_lines.append((f, text.splitlines()))

    index: dict[str, list[dict]] = {}
    for t in tracked:
        name = t.name
        hits = []
        for f, lines in scan_lines:
            if f == t:
                continue  # don't count self-references
            for lineno, line in enumerate(lines, 1):
                if name in line:
                    hits.append({
                        "file": str(f.relative_to(root)),
                        "line": lineno,
                        "text": line.strip()[:160],
                    })
        index[str(t.relative_to(root))] = hits
    return index


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=None, help="repo root (default: auto-detect via .git)")
    ap.add_argument("--track", type=Path, default=Path("examples"), help="dir whose files to build an impact map for (default: examples)")
    ap.add_argument("--impact", metavar="SUBSTR", help="show inbound references for tracked files whose path contains SUBSTR")
    ap.add_argument("--links-only", action="store_true", help="only validate Markdown links")
    ap.add_argument("--orphans-only", action="store_true", help="only list unreferenced tracked files")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    root = (args.root or find_repo_root(script_dir)).resolve()
    track_dir = (root / args.track).resolve()

    all_files = list_files(root)
    docs = [f for f in all_files if f.suffix.lower() in DOC_SUFFIXES]
    tracked = sorted(f for f in all_files if track_dir in f.parents or f.parent == track_dir)

    # ── Link validation ─────────────────────────────────────────────────────
    broken = validate_links(root, docs)

    # ── Reference / impact index ─────────────────────────────────────────────
    index = build_reference_index(root, tracked, all_files)
    orphans = sorted(rel for rel, hits in index.items() if not hits)

    # ── Impact query mode ────────────────────────────────────────────────────
    if args.impact:
        subset = {rel: hits for rel, hits in index.items() if args.impact in rel}
        if args.json:
            print(json.dumps(subset, indent=2))
        else:
            if not subset:
                print(f"no tracked files match substring: {args.impact!r}")
            for rel in sorted(subset):
                hits = subset[rel]
                tag = "  ⚠ ORPHAN (no external refs)" if not hits else ""
                print(f"\n{rel}  [{len(hits)} ref(s)]{tag}")
                for h in hits:
                    print(f"    {h['file']}:{h['line']}: {h['text']}")
        return 0

    # ── Full / focused report ────────────────────────────────────────────────
    if args.json:
        out = {"broken_links": broken, "orphans": orphans}
        if not args.links_only and not args.orphans_only:
            out["impact_counts"] = {rel: len(h) for rel, h in index.items()}
        print(json.dumps(out, indent=2))
        return 1 if broken else 0

    if not args.orphans_only:
        print(f"== Markdown link validation ({len(docs)} docs) ==")
        if not broken:
            print("  ✓ no broken links")
        else:
            for b in broken:
                print(f"  ✗ {b['doc']}:{b['line']}  →  {b['target']}  ({b['why']}, {b['kind']})")
        print()

    if not args.links_only:
        print(f"== Orphaned tracked files under {args.track}/ (no inbound references) ==")
        if not orphans:
            print("  ✓ none — every tracked file is referenced somewhere")
        else:
            for o in orphans:
                print(f"  • {o}")
        print()
        print("Tip: `--impact <name>` shows exactly who references a file before you move/delete it.")

    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
