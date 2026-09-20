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

# GRUB2FS_ONLY=1 builds a firmware with the OLD grubfs package NOT registered
# (CONFIG_GRUBFS=false), so grub2fs is the ONLY filesystem reader. The fs-tiers
# track (POC-5) needs per-reader attribution: a read through this firmware is
# unambiguously grub2fs's, with no probe-order guess about which package handled it
# (the stock grubfs-only firmware is the other single-reader half). Default (unset)
# keeps grubfs registered too, as POC-1b..4 shipped.
GRUB2FS_ONLY="${GRUB2FS_ONLY:-}"
# ENDGAME_WRITE builds a WRITABLE variant (O_RDWR + blk write-blocks + disk-label
# write relay) — keep its firmware in a distinct dir so the read-only firmwares are
# never confused with it.
_wsfx=""; [[ -n "${ENDGAME_WRITE:-}" ]] && _wsfx="-write"
if [[ -n "$GRUB2FS_ONLY" ]]; then
  OUT="$WORKDIR/grub2fs-only$_wsfx"; BUILDROOT="$WORKDIR/grub2fs-only$_wsfx-build"
else
  OUT="$WORKDIR/grub2fs$_wsfx"; BUILDROOT="$WORKDIR/grub2fs$_wsfx-build"
fi
COPY="$BUILDROOT/openbios"

[[ -d "$TREE" ]] || { echo "no OpenBIOS tree at $TREE — run openbios-the-rival-that-shipped/build-openbios.sh unix first" >&2; exit 2; }
command -v podman >/dev/null || { echo "podman not found (toolchain lives in $IMG)" >&2; exit 2; }
for f in grub2fs/grub2fs_fs.c grub2fs/grub2fs_glue.c grub2fs/grub2fs.h grub2fs/build.xml \
         upstream-grub/ext2.c upstream-grub/fshelp.c \
         upstream-grub/iso9660.c upstream-grub/fat.h upstream-grub/exfat.h; do
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
cp "$HERE/upstream-grub/ext2.c" "$HERE/upstream-grub/fshelp.c" \
   "$HERE/upstream-grub/fat.c" "$HERE/upstream-grub/iso9660.c" "$COPY/fs/grub2fs/"
cp "$HERE"/grub2fs/grub/*.h "$COPY/include/grub/"
# vendored GRUB headers (on-disk structs) also go in include/grub/
cp "$HERE/upstream-grub/fat.h" "$HERE/upstream-grub/exfat.h" "$COPY/include/grub/"
cd "$COPY"
sed -i 's#<include href="grubfs/build.xml"/>#<include href="grubfs/build.xml"/>\n <include href="grub2fs/build.xml"/>#' fs/build.xml
sed -i 's#<option name="CONFIG_GRUBFS" type="boolean" value="true"/>#<option name="CONFIG_GRUBFS" type="boolean" value="true"/>\n  <option name="CONFIG_FSYS_GRUB2FS" type="boolean" value="true"/>#' config/examples/amd64_config.xml
if [[ -n "$GRUB2FS_ONLY" ]]; then
  # grub2fs-only: turn the old grubfs package OFF so grub2fs is the sole reader
  # (the #ifdef CONFIG_GRUBFS guard around grubfs_init() then compiles it out).
  sed -i 's#<option name="CONFIG_GRUBFS" type="boolean" value="true"/>#<option name="CONFIG_GRUBFS" type="boolean" value="false"/>#' config/examples/amd64_config.xml
  echo "grub2fs: GRUB2FS_ONLY — grubfs package disabled (CONFIG_GRUBFS=false); grub2fs is the sole fs reader"
fi
sed -i 's#\(mkdir -p \$OBJDIR/target/fs/grubfs\)#\1\n    mkdir -p $OBJDIR/target/fs/grub2fs#' config/scripts/switch-arch
sed -i 's#extern void \tgrubfs_init( void );#extern void \tgrubfs_init( void );\nextern void \tgrub2fs_init( void );#' packages/packages.h
python3 - <<'PY'
p="packages/init.c"; s=open(p).read()
anchor="#ifdef CONFIG_GRUBFS\n\tgrubfs_init();\n#endif"
assert anchor in s, "grubfs init block not found in packages/init.c"
# grub2fs is the preferred (more capable) reader; grubfs is the fallback.
open(p,"w").write(s.replace(anchor, "#ifdef CONFIG_FSYS_GRUB2FS\n\tgrub2fs_init();\n#endif\n"+anchor, 1))
PY

# ── endgame E2 (ENDGAME_WRITE=1): make the hosted disk WRITABLE ──
# The hosted disk (arch/unix/blk.c) is read-only: the image is opened O_RDONLY (a
# deliberate safety choice) and blk.c exposes no write-blocks. The C deblocker
# (packages/deblocker.c) ALREADY implements byte-level `write` via the parent's
# write-blocks — it just found none. So: open the image O_RDWR, add write_to_disk
# (mirror read_from_disk), and add a blk.c write-blocks method. Then grub2fs's
# write path (glue write_io -> disk `write` -> deblocker -> write-blocks) works.
# Off by default → the normal grub2fs hosted firmware stays read-only.
if [[ -n "${ENDGAME_WRITE:-}" ]]; then
  echo "grub2fs: ENDGAME_WRITE — hosted disk made writable (O_RDWR + blk.c write-blocks)"
  # 1. open the disk image read-write
  sed -i 's#diskemu=open(optarg, O_RDONLY|__LFS);#diskemu=open(optarg, O_RDWR|__LFS);#' arch/unix/unix.c
  grep -q 'O_RDWR|__LFS' arch/unix/unix.c || { echo "ENDGAME_WRITE: failed to set O_RDWR in unix.c" >&2; exit 1; }
  # 2. write_to_disk (mirror read_from_disk) + its declaration
  python3 - <<'PY'
p="arch/unix/unix.c"; s=open(p).read()
anchor="\tlseek(diskemu, (ducell)blk*512, SEEK_SET);\n\tread(diskemu, buf, size);\n\n\treturn 0;\n}"
assert anchor in s, "unix.c read_from_disk body not found"
wf = """

int
write_to_disk( int channel, int unit, int blk, unsigned long mphys, int size )
{
\tunsigned char *buf=(unsigned char *)mphys;

\tif(diskemu==-1)
\t\treturn -1;

\tlseek(diskemu, (ducell)blk*512, SEEK_SET);
\tif( write(diskemu, buf, size) != size )
\t\treturn -1;

\treturn 0;
}"""
s = s.replace(anchor, anchor + wf, 1)
open(p,"w").write(s)

p="arch/unix/blk.h"; s=open(p).read()
decl='extern int\tread_from_disk( int channel, int unit, int blk, unsigned long mphys, int size );'
assert decl in s, "blk.h read_from_disk decl not found"
s = s.replace(decl, decl + '\nextern int\twrite_to_disk( int channel, int unit, int blk, unsigned long mphys, int size );', 1)
open(p,"w").write(s)

p="arch/unix/blk.c"; s=open(p).read()
# insert blk_write_blocks after blk_read_blocks
anchor="""\t\tmemcpy( dest, buf, m * 512 );
\t\ti += m;
\t\tdest += m * 512;
\t}
\tPUSH( n );
}"""
assert anchor in s, "blk.c blk_read_blocks body not found"
wb = """

/* ( buf blk nblks -- actual ) */
static void
blk_write_blocks( blk_data_t *pb )
{
\tcell i, n = POP();
\tcell blk = POP();
\tchar *src = (char*)POP();

\tfor( i=0; i<n; ) {
\t\tchar buf[4096];
\t\tucell m = MIN( n-i, sizeof(buf)/512 );

\t\tmemcpy( buf, src, m * 512 );
\t\tif( write_to_disk(pb->channel, pb->unit, blk+i, (ucell)buf, m*512) < 0 ) {
\t\t\tprintk("write_to_disk: error\\n");
\t\t\tRET(0);
\t\t}
\t\ti += m;
\t\tsrc += m * 512;
\t}
\tPUSH( n );
}"""
s = s.replace(anchor, anchor + wb, 1)
s = s.replace('\t{ "read-blocks",\tblk_read_blocks\t},',
              '\t{ "read-blocks",\tblk_read_blocks\t},\n\t{ "write-blocks",\tblk_write_blocks\t},', 1)
open(p,"w").write(s)

# 4. disk-label relays only read/seek/tell to its parent; its `write` is a hard
#    stub (DDROP; PUSH -1). grub2fs's parent IS the disk-label, so its write must
#    relay too. Cache parent_write_xt and forward, exactly like dlabel_read.
p="packages/disk-label.c"; s=open(p).read()
assert '\txt_t\t\tparent_read_xt;' in s, "disk-label.c struct field not found"
s = s.replace('\txt_t\t\tparent_read_xt;',
              '\txt_t\t\tparent_read_xt;\n\txt_t\t\tparent_write_xt;', 1)
assert '\tdi->parent_read_xt = find_parent_method("read");' in s, "disk-label.c open read_xt not found"
s = s.replace('\tdi->parent_read_xt = find_parent_method("read");',
              '\tdi->parent_read_xt = find_parent_method("read");\n\tdi->parent_write_xt = find_parent_method("write");', 1)
stub = 'dlabel_write( __attribute__((unused)) dlabel_info_t *di )\n{\n\tDDROP();\n\tPUSH( -1 );\n}'
assert stub in s, "disk-label.c dlabel_write stub not found"
s = s.replace(stub,
              'dlabel_write( dlabel_info_t *di )\n{\n\t/* relay to the parent (deblocker over write-blocks) — endgame E2 */\n\tcall_package(di->parent_write_xt, my_parent());\n}', 1)
open(p,"w").write(s)
PY
  grep -q 'blk_write_blocks' arch/unix/blk.c || { echo "ENDGAME_WRITE: blk.c write-blocks fn not staged" >&2; exit 1; }
  grep -qE '"write-blocks"[^}]*blk_write_blocks' arch/unix/blk.c || { echo "ENDGAME_WRITE: blk.c write-blocks METHOD entry not staged" >&2; exit 1; }
  grep -q 'write_to_disk' arch/unix/blk.h || { echo "ENDGAME_WRITE: write_to_disk decl not staged in blk.h" >&2; exit 1; }
  grep -q 'parent_write_xt' packages/disk-label.c || { echo "ENDGAME_WRITE: disk-label write relay not staged" >&2; exit 1; }
fi

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
for want in grub2fs_init grub_ext2_fs grub_fat_fs grub_iso9660_fs; do
  grep -qE "$want" <<<"$syms" || { echo "FAIL: $want not linked into openbios-unix" >&2; exit 1; }
done
mkdir -p "$OUT"
cp "$BIN" "$COPY/obj-amd64/openbios-unix.dict" "$OUT/"
echo "grub2fs: OK — firmware at $OUT/openbios-unix (+ .dict). Shared tree untouched."
grep -E 'grub2fs_init|grub_ext2_fs|grub_fat_fs|grub_iso9660_fs|grub_disk_read|grub_fs_register' <<<"$syms" || true
# trap removes the throwaway copy.
