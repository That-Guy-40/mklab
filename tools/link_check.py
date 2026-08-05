#!/usr/bin/env python3
"""link_check.py — doc cross-link validator + file-reference/impact mapper.

Two jobs, both aimed at safely cleaning up / reorganizing files (especially
under examples/) without leaving dangling references behind:

  1. LINK VALIDATION  — parse every Markdown doc for links and flag the ones
     whose target doesn't exist on disk.  Catches the classic "renamed a file,
     forgot a link in the README/INDEX" rot.  Handles inline links
     `[text](path)` and reference definitions `[id]: path`.  External URLs
     (http/https/mailto/…) are skipped.  (`[[ ]]` is NOT treated as a link —
     here it's TOML/bash/regex syntax, not a wiki link.)

  1b. ANCHOR VALIDATION — and the *fragment* too: `doc.md#some-heading` and a
     same-file `#some-heading` are checked against the heading anchors GitHub
     will actually generate for the destination.  This exists because for a
     long time it did NOT: the checker split the fragment off and threw it
     away, so a run could report "0 broken links" over a doc whose every
     in-page link was dead.  That is the repo's own bug class — a cheap check
     standing in for the real one — and a green result from it meant only
     "the FILE exists", never "the SECTION does".  A missing anchor is a
     *silent* failure in a browser (you land at the top of the page), which is
     exactly why a machine has to be the one looking.  See `github_slug()` for
     the rule and the em-dash trap that motivated it.

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
  tools/link_check.py --no-anchors         # paths only — the pre-2026-08-05 behaviour
  tools/link_check.py --anchors-of DOC     # print every anchor a doc generates
  tools/link_check.py --json               # machine-readable

Exit status: non-zero if broken links are found (so it can gate CI / a commit).
Defaults: --root = the git repo (parent of this script's tools/ dir),
          --track = examples/, scan = the whole repo (minus .git and VCS noise).
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

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


def split_anchor(target: str) -> tuple[str, str]:
    """Split a link target into (path, fragment); either part may be ''.

    `<>`-wrapping is removed and the fragment is percent-decoded, because a
    heading with a non-ASCII character is written `#caf%C3%A9` by some editors
    and `#café` by others — the same anchor, and neither may be reported broken.
    """
    target = target.strip()
    if target.startswith("<") and target.endswith(">"):
        target = target[1:-1]
    path, _, frag = target.partition("#")
    return path, unquote(frag)


def strip_anchor(target: str) -> str:
    """Drop a #fragment and surrounding <> from a link target."""
    return split_anchor(target)[0]


# ── Heading anchors ─────────────────────────────────────────────────────────
# GitHub gives every heading an id by slugifying its RENDERED text:
#   lowercase → delete everything that is not a word char / space / hyphen →
#   spaces become hyphens → a repeated slug gets -1, -2, … in document order.
#
# Two consequences cause almost every hand-written anchor to be wrong:
#
#   * an em dash is deleted, not replaced, so a heading's " — " (space, dash,
#     space) becomes TWO hyphens: `### I.7 The fabric — PASS` → `i7-the-fabric--pass`.
#     Writing the obvious single hyphen produces a link that silently lands the
#     reader at the top of the page.
#   * `_` is a word character and SURVIVES, while `.`, `'`, `’`, `(`, `)` and
#     `/` are all deleted with no separator: `test's` → `tests`, `F.7` → `f7`.
#
# We slug the *rendered* text, so a heading containing a link, an image, code
# spans or `**bold**` slugs the way the browser will see it — `[x](y)` is `x`,
# not `xy`.
MD_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
MD_REFLINK_RE = re.compile(r"\[([^\]]*)\]\[[^\]]*\]")
HTML_TAG_RE = re.compile(r"<[^>]+>")
ATX_RE = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$")
# An explicit `<a id="x">` / `<a name="x">` (or any tag carrying an id) is a real
# anchor too, and several docs use one to pin a name a heading would not produce.
HTML_ID_RE = re.compile(r"""<[a-z][^>]*?\b(?:name|id)\s*=\s*["']([^"']+)["']""", re.I)
EMPHASIS_RES = (
    (re.compile(r"\*\*(.+?)\*\*"), r"\1"),
    (re.compile(r"__(.+?)__"), r"\1"),
    (re.compile(r"\*(.+?)\*"), r"\1"),
    (re.compile(r"~~(.+?)~~"), r"\1"),
    (re.compile(r"(?<![\w`])_(.+?)_(?![\w`])"), r"\1"),
)
# `file.sh#L42` / `#L10-L20` are GitHub's line anchors on a code blob, not
# headings — never resolvable from a Markdown doc's headings.
LINE_ANCHOR_RE = re.compile(r"^L\d+(?:-L\d+)?$")


def heading_render(raw: str) -> str:
    """Approximate the rendered text of a heading (strip inline markdown)."""
    s = MD_IMAGE_RE.sub(r"\1", raw)
    s = MD_LINK_RE.sub(r"\1", s)
    s = MD_REFLINK_RE.sub(r"\1", s)
    for rx, rep in EMPHASIS_RES:
        s = rx.sub(rep, s)
    s = s.replace("`", "")
    return HTML_TAG_RE.sub("", s)


def github_slug(raw: str) -> str:
    """The id GitHub will generate for a heading (before duplicate numbering)."""
    s = heading_render(raw).strip().lower()
    s = re.sub(r"[^\w\s-]", "", s, flags=re.UNICODE)
    return re.sub(r"\s", "-", s)


def collect_anchors(text: str) -> list[str]:
    """Every anchor a Markdown doc offers, in document order.

    Headings inside fenced code are NOT headings — a shell comment `# foo` in a
    ```bash block would otherwise mint an anchor nothing links to and, worse,
    consume the `-1` suffix a real duplicate heading needed.
    """
    anchors: list[str] = []
    seen: dict[str, int] = {}
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in HTML_ID_RE.finditer(line):
            anchors.append(m.group(1))
        m = ATX_RE.match(line)
        if not m:
            continue
        base = github_slug(m.group(2))
        if not base:
            continue
        n = seen.get(base, 0)
        seen[base] = n + 1
        anchors.append(base if n == 0 else f"{base}-{n}")
    return anchors


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


def validate_links(root: Path, docs: list[Path], check_anchors: bool = True):
    """Return (broken, stats): missing files AND missing anchors, plus how much
    was actually looked at.

    `stats` exists because an all-green report is otherwise indistinguishable
    from one that checked nothing — if a regex stopped matching, or every
    fragment were skipped as "not checkable", the output would still read
    `✓ no broken links`.  Printing the counts makes the difference visible.
    """
    broken = []
    stats = {"links": 0, "fragments": 0, "anchors_checked": 0, "anchors_skipped": 0}
    anchor_cache: dict[Path, list[str] | None] = {}

    def anchors_of(p: Path):
        if p not in anchor_cache:
            t = read_text(p)
            anchor_cache[p] = None if t is None else collect_anchors(t)
        return anchor_cache[p]

    for doc in docs:
        text = read_text(doc)
        if text is None:
            continue
        for lineno, raw, kind in extract_links(text):
            target, frag = split_anchor(raw)
            if target and EXTERNAL_RE.match(target):
                continue  # external URL
            stats["links"] += 1
            if frag:
                stats["fragments"] += 1
            if not target:
                dest = doc  # same-document anchor: #section
            else:
                # Resolve relative to the doc's directory; allow trailing-slash dirs.
                dest = (doc.parent / target).resolve()
                if not dest.exists():
                    # Some links are written repo-root-relative; try that too.
                    alt = (root / target).resolve()
                    if not alt.exists():
                        broken.append(_b(root, doc, lineno, target, kind, "target not found"))
                        continue
                    dest = alt
            if not (check_anchors and frag):
                continue
            # Anchors are only checkable in Markdown. `foo.sh#L42` is GitHub's
            # line anchor on a blob and a directory has no headings at all —
            # report neither, rather than inventing a failure we cannot judge.
            if dest.is_dir() or dest.suffix.lower() not in DOC_SUFFIXES or LINE_ANCHOR_RE.match(frag):
                stats["anchors_skipped"] += 1
                continue
            have = anchors_of(dest)
            if have is None:
                stats["anchors_skipped"] += 1
                continue
            stats["anchors_checked"] += 1
            if frag in have:
                continue
            where = "this doc" if dest == doc else str(dest.relative_to(root)) if root in dest.parents else dest.name
            near = difflib.get_close_matches(frag, have, n=1, cutoff=0.55)
            why = f"anchor not found in {where}"
            if near:
                why += f" — closest: #{near[0]}"
            broken.append(_b(root, doc, lineno, f"{target}#{frag}", kind, why))
    return broken, stats


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
    ap.add_argument("--no-anchors", action="store_true", help="validate paths only, not #fragments (the pre-2026-08-05 behaviour)")
    ap.add_argument("--anchors-of", metavar="DOC", help="print every anchor DOC generates, in document order, and exit")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args(argv)

    script_dir = Path(__file__).resolve().parent
    root = (args.root or find_repo_root(script_dir)).resolve()
    track_dir = (root / args.track).resolve()

    # ── Anchor listing (the "what SHOULD I have written?" mode) ─────────────
    if args.anchors_of:
        p = Path(args.anchors_of)
        if not p.exists():
            p = root / args.anchors_of
        text = read_text(p) if p.exists() else None
        if text is None:
            print(f"cannot read: {args.anchors_of}", file=sys.stderr)
            return 2
        found = collect_anchors(text)
        if args.json:
            print(json.dumps(found, indent=2))
        else:
            for a in found:
                print(f"#{a}")
        return 0

    all_files = list_files(root)
    docs = [f for f in all_files if f.suffix.lower() in DOC_SUFFIXES]
    tracked = sorted(f for f in all_files if track_dir in f.parents or f.parent == track_dir)

    # ── Link validation ─────────────────────────────────────────────────────
    broken, stats = validate_links(root, docs, check_anchors=not args.no_anchors)

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
        out = {"broken_links": broken, "orphans": orphans, "stats": stats}
        if not args.links_only and not args.orphans_only:
            out["impact_counts"] = {rel: len(h) for rel, h in index.items()}
        print(json.dumps(out, indent=2))
        return 1 if broken else 0

    if not args.orphans_only:
        scope = "paths only (--no-anchors)" if args.no_anchors else "paths + #anchors"
        print(f"== Markdown link validation ({len(docs)} docs, {scope}) ==")
        print(f"  {stats['links']} local links, {stats['fragments']} carrying a #fragment "
              f"→ {stats['anchors_checked']} anchors verified, "
              f"{stats['anchors_skipped']} not checkable (dir / non-Markdown / #L42)")
        if not broken:
            print("  ✓ no broken links")
        else:
            for b in broken:
                print(f"  ✗ {b['doc']}:{b['line']}  →  {b['target']}  ({b['why']}, {b['kind']})")
            print("\n  Tip: `--anchors-of <doc>` prints the anchors that doc actually generates.")
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
