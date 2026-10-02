#!/usr/bin/env bash
# smoke-pacme-edit.sh — Spike 4 (edit live): GNU poke EDITS a value in the running
# firmware's NVRAM store over the bridge, and the firmware READS the new value on
# its next boot. The editor side of the store note's survives-and-is-observed test.
#
# Spike 0 measured that a writable NBD export of the IDE NVRAM node is REFUSED while
# the guest's ide device holds it unshared. This spike resolves the write path: the
# honest shape is to attach the node with `share-rw=on` (the device permits a second
# writer), after which the writable export is ACCEPTED — measured here, both ways.
# The edit is LIVE (poke writes the node of a RUNNING QEMU, over NBD); the firmware
# OBSERVES it on its next boot (OpenBIOS reads its NVRAM store at boot — the store's
# access model), so a fresh boot on the live-edited store reads poke's value.
#
# GRADE: boot 1 writes boot-file=<A>; poke edits <A>→<B> in the LIVE store; a fresh
# boot reads boot-file=<B> — the firmware saw exactly pacme's edit, and nothing was
# zapped (a same-length value edit keeps the OFW nvram partition valid).
# CONTROLS THAT BITE:
#   * WITHOUT share-rw the writable export is REFUSED (the Spike-0 hazard) — the write
#     path is permission-gated, not a free-for-all behind QEMU's back.
#   * an out-of-bounds poke write (past the store) is REFUSED before any byte lands —
#     refuse before the irreversible step.
#
# Exit: 0 PASS / 1 FAIL / 77 SKIP.  Env: OPENBIOS_WORKDIR (default ~/openbios-lab).
set -u
usage() {
    cat <<'USAGE'
smoke-pacme-edit.sh   Spike 4: poke edits the live NVRAM store; the firmware reads it

Boots OpenBIOS with a share-rw IDE NVRAM node, writes boot-file=<A>, exports the node
writable over NBD, and poke edits <A>→<B> in the LIVE store; a fresh boot then reads
boot-file=<B>. Controls: without share-rw the writable export is refused (the Spike-0
hazard); an out-of-bounds poke write is refused before it lands. SKIPs by name without
poke / qemu / the x86 firmware.
Exit: 0 PASS / 1 FAIL / 77 SKIP.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-bridge.sh
source "$HERE/lib-bridge.sh"

pass() { echo "PASS: $*"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 77; }
note() { echo "  - $*"; }
SD=""; QP=""
cleanup() { [[ -n "$QP" ]] && kill "$QP" 2>/dev/null; [[ -n "$QP" ]] && wait "$QP" 2>/dev/null; [[ -n "$SD" ]] && rm -rf "$SD"; }
# shellcheck disable=SC2154
trap 'rc=$?; cleanup; [[ $rc -eq 0 || $rc -eq 1 || $rc -eq 77 ]] || echo "FAIL: smoke-pacme-edit.sh exited early (rc=$rc)"' EXIT

bridge_require skip   # poke, qemu-system-x86_64, python3, the firmware

SD="$(mktemp -d /tmp/pk.XXXXXX)"     # short path (AF_UNIX); sockets live here
NV="$SD/nvram-store.img"; truncate -s 1M "$NV"
NONCE_A="PACME-EDIT-A"; NONCE_B="PACME-EDIT-B"   # same length; differ in the last byte

# launch QEMU on $NV; $1=serial sock $2=qmp sock $3=share|noshare. Echoes the PID.
qlaunch() {
    local ser="$1" qmp="$2" mode="$3" dev
    if [[ "$mode" == share ]]; then dev="ide-hd,drive=nvstore,bus=ide.1,unit=1,share-rw=on"
    else                            dev="ide-hd,drive=nvstore,bus=ide.1,unit=1"; fi
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$FW_MB" -initrd "$FW_DICT" \
        -blockdev "node-name=nvstore,driver=raw,file.driver=file,file.filename=$NV" \
        -device "$dev" -display none -serial "unix:$ser,server=on" \
        -qmp "unix:$qmp,server=on,wait=off" -no-reboot >"$SD/qemu.log" 2>&1 &
    echo $!
}
# QMP block-export-add over NBD; $1=qmp $2=nbdsock $3=writable(true|false). Echoes
# "ACCEPTED" or "REFUSED: <desc>".
qexport() {
    python3 - "$1" "$2" "$3" <<'PY'
import socket,sys,json,time
qmp,nbdsock,writable=sys.argv[1],sys.argv[2],(sys.argv[3]=="true")
s=socket.socket(socket.AF_UNIX); s.settimeout(15)
for _ in range(30):
    try: s.connect(qmp); break
    except OSError: time.sleep(0.3)
else: print("REFUSED: no QMP"); sys.exit(0)
s.recv(65536)
def c(o): s.sendall((json.dumps(o)+"\n").encode()); time.sleep(0.2); return json.loads(s.recv(1<<16).decode().splitlines()[0])
c({"execute":"qmp_capabilities"})
r=c({"execute":"nbd-server-start","arguments":{"addr":{"type":"unix","data":{"path":nbdsock}}}})
if "error" in r: print("REFUSED: nbd-server-start: "+r["error"]["desc"]); sys.exit(0)
r=c({"execute":"block-export-add","arguments":{"type":"nbd","id":"e","node-name":"nvstore","name":"nv","writable":writable}})
print("ACCEPTED" if "error" not in r else "REFUSED: "+r["error"]["desc"])
PY
}

# ── BOOT 1: write boot-file=<A>, then poke edits <A>→<B> in the LIVE store ────
SER="$SD/s1"; QMP="$SD/q1"; NBD="$SD/n1"
QP="$(qlaunch "$SER" "$QMP" share)"; sleep 1
kill -0 "$QP" 2>/dev/null || { cat "$SD/qemu.log" >&2; fail "QEMU died at boot 1 — see above"; }
python3 "$REPO_ROOT/tools/drive-serial-repl.py" "$SER" "$SD/b1.log" --timeout 90 --expect "0 > " \
    --send "setenv boot-file $NONCE_A\r" --expect "0 > " \
    --send "\" /nvram\" \" update-nvram\" execute-device-method .\r" --expect "0 > " >/dev/null 2>&1
grep -qa 'nvram: backed by ide@3' "$SD/b1.log" || fail "boot 1: the store is not backed by ide@3 — see $SD/b1.log"
grep -qa 'execute-device-method \. -1' <(tr -d '\r' < "$SD/b1.log") || fail "boot 1: update-nvram did not report success — see $SD/b1.log"

# share-rw ⟹ the writable export is ACCEPTED (Spike 0's hazard resolved)
RW="$(qexport "$QMP" "$NBD" true)"
[[ "$RW" == ACCEPTED ]] || fail "the writable export was not accepted on a share-rw node: $RW"
OFF="$(grep -aob "$NONCE_A" "$NV" | head -1 | cut -d: -f1)"
[[ -n "$OFF" ]] || fail "boot 1: the nonce did not reach the store"
URI="nbd+unix:///nv?socket=$NBD"
# poke confirms <A> live, then edits the last byte 'A'→'B' (same length) in the live store
PRE="$(poke --quiet -c "var f=open(\"$URI\"); var s = string @ f : ${OFF}#B; print s;" 2>/dev/null)"
[[ "$PRE" == "$NONCE_A" ]] || fail "poke read '$PRE' over the writable export, expected '$NONCE_A'"
poke --quiet -c "var f=open(\"$URI\"); uint<8> @ f : $(( OFF + ${#NONCE_A} - 1 ))#B = 0x42; close(f);" 2>/dev/null
LIVE="$(dd if="$NV" bs=1 skip="$OFF" count="${#NONCE_B}" 2>/dev/null)"
[[ "$LIVE" == "$NONCE_B" ]] || fail "poke's live edit did not land in the store (store reads '$LIVE', expected '$NONCE_B')"
note "boot 1: firmware wrote boot-file=$NONCE_A; poke edited the LIVE store (share-rw NBD) → $NONCE_B"

# ── control: an out-of-bounds poke write is REFUSED before it lands ──────────
BEFORE_END="$(od -An -tx1 -j $((1024*1024 - 4)) -N 4 "$NV" | tr -d ' \n')"
OOB="$(poke --quiet -c "var f=open(\"$URI\"); try { uint<8> @ f : $((1024*1024 + 16))#B = 0xff; print \"WROTE\"; } catch (Exception e) { print \"REFUSED\"; }" 2>&1 | head -1)"
AFTER_END="$(od -An -tx1 -j $((1024*1024 - 4)) -N 4 "$NV" | tr -d ' \n')"
[[ "$OOB" != "WROTE" && "$BEFORE_END" == "$AFTER_END" ]] \
    || fail "CONTROL did NOT bite: an out-of-bounds poke write was not refused (got '$OOB'; tail $BEFORE_END→$AFTER_END)"
note "control: an out-of-bounds poke write is refused ($OOB), the store's tail unchanged — refuse before the irreversible step"
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; QP=""

# ── BOOT 2: a FRESH firmware on the live-edited store reads boot-file=<B> ─────
SER="$SD/s2"; QMP="$SD/q2"
QP="$(qlaunch "$SER" "$QMP" share)"; sleep 1
kill -0 "$QP" 2>/dev/null || { cat "$SD/qemu.log" >&2; fail "QEMU died at boot 2 — see above"; }
python3 "$REPO_ROOT/tools/drive-serial-repl.py" "$SER" "$SD/b2.log" --timeout 90 --expect "0 > " \
    --send "printenv boot-file\r" --expect "0 > " >/dev/null 2>&1
B2="$(tr -d '\r' < "$SD/b2.log")"
grep -qa 'zapping pram' <<<"$B2" && fail "boot 2: the firmware ZAPPED the store — poke's edit broke the nvram partition (not a clean same-length value edit) — see $SD/b2.log"
grep -qa "boot-file.*\"$NONCE_B\"" <<<"$B2" \
    || fail "boot 2: the firmware did not read poke's edited value '$NONCE_B' — see $SD/b2.log"
grep -qa "$NONCE_A" <<<"$B2" \
    && fail "boot 2: the firmware still reads the pre-edit value '$NONCE_A' — pacme's edit did not reach it"
note "boot 2: the fresh firmware read boot-file=$NONCE_B — it observed exactly pacme's live edit (pre-edit was $NONCE_A)"
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; QP=""

# ── control: WITHOUT share-rw, the writable export is REFUSED (the write path is gated)
SER="$SD/s3"; QMP="$SD/q3"; NBD="$SD/n3"
QP="$(qlaunch "$SER" "$QMP" noshare)"; sleep 1
kill -0 "$QP" 2>/dev/null || { cat "$SD/qemu.log" >&2; fail "QEMU died at the hazard control boot — see above"; }
python3 "$REPO_ROOT/tools/drive-serial-repl.py" "$SER" "$SD/b3.log" --timeout 90 --expect "0 > " >/dev/null 2>&1
HZ="$(qexport "$QMP" "$NBD" true)"
case "$HZ" in
    REFUSED*) note "control: without share-rw a writable export is REFUSED — ${HZ#REFUSED: }" ;;
    *) fail "CONTROL did NOT bite: a writable export of the UNSHARED in-use node was $HZ (Spike 0 measured it refused) — the write path is not gated" ;;
esac
kill "$QP" 2>/dev/null; wait "$QP" 2>/dev/null; QP=""

pass "Spike 4 (edit live): GNU poke edited boot-file=$NONCE_A→$NONCE_B in the RUNNING firmware's NVRAM store over a writable NBD export (share-rw), and a fresh firmware boot read exactly $NONCE_B (nothing zapped) — the editor-side survives-and-is-observed test. The write path is gated (unshared → refused, the Spike-0 hazard) and bounded (an out-of-bounds write refused before it lands)"
