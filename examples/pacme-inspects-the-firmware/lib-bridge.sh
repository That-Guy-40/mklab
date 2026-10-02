#!/usr/bin/env bash
# lib-bridge.sh — the SEAM between GNU poke (host) and a RUNNING OpenBIOS firmware
# (QEMU), shared by the Spike-0 decision (bridge.sh) and the Spike-1 proof
# (smoke-pacme-seam.sh). Source it; it defines helpers, not a verdict.
#
# The bridge, measured end to end 2026-10-02: launch OpenBIOS x86 with its IDE
# NVRAM store (a real block NODE QEMU holds), drive the firmware over serial to
# write a known nonce into that store, then expose the LIVE node to poke two ways:
#   FILE  — read the backing file / a QMP pmemsave snapshot (SNAPSHOT: stale once read)
#   NBD   — QMP `block-export-add type=nbd` of the live node; poke opens nbd+unix://
#           (LIVE: block-only — poke sees the bytes the firmware just wrote)
# The gdbstub IOD for live RAM (Spike 5/C) is named, not built; RAM is SNAPSHOT.
#
# GOTCHAS banked while building this (each cost a measurement):
#  * serial MUST be `-serial unix:…,server=on` (QEMU waits for the driver to
#    attach); `,wait=off` loses the firmware's prompt output and the drive times out.
#  * QMP is `-qmp unix:…,server=on,wait=off` — we attach to it AFTER the drive, so it
#    must not block boot.
#  * socket paths must be < 108 bytes (AF_UNIX sun_path) — we mint them under
#    /tmp/pk.XXXXXX, never under the long scratchpad/WORKDIR path.
#  * poke's NBD URI is `nbd+unix:///<export>?socket=<path>` (the other forms throw).
#  * teardown is BY PID (the socket path is in QEMU's argv, so `pkill -f` would match
#    QEMU itself — the repo's standing rule).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="${OPENBIOS_WORKDIR:-$HOME/openbios-lab}"
FW_MB="$WORKDIR/openbios/obj-x86/openbios.multiboot"
FW_DICT="$WORKDIR/openbios/obj-x86/openbios-x86.dict"
ACCEL=$([[ -w /dev/kvm ]] && echo kvm || echo tcg)

# filled by bridge_up / bridge_export_ro:
BR_SD=""; BR_NV=""; BR_SER=""; BR_QMP=""; BR_NBD=""; BR_QPID=""; BR_NONCE=""; BR_NODE=""; BR_URI=""

# bridge_require <skip-fn> — SKIP by name (via the caller's skip()) if a prereq is absent.
bridge_require() {
    local skip="$1"
    command -v qemu-system-x86_64 >/dev/null || $skip "qemu-system-x86_64 not installed"
    command -v poke >/dev/null || $skip "GNU poke not installed — run ./deps.sh (sudo apt-get install -y poke)"
    command -v python3 >/dev/null || $skip "python3 not installed"
    [[ -f "$FW_MB" && -f "$FW_DICT" ]] \
        || $skip "no OpenBIOS x86 firmware at $FW_MB — run openbios-the-rival-that-shipped/build-openbios.sh x86 first"
    grep -q 'ob_ide_write_blocks_nr' "$WORKDIR/openbios/arch/x86/openbios.c" 2>/dev/null \
        || $skip "the built firmware has no IDE NVRAM backing (P1 not applied) — this lab inspects that store"
}

# bridge_up <fail-fn> — launch the firmware, write BR_NONCE into its IDE NVRAM, leave
# QEMU ALIVE at the prompt (BR_QPID). Calls <fail-fn> on any break.
bridge_up() {
    local fail="$1"
    BR_SD="$(mktemp -d /tmp/pk.XXXXXX)"        # short path for AF_UNIX
    BR_SER="$BR_SD/ser"; BR_QMP="$BR_SD/qmp"; BR_NBD="$BR_SD/nbd"
    BR_NV="$BR_SD/nvram-store.img"; truncate -s 1M "$BR_NV"
    BR_NONCE="PACME-SEAM-$$-$RANDOM"
    qemu-system-x86_64 -M "pc,accel=$ACCEL" -m 512 -kernel "$FW_MB" -initrd "$FW_DICT" \
        -drive "if=ide,index=3,format=raw,cache=writethrough,file=$BR_NV" \
        -display none -serial "unix:$BR_SER,server=on" \
        -qmp "unix:$BR_QMP,server=on,wait=off" -no-reboot >"$BR_SD/qemu.log" 2>&1 &
    BR_QPID=$!
    # drive the prompt to write the nonce; drive-serial-repl.py attaches (unblocking
    # the server=on serial), converses, and exits — it does NOT own QEMU's lifecycle.
    python3 "$REPO_ROOT/tools/drive-serial-repl.py" "$BR_SER" "$BR_SD/drive.log" --timeout 90 \
        --expect "0 > " \
        --send "setenv boot-file $BR_NONCE\r" --expect "0 > " \
        --send "\" /nvram\" \" update-nvram\" execute-device-method .\r" --expect "0 > " \
        >/dev/null 2>&1
    local rc=$?
    kill -0 "$BR_QPID" 2>/dev/null || { cat "$BR_SD/qemu.log" >&2; $fail "QEMU exited during bring-up — see above"; }
    [[ $rc -eq 0 ]] || $fail "firmware prompt conversation failed (drive rc=$rc) — see $BR_SD/drive.log"
    grep -qa 'execute-device-method \. -1' <(tr -d '\r' < "$BR_SD/drive.log") \
        || $fail "update-nvram did not report success (-1) — see $BR_SD/drive.log"
    grep -qa "nvram: backed by ide@3" "$BR_SD/drive.log" \
        || $fail "the store is not backed by ide@3 — the nonce did not reach the inspected node"
}

# bridge_nonce_offset — byte offset of BR_NONCE in the backing file (host-side,
# independent of poke), or empty if not present. The recognizable span to compare.
bridge_nonce_offset() { grep -aob "$BR_NONCE" "$BR_NV" 2>/dev/null | head -1 | cut -d: -f1; }

# bridge_export_ro — QMP: find the IDE node, start NBD, export it READ-ONLY. Sets the
# GLOBALS BR_NODE and BR_URI (the poke NBD URI) in the CALLER's shell — so it must NOT
# be called inside $(...) (a command-substitution subshell would discard them, which
# silently emptied BR_NODE and gave the writable-export hazard a FALSE refusal: it was
# refused for "node-name=''", not the real permission conflict). Returns 0, or 1 with
# an "ERR: …" line on stderr.
bridge_export_ro() {
    local out; out="$(python3 - "$BR_QMP" "$BR_NBD" "$BR_NV" <<'PY'
import socket,sys,json,time
qmp,nbdsock,nvfile=sys.argv[1:4]
s=socket.socket(socket.AF_UNIX); s.settimeout(15)
for _ in range(30):
    try: s.connect(qmp); break
    except OSError: time.sleep(0.3)
else: print("ERR: no QMP socket"); sys.exit(0)
s.recv(65536)
def cmd(o):
    s.sendall((json.dumps(o)+"\n").encode()); time.sleep(0.2)
    return json.loads(s.recv(1<<16).decode().splitlines()[0])
cmd({"execute":"qmp_capabilities"})
node=None
for n in cmd({"execute":"query-named-block-nodes"}).get("return",[]):
    if n.get("file")==nvfile or (n.get("image") or {}).get("filename")==nvfile:
        node=n["node-name"]; break
if not node: print("ERR: could not find the IDE node by filename"); sys.exit(0)
r=cmd({"execute":"nbd-server-start","arguments":{"addr":{"type":"unix","data":{"path":nbdsock}}}})
if "error" in r: print("ERR: nbd-server-start: "+r["error"]["desc"]); sys.exit(0)
r=cmd({"execute":"block-export-add","arguments":{"type":"nbd","id":"ro","node-name":node,"name":"nvram","writable":False}})
if "error" in r: print("ERR: block-export-add: "+r["error"]["desc"]); sys.exit(0)
print("NODE="+node)
PY
)"
    BR_NODE="$(sed -n 's/^NODE=//p' <<<"$out")"
    if [[ -n "$BR_NODE" ]]; then
        BR_URI="nbd+unix:///nvram?socket=$BR_NBD"
        return 0
    fi
    echo "$out" >&2
    BR_URI=""
    return 1
}

# bridge_writable_probe — the Spike-0 HAZARD: try to export the SAME in-use node
# writable. Echoes "accepted" or "refused: <desc>". Measures, does not assume.
bridge_writable_probe() {
    python3 - "$BR_QMP" "$BR_NODE" <<'PY'
import socket,sys,json,time
qmp,node=sys.argv[1:3]
s=socket.socket(socket.AF_UNIX); s.settimeout(15)
for _ in range(30):
    try: s.connect(qmp); break
    except OSError: time.sleep(0.3)
else: print("refused: no QMP socket"); sys.exit(0)
s.recv(65536)
def cmd(o):
    s.sendall((json.dumps(o)+"\n").encode()); time.sleep(0.2)
    return json.loads(s.recv(1<<16).decode().splitlines()[0])
cmd({"execute":"qmp_capabilities"})
r=cmd({"execute":"block-export-add","arguments":{"type":"nbd","id":"rw","node-name":node,"name":"nvramw","writable":True}})
print("accepted" if "error" not in r else "refused: "+r["error"]["desc"])
PY
}

# poke_hex <uri> <offset> <len> — poke reads <len> bytes at <offset> over the seam,
# echoed as lowercase hex (the foreign reader; compared against od on the host).
poke_hex() {
    local uri="$1" off="$2" len="$3"
    poke --quiet -c \
      "var f=open(\"$uri\"); var b=uint<8>[$len] @ f : ${off}#B; var i=0; while(i<$len){printf(\"%u8x\",b[i]);i=i+1;}" \
      2>/dev/null
}

# bridge_down — teardown BY PID (never by pattern). Idempotent; safe in a trap.
bridge_down() {
    [[ -n "$BR_QPID" ]] && kill "$BR_QPID" 2>/dev/null
    [[ -n "$BR_QPID" ]] && wait "$BR_QPID" 2>/dev/null
    [[ -n "$BR_SD" ]] && rm -rf "$BR_SD"
    BR_QPID=""
}
