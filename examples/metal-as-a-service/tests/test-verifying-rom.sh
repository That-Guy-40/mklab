#!/usr/bin/env bash
# test-verifying-rom.sh — the ON-NODE half of F2, executed.
#
# Every other test in this suite verifies payloads the way the CONTROL PLANE does:
# `openssl cms -verify` on the host, before the node is touched. This one boots the
# firmware and makes the MACHINE answer, with the control plane out of the picture:
#
#   §1  the ROM speaks on the serial console at all      (the instrument)
#   §2  it runs the netboot-chain script, not a baked payload
#   §3  `imgverify` exists                                (IMAGE_TRUST_CMD)
#   §4  ...and this firmware reports unknown commands, so §3 discriminates
#   §5  a payload signed by THIS fleet's CA is ACCEPTED  (positive)
#   §6  a tampered payload is REFUSED, by the firmware   (negative)
#
# §5 and §6 are the same assertion pointed at two files, so neither can be vacuous:
# if the matcher could not see a refusal, §6 fails; if it saw one everywhere, §5 does.
#
# QEMU INVOCATION, deliberately: `-display none -serial ...`, as libvirt runs a
# domain — NOT `-nographic`. Under -nographic QEMU sets FW_CFG_NOGRAPHIC, SeaBIOS
# puts its own console on COM1, and a CONSOLE_SERIAL build then has two writers
# whose bytes interleave ("iiPPXXEE"): the stock ROM would look instrumented and
# this one would look broken, which is backwards. The harness must not read its own
# artifact.
#
# Slirp gives the guest a route to the host without a listening host port: the
# gateway (net+2) proxies to 127.0.0.1, so the payload server binds loopback only.
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need qemu-system-x86_64 python3 openssl

# Asked of maas-lab.sh, the one owner of the answer — the same call
# build-verifying-rom.sh makes, so the ROM under test and the CA it is checked
# against come from the same store the drivers sign into.
IMAGES_DIR="${MAAS_IMAGES_DIR:-$("$(dirname -- "${BASH_SOURCE[0]}")/../maas-lab.sh" _images-dir)}"
[[ -n "$IMAGES_DIR" ]] || fail "maas-lab.sh _images-dir returned nothing"
BUILD_DIR="${MAAS_ROM_BUILD_DIR:-$HOME/.cache/lab-create/maas/ipxe}"
ROM="$BUILD_DIR/ipxe-8086100e.rom"
ROM_CA="$BUILD_DIR/ca.der"
TRUST="$IMAGES_DIR/trust"

[[ -f "$ROM" ]] || skip "no verifying ROM built — run ./build-verifying-rom.sh build (needs docker, minutes)"
[[ -f "$ROM_CA" ]] || skip "no ca.der beside the ROM — rebuild with ./build-verifying-rom.sh build"
[[ -f "$TRUST/ca.key" && -f "$TRUST/ca.crt" ]] || skip "no fleet CA in $TRUST — run maas-lab.sh stage first"

WORK="$(mktemp -d)"
QPID=""; HTTPD=""
cleanup() {
    # By PID, never by pattern (CLAUDE.md): the qemu cmdline carries this socket
    # path, so a pattern kill would match the very thing it names.
    [[ -n "$QPID"  ]] && kill "$QPID"  2>/dev/null
    [[ -n "$HTTPD" ]] && kill "$HTTPD" 2>/dev/null
    rm -rf "$WORK"
}
# lib.sh's _on_exit captures the exit status BEFORE running anything registered here —
# `cleanup; _rc=$?` would record what the teardown returned (nearly always 0) and the
# safety net would report nothing.
on_exit 'cleanup'

# The ROM trusts exactly one root, compiled in. If the fleet re-minted its CA after
# the ROM was built, every verification would fail for a reason that is not a
# regression — so check identity first and say which it is.
openssl x509 -in "$TRUST/ca.crt" -outform DER -out "$WORK/live-ca.der" 2>/dev/null \
    || fail "could not convert $TRUST/ca.crt to DER"
cmp -s "$WORK/live-ca.der" "$ROM_CA" \
    || skip "the ROM was built against a different CA than $TRUST/ca.crt — rebuild it (./build-verifying-rom.sh build)"

# Sign with a leaf minted under the fleet CA using the profile iPXE requires. Minted
# here rather than read from $TRUST so this test measures the FIRMWARE, not whether
# the live keydir has been re-minted yet (test-signing-cert-profile.sh owns that).
mkdir -p "$WORK/keys" "$WORK/srv"
cp "$TRUST/ca.crt" "$TRUST/ca.key" "$WORK/keys/" || fail "could not copy the fleet CA"
cat > "$WORK/keys/leaf.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EXT
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/keys/codesign.key" -out "$WORK/keys/c.csr" \
    -subj '/CN=rom-test signer' >/dev/null 2>&1 || fail "could not mint a test signer key"
openssl x509 -req -in "$WORK/keys/c.csr" -CA "$WORK/keys/ca.crt" -CAkey "$WORK/keys/ca.key" \
    -CAcreateserial -days 3650 -extfile "$WORK/keys/leaf.ext" -out "$WORK/keys/codesign.crt" >/dev/null 2>&1 \
    || fail "could not sign the test leaf with the fleet CA"

printf 'GOOD-PAYLOAD-FOR-ROM-TEST\n' > "$WORK/srv/good.img"
printf 'BAD-PAYLOAD-FOR-ROM-TEST\n'  > "$WORK/srv/bad.img"
for f in good bad; do
    openssl cms -sign -binary -noattr -outform DER \
        -signer "$WORK/keys/codesign.crt" -inkey "$WORK/keys/codesign.key" -certfile "$WORK/keys/ca.crt" \
        -in "$WORK/srv/$f.img" -out "$WORK/srv/$f.img.sig" >/dev/null 2>&1 \
        || fail "CMS signing failed for $f.img"
done
# Tamper AFTER signing: the signature stays valid-looking, the bytes do not match.
printf 'X' | dd of="$WORK/srv/bad.img" bs=1 seek=1 conv=notrunc status=none 2>/dev/null \
    || fail "could not tamper with bad.img"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/srv" >/dev/null 2>&1 &
HTTPD=$!
sleep 1
kill -0 "$HTTPD" 2>/dev/null || fail "the payload HTTP server did not stay up on 127.0.0.1:$PORT"

SOCK="$WORK/serial.sock"
LOG="$WORK/serial.log"
qemu-system-x86_64 -m 512 -display none \
    -device "e1000,romfile=$ROM,netdev=n0" \
    -netdev 'user,id=n0,net=10.9.9.0/24' \
    -boot n -serial "unix:$SOCK,server=on,wait=off" >"$WORK/qemu.log" 2>&1 &
QPID=$!
sleep 1
kill -0 "$QPID" 2>/dev/null || { sed 's/^/    /' "$WORK/qemu.log" >&2; fail "qemu exited immediately — see its output above"; }

BASE="http://10.9.9.2:$PORT"
# The chain's three HTTP attempts fail fast (nothing serves :8181 on the slirp
# gateway), which is what drops us at the prompt. One client on the socket only.
python3 "$LAB_DIR/../../tools/drive-serial-repl.py" "$SOCK" "$LOG" --timeout 240 \
    --expect 'iPXE>' \
    --send 'imgverify\r'                                   --expect 'iPXE>' \
    --send 'nosuchcmd\r'                                   --expect 'iPXE>' \
    --send "imgverify $BASE/good.img $BASE/good.img.sig\r" --expect 'iPXE>' \
    --send "imgverify $BASE/bad.img $BASE/bad.img.sig\r"   --expect 'iPXE>'
drc=$?
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
kill "$HTTPD" 2>/dev/null; wait "$HTTPD" 2>/dev/null; HTTPD=""

if [[ $drc -eq 124 ]]; then
    sed 's/^/    /' "$LOG" >&2
    fail "the firmware never reached the iPXE prompt within the deadline — transcript above"
elif [[ $drc -eq 125 ]]; then
    fail "the console dropped input bytes (drive-serial-repl exit 125) — the conversation was not delivered intact"
elif [[ $drc -ne 0 ]]; then
    sed 's/^/    /' "$LOG" >&2
    fail "driving the iPXE prompt failed (rc=$drc) — transcript above"
fi

# ─── §1 the instrument ───────────────────────────────────────────────────────
[[ -s "$LOG" ]] \
    || fail "REGRESSION: the ROM produced NOTHING on the serial console under libvirt's own QEMU invocation — an iPXE-level failure would again be a silence (build with --serial-console)"
grep -q 'iPXE' "$LOG" \
    || fail "REGRESSION: serial output exists but carries no iPXE banner — something else is writing to COM1"
note "the ROM speaks on the serial console (-display none, as libvirt runs it)"

# ─── §2 it asks the control plane ───────────────────────────────────────────
grep -q 'MAAS: resolving a boot script' "$LOG" \
    || fail "REGRESSION: the compiled-in script is not netboot-chain's — the ROM is carrying a baked payload instead of asking the control plane what to boot"
note "the compiled-in script is netboot-chain's per-node resolver"

# ─── §3/§4 imgverify exists, and 'missing' is distinguishable ───────────────
grep -q 'imgverify \[-s|--signer' "$LOG" \
    || fail "REGRESSION: 'imgverify' is not a command in this firmware — IMAGE_TRUST_CMD was not compiled in, and the on-node half of F2 cannot run at all"
grep -q 'nosuchcmd: command not found' "$LOG" \
    || fail "the control command did not produce 'command not found' — so the §3 assertion cannot be said to discriminate between a present and an absent command"
note "imgverify is present; an absent command reports 'command not found' (§3 discriminates)"

# ─── §5/§6 the firmware's verdict on real payloads ──────────────────────────
awk '/imgverify http/ && /good\.img/ {g=1; next} /imgverify http/ && /bad\.img/ {g=0} g' "$LOG" > "$WORK/seg-good.txt"
awk '/imgverify http/ && /bad\.img/  {b=1; next} b' "$LOG" > "$WORK/seg-bad.txt"

grep -q 'good.img\.\.\. ok' "$LOG" \
    || fail "the firmware never fetched good.img — the payload server was unreachable from the guest, so no verdict was reached"
if grep -q 'Could not verify' "$WORK/seg-good.txt"; then
    sed 's/^/    /' "$WORK/seg-good.txt" >&2
    fail "REGRESSION: the firmware REFUSED a payload signed by this fleet's own CA — F2 is failing closed on good material. If the reason is 022ae1 ('Not a signing certificate') the signing leaf lost keyUsage=digitalSignature"
fi
note "signed payload ACCEPTED by the firmware (no refusal between its fetch and the prompt)"

grep -q 'Could not verify' "$WORK/seg-bad.txt" \
    || fail "REGRESSION: the firmware ACCEPTED a TAMPERED payload — imgverify is not actually verifying, and every claim F2 makes on the node is void"
grep -q '0227e13c' "$WORK/seg-bad.txt" \
    || note "tamper refused, but not with the expected digest-mismatch code 0227e13c — check what it did report"
note "tampered payload REFUSED by the firmware (digest mismatch)"

pass "the on-node half of F2 runs: this firmware has imgverify, accepts a payload signed by the fleet CA, and refuses a tampered one"
