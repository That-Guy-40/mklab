#!/usr/bin/env bash
# build-grub2fs-arch.sh <ppc|x86> — build a REAL (QEMU) OpenBIOS firmware WITH the
# grub2fs read shim, for the four-arch matrix (POC-4). Sibling of build-grub2fs.sh
# (which does the hosted unix-amd64); same throwaway-copy discipline (the shared
# tree is never touched), same 5 integration edits, retargeted per arch:
#
#   ppc  -> switch-arch qemu-ppc -> obj-ppc/openbios-qemu.elf   (-bios for qemu-system-ppc)
#           config/examples/ppc_config.xml   (BIG-ENDIAN — the byte-order control)
#   x86  -> switch-arch x86      -> obj-x86/openbios.multiboot + openbios-x86.dict
#           config/examples/x86_config.xml   (little-endian, real-firmware confirmation)
#
# Output: $WORKDIR/grub2fs-<arch>/<firmware>. Shared tree untouched (EXIT-trap cleanup).
set -euo pipefail

ARCH="${1:?usage: build-grub2fs-arch.sh <ppc|x86>}"
case "$ARCH" in
  ppc) SW=qemu-ppc; CFG=ppc_config.xml; OBJ=obj-ppc;  BINS=(openbios-qemu.elf) ;;
  x86) SW=x86;      CFG=x86_config.xml; OBJ=obj-x86;  BINS=(openbios.multiboot openbios-x86.dict) ;;
  *)   echo "unknown arch '$ARCH' (want ppc|x86)" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
TREE="$WORKDIR/openbios"
IMG="${OPENBIOS_BUILD_IMG:-localhost/openbios-build:latest}"

# GRUB2FS_ONLY=1 disables the old grubfs package (CONFIG_GRUBFS=false) so grub2fs is
# the SOLE fs reader — an `open-dev hd:\file` is then unambiguously grub2fs's (with
# grubfs registered too, grubfs mounts any ext2 first and answers open-dev, hiding
# grub2fs's methods). The endgame's write path is reached through grub2fs, so it
# needs this. Mirrors build-grub2fs.sh's GRUB2FS_ONLY.
GRUB2FS_ONLY="${GRUB2FS_ONLY:-}"
if [[ -n "$GRUB2FS_ONLY" ]]; then
  OUT="$WORKDIR/grub2fs-only-$ARCH"; BUILDROOT="$WORKDIR/grub2fs-only-build-$ARCH"
else
  OUT="$WORKDIR/grub2fs-$ARCH"; BUILDROOT="$WORKDIR/grub2fs-build-$ARCH"
fi
COPY="$BUILDROOT/openbios"

[[ -d "$TREE" ]] || { echo "no OpenBIOS tree at $TREE — run openbios-the-rival-that-shipped/build-openbios.sh first" >&2; exit 2; }
command -v podman >/dev/null || { echo "podman not found (toolchain lives in $IMG)" >&2; exit 2; }
[[ -f "$TREE/config/examples/$CFG" ]] || { echo "no $CFG in tree (arch not buildable here?)" >&2; exit 2; }
for f in grub2fs/grub2fs_fs.c grub2fs/grub2fs_glue.c grub2fs/grub2fs.h grub2fs/build.xml \
         upstream-grub/ext2.c upstream-grub/fshelp.c upstream-grub/fat.c upstream-grub/iso9660.c \
         upstream-grub/fat.h upstream-grub/exfat.h; do
  [[ -f "$HERE/$f" ]] || { echo "missing shipped file $HERE/$f" >&2; exit 2; }
done

trap 'rm -rf "$BUILDROOT"' EXIT

echo "grub2fs[$ARCH]: copying tree source -> $COPY (shared tree untouched)"
rm -rf "$BUILDROOT"; mkdir -p "$COPY"
if command -v rsync >/dev/null; then rsync -a --exclude 'obj-*' "$TREE/" "$COPY/"
else cp -a "$TREE/." "$COPY/"; rm -rf "$COPY"/obj-*; fi

# stage the shim + the 5 integration edits (fresh copy) — identical to build-grub2fs.sh
# except the FSYS_GRUB2FS option goes in THIS arch's config XML.
mkdir -p "$COPY/fs/grub2fs" "$COPY/include/grub"
cp "$HERE/grub2fs/grub2fs_fs.c" "$HERE/grub2fs/grub2fs_glue.c" \
   "$HERE/grub2fs/grub2fs.h" "$HERE/grub2fs/build.xml" "$COPY/fs/grub2fs/"
cp "$HERE/upstream-grub/ext2.c" "$HERE/upstream-grub/fshelp.c" \
   "$HERE/upstream-grub/fat.c" "$HERE/upstream-grub/iso9660.c" "$COPY/fs/grub2fs/"
cp "$HERE"/grub2fs/grub/*.h "$COPY/include/grub/"
cp "$HERE/upstream-grub/fat.h" "$HERE/upstream-grub/exfat.h" "$COPY/include/grub/"
cd "$COPY"
sed -i 's#<include href="grubfs/build.xml"/>#<include href="grubfs/build.xml"/>\n <include href="grub2fs/build.xml"/>#' fs/build.xml
sed -i "s#<option name=\"CONFIG_GRUBFS\" type=\"boolean\" value=\"true\"/>#<option name=\"CONFIG_GRUBFS\" type=\"boolean\" value=\"true\"/>\n  <option name=\"CONFIG_FSYS_GRUB2FS\" type=\"boolean\" value=\"true\"/>#" "config/examples/$CFG"
if [[ -n "$GRUB2FS_ONLY" ]]; then
  sed -i "s#<option name=\"CONFIG_GRUBFS\" type=\"boolean\" value=\"true\"/>#<option name=\"CONFIG_GRUBFS\" type=\"boolean\" value=\"false\"/>#" "config/examples/$CFG"
  echo "grub2fs[$ARCH]: GRUB2FS_ONLY — grubfs package disabled (CONFIG_GRUBFS=false)"
fi
sed -i 's#\(mkdir -p \$OBJDIR/target/fs/grubfs\)#\1\n    mkdir -p $OBJDIR/target/fs/grub2fs#' config/scripts/switch-arch
sed -i 's#extern void \tgrubfs_init( void );#extern void \tgrubfs_init( void );\nextern void \tgrub2fs_init( void );#' packages/packages.h
python3 - <<'PY'
p="packages/init.c"; s=open(p).read()
anchor="#ifdef CONFIG_GRUBFS\n\tgrubfs_init();\n#endif"
assert anchor in s, "grubfs init block not found in packages/init.c"
open(p,"w").write(s.replace(anchor, "#ifdef CONFIG_FSYS_GRUB2FS\n\tgrub2fs_init();\n#endif\n"+anchor, 1))
PY

# ── endgame E2 (ENDGAME_WRITE=1): expose a write-blocks METHOD on the ide disk ──
# drivers/ide.c already carries a guarded ATA write path (ob_ide_write_sectors —
# refuses ATAPI/CHS/out-of-LBA28/out-of-range); it is simply not bound as a Forth
# method. Mirror read-blocks (drivers/floppy.c shows the shape) so the same-length
# in-place write (design notes §2.6) can reach it. Off by default → POC-4's arch
# builds are byte-for-byte unchanged.
if [[ -n "${ENDGAME_WRITE:-}" ]]; then
  echo "grub2fs[$ARCH]: ENDGAME_WRITE — exposing ide.c write-blocks (mirror of read-blocks)"
  python3 - <<'PY'
p = "drivers/ide.c"; s = open(p).read()
fn = """static void
ob_ide_write_blocks(int *idx)
{
\tcell n = POP(), cnt = n;
\tucell blk = POP();
\tunsigned char *src = (unsigned char *)cell2pointer(POP());
\tstruct ide_drive *drive = *(struct ide_drive **)idx;

\twhile (n) {
\t\tunsigned int len = (unsigned int) n;
\t\tif (len > (unsigned int) drive->max_sectors)
\t\t\tlen = drive->max_sectors;
\t\t/* ob_ide_write_sectors refuses ATAPI/CHS/out-of-LBA28/range by itself */
\t\tif (ob_ide_write_sectors(drive, blk, src, len)) {
\t\t\tIDE_DPRINTF("ob_ide_write_blocks: error\\n");
\t\t\tRET(0);
\t\t}
\t\tsrc += len * drive->bs;
\t\tn -= len;
\t\tblk += len;
\t}
\tPUSH(cnt);
}

"""
anchor = "static void\nob_ide_block_size(int *idx)"
assert anchor in s, "ide.c: ob_ide_block_size anchor not found"
s = s.replace(anchor, fn + anchor, 1)
# add the method-table entry right after the read-blocks line (copy its indent)
lines = s.splitlines(keepends=True); out = []; done = False
for ln in lines:
    out.append(ln)
    if not done and '"read-blocks"' in ln and "ob_ide_read_blocks" in ln:
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(indent + '{ "write-blocks",\tob_ide_write_blocks\t},\n')
        done = True
assert done, "ide.c: read-blocks method-table entry not found"
open(p, "w").write("".join(out))
PY
fi

echo "grub2fs[$ARCH]: building (switch-arch $SW) — one plain from-scratch make"
podman run --rm -v "$COPY:/src" --userns=keep-id -w /src "$IMG" \
    sh -c "config/scripts/switch-arch $SW && make"

BIN="$COPY/$OBJ/${BINS[0]}"
[[ -f "$BIN" ]] || { echo "FAIL: ${BINS[0]} not produced" >&2; exit 1; }
# gate: grub2fs linked. The ppc openbios-qemu.elf is STRIPPED (nm: no symbols), so
# verify via the UNSTRIPPED objects + the fs archive instead of the final binary:
# each driver's init is defined in its object, the objects are archived into libfs.a,
# and the link above SUCCEEDED (init.o references grub2fs_init under CONFIG_FSYS_GRUB2FS,
# so an unlinked grub2fs would have failed the link with an undefined symbol).
# (capture nm to a var, grep <<< — NEVER a pipe gate; SIGPIPE would lie.)
G2OBJS="$(find "$COPY/$OBJ" -path '*grub2fs*' -name '*.o' 2>/dev/null)"
[[ -n "$G2OBJS" ]] || { echo "FAIL: no grub2fs objects compiled" >&2; exit 1; }
syms="$(nm $G2OBJS 2>/dev/null)"
for want in grub2fs_init grub_ext2_init grub_fat_init grub_iso9660_init; do
  grep -qE "[TtWw] $want\$" <<<"$syms" || { echo "FAIL: $want not defined in grub2fs objects" >&2; exit 1; }
done
FSLIB="$(find "$COPY/$OBJ" -name 'libfs*.a' 2>/dev/null | head -1)"
arlist="$(ar t "$FSLIB" 2>/dev/null)"
grep -q 'grub2fs_fs.o' <<<"$arlist" || { echo "FAIL: grub2fs not archived into $FSLIB" >&2; exit 1; }
mkdir -p "$OUT"
for b in "${BINS[@]}"; do cp "$COPY/$OBJ/$b" "$OUT/"; done
echo "grub2fs[$ARCH]: OK — firmware at $OUT/${BINS[0]}. Shared tree untouched."
