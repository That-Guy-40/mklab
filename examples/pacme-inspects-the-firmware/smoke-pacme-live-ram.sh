#!/usr/bin/env bash
# smoke-pacme-live-ram.sh — Spike 5: GNU poke reads and EDITS the firmware's LIVE
# RAM, over a bespoke gdbstub IO device. The one honest UNKNOWN the rest of the
# lab left standing.
#
# Everywhere else in this lab, poke reaches the running firmware's *block* store
# live (QMP-NBD, Spikes 1/4), but its *RAM* was only ever a SNAPSHOT — a QMP
# pmemsave / a file poke opened after the fact (design note §2b, stated, never
# dressed as live). This spike closes that gap with `pokegdb` (gdb-iod.c): libpoke
# lets an embedding program register a foreign IO device (pk_register_iod), and
# QEMU's gdbstub answers memory reads/writes for the LIVE guest. So poke's pread/
# pwrite become gdb `m`/`M` packets to a running OpenBIOS.
#
# THE GRADES (each measured, none assumed — see the README's "Spike 5" section):
#  1. LIVE READ == ORACLE. The firmware writes a run-unique nonce into a buffer it
#     allocated; we LOCATE that value in physical RAM by scanning a QMP pmemsave
#     dump (a Forth address is NOT a physical one on x86 OpenBIOS — the ofmem
#     offset is real — so we never assume, we scan). poke-over-gdbstub reads that
#     physical offset and gets the nonce, and so does the independent QMP `xp`
#     oracle: three readers — the firmware that wrote it, poke's gdbstub IOD, and
#     QEMU's monitor — agree. The IOD reads the live guest, not a file.
#  2. LIVE vs SNAPSHOT (the distinction the whole lab turns on). We snapshot the
#     region (pmemsave to a file, holding N1), the firmware OVERWRITES its buffer
#     with N2, and then the SAME poke reader reads both handles: the gdbstub IOD
#     reads N2 (LIVE — it re-read the running guest), while poke opening the
#     snapshot FILE still reads N1 (SNAPSHOT — frozen at capture). Same code, two
#     IODs; live tracks the change, the snapshot does not.
#  3. poke EDITS live RAM. poke-over-gdbstub WRITES N3 into that same physical
#     cell; QEMU's `xp` oracle confirms the live guest RAM changed, and the
#     FIRMWARE reads N3 back from its own Forth buffer (`buf l@`). poke mutated
#     memory the firmware then observed — the RAM analogue of Spike 4's edit-live.
#
# CONTROLS THAT BITE: grade 2 is itself the control for "live" being a real claim
# — if the IOD were secretly reading the snapshot, the live read would ALSO be N1
# and the grade fails (we assert live==N2 AND snap==N1 AND N1!=N2, so a vacuous
# "live" cannot pass). Plus a POSITION control: the nonce is NOT found one 64 KiB
# page past where we located it (the offset is specific, not a lucky constant).
#
# THE HONEST BOUNDARY (stated, not hidden): this works because OpenBIOS x86 runs
# with CR0.PG=0 (no paging), so a gdb linear address IS the guest-physical address
# and equals QMP `xp` — the IOD passes the poke offset to `m`/`M` verbatim and
# makes NO translation claim; on a paged guest an address would need translating.
# The gdbstub is a QEMU debug transport (`-gdb`), a lab instrument, not a firmware
# feature. x86 only; other arches not claimed. libpoke is GPLv3, host-side only.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-live-ram.sh   Spike 5: poke reads and edits the firmware's LIVE RAM

Builds `pokegdb` (a libpoke embed with a gdbstub-backed IO device), boots OpenBIOS
x86 under QEMU with a gdbstub, has the firmware write a nonce, locates it in
physical RAM, and grades: poke-over-gdbstub reads it live (== QMP oracle); a
snapshot taken before a firmware overwrite still reads the old value while the
live handle reads the new one; and poke writes a value the firmware then reads
back. Controls: a vacuous "live" cannot pass (live==N2 & snap==N1 & N1!=N2); the
nonce is not at a wrong offset. SKIPs by name without poke / cc / qemu / firmware.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
FW="$WORKDIR/openbios/obj-x86/openbios.multiboot"
DICT="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
RAM_MB=512
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
# hex-value equality (NOT string): poke's %x and Forth's u. drop leading zeros,
# while our nonces are %08x zero-padded — compare the numbers, not the spellings.
heq() { [[ "$1" =~ ^[0-9a-fA-F]+$ && "$2" =~ ^[0-9a-fA-F]+$ ]] && (( 16#$1 == 16#$2 )); }
WD=""; QPID=""
# shellcheck disable=SC2154
trap 'rc=$?; [[ -n "$QPID" ]] && kill "$QPID" 2>/dev/null; [[ -n "$QPID" ]] && wait "$QPID" 2>/dev/null; [[ -n "$WD" ]] && rm -rf "$WD"; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-live-ram.sh exited early (rc=$rc)"' EXIT

command -v poke >/dev/null || skip "GNU poke not installed — run ./deps.sh"
command -v qemu-system-x86_64 >/dev/null || skip "qemu-system-x86_64 not installed"
command -v python3 >/dev/null || skip "python3 not installed"
command -v "${CC:-cc}" >/dev/null || skip "no C compiler to build pokegdb (set CC=…, or install gcc)"
[[ -f "$FW" && -f "$DICT" ]] || skip "no OpenBIOS x86 firmware at $FW — run openbios-the-rival-that-shipped/build-openbios.sh x86 first"

# ── build pokegdb (the gdbstub IOD embed) ──────────────────────────────────
POKEGDB="$("$HERE/build-gdb-iod.sh" 2>"$HERE/.build.err")"; bc=$?
if [[ $bc -eq 77 ]]; then skip "$(sed -n 's/^SKIP: //p' "$HERE/.build.err" | head -1)"; fi
[[ $bc -eq 0 && -x "$POKEGDB" ]] || fail "could not build pokegdb — $(tail -1 "$HERE/.build.err")"
rm -f "$HERE/.build.err"
note "built $(basename "$POKEGDB") (libpoke embed, gdbstub IO device)"

WD="$(mktemp -d /tmp/pk.XXXXXX)"    # short AF_UNIX path
SER="$WD/ser"; QMP="$WD/qmp"; PORT=$(( 20000 + (RANDOM % 20000) ))
# run-unique 8-byte nonce (N1) and the overwrite value (N2), as two 32-bit words
W1=$(printf '%08x' $(( ((RANDOM<<17) ^ (RANDOM<<2) ^ $$ ^ 0xde000000) & 0xffffffff )))
W2=$(printf '%08x' $(( ((RANDOM<<15) ^ RANDOM ^ 0x00c0de00) & 0xffffffff )))
N2=$(printf '%08x' $(( ((RANDOM<<16) ^ RANDOM ^ 0xbad00000) & 0xffffffff )))
N3=$(printf '%08x' $(( ((RANDOM<<13) ^ RANDOM ^ 0xf00d0000) & 0xffffffff )))
GDB="gdb://127.0.0.1:$PORT"

# ── boot OpenBIOS x86 with a gdbstub; serial server=on (QEMU waits), QMP wait=off ──
qemu-system-x86_64 -M "pc,accel=$ACCEL" -m "$RAM_MB" -kernel "$FW" -initrd "$DICT" \
    -display none -serial "unix:$SER,server=on" \
    -qmp "unix:$QMP,server=on,wait=off" -gdb "tcp:127.0.0.1:$PORT" -no-reboot \
    >"$WD/qemu.log" 2>&1 &
QPID=$!

# ── firmware: allocate a buffer, write the nonce N1 (W1@buf, W2@buf+4), print addr ──
python3 "$REPO/tools/drive-serial-repl.py" "$SER" "$WD/drive1.log" --timeout 120 \
    --expect "0 > " \
    --send "h# 10 alloc-mem value buf\r" --expect "0 > " \
    --send "h# $W1 buf l!\r" --expect "0 > " \
    --send "h# $W2 buf 4 + l!\r" --expect "0 > " \
    --send "buf u.\r" --expect "0 > " >/dev/null 2>&1
drc=$?
kill -0 "$QPID" 2>/dev/null || { cat "$WD/qemu.log" >&2; fail "QEMU exited during bring-up — see above"; }
[[ $drc -eq 0 ]] || { cat "$WD/drive1.log" >&2; fail "could not drive the firmware to write the nonce (rc=$drc)"; }
FADDR=$(grep -aoE 'buf u\. [0-9a-f]+' <(tr -d '\r' <"$WD/drive1.log") | head -1 | awk '{print $NF}')
[[ -n "$FADDR" ]] || fail "the firmware did not print the buffer's Forth address"
note "firmware wrote nonce N1=$W1$W2 into its buffer at Forth address 0x$FADDR"

# ── locate N1 in PHYSICAL RAM (pmemsave + scan); capture the SNAPSHOT at the same time ──
loc() {  # <dumpfile> -> prints "OFF" (decimal) of the LE nonce, or empty
    python3 - "$QMP" "$1" "$RAM_MB" "$W1" "$W2" <<'PY'
import socket,json,time,sys,struct
qmp,dump,mb,w1,w2=sys.argv[1:6]
s=socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(qmp); s.recv(65536)
def c(o):
    s.sendall((json.dumps(o)+"\n").encode()); time.sleep(0.2); return json.loads(s.recv(1<<16).decode().splitlines()[0])
c({"execute":"qmp_capabilities"})
r=c({"execute":"pmemsave","arguments":{"val":0,"size":int(mb)*1024*1024,"filename":dump}})
if "error" in r: sys.exit(0)
pat=struct.pack("<II",int(w1,16),int(w2,16))   # little-endian, as Forth l! stores
data=open(dump,"rb").read()
i=data.find(pat)
if i>=0 and data.find(pat,i+1)==-1:            # require a UNIQUE match
    print(i)
PY
}
PHYS=$(loc "$WD/snap1.bin")
[[ -n "$PHYS" ]] || fail "could not uniquely locate the firmware's nonce in a ${RAM_MB}MiB physical RAM dump"
note "located N1 at physical offset 0x$(printf '%x' "$PHYS") (Forth 0x$FADDR != physical — ofmem translation is real)"

# ═══ GRADE 1: poke-over-gdbstub reads it LIVE, and agrees with the QMP oracle ═══
rd_gdb() {  # <phys-offset> -> prints the 32-bit word (hex, LE) poke reads live
    "$POKEGDB" "$GDB" 'var _e = set_endian(ENDIAN_LITTLE);' \
        "printf(\"%u32x\", uint<32> @ ${1}#B);" 2>/dev/null
}
rd_qmp() {  # <phys-offset> -> prints the 32-bit word (hex) the QMP xp oracle reads
    python3 - "$QMP" "$1" <<'PY'
import socket,json,time,sys
s=socket.socket(socket.AF_UNIX); s.settimeout(15); s.connect(sys.argv[1]); s.recv(65536)
def c(o):
    s.sendall((json.dumps(o)+"\n").encode()); time.sleep(0.15); return json.loads(s.recv(1<<16).decode().splitlines()[0])
c({"execute":"qmp_capabilities"})
r=c({"execute":"human-monitor-command","arguments":{"command-line":"xp /1xw %d"%int(sys.argv[2])}})["return"]
print(r.split(":")[-1].strip().replace("0x","").replace("\r",""))
PY
}
G1=$(rd_gdb "$PHYS"); Q1=$(rd_qmp "$PHYS")
heq "$G1" "$W1" \
    || fail "poke-over-gdbstub read '$G1' at the located cell, not the firmware's nonce '$W1' — the IOD is not reading the live guest"
heq "$Q1" "$W1" \
    || fail "the QMP oracle read '$Q1', not '$W1' — the located offset is wrong (test bug, not a result)"
note "grade 1: poke-over-gdbstub=$G1, QMP xp=$Q1, firmware wrote=$W1 — all three agree; the IOD reads the LIVE guest"

# POSITION control: the nonce must NOT be at a wrong offset (64 KiB further on)
GWRONG=$(rd_gdb $(( PHYS + 0x10000 )))
heq "$GWRONG" "$W1" \
    && fail "CONTROL did NOT bite: the nonce also read at offset+0x10000 — the address is not position-specific"
note "control: a read 64 KiB past the cell is '$GWRONG', not the nonce — the offset is specific"

# ═══ GRADE 2: LIVE vs SNAPSHOT — snap1.bin froze N1; now the firmware overwrites to N2 ═══
# (a reconnected serial session needs a leading CR to re-elicit the prompt — the
#  firmware printed "0 > " once, for the client that has since disconnected)
python3 "$REPO/tools/drive-serial-repl.py" "$SER" "$WD/drive2.log" --timeout 60 \
    --send "\r" --expect "0 > " \
    --send "h# $N2 buf l!\r" --expect "0 > " >/dev/null 2>&1
[[ $? -eq 0 ]] || { cat "$WD/drive2.log" >&2; fail "could not drive the firmware to overwrite the nonce"; }
LIVE=$(rd_gdb "$PHYS")        # the LIVE handle re-reads the running guest
SNAP=$(poke --quiet -c "var f=open(\"$WD/snap1.bin\");" \
    -c 'var _e = set_endian(ENDIAN_LITTLE);' \
    -c "printf(\"%u32x\", uint<32> @ ${PHYS}#B);" 2>/dev/null)   # the SNAPSHOT file is frozen
heq "$W1" "$N2" && fail "test bug: N1 and N2 collided ($W1) — rerun"
heq "$LIVE" "$N2" \
    || fail "after the firmware overwrote the cell, poke-over-gdbstub still read '$LIVE', not '$N2' — the live handle did not re-read the guest"
heq "$SNAP" "$W1" \
    || fail "the snapshot file read '$SNAP', not the captured '$W1' — a 'live' read that also changed the snapshot would make the LIVE claim vacuous (control)"
note "grade 2: firmware overwrote N1=$W1 -> N2=$N2; LIVE (gdbstub)=$LIVE sees it, SNAPSHOT (file)=$SNAP does not — same poke reader, two IODs"

# ═══ GRADE 3: poke EDITS live RAM — writes N3; QMP confirms; the FIRMWARE reads it back ═══
"$POKEGDB" "$GDB" 'var _e = set_endian(ENDIAN_LITTLE);' \
    "uint<32> @ ${PHYS}#B = 0x${N3};" 2>/dev/null \
    || fail "poke-over-gdbstub could not write to the live cell"
QN3=$(rd_qmp "$PHYS")
heq "$QN3" "$N3" \
    || fail "after poke wrote 0x$N3, the QMP oracle read '$QN3' — poke's write did not reach live guest RAM"
# the firmware reads its own buffer back over serial (forced hex) — it must see poke's edit
python3 "$REPO/tools/drive-serial-repl.py" "$SER" "$WD/drive3.log" --timeout 60 \
    --send "\r" --expect "0 > " \
    --send "hex buf l@ u.\r" --expect "0 > " >/dev/null 2>&1
FBACK=$(grep -aoE 'buf l@ u\. [0-9a-f]+' <(tr -d '\r' <"$WD/drive3.log") | head -1 | awk '{print $NF}')
heq "$FBACK" "$N3" \
    || fail "poke wrote 0x$N3 to the cell, QMP confirmed it, but the firmware read back '0x$FBACK' — the firmware did not observe poke's edit"
note "grade 3: poke wrote N3=$N3 into live RAM; QMP oracle=$QN3 and the firmware's own 'buf l@'=$FBACK both see it — poke edited RAM the firmware reads"

pass "Spike 5: GNU poke reads and EDITS the firmware's LIVE RAM over a bespoke gdbstub IO device (pokegdb). A firmware-written nonce, located in physical RAM by scanning (Forth 0x$FADDR != physical 0x$(printf '%x' "$PHYS") — ofmem translation stated), reads identically via the gdbstub IOD and the QMP oracle; a snapshot taken before a firmware overwrite stays at N1 ($W1) while the live handle re-reads N2 ($N2) with the same poke code; and poke's own write (N3=$N3) reaches live guest RAM (QMP-confirmed) and is read back by the firmware. The lab's last SNAPSHOT-only boundary (live RAM) is closed — on x86 OpenBIOS (CR0.PG=0, gdb linear==physical), via QEMU's -gdb debug transport, host-side, GPLv3-walled"
