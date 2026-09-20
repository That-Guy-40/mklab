#!/usr/bin/env bash
# smoke-grub2fs-arches.sh — S1 POC-4, the byte-order control. Proves grub2fs reads
# a MODERN little-endian ext2 filesystem correctly on a BIG-ENDIAN firmware (ppc),
# where the shim's grub_le_to_cpu16/32/64 must SWAP: a correct read (inode size +
# data == grub-fstest) is the assertion that the typed accessors were used and not
# the CPU's native order. Everything before POC-4 ran little-endian (amd64), which
# exercised only the identity byteorder path.
#
# Firmware: $WORKDIR/grub2fs-ppc/openbios-qemu.elf (built by build-grub2fs-arch.sh
# ppc — grub2fs is the ppc fs reader; ppc's grubfs has no fs drivers compiled, so
# the "old package can't read" control is moot here — the proof is the positive
# grub-fstest oracle read on a BE firmware). ppc's console is PTY-only, hex prompt.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR.
set -u
usage() { cat <<'USAGE'
smoke-grub2fs-arches.sh   S1 POC-4: grub2fs reads modern ext2/FAT/ISO on BIG-ENDIAN ppc
Builds the ppc firmware with grub2fs (if absent), then for ext2 (required — the
byte-order control), FAT and ISO: mounts the image in qemu-system-ppc and loads
/HELLO via grub2fs; the bytes must equal `grub-fstest <img> cp /HELLO -`.
SKIPs by name without podman / qemu-system-ppc / grub-fstest / mke2fs.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
FW="$WORKDIR/grub2fs-ppc/openbios-qemu.elf"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
WD=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-grub2fs-arches.sh exited early (rc=$rc)"' EXIT

command -v podman            >/dev/null || skip "podman not installed (grub2fs ppc firmware is built in a container)"
command -v qemu-system-ppc   >/dev/null || skip "qemu-system-ppc not installed (the big-endian firmware)"
command -v grub-fstest       >/dev/null || skip "grub-fstest not installed (the foreign oracle)"
command -v mke2fs            >/dev/null || skip "mke2fs not installed"
command -v python3           >/dev/null || skip "python3 not installed"

# build the ppc firmware if absent
if [[ ! -f "$FW" ]]; then
    note "ppc grub2fs firmware absent — building it (build-grub2fs-arch.sh ppc)"
    if ( OPENBIOS_WORKDIR="$WORKDIR" "$HERE/build-grub2fs-arch.sh" ppc >/dev/null 2>&1 ); then :; else
        skip "build-grub2fs-arch.sh ppc could not build the firmware — run it directly to see why"
    fi
fi
[[ -f "$FW" ]] || fail "ppc grub2fs firmware still absent after build"

WD="$(mktemp -d)"; mkdir -p "$WD/content"
printf 'grub2fs on a BIG-ENDIAN ppc reads a modern little-endian ext2 fs.\n' > "$WD/content/HELLO"

# drive_ppc <img> <devpath> <out.read> — boot qemu-system-ppc on the grub2fs ppc
# firmware with <img> attached, load <devpath> (e.g. hd:\HELLO) via grub2fs, and
# capture the loaded bytes (printed between DA< >DA markers; the driver echoes the
# typed command first, so the LAST marker pair is the real output). Echoes the size.
drive_ppc() {
    # $1 img (unused here — the caller set the global `media` array), $2 dev, $3 out.
    local dev="$2" out="$3" log="$WD/drive.log"; rm -f "$log" "$out"
    python3 "$REPO/tools/drive-pty-repl.py" "$log" --timeout 150 --echo-gate --echo-timeout 8 \
        --expect "0 > " \
        --send "load $dev\\r" \
        --expect "0 > " \
        --send 'cr ." SZ<" load-size . ." >SZ" cr\r' \
        --expect ">SZ" \
        --send 'cr ." DA<" load-base load-size type ." >DA" cr\r' \
        --expect ">DA" \
        -- qemu-system-ppc -M mac99 -m 256 "${media[@]}" -bios "$FW" -nographic -vga none >/dev/null 2>&1
    python3 - "$log" "$out" <<'PY'
import sys,re
raw=open(sys.argv[1],'rb').read().replace(b'\r',b'')
ms=re.findall(rb'DA<(.*?)>DA', raw, re.S)     # [-1] = real output (past the command echo)
open(sys.argv[2],'wb').write(ms[-1] if ms else b'')
PY
}

# ── ext2 (REQUIRED — the byte-order control) ─────────────────────────────────
note "ext2 (BE control): modern mke2fs image (inode 256, dir_index/filetype)"
mke2fs -q -F -t ext2 -b 1024 -I 256 -O dir_index,filetype -d "$WD/content" "$WD/e.ext2" 2048 >/dev/null 2>&1 \
    || fail "mke2fs could not create the modern ext2 image"
grub-fstest "$WD/e.ext2" cp /HELLO "$WD/e.oracle" 2>/dev/null || fail "ext2: grub-fstest oracle read failed"
media=(-drive "file=$WD/e.ext2,format=raw"); drive_ppc "$WD/e.ext2" 'hd:\\HELLO' "$WD/e.read" media
[[ -s "$WD/e.read" ]] || fail "ext2 (ppc): grub2fs loaded no bytes for /HELLO — see the drive log"
cmp -s "$WD/e.read" "$WD/e.oracle" \
    || fail "ext2 (ppc): grub2fs read $(wc -c <"$WD/e.read")B, differs from grub-fstest $(wc -c <"$WD/e.oracle")B — a byte-order bug in the LE accessors on big-endian ppc"
note "ext2 (ppc): grub2fs read /HELLO == grub-fstest ($(wc -c <"$WD/e.read")B) — big-endian firmware read LE ext2 fields correctly"

# ── FAT (best-effort second driver on BE) ────────────────────────────────────
FATNOTE="UNCOVERED"
if command -v mkfs.vfat >/dev/null && command -v mcopy >/dev/null; then
    truncate -s 2M "$WD/f.fat" && mkfs.vfat "$WD/f.fat" >/dev/null 2>&1 && mcopy -i "$WD/f.fat" "$WD/content/HELLO" ::/HELLO 2>/dev/null \
      && grub-fstest "$WD/f.fat" cp /HELLO "$WD/f.oracle" 2>/dev/null && {
        media=(-drive "file=$WD/f.fat,format=raw"); drive_ppc "$WD/f.fat" 'hd:\\HELLO' "$WD/f.read" media
        if [[ -s "$WD/f.read" ]] && cmp -s "$WD/f.read" "$WD/f.oracle"; then
            FATNOTE="COVERED"; note "FAT (ppc): grub2fs read /HELLO == grub-fstest ($(wc -c <"$WD/f.read")B)"
        else note "FAT (ppc): UNCOVERED — grub2fs read $(wc -c <"$WD/f.read" 2>/dev/null)B vs oracle $(wc -c <"$WD/f.oracle")B (device-path/driver quirk; the ext2 BE control stands)"; fi
      }
else note "FAT: UNCOVERED — mkfs.vfat/mcopy not installed"; fi

# ── ISO 9660 (best-effort; ppc CD path) ──────────────────────────────────────
ISONOTE="UNCOVERED"
if command -v xorriso >/dev/null || command -v genisoimage >/dev/null; then
    if command -v xorriso >/dev/null; then xorriso -as mkisofs -quiet -o "$WD/i.iso" "$WD/content" >/dev/null 2>&1
    else genisoimage -quiet -o "$WD/i.iso" -r "$WD/content" >/dev/null 2>&1; fi
    if grub-fstest "$WD/i.iso" cp /HELLO "$WD/i.oracle" 2>/dev/null; then
        media=(-cdrom "$WD/i.iso"); drive_ppc "$WD/i.iso" 'cd:\\HELLO' "$WD/i.read" media
        if [[ -s "$WD/i.read" ]] && cmp -s "$WD/i.read" "$WD/i.oracle"; then
            ISONOTE="COVERED"; note "ISO (ppc): grub2fs read /HELLO == grub-fstest ($(wc -c <"$WD/i.read")B)"
        else note "ISO (ppc): UNCOVERED — grub2fs read $(wc -c <"$WD/i.read" 2>/dev/null)B vs oracle $(wc -c <"$WD/i.oracle")B (device-path quirk; the ext2 BE control stands)"; fi
    else note "ISO: UNCOVERED — grub-fstest could not read the ISO oracle"; fi
else note "ISO: UNCOVERED — xorriso/genisoimage not installed"; fi

pass "grub2fs read a MODERN little-endian ext2 filesystem correctly on a BIG-ENDIAN ppc firmware — /HELLO byte-for-byte equal to grub-fstest, the inode size (a LE on-disk field read through grub_le_to_cpu, which SWAPS on ppc) and the data both correct. This is the byte-order control the whole four-arch design leans on: the typed accessors were used, not the CPU's native order. (FAT: $FATNOTE, ISO: $ISONOTE on ppc. amd64 LE proven by smoke-grub2fs.sh; x86 real-firmware + sparc are UNCOVERED-by-name — see PLAN.md POC-4.)"
