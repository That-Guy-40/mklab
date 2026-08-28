#!/usr/bin/env bash
# openbios-archive-tree.sh — take a dated, compressed snapshot of the patched
# OpenBIOS source tree, bound to the identity of what produced it.
#
# THE ARCHIVE IS NOT THE SOURCE OF TRUTH, and saying so is the whole design. The
# tree is REPRODUCIBLE: the pinned upstream commit plus
# patches/TESTED-TREE.patch regenerates it exactly (722 of 722 source files
# sha256-identical, measured 2026-08-27). This is insurance and convenience --
# against upstream vanishing, a rewritten history, or simply wanting the bytes
# that were running on a given day -- not a second definition of the firmware.
#
# WHICH IS WHY IT CARRIES A MANIFEST. An archive with no identity is a cached
# fact of the worst kind: a directory of tarballs whose names say when they were
# made and nothing about WHAT they contain, so the day two of them disagree
# there is no way to tell which one is the tree that was tested. Bug class #1 in
# CLAUDE.md. So every archive is stamped with:
#
#   - the openbios PIN it diverges from, read out of build-openbios.sh
#   - the sha256 of the TESTED-TREE.patch that produced it
#   - a TREE DIGEST over the file contents themselves
#   - the mklab commit that was checked out when it was taken
#
# A DATE IS A RECORD; THE DIGEST IS THE IDENTITY. Both are in the filename, so
# `ls` answers "when" and "is this the same tree" without opening anything. Two
# archives taken a month apart from an unchanged tree have the same digest and
# the second is not written at all -- see the dedup below.
#
# WHAT IS EXCLUDED, and why it is not arbitrary: .git (the archive is of a
# working tree, not its history), obj-* (build output, regenerated in seconds),
# and config-host.mak (switch-arch writes it, and it is the ONE file that
# differs between a cold and a warm tree -- excluding it is what makes the digest
# stable across build states rather than a function of what was last built).
set -euo pipefail

usage() {
    cat <<'USAGE'
openbios-archive-tree.sh [OPTIONS]

Archives the patched OpenBIOS source tree as a dated, content-addressed tarball
with a manifest binding it to the pin and patch that produced it.

  --workdir DIR    tree to archive        (default $HOME/openbios-lab/openbios)
  --out DIR        where archives live    (default <workdir>/../archives)
  --verify FILE    verify an existing archive instead of writing one:
                   re-derives its tree digest from the bytes and compares it
                   against its own manifest, and against the live tree
  --keep N         keep only the N most recent archives (default 4; 0 = keep all)
  --force          write even when an archive of this exact tree already exists
  --quiet          only print the archive path (for scripting)

Exit: 0 ok / 1 a check failed / 2 usage error.
USAGE
}

WD="$HOME/openbios-lab/openbios"; OUT=""; VERIFY=""; FORCE=0; QUIET=0; KEEP=4
while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir) WD="${2:?--workdir needs a directory}"; shift 2 ;;
        --out)     OUT="${2:?--out needs a directory}"; shift 2 ;;
        --verify)  VERIFY="${2:?--verify needs a file}"; shift 2 ;;
        --keep)    KEEP="${2:?--keep needs a number}"
                   [[ "$KEEP" =~ ^[0-9]+$ ]] || { echo "--keep wants a non-negative integer, got '$KEEP'" >&2; exit 2; }
                   shift 2 ;;
        --force)   FORCE=1; shift ;;
        --quiet)   QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
say() { (( QUIET )) || echo "$@"; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAB="$HERE/examples/openbios-the-rival-that-shipped"
PATCH="$LAB/patches/TESTED-TREE.patch"

# tree_digest <dir> — sha256 over the CONTENTS of every source file, order-stable.
#
# LC_ALL=C on the sort is load-bearing: a locale-dependent order would make the
# same tree digest differently on two machines, and a digest that depends on who
# is asking is not an identity.
tree_digest() {
    ( cd "$1" && find . -type f \
        -not -path './.git/*' -not -path './obj-*' -not -name 'config-host.mak' \
        -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1 )
}
tree_count() {
    ( cd "$1" && find . -type f \
        -not -path './.git/*' -not -path './obj-*' -not -name 'config-host.mak' | wc -l )
}

# ── verify mode ────────────────────────────────────────────────────────────────
if [[ -n "$VERIFY" ]]; then
    [[ -f "$VERIFY" ]] || { echo "ERROR: no such archive: $VERIFY" >&2; exit 1; }
    MAN="${VERIFY%.tar.*}.manifest.txt"
    [[ -f "$MAN" ]] || { echo "ERROR: no manifest beside $VERIFY — an archive with no identity cannot be verified, only unpacked" >&2; exit 1; }
    want="$(sed -n 's/^tree-digest: //p' "$MAN" | head -1)"
    [[ -n "$want" ]] || { echo "ERROR: $MAN has no tree-digest line" >&2; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT
    tar -xf "$VERIFY" -C "$tmp"
    root="$tmp/$(ls "$tmp")"
    got="$(tree_digest "$root")"
    say "manifest:  $want"
    say "recomputed: $got"
    if [[ "$want" != "$got" ]]; then
        echo "FAIL: the archive's contents do not match its own manifest — it was modified after being written, or the manifest was" >&2
        exit 1
    fi
    say "  - the archive matches its manifest"
    if [[ -d "$WD" ]]; then
        live="$(tree_digest "$WD")"
        if [[ "$live" == "$got" ]]; then
            say "  - and it matches the LIVE tree at $WD — this is the tree running now"
        else
            say "  - the live tree at $WD has digest $live, so it has CHANGED since this archive (that is information, not an error)"
        fi
    else
        say "  - no live tree at $WD to compare against — UNCHECKED, which is an unknown and not a pass"
    fi
    echo "PASS: $(basename "$VERIFY") is internally consistent and identifies the tree it holds"
    exit 0
fi

# ── archive mode ───────────────────────────────────────────────────────────────
[[ -d "$WD" ]] || { echo "ERROR: no tree at $WD (use --workdir)" >&2; exit 1; }
[[ -f "$PATCH" ]] || { echo "ERROR: $PATCH is missing — an archive that cannot name the patch it came from is an orphan" >&2; exit 1; }
[[ -z "$OUT" ]] && OUT="$(cd "$WD/.." && pwd)/archives"
mkdir -p "$OUT"

PIN="$(sed -n 's/^OPENBIOS_PIN=\([0-9a-f]\{40\}\)$/\1/p' "$LAB/build-openbios.sh" | head -1)"
[[ -n "$PIN" ]] || { echo "ERROR: no OPENBIOS_PIN in build-openbios.sh" >&2; exit 1; }
PATCH_SHA="$(sha256sum "$PATCH" | cut -d' ' -f1)"
ARCH_TESTED="$(sed -n 's/^Arch-tested: //p' "$PATCH" | head -1)"
MKLAB_COMMIT="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)"
AT="$(git -C "$WD" rev-parse HEAD 2>/dev/null || echo unknown)"

DIGEST="$(tree_digest "$WD")"
COUNT="$(tree_count "$WD")"
DATE="$(date -u +%Y-%m-%d)"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SHORT="${DIGEST:0:12}"

# DEDUP BY WHAT IT CONTAINS, not by when it was taken. Running this after every
# build is meant to be free when nothing changed; otherwise a tool that is safe
# to automate quietly fills a disk with identical trees under different dates.
if (( ! FORCE )); then
    existing="$(find "$OUT" -maxdepth 1 -name "*-$SHORT.tar.*" | head -1)"
    if [[ -n "$existing" ]]; then
        say "==> this exact tree is already archived (digest ${SHORT}):"
        say "    $existing"
        say "    nothing written. Use --force to write a second copy under today's date."
        (( QUIET )) && printf '%s\n' "$existing"
        exit 0
    fi
fi

if command -v zstd >/dev/null 2>&1; then EXT=tar.zst; COMP=(--zstd)
else                                     EXT=tar.gz;  COMP=(--gzip); fi
BASE="openbios-tested-tree-$DATE-$SHORT"
TARBALL="$OUT/$BASE.$EXT"
MANIFEST="$OUT/$BASE.manifest.txt"

say "==> archiving $WD"
say "    $COUNT source files, tree digest $DIGEST"
tar --create "${COMP[@]}" --file "$TARBALL" \
    --exclude='.git' --exclude='obj-*' --exclude='config-host.mak' \
    --directory "$(dirname "$WD")" --sort=name \
    --owner=0 --group=0 --numeric-owner \
    "$(basename "$WD")"
TAR_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"

cat > "$MANIFEST" <<MAN
# openbios tested-tree archive
#
# This is a SNAPSHOT, not the source of truth. The tree is reproducible from the
# pin and the patch named below; regenerating it is the primary path and this is
# the fallback. Verify with:
#
#     tools/openbios-archive-tree.sh --verify $(basename "$TARBALL")
#
archive: $(basename "$TARBALL")
taken: $STAMP
tree-digest: $DIGEST
tree-files: $COUNT
archive-sha256: $TAR_SHA
openbios-pin: $PIN
workdir-head: $AT
tested-tree-patch-sha256: $PATCH_SHA
arch-tested: ${ARCH_TESTED:-UNKNOWN (no Arch-tested line in the patch)}
mklab-commit: $MKLAB_COMMIT
#
# tree-digest is sha256 over the sha256sums of every source file, sorted under
# LC_ALL=C, excluding .git, obj-* and config-host.mak. It is the IDENTITY. The
# date above is a record of when the snapshot was taken and identifies nothing.
MAN

say "==> wrote:"
say "    $TARBALL ($(du -h "$TARBALL" | cut -f1))"
say "    $MANIFEST"

# RETENTION. Archives are snapshots of a reproducible tree, so old ones are a
# convenience and not a record anyone is obliged to keep -- but "keep everything"
# turns a tool that is safe to run on every build into one that fills a disk.
#
# THREE RULES, because this deletes files:
#   1. Only this tool's OWN names are ever considered:
#      openbios-tested-tree-<date>-<digest>.tar.*  -- anything else in the
#      directory is invisible to it, so a file someone put here by hand cannot be
#      swept up by a retention policy it was never part of.
#   2. A tarball is only removed together with ITS manifest, and only if that
#      manifest exists. An archive with no manifest cannot be verified and is also
#      not something this tool wrote in one piece, so it is left alone and NAMED.
#   3. Everything removed is PRINTED. A retention policy that prunes quietly is
#      indistinguishable from a bug that eats archives.
if (( KEEP > 0 )); then
    mapfile -t ARCHIVES < <(find "$OUT" -maxdepth 1 -name 'openbios-tested-tree-*.tar.*' \
                            -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    if (( ${#ARCHIVES[@]} > KEEP )); then
        say "==> retention: keeping the $KEEP most recent of ${#ARCHIVES[@]} archives"
        for old in "${ARCHIVES[@]:$KEEP}"; do
            oldman="${old%.tar.*}.manifest.txt"
            if [[ -f "$oldman" ]]; then
                rm -f -- "$old" "$oldman"
                say "    removed $(basename "$old") and its manifest"
            else
                say "    KEPT $(basename "$old") — it has no manifest, so this tool did not write it as a pair and will not delete it"
            fi
        done
    fi
fi
(( QUIET )) && printf '%s\n' "$TARBALL"
exit 0
