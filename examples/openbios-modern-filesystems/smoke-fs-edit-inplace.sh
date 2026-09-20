#!/usr/bin/env bash
# smoke-fs-edit-inplace.sh — the endgame (design notes §2.6): a SAME-LENGTH in-place
# file write on a real block filesystem, from the firmware prompt, with no USB stick.
#
# grub2fs's `write-file` overwrites a file's own DATA blocks in place (the sectors
# `blocks-of` located, already allocated to the file) with exactly-its-own-length
# bytes — touching NO filesystem metadata (inode size, extent/block map, bitmaps,
# free counts). So the classic rescues fit: comment a line, flip ro->rw, MODE=die->run.
#
# THE GRADE (assert the OUTCOME): after the firmware writes, the HOST reads the file
# back with the fix, same length, and `e2fsck` reports the filesystem CLEAN — the proof
# this is not a `dd`, because the metadata was never touched. Two direct checks beyond
# fsck: the file's size is unchanged, and image-wide EXACTLY the edited bytes differ
# (a general writer would also move bitmaps/timestamps).
#
# NEGATIVE CONTROL (watched to bite): a LENGTH-CHANGING write-file is refused BY NAME
# before any sector is written — the image stays byte-identical and fsck stays clean.
# That is the boundary against §5's excluded general writer.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR.
set -u
usage() { cat <<'USAGE'
smoke-fs-edit-inplace.sh   the endgame: grub2fs edits a file IN PLACE on a real ext2
                           filesystem (same-length), fsck stays clean, host reads the fix.
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
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-fs-edit-inplace.sh exited early (rc=$rc)"' EXIT

command -v podman  >/dev/null || skip "podman not installed (the grub2fs firmware is built in a container)"
command -v mke2fs  >/dev/null || skip "mke2fs not installed"
command -v debugfs >/dev/null || skip "debugfs not installed (the foreign oracle)"
command -v e2fsck  >/dev/null || skip "e2fsck not installed (the fsck-clean grade)"

# the writable grub2fs-only firmware (O_RDWR + blk write-blocks + disk-label write relay)
G2="$WORKDIR/grub2fs-only-write/openbios-unix"; G2D="$WORKDIR/grub2fs-only-write/openbios-unix.dict"
if [[ ! -f "$G2" || ! -f "$G2D" ]]; then
    note "writable grub2fs firmware absent — building it (GRUB2FS_ONLY=1 ENDGAME_WRITE=1 build-grub2fs.sh)"
    [[ -x "$HERE/build-grub2fs.sh" ]] || fail "build-grub2fs.sh missing/not executable"
    ( OPENBIOS_WORKDIR="$WORKDIR" GRUB2FS_ONLY=1 ENDGAME_WRITE=1 "$HERE/build-grub2fs.sh" >/dev/null 2>&1 ) \
        || skip "could not build the writable firmware — run GRUB2FS_ONLY=1 ENDGAME_WRITE=1 build-grub2fs.sh to see why"
fi
[[ -f "$G2" && -f "$G2D" ]] || fail "writable grub2fs firmware still absent after build"

WD="$(mktemp -d)"

# author an ext2 image holding /CONF = "MODE=die\n" (9 bytes; die at offsets 5,6,7)
mkimg() { local out="$1"; mkdir -p "$WD/c"; printf 'MODE=die\n' > "$WD/c/CONF"
    SOURCE_DATE_EPOCH=0 mke2fs -q -F -t ext2 -b 1024 -I 256 -O dir_index,filetype -d "$WD/c" "$out" 8192 >/dev/null 2>&1 \
        || fail "mke2fs could not author $out"; }
fsck_clean() { e2fsck -fn "$1" >/dev/null 2>&1; }   # rc 0 = clean

# ── POSITIVE: firmware edits /CONF die->run in place ──────────────────────────
POS="$WD/pos.ext2"; mkimg "$POS"
fsck_clean "$POS" || fail "freshly-authored image is not fsck-clean — bad fixture"
cp "$POS" "$WD/pos.before"
echo "== POSITIVE: firmware overwrites /CONF's data in place (MODE=die -> MODE=run) =="
# load /CONF to a buffer, poke die->run (char-code, base-independent), write-file back
( printf '%s\n' \
    '100000 alloc-mem value buf' \
    '" hd:\CONF" open-dev value ih' \
    'buf " load" ih $call-method value sz' \
    'char r buf 5 + c!' 'char u buf 6 + c!' 'char n buf 7 + c!' \
    'buf sz " write-file" ih $call-method ." WF=" . cr' \
    'ih close-dev' 'bye' | "$G2" -f "$POS" "$G2D" 2>&1 | tr -d '\r' ) > "$WD/pos.log" 2>&1
wf="$(grep -aoE 'WF=-?[0-9]+' "$WD/pos.log" | head -1 | cut -d= -f2)"
[[ "$wf" == "9" ]] || fail "write-file returned '$wf' (expected 9 bytes written) — $(grep -aoE 'write-file:.*|File not found' "$WD/pos.log" | head -1) — see log"
# OUTCOME 1: the host reads the fix
got="$(debugfs -R 'cat /CONF' "$POS" 2>/dev/null)"
[[ "$got" == "MODE=run" ]] || fail "host reads '/CONF' as '$got', expected 'MODE=run' — the in-place edit did not land"
# OUTCOME 2: same length
sz_after="$(debugfs -R 'stat /CONF' "$POS" 2>/dev/null | grep -oE 'Size: [0-9]+' | head -1 | awk '{print $2}')"
[[ "$sz_after" == "9" ]] || fail "file size changed to $sz_after (expected 9) — not a same-length write"
# OUTCOME 3: fsck CLEAN (no metadata touched)
fsck_clean "$POS" || fail "e2fsck reports the filesystem DIRTY after the in-place write — metadata was disturbed (this must be clean; that is the proof it is not a dd)"
# OUTCOME 4: image-wide, EXACTLY the edited bytes differ (3: d->r,i->u,e->n) — no metadata moved
ndiff="$(cmp -l "$WD/pos.before" "$POS" 2>/dev/null | wc -l)"
[[ "$ndiff" == "3" ]] || fail "image-wide $ndiff bytes differ after the edit (expected exactly 3 = the changed characters) — something beyond the file's data changed (metadata?)"
note "firmware wrote 9B in place; host reads 'MODE=run', size 9, fsck CLEAN, and exactly 3 bytes changed across the whole image (only the edit — no metadata)"

# ── NEGATIVE CONTROL: a length-changing write-file is refused before any write ──
echo "== NEGATIVE CONTROL: a length-changing edit is refused BY NAME, image untouched =="
NEG="$WD/neg.ext2"; mkimg "$NEG"; cp "$NEG" "$WD/neg.before"
# call write-file with len = sz+1 (a grow) — must be refused; nothing written
( printf '%s\n' \
    '100000 alloc-mem value buf' \
    '" hd:\CONF" open-dev value ih' \
    'buf " load" ih $call-method value sz' \
    'buf sz 1+ " write-file" ih $call-method ." WF=" . cr' \
    'ih close-dev' 'bye' | "$G2" -f "$NEG" "$G2D" 2>&1 | tr -d '\r' ) > "$WD/neg.log" 2>&1
nwf="$(grep -aoE 'WF=-?[0-9]+' "$WD/neg.log" | head -1 | cut -d= -f2)"
[[ -n "$nwf" && "$nwf" -lt 0 ]] || fail "control VOID: a length-changing write-file returned '$nwf' (expected a negative refusal) — the same-length guard did not bite"
grep -qaE 'write-file: refusing length' "$WD/neg.log" || fail "control: write-file did not print the same-length refusal by name — see log"
# the image must be byte-identical (refused BEFORE any sector was written)
cmp -s "$WD/neg.before" "$NEG" || fail "control: the image CHANGED despite the length-changing edit being refused — a sector was written before the guard"
fsck_clean "$NEG" || fail "control: e2fsck reports DIRTY after a refused edit — the untouched image must stay clean"
note "control bites: a length-changing write-file returned $nwf and printed 'refusing length …'; the image is byte-identical and fsck CLEAN"

pass "the endgame: grub2fs edited a file IN PLACE on a real ext2 filesystem from the firmware prompt (MODE=die -> MODE=run) — same length, host reads the fix, e2fsck CLEAN, and image-wide only the 3 edited bytes changed (no metadata touched, the proof it is not a dd); the negative control (a length-changing edit refused by name, image byte-identical, fsck clean) bit (endgame E2, design notes §2.6)"
