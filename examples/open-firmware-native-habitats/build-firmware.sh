#!/usr/bin/env bash
# build-firmware.sh [sparc32|ppc|both] — build OpenBIOS with `patch` REALLY
# implemented, instead of shadowed from NVRAM.
#
# Everything else in this lab runs the STOCK blob QEMU ships, deliberately. This
# script is the one exception and it exists for one reason: loading our own
# `patch` at runtime SHADOWS the firmware's empty stub — the firmware says so
# itself, printing `patch isn't unique.` — so anything already compiled against
# the stub still calls the stub. That is fine for this lab's tracers, and wrong
# as a fix. patches/01-implement-patch.patch puts the implementation where it
# belongs, in forth/debugging/firmware.fs, and this builds the result.
#
# ISOLATION (the house rule, learned the hard way in the sibling labs):
#   * its OWN clone at $WORKDIR/openbios-src — the rival lab's tree at
#     ~/openbios-lab/openbios carries that lab's uncommitted x86-revival patch
#     and is NEVER touched here.
#   * its OWN image (openbios-habitat-build) — the sibling's smokes are pinned
#     to the sibling's image.
#   * the rival lab's built artifacts are sha-guarded across the run and the
#     script fails loudly if any of them moves.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${HABITAT_WORKDIR:-$HOME/ofhabitat-lab}"
SRC="$WORKDIR/openbios-src"
RIVAL="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
IMG=localhost/openbios-habitat-build
TARGET="${1:-both}"

case "$TARGET" in sparc32|ppc|both) ;; *) echo "usage: $0 [sparc32|ppc|both]" >&2; exit 1 ;; esac
command -v podman >/dev/null || { echo "SKIP: podman not installed"; exit 77; }
command -v git    >/dev/null || { echo "SKIP: git not installed"; exit 77; }

mkdir -p "$WORKDIR"

# ── sha-guard the sibling lab's artifacts ────────────────────────────────────
GUARDED=(
    "$RIVAL/openbios/obj-ppc/openbios-qemu.elf"
    "$RIVAL/openbios/obj-x86/openbios.multiboot"
    "$RIVAL/openbios/obj-x86/openbios-builtin.elf"
)
guard_snapshot() {
    local f
    for f in "${GUARDED[@]}"; do
        [ -f "$f" ] && sha256sum "$f"
    done
}
BEFORE="$(guard_snapshot)"

# ── the sources ──────────────────────────────────────────────────────────────
# Cloned from the rival lab's checkout when it exists (fast, offline) — a clone
# copies committed HEAD only, so that lab's uncommitted revival patch does NOT
# come along. Verified: the fresh clone reports 0 modified files.
if [ ! -d "$SRC/.git" ]; then
    if [ -d "$RIVAL/openbios/.git" ]; then
        echo "==> cloning openbios from the rival lab's checkout (committed HEAD only)"
        git clone -q --shared "$RIVAL/openbios" "$SRC"
    else
        echo "==> cloning openbios from upstream"
        git clone -q https://github.com/openbios/openbios.git "$SRC"
    fi
fi
if [ ! -d "$WORKDIR/fcode-utils/.git" ]; then
    if [ -d "$RIVAL/fcode-utils/.git" ]; then
        git clone -q --shared "$RIVAL/fcode-utils" "$WORKDIR/fcode-utils"
    else
        git clone -q https://github.com/openbios/fcode-utils.git "$WORKDIR/fcode-utils"
    fi
fi

echo "==> applying patches/01-implement-patch.patch (idempotent)"
if git -C "$SRC" apply --check "$HERE/patches/01-implement-patch.patch" 2>/dev/null; then
    git -C "$SRC" apply "$HERE/patches/01-implement-patch.patch"
    echo "    applied"
elif git -C "$SRC" apply --reverse --check "$HERE/patches/01-implement-patch.patch" 2>/dev/null; then
    echo "    already applied"
else
    echo "ERROR: the patch neither applies nor reverses — the tree has diverged." >&2
    echo "       Compare $SRC/forth/debugging/firmware.fs against the patch." >&2
    exit 1
fi

echo "==> building the build-box image ($IMG)"
podman build -q -t openbios-habitat-build -f "$HERE/Containerfile" "$WORKDIR" >/dev/null

obuild() {  # obuild <switch-arch target> <objdir> <artifact>
    echo "==> building $1"
    podman run --rm -v "$SRC:/src" --userns=keep-id -w /src "$IMG" \
        sh -c "config/scripts/switch-arch $1 >/dev/null && make >/dev/null 2>&1 || make"
    [ -f "$SRC/$2/$3" ] || { echo "ERROR: $2/$3 was not produced" >&2; exit 1; }
    cp "$SRC/$2/$3" "$WORKDIR/openbios-$4-patched"
    echo "    -> $WORKDIR/openbios-$4-patched"
}

case "$TARGET" in
  sparc32) obuild sparc32   obj-sparc32 openbios-builtin.elf sparc32 ;;
  ppc)     obuild qemu-ppc  obj-ppc     openbios-qemu.elf    ppc ;;
  both)    obuild sparc32   obj-sparc32 openbios-builtin.elf sparc32
           obuild qemu-ppc  obj-ppc     openbios-qemu.elf    ppc ;;
esac

# ── the guard has to hold ────────────────────────────────────────────────────
AFTER="$(guard_snapshot)"
if [ "$BEFORE" != "$AFTER" ]; then
    echo "FAIL: a sibling lab's artifact changed during this build — isolation broke" >&2
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") >&2 || true
    exit 1
fi
echo "==> sibling lab artifacts unchanged ($(printf '%s\n' "$BEFORE" | grep -c . ) guarded)"
