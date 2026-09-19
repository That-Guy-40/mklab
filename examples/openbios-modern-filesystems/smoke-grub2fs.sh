#!/usr/bin/env bash
# smoke-grub2fs.sh — one-verdict proof of S1 (POC-1b + POC-2): the grub2fs read
# shim reads a MODERN ext2 filesystem that the vendored GRUB 0.97 `grubfs` CANNOT,
# byte-for-byte equal to `grub-fstest` (GRUB's own shim, the foreign oracle).
#
# THE NEGATIVE CONTROL IS THE POINT: the same modern image reads "File not found"
# through the stock grubfs-only firmware — but that firmware DOES read a classic
# image (so it is not merely broken). grub2fs reads the modern one. If grubfs could
# read the modern image, the shim would prove nothing, so that case FAILS the test.
#
# Firmwares:
#   grub2fs   $WORKDIR/grub2fs/openbios-unix     (built by build-grub2fs.sh)
#   grubfs    $WORKDIR/openbios/obj-amd64/openbios-unix  (the rival lab's stock,
#             grubfs-only — the negative control)
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR.
set -u
usage() {
    cat <<'USAGE'
smoke-grub2fs.sh   S1 POC-1b+POC-2: grub2fs reads a modern ext2 image grubfs can't

Builds a modern ext2 image (inode size 256, dir_index/filetype — the features the
0.97 grubfs chokes on) and a classic one, each holding /HELLO, then:
  POSITIVE  the grub2fs firmware mounts the MODERN image and loads /HELLO; the bytes
            equal `grub-fstest <img> cp /HELLO -` (the foreign oracle).
  CONTROL   the stock grubfs-only firmware returns "File not found" on the MODERN
            image, but reads the CLASSIC one == its own grub-fstest oracle. The
            control must BITE (grubfs fails modern), else the test proves nothing.

Runs build-grub2fs.sh if the grub2fs firmware is absent. SKIPs by name without
podman / grub-fstest / mke2fs / the stock firmware.
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
# shellcheck disable=SC2154  # rc IS set by rc=$? at the top of this same trap body
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-grub2fs.sh exited early (rc=$rc)"' EXIT

# ── guards (SKIP by name) ─────────────────────────────────────────────────────
command -v podman     >/dev/null || skip "podman not installed (grub2fs firmware is built in a container)"
command -v grub-fstest >/dev/null || skip "grub-fstest not installed (the foreign oracle — GRUB's own shim)"
command -v mke2fs     >/dev/null || skip "mke2fs not installed (needed to author the ext2 images)"
command -v python3    >/dev/null || skip "python3 not installed"
GF="$TREE/obj-amd64/openbios-unix"; GFD="$TREE/obj-amd64/openbios-unix.dict"
[[ -f "$GF" && -f "$GFD" ]] || skip "no stock grubfs firmware at $GF — run openbios-the-rival-that-shipped/build-openbios.sh unix first (it is the negative control)"

# ── ensure the grub2fs firmware exists (build it if not) ──────────────────────
G2="$WORKDIR/grub2fs/openbios-unix"; G2D="$WORKDIR/grub2fs/openbios-unix.dict"
if [[ ! -f "$G2" || ! -f "$G2D" ]]; then
    note "grub2fs firmware absent — building it (build-grub2fs.sh)"
    [[ -x "$HERE/build-grub2fs.sh" ]] || fail "build-grub2fs.sh missing/not executable"
    if ( OPENBIOS_WORKDIR="$WORKDIR" "$HERE/build-grub2fs.sh" >/dev/null 2>&1 ); then :; else
        skip "build-grub2fs.sh could not build the grub2fs firmware (no tree/toolchain?) — run it directly to see why"
    fi
fi
[[ -f "$G2" && -f "$G2D" ]] || fail "grub2fs firmware still absent after build-grub2fs.sh"

WD="$(mktemp -d)"
mkdir -p "$WD/content"
printf 'grub2fs reads a modern ext2 filesystem: hello from the S1 smoke.\n' > "$WD/content/HELLO"

# ── author a MODERN and a CLASSIC ext2 image, each holding /HELLO ─────────────
# modern: 256-byte inodes + dir_index + filetype — the features 0.97 grubfs chokes on.
mke2fs -q -F -t ext2 -b 1024 -I 256 -O dir_index,filetype -d "$WD/content" "$WD/modern.ext2" 2048 >/dev/null 2>&1 \
    || fail "mke2fs could not create the modern ext2 image"
# classic: 128-byte inodes, none of the modern features — what 0.97 grubfs reads.
mke2fs -q -F -t ext2 -b 1024 -I 128 -O ^resize_inode,^dir_index,^ext_attr,^filetype -d "$WD/content" "$WD/classic.ext2" 1024 >/dev/null 2>&1 \
    || fail "mke2fs could not create the classic ext2 image"

# ── foreign oracle: GRUB's own shim reads /HELLO from each image ──────────────
grub-fstest "$WD/modern.ext2"  cp /HELLO "$WD/oracle-modern.bin"  2>/dev/null || fail "grub-fstest could not read /HELLO from the modern image (oracle failed)"
grub-fstest "$WD/classic.ext2" cp /HELLO "$WD/oracle-classic.bin" 2>/dev/null || fail "grub-fstest could not read /HELLO from the classic image (oracle failed)"

# drive_load <fw> <dict> <img> <outname> — mount <img> via the firmware, load /HELLO
# to an alloc-mem load-base buffer (the hosted-firmware load-base gotcha: the default
# load-base is unmapped and a real read there segfaults), write it out, echo the log.
drive_load() {
    local fw="$1" dict="$2" img="$3" out="$4"
    rm -f "$WD/$out"
    ( cd "$WD" && printf '%s\n' \
        '100000 alloc-mem value bb  bb (u.) s" load-base" $setenv' \
        'load hd:\HELLO' \
        "load-base load-size s\" $out\" write-file" \
        'bye' | "$fw" -f "$img" "$dict" 2>&1 | tr -d '\r' )
}

# ── POSITIVE: grub2fs reads the MODERN image, bytes == grub-fstest oracle ─────
note "POSITIVE: grub2fs firmware mounts the modern ext2 image and loads /HELLO"
drive_load "$G2" "$G2D" "$WD/modern.ext2" pos.bin > "$WD/pos.log" 2>&1
[[ -s "$WD/pos.bin" ]] || fail "grub2fs produced no bytes loading /HELLO from the modern image — $(grep -aoE 'File not found|panic[^ ]*|violation' "$WD/pos.log" | head -1) — see the run log"
cmp -s "$WD/pos.bin" "$WD/oracle-modern.bin" \
    || fail "grub2fs read /HELLO but the bytes differ from grub-fstest ($(wc -c <"$WD/pos.bin") vs $(wc -c <"$WD/oracle-modern.bin") bytes) — the shim read the wrong data"
note "grub2fs read /HELLO from the modern image, $(wc -c <"$WD/pos.bin") bytes, byte-equal to grub-fstest"

# ── NEGATIVE CONTROL part A: grubfs CANNOT read the modern image ──────────────
note "CONTROL A: the stock grubfs firmware on the SAME modern image -> expect File not found"
drive_load "$GF" "$GFD" "$WD/modern.ext2" nc-modern.bin > "$WD/ncm.log" 2>&1
if [[ -s "$WD/nc-modern.bin" ]] && cmp -s "$WD/nc-modern.bin" "$WD/oracle-modern.bin"; then
    fail "the stock grubfs firmware READ /HELLO from the modern image — 0.97 is not failing, so the control is void and the shim proves nothing"
fi
grep -qaF 'File not found' "$WD/ncm.log" \
    || fail "grubfs neither read the modern file nor printed 'File not found' — the control did not bite as expected — see the run log"
note "grubfs on the modern image: File not found (0.97 cannot read its dir_index/256-byte-inode directory)"

# ── NEGATIVE CONTROL part B: grubfs DOES read the classic image (not just broken) ──
note "CONTROL B: the stock grubfs firmware reads the CLASSIC image == its grub-fstest oracle"
drive_load "$GF" "$GFD" "$WD/classic.ext2" nc-classic.bin > "$WD/ncc.log" 2>&1
[[ -s "$WD/nc-classic.bin" ]] || fail "grubfs produced no bytes on the classic image — it appears broken, so 'File not found' on modern would not be meaningful — see the run log"
cmp -s "$WD/nc-classic.bin" "$WD/oracle-classic.bin" \
    || fail "grubfs read the classic image but the bytes differ from grub-fstest — the control firmware is misbehaving"
note "grubfs read /HELLO from the classic image, byte-equal to grub-fstest — it works, just not on modern ext2"

pass "grub2fs (GRUB 2's ext2 driver behind an OpenBIOS package) read /HELLO from a MODERN ext2 image (inode size 256, dir_index/filetype) byte-for-byte equal to grub-fstest, which the shipped 0.97 grubfs could not (File not found) though it read a classic image — the read shim reads a modern block filesystem the frozen firmware cannot (S1 POC-1b build + POC-2 read, verified against a foreign oracle with the negative control biting)"
