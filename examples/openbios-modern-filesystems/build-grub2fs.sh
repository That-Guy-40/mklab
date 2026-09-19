#!/usr/bin/env bash
# build-grub2fs.sh — build openbios-unix WITH the grub2fs read shim, without ever
# touching the shared OpenBIOS tree. POC-1b of S1 (the grub2fs read shim). See PLAN.md.
#
# The rival and habitats labs build from the SAME shared tree
# (${OPENBIOS_WORKDIR:-$HOME/openbios-lab}/openbios), so this script does NOT edit
# it in place (an in-place edit + revert is fragile: switch-arch reinitializes the
# obj tree on a config change, and a failed revert would break the siblings'
# builds). Instead it builds in a THROWAWAY COPY of the tree's source and copies
# the firmware out:
#   1. rsync the tree's source (obj-* excluded) to $WORKDIR/grub2fs-build/openbios,
#   2. stage the shim + apply the 5 integration edits IN THE COPY,
#   3. build openbios-unix (amd64) there,
#   4. copy the result to the lab-owned $WORKDIR/grub2fs/{openbios-unix,.dict},
#   5. remove the copy (trap, even on failure).
# The shared tree is never modified. Idempotent and safe to re-run.
#
# Output: $WORKDIR/grub2fs/openbios-unix + openbios-unix.dict  (the grub2fs firmware)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
TREE="$WORKDIR/openbios"
IMG="${OPENBIOS_BUILD_IMG:-localhost/openbios-build:latest}"
OUT="$WORKDIR/grub2fs"                        # lab-owned firmware output
BUILDROOT="$WORKDIR/grub2fs-build"            # throwaway build copy
COPY="$BUILDROOT/openbios"

[[ -d "$TREE" ]] || { echo "no OpenBIOS tree at $TREE — run openbios-the-rival-that-shipped/build-openbios.sh unix first" >&2; exit 2; }
command -v podman >/dev/null || { echo "podman not found (toolchain lives in $IMG)" >&2; exit 2; }
for f in grub2fs/grub2fs_fs.c grub2fs/grub2fs_glue.c grub2fs/grub2fs.h grub2fs/build.xml \
         upstream-grub/ext2.c upstream-grub/fshelp.c; do
  [[ -f "$HERE/$f" ]] || { echo "missing shipped file $HERE/$f" >&2; exit 2; }
done

trap 'rm -rf "$BUILDROOT"' EXIT

# ── 1. throwaway copy of the tree's SOURCE (obj-* excluded, rebuilt fresh) ──
echo "grub2fs: copying tree source -> $COPY (shared tree untouched)"
rm -rf "$BUILDROOT"; mkdir -p "$COPY"
if command -v rsync >/dev/null; then
  rsync -a --exclude 'obj-*' "$TREE/" "$COPY/"
else
  cp -a "$TREE/." "$COPY/"; rm -rf "$COPY"/obj-*
fi

# ── 2. stage the shim + the 5 integration edits (fresh copy) ──
mkdir -p "$COPY/fs/grub2fs" "$COPY/include/grub"
cp "$HERE/grub2fs/grub2fs_fs.c" "$HERE/grub2fs/grub2fs_glue.c" \
   "$HERE/grub2fs/grub2fs.h" "$HERE/grub2fs/build.xml" "$COPY/fs/grub2fs/"
cp "$HERE/upstream-grub/ext2.c" "$HERE/upstream-grub/fshelp.c" "$COPY/fs/grub2fs/"
cp "$HERE"/grub2fs/grub/*.h "$COPY/include/grub/"
cd "$COPY"
sed -i 's#<include href="grubfs/build.xml"/>#<include href="grubfs/build.xml"/>\n <include href="grub2fs/build.xml"/>#' fs/build.xml
sed -i 's#<option name="CONFIG_GRUBFS" type="boolean" value="true"/>#<option name="CONFIG_GRUBFS" type="boolean" value="true"/>\n  <option name="CONFIG_FSYS_GRUB2FS" type="boolean" value="true"/>#' config/examples/amd64_config.xml
sed -i 's#\(mkdir -p \$OBJDIR/target/fs/grubfs\)#\1\n    mkdir -p $OBJDIR/target/fs/grub2fs#' config/scripts/switch-arch
sed -i 's#extern void \tgrubfs_init( void );#extern void \tgrubfs_init( void );\nextern void \tgrub2fs_init( void );#' packages/packages.h
python3 - <<'PY'
p="packages/init.c"; s=open(p).read()
anchor="#ifdef CONFIG_GRUBFS\n\tgrubfs_init();\n#endif"
assert anchor in s, "grubfs init block not found in packages/init.c"
# grub2fs is the preferred (more capable) reader; grubfs is the fallback.
open(p,"w").write(s.replace(anchor, "#ifdef CONFIG_FSYS_GRUB2FS\n\tgrub2fs_init();\n#endif\n"+anchor, 1))
PY

# ── 3. build openbios-unix (amd64) in the copy — ONE plain, from-scratch make ──
# A single `make` on a fresh (obj-free) copy is deterministic. The generated
# rules.mak lists all four grub2fs objects as prerequisites of $(ODIR)/libfs.a
# (verified identical across runs), and that archive is built exactly ONCE, from
# scratch, with `ar cru $@ $^` — so every fs object, grub2fs included, is in it;
# init.o (compiled with CONFIG_FSYS_GRUB2FS) references grub2fs_init, so the link
# pulls grub2fs_fs.o out of libfs.a. Measured deterministic 15/15.
#
# Do NOT reintroduce a "delete libfs.a + re-make" step: re-archiving in an
# incremental second make (objects already built, libfs.a recreated) is
# timestamp-sensitive on the build filesystem and INTERMITTENTLY drops grub2fs
# from libfs.a (measured ~1-in-3 to 1-in-6 failures) — the exact bug this replaces.
echo "grub2fs: building openbios-unix (amd64) with grub2fs"
podman run --rm -v "$COPY:/src" --userns=keep-id -w /src "$IMG" \
    sh -c "config/scripts/switch-arch unix-amd64 && make"

# ── 4. verify + copy the firmware out ──
# Capture `nm` to a variable, THEN grep — never `nm | grep -q` as a gate: with
# `set -o pipefail`, grep -q closes the pipe on its first match, nm (large output)
# takes SIGPIPE (141), pipefail propagates it, and the `||` fires a SPURIOUS exit 1
# even though the symbol is present. That race — grep's early close vs nm finishing
# its write — was the whole intermittency; the build itself was always correct.
BIN="$COPY/obj-amd64/openbios-unix"
[[ -f "$BIN" ]] || { echo "FAIL: openbios-unix was not produced" >&2; exit 1; }
syms="$(nm "$BIN")"
grep -qE 'grub2fs_init' <<<"$syms" || { echo "FAIL: grub2fs not linked into openbios-unix" >&2; exit 1; }
mkdir -p "$OUT"
cp "$BIN" "$COPY/obj-amd64/openbios-unix.dict" "$OUT/"
echo "grub2fs: OK — firmware at $OUT/openbios-unix (+ .dict). Shared tree untouched."
grep -E 'grub2fs_init|grub_ext2_fs|grub_disk_read|grub_fs_register' <<<"$syms" || true
# trap removes the throwaway copy.
