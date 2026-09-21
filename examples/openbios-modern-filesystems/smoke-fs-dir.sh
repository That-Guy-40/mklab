#!/usr/bin/env bash
# smoke-fs-dir.sh — S1's literal milestone (design notes §4, step S1): `dir hd:\`
# through grub2fs LISTS a modern `mke2fs` ext2 directory, and the same path through
# the shipped 0.97 grubfs cannot (grubfs's dir is a stub AND it can't even mount a
# modern-ext2 directory) — so the modern reader lists directories the frozen firmware
# cannot. Graded against `debugfs -R ls` (the foreign oracle).
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR.
set -u
usage() { cat <<'USAGE'
smoke-fs-dir.sh   S1: grub2fs `dir hd:\` lists a modern ext2 dir; grubfs cannot.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
TREE="$WORKDIR/openbios"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-fs-dir.sh exited early (rc=$rc)"' EXIT

command -v podman  >/dev/null || skip "podman not installed (the grub2fs firmware is built in a container)"
command -v mke2fs  >/dev/null || skip "mke2fs not installed"
command -v debugfs >/dev/null || skip "debugfs not installed (the foreign oracle)"

G2="$WORKDIR/grub2fs-only/openbios-unix"; G2D="$WORKDIR/grub2fs-only/openbios-unix.dict"
if [[ ! -f "$G2" || ! -f "$G2D" ]]; then
    note "grub2fs-only firmware absent — building it"
    ( OPENBIOS_WORKDIR="$WORKDIR" GRUB2FS_ONLY=1 "$HERE/build-grub2fs.sh" >/dev/null 2>&1 ) \
        || skip "could not build the grub2fs-only firmware — run GRUB2FS_ONLY=1 build-grub2fs.sh"
fi
[[ -f "$G2" && -f "$G2D" ]] || fail "grub2fs-only firmware still absent after build"
GF="$TREE/obj-amd64/openbios-unix"; GFD="$TREE/obj-amd64/openbios-unix.dict"

WD="$(mktemp -d)"; mkdir -p "$WD/c/subdir"
printf 'hi\n' > "$WD/c/HELLO"; printf 'w\n' > "$WD/c/WORLD.TXT"; printf 'x\n' > "$WD/c/subdir/inner"
# modern ext2 (256B inodes + dir_index) — the layout 0.97 grubfs chokes on
SOURCE_DATE_EPOCH=0 mke2fs -q -F -t ext2 -b 1024 -I 256 -O dir_index,filetype -d "$WD/c" "$WD/w.ext2" 8192 >/dev/null 2>&1 \
    || fail "mke2fs could not author the modern ext2 image"

# the foreign oracle: the entries debugfs reports in / (minus . / ..)
mapfile -t ORACLE < <(debugfs -R 'ls -l /' "$WD/w.ext2" 2>/dev/null | awk '{print $NF}' | grep -vE '^\.\.?$|^$|^[0-9]+$')
[[ ${#ORACLE[@]} -ge 3 ]] || fail "debugfs oracle found ${#ORACLE[@]} entries (expected >=3: lost+found HELLO WORLD.TXT subdir)"

drive_dir() { ( printf '%s\n' 'dir hd:\' 'bye' | "$1" -f "$WD/w.ext2" "$2" 2>&1 | tr -d '\r' ); }

# ── POSITIVE: grub2fs lists every oracle entry, and no Stack Underflow/panic ──
echo "== grub2fs: dir hd:\\ lists the modern ext2 root =="
drive_dir "$G2" "$G2D" > "$WD/g2.log" 2>&1
grep -qaE 'Underflow|panic|violation' "$WD/g2.log" && fail "grub2fs dir hd:\\ faulted — $(grep -aoE 'Underflow|panic[^ ]*|violation' "$WD/g2.log" | head -1) — see log"
missing=""
for e in "${ORACLE[@]}"; do grep -qaF "$e" "$WD/g2.log" || missing="$missing $e"; done
[[ -z "$missing" ]] || fail "grub2fs dir omitted entries the oracle lists:$missing"
# subdirectories are marked with a trailing backslash
grep -qaE 'subdir\\|lost\+found\\' "$WD/g2.log" || fail "grub2fs dir did not mark subdirectories with a trailing backslash"
note "grub2fs listed all ${#ORACLE[@]} oracle entries (${ORACLE[*]}), dirs marked with a trailing backslash"

# ── CONTROL: stock grubfs (0.97) cannot list the modern ext2 directory ────────
if [[ -f "$GF" && -f "$GFD" ]]; then
    drive_dir "$GF" "$GFD" > "$WD/gf.log" 2>&1
    listed_all=1
    for e in "${ORACLE[@]}"; do grep -qaF "$e" "$WD/gf.log" || listed_all=0; done
    [[ "$listed_all" -eq 0 ]] || fail "the stock grubfs firmware LISTED the modern ext2 directory — the control is void, grub2fs's dir proves nothing"
    note "control: stock grubfs cannot list the modern ext2 directory ($(grep -aoE 'File not found|not implemented|Unable to locate[^\\]*' "$WD/gf.log" | head -1))"
else
    note "control SKIPPED-by-name: no stock grubfs firmware at $GF (run openbios-the-rival build-openbios.sh unix)"
fi

pass "grub2fs \`dir hd:\\\` lists a MODERN mke2fs ext2 directory (all $((${#ORACLE[@]})) entries == debugfs, subdirectories marked) — the shipped 0.97 grubfs cannot (its dir is a stub and it cannot mount a modern-ext2 directory); S1's literal 'dir lists a modern image' milestone (design notes §4)"
