#!/usr/bin/env bash
# smoke-fs-blocks.sh — endgame E1: grub2fs's `blocks-of` method reports the exact
# device LBAs a file's DATA occupies on the parent device (design notes §2.6, the
# read-side addition the same-length in-place write is built on).
#
# GRUB's ext2/fat/iso readers already walk the block chain to a file's data; the
# shim now fires disk->read_hook for exactly those FILE-DATA reads (fshelp.c scopes
# the hook to them), so `blocks-of` re-reads the file with a recording hook and
# learns the device segments. THE GRADE, a foreign oracle: read those raw device
# byte-ranges straight off the image on the host and confirm they RECONSTRUCT the
# file byte-for-byte — and that debugfs (e2fsprogs) independently agrees the file's
# content is what came back. If blocks-of reported a metadata block, an inode, or a
# wrong LBA, the reconstruction would differ.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR.
set -u
usage() { cat <<'USAGE'
smoke-fs-blocks.sh   endgame E1: grub2fs `blocks-of` reports a file's device data
                     LBAs; raw device bytes there reconstruct the file (foreign-graded).
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-fs-blocks.sh exited early (rc=$rc)"' EXIT

command -v podman  >/dev/null || skip "podman not installed (the grub2fs firmware is built in a container)"
command -v mke2fs  >/dev/null || skip "mke2fs not installed"
command -v debugfs >/dev/null || skip "debugfs not installed (the foreign oracle)"
command -v python3 >/dev/null || skip "python3 not installed"

# grub2fs-only firmware: grubfs not registered, so blocks-of is always available and
# the read is unambiguously grub2fs's.
G2="$WORKDIR/grub2fs-only/openbios-unix"; G2D="$WORKDIR/grub2fs-only/openbios-unix.dict"
if [[ ! -f "$G2" || ! -f "$G2D" ]]; then
    note "grub2fs-only firmware absent — building it (GRUB2FS_ONLY=1 build-grub2fs.sh)"
    [[ -x "$HERE/build-grub2fs.sh" ]] || fail "build-grub2fs.sh missing/not executable"
    ( OPENBIOS_WORKDIR="$WORKDIR" GRUB2FS_ONLY=1 "$HERE/build-grub2fs.sh" >/dev/null 2>&1 ) \
        || skip "could not build the grub2fs-only firmware — run GRUB2FS_ONLY=1 build-grub2fs.sh to see why"
fi
[[ -f "$G2" && -f "$G2D" ]] || fail "grub2fs-only firmware still absent after build"

WD="$(mktemp -d)"
IMG="$WD/blocks.ext2"; mkdir -p "$WD/c"
# a single-block file and a multi-block file, distinct content each
printf 'blocks-of E1: the small file, one data block.\n' > "$WD/c/SMALL"
python3 -c "import sys; sys.stdout.write(''.join('multi-block line %04d :: xyzzy padding\n'%i for i in range(200)))" > "$WD/c/BIG"
SOURCE_DATE_EPOCH=0 mke2fs -q -F -t ext2 -b 1024 -I 256 -O dir_index,filetype -d "$WD/c" "$IMG" 8192 >/dev/null 2>&1 \
    || fail "mke2fs could not author the ext2 image"

# blockmap <forth-path> -> prints G2BLK lines to stdout (≤80-col typed lines: the
# hosted openbios-unix input is 80-column — a longer line is truncated).
blockmap() {
    printf '%s\n' \
        "\" hd:$1\" open-dev value ih" \
        'ih if " blocks-of" ih $call-method ih close-dev then' \
        'bye' | "$G2" -f "$IMG" "$G2D" 2>&1 | tr -d '\r'
}

# grade_file <forth-path> <content-file> <label>
grade_file() {
    local fpath="$1" content="$2" label="$3"
    local log="$WD/${label}.log" segs="$WD/${label}.segs" recon="$WD/${label}.recon"
    blockmap "$fpath" > "$log" 2>&1
    grep -aoE 'off=[0-9]+ len=[0-9]+' "$log" | sed 's/off=//;s/len=//' > "$segs"
    [[ -s "$segs" ]] || fail "$label: blocks-of reported NO segments — $(grep -aoE 'G2BLK.*|File not found|UNABLE.*' "$log" | head -1) — see the drive log"
    : > "$recon"
    local off len total=0
    while read -r off len; do
        dd if="$IMG" bs=1 skip="$off" count="$len" 2>/dev/null >> "$recon"
        total=$((total + len))
    done < "$segs"
    local fsize; fsize=$(wc -c < "$content")
    # the reported segments must sum to EXACTLY the file size (no metadata, no slop)
    [[ "$total" -eq "$fsize" ]] || fail "$label: reported segments sum to ${total}B but the file is ${fsize}B — blocks-of over/under-reported the data extent"
    # the raw device bytes at those LBAs must reconstruct the file
    cmp -s "$recon" "$content" || fail "$label: raw device bytes at the reported LBAs do NOT reconstruct the file — blocks-of pointed at the wrong sectors"
    # foreign oracle: debugfs independently reads the same content back
    # (Forth path is backslash-style, e.g. \SMALL; debugfs wants /SMALL)
    local dpath="/${fpath#\\}"
    debugfs -R "cat $dpath" "$IMG" 2>/dev/null > "$WD/${label}.dbg"
    cmp -s "$WD/${label}.dbg" "$content" || fail "$label: debugfs readback != the written content (image malformed?) — the oracle is unsound"
    note "$label ($fpath): $(wc -l <"$segs") segment(s), ${total}B — raw device bytes at the reported LBAs reconstruct the file, == debugfs"
}

echo "== E1: blocks-of reports each file's device data LBAs; raw bytes there reconstruct it =="
grade_file '\SMALL' "$WD/c/SMALL" small
grade_file '\BIG'   "$WD/c/BIG"   big

# CONTROL (discrimination — blocks-of points at LIVE data, not a cache): change the
# file's bytes on disk via debugfs, and the SAME LBAs must now reconstruct the NEW
# content. If blocks-of returned a stale/hardcoded map, the reconstruction would not
# follow the change.
printf 'CONTROL: entirely different bytes written to SMALL via debugfs, same length.\n' > "$WD/newsmall"
# match the length so it stays in the same block (same-length is the endgame's rule)
oldlen=$(wc -c < "$WD/c/SMALL"); newlen=$(wc -c < "$WD/newsmall")
if [[ "$newlen" -ne "$oldlen" ]]; then
    # pad/truncate the control content to the original length
    head -c "$oldlen" <(cat "$WD/newsmall" /dev/zero) > "$WD/newsmall.fix" 2>/dev/null; mv "$WD/newsmall.fix" "$WD/newsmall"
fi
cp "$IMG" "$WD/ctl.img"
debugfs -w -R "rm /SMALL" "$WD/ctl.img" >/dev/null 2>&1
debugfs -w -R "write $WD/newsmall SMALL" "$WD/ctl.img" >/dev/null 2>&1
# re-map on the mutated image (blocks may differ after rm+write; re-read them)
IMG_SAVE="$IMG"; IMG="$WD/ctl.img"
blockmap '\SMALL' > "$WD/ctl.log" 2>&1
grep -aoE 'off=[0-9]+ len=[0-9]+' "$WD/ctl.log" | sed 's/off=//;s/len=//' > "$WD/ctl.segs"
[[ -s "$WD/ctl.segs" ]] || fail "control: blocks-of reported no segments on the mutated image"
: > "$WD/ctl.recon"; while read -r off len; do dd if="$IMG" bs=1 skip="$off" count="$len" 2>/dev/null >> "$WD/ctl.recon"; done < "$WD/ctl.segs"
if cmp -s "$WD/ctl.recon" "$WD/c/SMALL"; then
    fail "control VOID: after rewriting SMALL's bytes on disk, blocks-of's LBAs still reconstructed the OLD content — the map is stale/hardcoded, not read from the live filesystem"
fi
cmp -s "$WD/ctl.recon" "$WD/newsmall" \
    || fail "control: the mutated SMALL reconstructed from blocks-of's LBAs matched neither old nor new content — unexpected"
IMG="$IMG_SAVE"
note "control bites: after rewriting SMALL on disk, blocks-of's LBAs reconstruct the NEW bytes — the map is read from the live filesystem, not cached"

pass "grub2fs blocks-of reports a file's exact device data LBAs (single- and multi-block): the raw device bytes at those ranges reconstruct the file byte-for-byte and sum to its exact size, agreeing with debugfs (foreign oracle), and the control (rewriting the bytes on disk moves the reconstruction to the new content) bit — the read-side foundation for the same-length in-place write (endgame E1, design notes §2.6)"
