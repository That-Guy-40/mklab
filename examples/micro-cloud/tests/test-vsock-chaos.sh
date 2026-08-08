#!/usr/bin/env bash
# Slice 5c's break pass: a chaos matrix for the vsock channel, graded on CLAUDE.md's ladder.
#
# WHY A MATRIX AND NOT MORE ASSERTIONS. test-vsock-both-engines.sh proves the happy path
# from both engines. The complementary question is "when this breaks, how gracefully does
# it fall?" — and it is asked by injecting a fault at each layer that can fail on its own
# and grading the outcome:
#
#   ABSORBED  the fault never reached the service — refused before it could do harm  ← goal
#   DEGRADED  still serving, on a fallback
#   HALTED    not serving, but honestly: a named error, and a verb that recovers it
#   STRANDED  stuck somewhere no verb accepts — healthy, and nothing to be done with it
#   LIED      the record and reality disagree
#
# THE MATRIX IS A REGRESSION GUARD, NOT A PASS/FAIL ON CRITICALS. One row here is a
# CRITICAL and it is not our defect — it is how Firecracker's vsock behaves. Failing
# forever on an upstream property would train the reader to ignore this file, so each row
# declares the rung it was MEASURED at and the test fails when a rung MOVES. A row that
# silently improves is as interesting as one that regresses, and both get caught.
#
# EVERY ROW MUST BE OCCUPIED, which is the check that keeps the matrix honest: a harness
# that breaks nothing reports all-ABSORBED, one that breaks everything unrecoverably
# reports all-STRANDED, and both look like a working matrix from the outside. §7 asserts
# that at least one row absorbed its fault AND at least one did not.
#
# Unprivileged: /dev/kvm and /dev/vhost-vsock are both root:kvm 0660 and this host's uid
# 1000 is in kvm.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

WORKDIR="${MC_WORKDIR:-$(mc_workdir)}"
KERNEL="${MC_KERNEL:-$WORKDIR/vmlinux}"
BASE_ROOTFS="${MC_ROOTFS:-$WORKDIR/api1.ext4}"
FC_BIN="${MC_FIRECRACKER:-$WORKDIR/firecracker}"
QEMU_BIN="${MC_QEMU:-qemu-system-x86_64}"
QBOOT="${MC_QBOOT:-/usr/share/qemu/qboot.rom}"
PROBE="$LAB_DIR/vsock-probe.py"
MAKER="$LAB_DIR/make-vsock-rootfs.sh"
PORT=1234
BOOT_TIMEOUT=45
# CIDs DERIVED FROM THIS SHELL, not written down. Two concurrent runs — or one leftover
# guest from a run that died — would otherwise collide, and 5c measured exactly what that
# costs: QEMU refuses a duplicate guest-cid at device creation, so the second run's CONTROL
# guest never boots and every row grades a harness failure. A test vulnerable to the very
# thing it documents is not a good look; this is the fix.
CID_A=$(( 3 + ($$ % 60000) * 2 ))
CID_B=$(( CID_A + 1 ))

need python3 musl-gcc debugfs e2fsck
[[ -r "$KERNEL" && -r "$BASE_ROOTFS" ]] || skip "slice 3's kernel/rootfs are not in $WORKDIR"
[[ -x "$FC_BIN" ]] || skip "no firecracker binary at $FC_BIN"
command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "no $QEMU_BIN on PATH"
"$QEMU_BIN" -device help 2>&1 | grep -q 'vhost-vsock-device' || skip "this QEMU has no vhost-vsock-device"
[[ -r "$QBOOT" ]] || skip "qboot ROM not readable at $QBOOT"
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm not read-write"
[[ -r /dev/vhost-vsock && -w /dev/vhost-vsock ]] || skip "/dev/vhost-vsock not read-write for this user"
[[ -x "$MAKER" && -r "$PROBE" ]] || skip "make-vsock-rootfs.sh / vsock-probe.py missing"

# EVERY unix socket in this stack is capped by sockaddr_un at ~108 bytes — Firecracker's
# uds_path AND QEMU's -qmp path both refuse a long one, which is why this is not a
# Firecracker quirk. Measured twice on 2026-08-07; the second time cost a confusing
# "No such device" that had nothing to do with vsock.
SHORT="$(mktemp -d /tmp/mcch.XXXX)" || fail "could not create a short-path scratch dir"
WORK="$(mktemp -d)" || fail "could not create a scratch dir"
PIDS=()
KEEP=0
_cleanup() {
    # BY PID, never by pattern — `pkill -f` on a shared path has killed a live QEMU and the
    # agent's own shell in this repo (exit 144).
    local p
    for p in ${PIDS+"${PIDS[@]}"}; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    for p in ${PIDS+"${PIDS[@]}"}; do [[ -n "$p" ]] && wait "$p" 2>/dev/null; done
    if (( KEEP || (_EXIT_RC != 0 && _EXIT_RC != 77) )); then
        printf '  (consoles kept: %s)\n' "$WORK" >&2
    else
        rm -rf -- "$WORK"
    fi
    rm -rf -- "$SHORT"
}
on_exit '_cleanup'

wait_for() { local f="$1" pat="$2" secs="$3" i=0
    while (( i < secs * 10 )); do
        [[ -s "$f" ]] && grep -q -- "$pat" "$f" 2>/dev/null && return 0
        sleep 0.1; i=$((i+1))
    done; return 1; }
probe() { python3 "$PROBE" "$@" 2>&1; }

# qmp <sock> <json…> — one command per line, capabilities negotiated first.
qmp() { local sock="$1"; shift; python3 - "$sock" "$@" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5); s.connect(sys.argv[1])
def rd():
    b = b""
    while not b.endswith(b"\n"):
        c = s.recv(1)
        if not c: break
        b += c
    return b.decode().strip()
rd(); s.sendall(b'{"execute":"qmp_capabilities"}\n'); rd()
for cmd in sys.argv[2:]:
    s.sendall(cmd.encode() + b"\n"); print(rd())
PY
}

ROWS=(); ABSORBED=0; NOTABSORBED=0
row() {  # row <name> <expected-rung> <measured-rung> <evidence>
    local name="$1" want="$2" got="$3" ev="$4"
    ROWS+=("$name|$want|$got")
    [[ "$got" == ABSORBED ]] && ABSORBED=$((ABSORBED+1)) || NOTABSORBED=$((NOTABSORBED+1))
    if [[ "$want" != "$got" ]]; then
        KEEP=1
        fail "REGRESSION: the '$name' row moved on the ladder — recorded $want, measured $got.
  evidence: $ev
A rung that changes means the platform's failure behaviour changed under this lab. That is
worth a human look in BOTH directions: a row that silently improved is as interesting as one
that regressed, and neither should pass quietly."
    fi
    note "$name — $got  ✓  ($ev)"
}

bash "$MAKER" --in "$BASE_ROOTFS" --out "$WORK/vsock.ext4" --port "$PORT" >"$WORK/make.log" 2>&1 \
    || { cat "$WORK/make.log" >&2; fail "make-vsock-rootfs.sh failed — nothing to break"; }

boot_qemu() {  # boot_qemu <tag> <cid> <extra-cmdline> [extra args…]
    local tag="$1" cid="$2" extra_cmdline="$3"; shift 3
    cp "$WORK/vsock.ext4" "$WORK/$tag.ext4"
    "$QEMU_BIN" -M microvm,rtc=on -cpu host -enable-kvm -m 256 -smp 1 \
        -no-user-config -nodefaults -no-reboot -display none \
        -bios "$QBOOT" -kernel "$KERNEL" \
        -append "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw mc_name=$tag $extra_cmdline" \
        -drive "file=$WORK/$tag.ext4,if=none,id=disk0,format=raw" \
        -device virtio-blk-device,drive=disk0 \
        -device "vhost-vsock-device,guest-cid=$cid" \
        -qmp "unix:$SHORT/$tag.qmp,server,nowait" \
        -serial "file:$WORK/$tag.console" "$@" >"$WORK/$tag.err" 2>&1 &
    # PUBLISHED IN A VARIABLE, NOT ECHOED. Calling this in `$( … )` would run it in a
    # SUBSHELL, so `PIDS+=` would update a copy the EXIT trap never sees and the guest would
    # leak — which is precisely the defect micro-cloud's DHCP-exhaustion test had (`dhcp_ask`
    # in a command substitution, cleanup bookkeeping lost to a subshell, the trap reaping
    # nothing). It recurred here, was found by a leaked guest holding a CID that then blocked
    # the NEXT run's control, and is fixed the same way: no command substitution.
    QEMU_LAST_PID=$!
    PIDS+=("$QEMU_LAST_PID")
}

# ── 0. THE NO-FAULT CONTROL ────────────────────────────────────────────────
# Without this row, "the harness reported failures" is indistinguishable from a system that
# never worked. It earns its place: in metal-as-a-service the equivalent row immediately
# caught a GRADING bug.
boot_qemu ctl "$CID_A" "mc_link=1" -netdev user,id=net0 -device virtio-net-device,netdev=net0,id=nic0
ctl_pid="$QEMU_LAST_PID"
wait_for "$WORK/ctl.console" 'MC-VSOCK-AGENT LISTENING' "$BOOT_TIMEOUT" \
    || { KEEP=1; fail "the control guest never came up, so every row below would grade a broken harness rather than the channel. If its stderr says 'unable to set guest cid', a guest leaked from an earlier run still holds CID $CID_A — check \`pgrep -a -f vhost-vsock-device\`, and kill BY PID. stderr: $(head -1 "$WORK/ctl.err" 2>/dev/null); console: $WORK/ctl.console"; }
out="$(probe --engine qemu --cid "$CID_A" --port "$PORT" --retries 20)"
grep -q 'name=ctl ' <<<"$out" \
    || { KEEP=1; fail "the NO-FAULT control did not answer ($out). Nothing below is measurable: a matrix whose control fails is reporting on its own harness"; }
row "control (no fault injected)" ABSORBED ABSORBED "the unbroken channel answers: ${out##*name=}"

# ── 1. the guest's ENTIRE network, pulled under a live agent ───────────────
# The fault DEFERRED.md asked for is "tear down br-mc0 with the agent connected". This is
# that property, injected more severely and without root: `set_link down` removes the link
# from the guest's point of view altogether, which is a superset of losing the bridge
# underneath a tap. The guest reported an address before the cut, so "the network is gone"
# is a transition rather than a state that might always have been true.
# WAIT for the address, do not sample for it. mc-probe.sh runs udhcpc as a sysinit action
# and the lease takes seconds; grepping once, the instant the control probe returned, is the
# same eventual-state race that turned main's CI red twice (phase3/phase4, fixed the same
# day). It bit here under load from a second VM — proving the point rather than refuting it.
wait_for "$WORK/ctl.console" 'addr *: *[0-9]' 60 \
    || { KEEP=1; fail "the control guest never took a network address within 60s, so pulling its link proves nothing — without a before, 'the network is gone' and 'it never had one' are the same observation. Console: $WORK/ctl.console"; }
addr_before="$(grep -oE 'addr *: *[0-9./]+' "$WORK/ctl.console" | head -1)"
# THE GUEST MUST HAVE SEEN CARRIER FIRST, or "carrier is gone" is not a transition.
wait_for "$WORK/ctl.console" 'MC-LINK carrier=1' 30 \
    || { KEEP=1; fail "the control guest never reported carrier=1, so severing its link cannot be observed as a change. mc_link=1 should make the image's link watcher emit an MC-LINK line every 2s from boot; console: $WORK/ctl.console"; }
qmp "$SHORT/ctl.qmp" '{"execute":"set_link","arguments":{"name":"net0","up":false}}' >"$WORK/setlink.json" 2>&1
grep -q '"return"' "$WORK/setlink.json" \
    || { KEEP=1; fail "the injector itself failed — set_link did not take: $(cat "$WORK/setlink.json"). A fault that was never injected grades as ABSORBED and means nothing"; }

# AND THE GUEST MUST HAVE NOTICED. `{"return":{}}` only says QEMU accepted the command; the
# outcome is the guest losing carrier, and those are different claims. Measured 2026-08-07
# by breaking it: replacing set_link with a DIFFERENT command that also returns `{"return":
# …}` left this row still grading ABSORBED, because vsock answers whether or not the network
# went away. The row was passing without its own fault. The guest's WATCH timeline — which
# exists for exactly this ("without a running timeline you cannot tell 'the guest lost the
# network' from 'it never had one'") — is what makes the verdict depend on the injection.
wait_for "$WORK/ctl.console" 'MC-LINK carrier=0' 30 \
    || { KEEP=1; fail "set_link returned success but the guest NEVER LOST CARRIER — the fault did not land, so an ABSORBED verdict here would be about a network that was never severed. Last MC-LINK line: $(grep -o 'MC-LINK .*' "$WORK/ctl.console" | tail -1)"; }
carrier_evidence="$(grep -o 'MC-LINK carrier=0.*' "$WORK/ctl.console" | head -1)"
out="$(probe --engine qemu --cid "$CID_A" --port "$PORT" --retries 10)"
if grep -q 'name=ctl ' <<<"$out"; then
    row "guest network severed (set_link down)" ABSORBED ABSORBED "had $addr_before; the guest then reported [$carrier_evidence]; vsock still answers — this channel is not the fabric"
else
    row "guest network severed (set_link down)" ABSORBED HALTED "vsock stopped answering once the network went: $out"
fi

# ── 2. the host channel, deleted — a fault only ONE engine can suffer ──────
# Firecracker's host end IS a file. QEMU's is a kernel object with no name in the
# filesystem, so this fault is not merely absorbed there, it is INEXPRESSIBLE. That is the
# 5c seam asymmetry showing up in the failure domain, which is a stronger form of it.
cp "$WORK/vsock.ext4" "$WORK/fcu.ext4"
cat > "$WORK/fcu.json" <<JSON
{ "boot-source": { "kernel_image_path": "$KERNEL",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off mc_name=fcu" },
  "drives": [ { "drive_id": "rootfs", "path_on_host": "$WORK/fcu.ext4",
                "is_root_device": true, "is_read_only": false } ],
  "vsock": { "guest_cid": $CID_B, "uds_path": "$SHORT/fcu.vsock" },
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 } }
JSON
"$FC_BIN" --api-sock "$SHORT/fcu.api" --config-file "$WORK/fcu.json" >"$WORK/fcu.console" 2>&1 &
fcu_pid=$!; PIDS+=("$fcu_pid")
wait_for "$WORK/fcu.console" 'MC-VSOCK-AGENT LISTENING' "$BOOT_TIMEOUT" \
    || { KEEP=1; fail "the Firecracker guest for the unlink row never came up: $WORK/fcu.console"; }
out="$(probe --engine firecracker --uds "$SHORT/fcu.vsock" --port "$PORT" --retries 20)"
grep -q 'name=fcu ' <<<"$out" \
    || { KEEP=1; fail "the unlink row's guest did not answer BEFORE the fault ($out) — the fault would then be injected into something already broken"; }

rm -f "$SHORT/fcu.vsock"
after="$(probe --engine firecracker --uds "$SHORT/fcu.vsock" --port "$PORT" --retries 2)"
alive=no; kill -0 "$fcu_pid" 2>/dev/null && alive=yes

# GRADE AFTER ATTEMPTING THE RECOVERY THE SYSTEM OFFERS — "critical" must mean nothing can
# be done, not that the first thing looked at was still wrong. Firecracker's API is up
# (--api-sock, no --no-api), so ask it to put the vsock back.
recov="$(curl -s --max-time 5 --unix-socket "$SHORT/fcu.api" -X PUT 'http://localhost/vsock' \
          -H 'Content-Type: application/json' \
          -d "{\"guest_cid\":$CID_B,\"uds_path\":\"$SHORT/fcu.vsock\"}" 2>&1)" || true
recovered=no
[[ -S "$SHORT/fcu.vsock" ]] && probe --engine firecracker --uds "$SHORT/fcu.vsock" --retries 3 | grep -q 'name=fcu ' && recovered=yes

if [[ "$recovered" == yes ]]; then
    row "firecracker host socket unlinked" STRANDED DEGRADED "the API restored the channel: $recov"
elif [[ "$alive" == yes ]]; then
    row "firecracker host socket unlinked" STRANDED STRANDED \
        "guest still RUNNING and healthy, host gets a clean ENOENT, and the API refuses to rebuild it (${recov:0:90}) — one rm severs a healthy guest permanently"
else
    row "firecracker host socket unlinked" STRANDED HALTED "the VMM exited when its socket was removed: $after"
fi

# The other half of the row, and the reason it is a seam finding rather than a bug report.
[[ ! -e "$SHORT/ctl.vsock" ]] \
    || fail "the QEMU guest has a vsock file on disk after all — the asymmetry this row rests on is gone, and the claim that this fault is inexpressible under QEMU no longer holds"
note "  …and QEMU has no such file to delete: the SAME fault cannot be expressed against it  ✓"

# ── 3. the VMM killed with the channel in use ──────────────────────────────
# The bar is an HONEST failure: a prompt, named error rather than a hang. A hang is worse
# than an error, because the caller cannot tell it from a slow guest.
kill "$fcu_pid" 2>/dev/null; wait "$fcu_pid" 2>/dev/null
t0=$SECONDS
fc_dead="$(probe --engine firecracker --uds "$SHORT/fcu.vsock" --port "$PORT" --retries 1)"
kill "$ctl_pid" 2>/dev/null; wait "$ctl_pid" 2>/dev/null
q_dead="$(probe --engine qemu --cid "$CID_A" --port "$PORT" --retries 1)"
elapsed=$((SECONDS - t0))
if grep -q 'VSOCK-PROBE-FAILED' <<<"$fc_dead" && grep -q 'VSOCK-PROBE-FAILED' <<<"$q_dead" && (( elapsed < 30 )); then
    row "the VMM killed under a live channel" HALTED HALTED "both engines fail promptly (${elapsed}s) with a named errno, neither hangs"
else
    row "the VMM killed under a live channel" HALTED LIED \
        "a dead guest did not produce a prompt named failure (${elapsed}s) — fc='${fc_dead:0:60}' qemu='${q_dead:0:60}'"
fi

# ── 4. the CID namespace's reserved end ────────────────────────────────────
# 0/1/2 are VMADDR_CID_{ANY,HYPERVISOR,HOST}. A guest granted one of them would be
# addressable as the host.
# `-enable-kvm` is load-bearing and was missing from the first draft: without it QEMU dies
# on "CPU model 'host' requires KVM" BEFORE it ever validates guest-cid, so the reserved CID
# is never actually offered. The row graded LIED and said so — the second time in one day
# that "a refusal must be checked for its REASON" caught a fault that was not being injected.
# A control follows for the same reason.
bad=""
try_cid() { "$QEMU_BIN" -M microvm -cpu host -enable-kvm -m 128 -smp 1 \
                -no-user-config -nodefaults -display none \
                -device "vhost-vsock-device,guest-cid=$1" 2>&1 | head -1; }
for c in 0 1 2; do
    o="$(try_cid "$c")"
    grep -qi 'must be greater than 2' <<<"$o" || bad="$bad cid=$c:'${o:0:70}'"
done
# THE CONTROL: a legal CID must NOT produce that refusal, or the row would pass on a QEMU
# that rejects every guest-cid for some unrelated reason.
legal="$(timeout 5 "$QEMU_BIN" -M microvm -cpu host -enable-kvm -m 128 -smp 1 \
            -no-user-config -nodefaults -display none \
            -device "vhost-vsock-device,guest-cid=99" 2>&1 | head -1)"
grep -qi 'must be greater than 2' <<<"$legal" \
    && bad="$bad (control) a LEGAL cid=99 was refused too: '${legal:0:70}'"
if [[ -z "$bad" ]]; then
    row "a guest asks for a reserved CID (0/1/2)" ABSORBED ABSORBED "refused at device creation, by name: 'guest-cid property must be greater than 2'"
else
    row "a guest asks for a reserved CID (0/1/2)" ABSORBED LIED "a reserved CID was accepted:$bad"
fi

# ── 5. the fabric's own TEARDOWN CODE, beneath a live agent ────────────────
# Row 1 severs the guest's link with `set_link down`, which is a SUPERSET of losing the
# bridge — so the PROPERTY (vsock survives the network going away) is measured there. What
# that does not do is run `fabric.sh down` while a guest is attached, and **a stronger fault
# does not prove the weaker one ran**. This row exercises the code path.
#
# Root-gated, so it self-skips — and a skip is reported as UNCOVERED rather than quietly
# folded into the pass, because the whole point of naming uncovered layers is that an
# unmeasured one must never read as measured.
FABRIC="$REPO_DIR/examples/micro-cloud/fabric.sh"
if [[ ${EUID:-$(id -u)} -eq 0 ]] && [[ -x "$FABRIC" ]] && ! ip link show br-mc0 >/dev/null 2>&1 \
   && [[ ! -e /run/mklab-mc/preflight ]] && command -v dnsmasq >/dev/null 2>&1; then
    OWNER="$(stat -c %U "$REPO_DIR")"
    if [[ -n "$OWNER" && "$OWNER" != root ]]; then
        flog="$WORK/fabric.log"
        if MC_OWNER="$OWNER" bash "$FABRIC" up >"$flog" 2>&1 \
           && MC_OWNER="$OWNER" bash "$FABRIC" tap chaos >>"$flog" 2>&1; then
            # A guest on a REAL fabric tap, with vsock alongside — then the fabric is torn
            # down underneath it by its own verb.
            cp "$WORK/vsock.ext4" "$WORK/fab.ext4"
            fmac="$(bash "$FABRIC" mac chaos 2>/dev/null)"
            "$QEMU_BIN" -M microvm,rtc=on -cpu host -enable-kvm -m 256 -smp 1 \
                -no-user-config -nodefaults -no-reboot -display none \
                -bios "$QBOOT" -kernel "$KERNEL" \
                -append "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw mc_name=fab mc_link=1" \
                -drive "file=$WORK/fab.ext4,if=none,id=disk0,format=raw" \
                -device virtio-blk-device,drive=disk0 \
                -netdev "tap,id=net0,ifname=mc-chaos,script=no,downscript=no" \
                -device "virtio-net-device,netdev=net0,mac=$fmac" \
                -device "vhost-vsock-device,guest-cid=$((CID_A + 2))" \
                -serial "file:$WORK/fab.console" >"$WORK/fab.err" 2>&1 &
            PIDS+=($!)
            if wait_for "$WORK/fab.console" 'MC-VSOCK-AGENT LISTENING' "$BOOT_TIMEOUT" \
               && probe --engine qemu --cid "$((CID_A + 2))" --port "$PORT" --retries 20 | grep -q 'name=fab '; then
                # THE FAULT: the fabric's own teardown verb, with a guest still on its tap.
                down_out="$(MC_OWNER="$OWNER" bash "$FABRIC" down 2>&1)"; down_rc=$?
                sleep 3
                after="$(probe --engine qemu --cid "$((CID_A + 2))" --port "$PORT" --retries 5)"
                if grep -q 'name=fab ' <<<"$after"; then
                    row "fabric.sh down beneath a live agent" ABSORBED ABSORBED \
                        "the fabric tore its own bridge, taps and nft table down (rc=$down_rc) with a guest attached, and vsock still answers"
                else
                    row "fabric.sh down beneath a live agent" ABSORBED HALTED \
                        "vsock stopped answering when the fabric was torn down: ${after:0:80}"
                fi
            else
                MC_OWNER="$OWNER" bash "$FABRIC" down >>"$flog" 2>&1 || true
                note "UNCOVERED: the fabric-tap guest never came up, so the teardown row did not run (see $flog)"
            fi
        else
            note "UNCOVERED: 'fabric.sh up/tap' failed here, so the teardown row did not run: $(tail -1 "$flog" 2>/dev/null)"
        fi
    else
        note "UNCOVERED: the checkout is root-owned, so a fabric tap would be unopenable by an unprivileged VMM (plan G.4) and the row cannot be staged"
    fi
else
    note "UNCOVERED: fabric.sh down beneath a live agent — needs root, a free br-mc0 and dnsmasq. Row 1 measures the PROPERTY more severely (set_link removes the link entirely), but the fabric's teardown CODE is not exercised without this"
fi

# ── 5b. layers named as NOT covered, rather than left implicit ─────────────
# CLAUDE.md: a layer with no scenario is a layer nobody has watched fall over, and the
# uncovered ones must be named. UNKNOWN is a verdict, distinct from PASS.
note "NOT covered, deliberately:"
note "  · CID exhaustion — the space is 2^32 and cannot be exhausted the way a DHCP pool can. There is no analogous failure to grade, which is itself the answer"
note "  · a partitioned/slow channel (the host reads but never replies) — no injector yet"

# ── 6. THE MATRIX MUST BE OCCUPIED ─────────────────────────────────────────
# Zero criticals proves none of this. A harness that breaks nothing is all-ABSORBED; one
# that breaks everything is all-STRANDED; both pass a criticals-only check.
(( ABSORBED > 0 )) \
    || fail "no row ABSORBED its fault. Either every injector is too blunt, or the channel has no defences left — and a matrix where nothing is absorbed cannot tell those apart"
(( NOTABSORBED > 0 )) \
    || fail "EVERY row absorbed its fault, including the ones recorded as not absorbing. That is what a matrix looks like when the faults are not actually being injected — the most likely cause is an injector that silently no-ops"
note "ladder occupied: $ABSORBED absorbed, $NOTABSORBED not — so the injectors are landing and the defences are real  ✓"

pass "vsock's break pass: ${#ROWS[@]} rows, every one at the rung it was recorded at. Severing the guest's ENTIRE network is ABSORBED — vsock really is not the fabric — and a reserved CID is refused at device creation, while killing the VMM HALTS both engines promptly with a named errno rather than hanging. The critical is not ours and is recorded rather than punished: deleting Firecracker's host socket leaves a RUNNING, healthy guest permanently unreachable, its API refuses to rebuild the channel, and QEMU cannot suffer the fault at all because its host end is not a file — the 5c seam asymmetry, showing up in the failure domain"
