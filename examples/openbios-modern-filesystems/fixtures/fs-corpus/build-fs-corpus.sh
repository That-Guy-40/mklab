#!/usr/bin/env bash
# build-fs-corpus.sh — the S1 POC-5 filesystem corpus: one image per EDGE, each
# named for the edge it isolates, each holding a distinct known payload so a
# cross-image mixup is caught (a wrong-image read mismatches its own .expected).
#
# The corpus is the SUBJECT the fs-tiers table is derived from, so it is bound to
# the table by hash (fs-tiers.toml records corpus.sha256; the track refuses a stale
# one). This builder is the elf-gate corpus-builder shape: deterministic, one edge
# per image, a manifest, and a sha over the images.
#
# Each edge is VALIDATED AT BUILD TIME by a FOREIGN reader (debugfs=e2fsprogs,
# mcopy=mtools, isoinfo=cdrkit) — never one of the two firmware readers under test
# (grubfs/grub2fs, both GRUB-lineage), so the corpus is not GRUB grading GRUB. The
# written payload is the ground truth (<edge>.expected); the foreign reader confirms
# the image is well-formed and actually contains it.
#
# Output (all under $OUTDIR, default ./out):
#   <edge>.img           the filesystem image
#   <edge>.expected      the exact bytes the payload file holds (firmware must reproduce)
#   manifest.tsv         format<TAB>edge<TAB>image<TAB>payload_path<TAB>foreign_oracle<TAB>note
#   corpus.sha256        sha256 of every image + expected + the manifest (the provenance anchor)
#
# ext2 edges are REQUIRED (they are the grubfs-vs-grub2fs deciders). FAT/ISO edges
# are best-effort: a missing authoring tool SKIPs that edge BY NAME in the manifest
# (note=SKIP:<reason>) rather than failing the corpus — the track then names it.
#
# Exit: 0 the required edges built + validated; 2 a required edge or tool failed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="${1:-$HERE/out}"

# ── REPRODUCIBILITY: the corpus anchors the fs-tiers table by hash, so the images
# must be byte-stable across rebuilds — otherwise every fresh build looks "stale"
# and the stale-refusal control cannot tell real drift from an ambient random UUID.
# Each authoring tool embeds randomness (mke2fs: UUID + htree hash_seed; mkfs.vfat:
# volume id; xorriso: creation dates); we pin all of it. Verified byte-identical
# across runs. ──
export SOURCE_DATE_EPOCH=0          # mke2fs superblock times; xorriso file/volume dates
FIXED_HASH_SEED="00000000-0000-0000-0000-0000000000fe"   # mke2fs dir_index htree seed

need() { command -v "$1" >/dev/null || { echo "build-fs-corpus: REQUIRED tool '$1' missing ($2)" >&2; exit 2; }; }
have() { command -v "$1" >/dev/null; }

# ── required tools (the ext2 deciders + the anchor) ──
need mke2fs "author the ext2 images — the grubfs-vs-grub2fs deciders"
need debugfs "foreign ext2 oracle (e2fsprogs), validates the ext2 images"
need sha256sum "the corpus provenance anchor"

rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
MANIFEST="$OUTDIR/manifest.tsv"
: > "$MANIFEST"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# payload_for <edge> — a DISTINCT payload per edge, so reading image B and getting
# image A's file (a mount/probe mixup) fails the byte-compare. The edge name is in
# the bytes; padding makes the files a non-trivial length.
payload_for() {
    local edge="$1"
    printf 'grub2fs fs-corpus edge=%s :: this is the payload the firmware must read back byte-for-byte.\n' "$edge"
    printf 'lorem ipsum %s dolor sit amet, the quick brown fox jumps over the lazy dog. 0123456789\n' "$edge"
}

emit_row() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$MANIFEST"; }
skip_edge() { echo "  - SKIP edge $2 ($1): $3"; emit_row "$1" "$2" "-" "-" "-" "SKIP:$3"; }

# ── ext2: classic (both readers) vs modern (grub2fs only — the decider) ──
build_ext2() {
    local edge="$1"; shift
    local img="$OUTDIR/$edge.img" exp="$OUTDIR/$edge.expected"
    local content="$WORK/$edge"; mkdir -p "$content"
    payload_for "$edge" > "$content/HELLO"; cp "$content/HELLO" "$exp"
    # -U/-E hash_seed + SOURCE_DATE_EPOCH pin the UUID, htree seed and times.
    mke2fs -q -F -t ext2 "$@" -U "00000000-0000-0000-0000-0000000000${FIXED_UUID_LSB}" \
        -E "hash_seed=$FIXED_HASH_SEED" -d "$content" "$img" 2048 >/dev/null 2>&1 \
        || { echo "build-fs-corpus: mke2fs failed for $edge" >&2; exit 2; }
    # FOREIGN validation: debugfs (e2fsprogs) reads /HELLO back == the payload.
    debugfs -R "cat /HELLO" "$img" 2>/dev/null > "$WORK/$edge.dbg" || { echo "build-fs-corpus: debugfs could not read /HELLO from $edge" >&2; exit 2; }
    cmp -s "$WORK/$edge.dbg" "$exp" || { echo "build-fs-corpus: debugfs readback of $edge != payload (malformed image)" >&2; exit 2; }
    echo "  - ext2 edge $edge: built + debugfs-validated ($(wc -c <"$exp") B /HELLO)"
}
echo "== ext2 =="
FIXED_UUID_LSB=01 build_ext2 ext2-classic -b 1024 -I 128 -O ^resize_inode,^dir_index,^ext_attr,^filetype
emit_row ext2 ext2-classic "ext2-classic.img" "/HELLO" "debugfs" "classic layout: 128B inodes, no dir_index/filetype — 0.97 grubfs reads this"
FIXED_UUID_LSB=02 build_ext2 ext2-modern  -b 1024 -I 256 -O dir_index,filetype
emit_row ext2 ext2-modern "ext2-modern.img" "/HELLO" "debugfs" "modern layout: 256B inodes, dir_index/filetype — 0.97 grubfs returns File not found (POC-2); the decider"

# ── FAT: grubfs FAT is NOT compiled in this repo's amd64 config, so only grub2fs
#    reads these here; kept because grub2fs eligibility across FAT12/16/32 + a VFAT
#    long name is real, and a future grubfs-with-FAT firmware makes it an overlap. ──
echo "== FAT =="
if have mkfs.vfat && have mcopy; then
    build_fat() {
        local edge="$1" fatbits="$2" payname="$3" sizeMB="$4"
        local img="$OUTDIR/$edge.img" exp="$OUTDIR/$edge.expected"
        payload_for "$edge" > "$exp"
        truncate -s "${sizeMB}M" "$img"
        # --invariant + -i pin the volume id and creation times (byte-stable).
        mkfs.vfat -F "$fatbits" --invariant -i "deadbe$fatbits" -n G2FS "$img" >/dev/null 2>&1 \
            || { echo "build-fs-corpus: mkfs.vfat -F $fatbits failed for $edge" >&2; exit 2; }
        mcopy -i "$img" "$exp" "::/$payname" 2>/dev/null || { echo "build-fs-corpus: mcopy failed for $edge" >&2; exit 2; }
        # FOREIGN validation: mcopy (mtools) reads it back.
        mcopy -i "$img" "::/$payname" "$WORK/$edge.mc" 2>/dev/null || { echo "build-fs-corpus: mcopy readback failed for $edge" >&2; exit 2; }
        cmp -s "$WORK/$edge.mc" "$exp" || { echo "build-fs-corpus: mcopy readback of $edge != payload" >&2; exit 2; }
        echo "  - FAT edge $edge (FAT$fatbits, /$payname): built + mcopy-validated"
        emit_row fat "$edge" "$edge.img" "/$payname" "mcopy" "FAT$fatbits${5:+, $5}"
    }
    # FAT16 needs its cluster count in 4085..65524; 16 MB is the smallest that
    # lands there with mkfs.fat's default cluster size (8 MB is "too small").
    build_fat fat16 16 HELLO 16
    build_fat fat32 32 HELLO 64
    # VFAT long name: an 8.3-incompatible name exercises the LFN directory entries.
    build_fat fat-vfat-long 16 "a-long-vfat-filename.txt" 16 "VFAT long name (LFN entries)"
else
    for e in fat16 fat32 fat-vfat-long; do skip_edge fat "$e" "mkfs.vfat/mcopy (mtools) not installed"; done
fi

# ── ISO 9660: plain (uppercased 8.3 + ;1) and Rock Ridge (long mixed-case names).
#    Both grubfs (fsys_iso9660) and grub2fs read ISO — the genuine two-reader overlap. ──
echo "== ISO 9660 =="
# Prefer xorriso: it honors SOURCE_DATE_EPOCH (byte-reproducible, verified);
# genisoimage is the fallback and may not, so its ISO images can vary run-to-run.
ISOTOOL=""; have genisoimage && ISOTOOL="genisoimage"; have xorriso && ISOTOOL="xorriso -as mkisofs"
if [[ -n "$ISOTOOL" ]] && have isoinfo; then
    build_iso() {
        local edge="$1" payname="$2" rr="$3" ondisk="$4"
        local img="$OUTDIR/$edge.img" exp="$OUTDIR/$edge.expected" root="$WORK/$edge-root"
        mkdir -p "$root"; payload_for "$edge" > "$exp"; cp "$exp" "$root/$payname"
        # shellcheck disable=SC2086  # ISOTOOL intentionally splits into program+args
        $ISOTOOL $rr -quiet -o "$img" "$root" 2>/dev/null || { echo "build-fs-corpus: $ISOTOOL failed for $edge" >&2; exit 2; }
        # FOREIGN validation: isoinfo (cdrkit) extracts the on-disk name.
        local flag=""; [[ "$rr" == *-r* ]] && flag="-R"
        isoinfo $flag -i "$img" -x "$ondisk" 2>/dev/null > "$WORK/$edge.iso" || { echo "build-fs-corpus: isoinfo could not extract $ondisk from $edge" >&2; exit 2; }
        cmp -s "$WORK/$edge.iso" "$exp" || { echo "build-fs-corpus: isoinfo readback of $edge != payload" >&2; exit 2; }
        echo "  - ISO edge $edge (on-disk '$ondisk'): built + isoinfo-validated"
        emit_row iso "$edge" "$edge.img" "$payname" "isoinfo" "${5:-}"
    }
    # plain: 8.3 uppercase; ISO9660 stores HELLO.;1 (the version suffix grubfs strips).
    build_iso iso-plain HELLO "" "/HELLO.;1" "plain ISO9660: uppercased 8.3 + ;1 version suffix"
    # Rock Ridge: long lower-case name preserved.
    build_iso iso-rockridge hello-rock-ridge.txt "-r" "/hello-rock-ridge.txt" "Rock Ridge: long mixed-case name"
else
    for e in iso-plain iso-rockridge; do skip_edge iso "$e" "xorriso/genisoimage or isoinfo not installed"; done
fi

# ── the provenance anchor: sha256 over the corpus DEFINITION, not the image bytes ──
# The tier verdicts depend on WHICH edges exist, their formats, their payloads and
# their paths, and the build recipe — never on a superblock's mkfs timestamp or a
# random UUID. This mke2fs does not honor SOURCE_DATE_EPOCH for the -d inode times,
# so the raw ext2 image bytes are not byte-stable across a second boundary; hashing
# them would bind the toml to ambient clock noise and make every fresh build look
# "stale". So the anchor is bound to the corpus's IDENTITY: the manifest (edges,
# formats, paths, oracles) + every .expected payload + this builder script itself.
# It moves iff something a tier verdict could depend on changed; the live track
# re-reads the images every run, so a reader's behaviour change is caught there.
{
    echo "# fs-corpus provenance anchor — sha256 over the corpus DEFINITION"
    echo "# (manifest + .expected payloads + the builder recipe); NOT the image bytes."
    # Basenames only (no absolute paths) so the anchor is machine-independent.
    ( cd "$OUTDIR" && LC_ALL=C ls manifest.tsv ./*.expected | sed 's#^\./##' | xargs sha256sum )
    printf '%s  build-fs-corpus.sh\n' "$(sha256sum <"$HERE/build-fs-corpus.sh" | cut -d' ' -f1)"
} > "$OUTDIR/corpus.sha256"
CORPUS_SHA="$(sha256sum <"$OUTDIR/corpus.sha256" | cut -d' ' -f1)"

built=$(grep -cvE '\tSKIP:' "$MANIFEST" || true)
skipped=$(grep -cE '\tSKIP:' "$MANIFEST" || true)
echo
echo "build-fs-corpus: OK — $built edges built, $skipped skipped (named in manifest.tsv)."
echo "build-fs-corpus: corpus anchor sha256(corpus.sha256) = $CORPUS_SHA"
echo "build-fs-corpus: manifest + images under $OUTDIR"
