#!/usr/bin/env bash
# Slice 5c: vsock — the first channel that is NOT the fabric.
#
# THE QUESTION. Every seam row so far is network-attached, and the fabric is the common
# seam that made §8.3 shape (b) defensible. vsock has no bridge, no lease, no name, no DNS.
# Does the seam story survive a channel where the GUEST contract is byte-identical and the
# HOST API differs in kind?
#
# THE ANSWER IS ASSERTED IN BOTH DIRECTIONS, which is the only reason it is worth having:
#   §3/§4  the two host APIs are genuinely different — a unix socket with a text handshake
#          vs a real AF_VSOCK address — and BOTH are exercised, not described.
#   §5     the two guest replies are structurally identical, from one statically-linked
#          binary with no engine-specific branch in it. If §5 failed, §3/§4's difference
#          would be an ordinary porting problem rather than a seam finding.
#
# NO ROOT, NO FABRIC, NO TAP — and that is the thesis, not a convenience. `/dev/kvm` and
# `/dev/vhost-vsock` are both root:kvm 0660 and this host's uid 1000 is in `kvm`, so the
# whole slice runs unprivileged. Neither guest is given a network interface at all: if this
# test passes while `br-mc0` does not exist, "vsock is independent of the fabric" is a
# measurement rather than a claim. §1 asserts that absence rather than assuming it.
#
# WHY THE CID MATRIX IS HERE (§6). DEFERRED.md asked the sharpest version of the question:
# give two guests the same CID and find out whether the second is refused or silently
# answers for the first — the "a seam can answer for the WRONG instance" class, which has
# bitten this repo once already through a vbmc port collision. The answer turns out to
# depend on the engine, which is a finding about `guest_cid` and not about vsock.
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

need python3 musl-gcc debugfs e2fsck
[[ -r "$KERNEL" && -r "$BASE_ROOTFS" ]] || skip "slice 3's kernel/rootfs are not in $WORKDIR"
[[ -x "$FC_BIN" ]] || skip "no firecracker binary at $FC_BIN"
command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "no $QEMU_BIN on PATH"
"$QEMU_BIN" -machine help 2>/dev/null | grep -q '^microvm ' || skip "this QEMU has no microvm machine type"
"$QEMU_BIN" -device help 2>&1 | grep -q 'vhost-vsock-device' \
    || skip "this QEMU has no vhost-vsock-device on the virtio-bus — on -M microvm the PCI variant is not usable"
[[ -r "$QBOOT" ]] || skip "qboot ROM not readable at $QBOOT"
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm not read-write"
[[ -r /dev/vhost-vsock && -w /dev/vhost-vsock ]] \
    || skip "/dev/vhost-vsock is not read-write for this user — QEMU's half of the comparison cannot run, and a one-engine result would answer nothing about a seam"
[[ -x "$MAKER" && -r "$PROBE" ]] || skip "make-vsock-rootfs.sh / vsock-probe.py missing"

# Firecracker binds its vsock backend to a UNIX socket, and sockaddr_un caps the path at
# ~108 bytes. Measured 2026-08-07: a scratch dir under the agent's own TMPDIR was too long
# and Firecracker refused with "path must be shorter than SUN_LEN" — an honest, immediate
# error, but one that looks like a vsock problem when it is a path-length problem. Hence a
# deliberately short directory, and never $TMPDIR.
SHORT="$(mktemp -d /tmp/mcvs.XXXX)" || fail "could not create a short-path scratch dir"
WORK="$(mktemp -d)" || fail "could not create a scratch dir"

FC_PID="" Q_PID="" FC2_PID=""
KEEP=0
_cleanup() {
    # BY PID, never by pattern. Every one of these command lines carries the shared scratch
    # path, and `pkill -f` on it has in this repo killed a live QEMU and the agent's own
    # shell (exit 144). While writing this test, `pgrep -a -f 'firecracker|qemu-system'`
    # matched the pgrep shell itself — the same footgun, one step earlier.
    local p
    for p in "$FC_PID" "$FC2_PID" "$Q_PID"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    for p in "$FC_PID" "$FC2_PID" "$Q_PID"; do [[ -n "$p" ]] && wait "$p" 2>/dev/null; done
    if (( KEEP || (_EXIT_RC != 0 && _EXIT_RC != 77) )); then
        printf '  (guest consoles kept: %s)\n' "$WORK" >&2
    else
        rm -rf -- "$WORK"
    fi
    rm -rf -- "$SHORT"
}
on_exit '_cleanup'

wait_for() {  # wait_for <file> <pattern> <seconds>
    local f="$1" pat="$2" secs="$3" i=0
    while (( i < secs * 10 )); do
        [[ -s "$f" ]] && grep -q -- "$pat" "$f" 2>/dev/null && return 0
        sleep 0.1; i=$((i+1))
    done
    return 1
}
probe() { python3 "$PROBE" "$@" 2>&1; }

# ── 1. the claim that this is not the fabric, asserted as an absence ────────
# A test that quietly ran beside a live fabric would prove nothing about independence.
if ip link show br-mc0 >/dev/null 2>&1; then
    skip "br-mc0 exists — this test's whole point is that vsock works with no fabric at all, and it cannot show that while one is up. Run 'fabric.sh down' first"
fi
note "no br-mc0, no taps, no dnsmasq: whatever answers below did not come over the fabric  ✓"

# ── 2. one rootfs, one agent, both engines ─────────────────────────────────
# The base image has ZERO vsock-capable userspace (`strings api1.ext4 | grep -ci vsock` =
# 0): busybox+musl, and busybox `nc` has no AF_VSOCK. That gap — not plumbing — is what
# slice 5c actually had to close.
base_has="$(strings "$BASE_ROOTFS" 2>/dev/null | grep -ci vsock || true)"
(( base_has == 0 )) \
    || note "(the base image already mentions vsock $base_has times — the gap this closes may have moved)"
bash "$MAKER" --in "$BASE_ROOTFS" --out "$WORK/vsock.ext4" --port "$PORT" >"$WORK/make.log" 2>&1 \
    || { cat "$WORK/make.log" >&2; fail "make-vsock-rootfs.sh failed — no image to boot: $(tail -1 "$WORK/make.log")"; }
grep -q "byte-identical" "$WORK/make.log" \
    || note "(the no-uapi fallback was not cross-checked on this host — linux-libc-dev absent)"
cp "$WORK/vsock.ext4" "$WORK/fc.ext4"
cp "$WORK/vsock.ext4" "$WORK/q.ext4"
# THE SAME BYTES IN BOTH. Asserted, because "one agent, two engines" is what makes §5's
# identical replies a statement about the guest contract rather than about two builds.
cmp -s "$WORK/fc.ext4" "$WORK/q.ext4" \
    || fail "the two guest images differ before boot — §5 would then be comparing two builds, not one contract"
note "one image, one static agent, copied to both guests: $(stat -c %s "$WORK/vsock.ext4") bytes  ✓"

# ── 3. Firecracker: a UNIX socket and a text handshake ─────────────────────
# Note what is ABSENT from this config: "network-interfaces". Nothing bridges, nothing
# leases, nothing resolves.
FC_CID=42
cat > "$WORK/fc.json" <<JSON
{
  "boot-source": { "kernel_image_path": "$KERNEL",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off mc_name=vs-fc" },
  "drives": [ { "drive_id": "rootfs", "path_on_host": "$WORK/fc.ext4",
                "is_root_device": true, "is_read_only": false } ],
  "vsock": { "guest_cid": $FC_CID, "uds_path": "$SHORT/fc.vsock" },
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 }
}
JSON
"$FC_BIN" --no-api --config-file "$WORK/fc.json" --api-sock "$SHORT/fc.api" \
    >"$WORK/fc.console" 2>&1 &
FC_PID=$!
wait_for "$WORK/fc.console" 'MC-VSOCK-AGENT LISTENING' "$BOOT_TIMEOUT" \
    || { KEEP=1; fail "the Firecracker guest never reported a listening agent within ${BOOT_TIMEOUT}s. If the console shows 'socket(AF_VSOCK) failed errno=97', the kernel has no vsock transport and the premise of this slice is wrong; console: $WORK/fc.console"; }

# The launcher ordering, MEASURED rather than trusted. busybox init runs every sysinit
# action to completion before starting any respawn one, and mc-probe.sh blocks ~60s with no
# NIC — so an agent registered as `respawn` would not exist for the first minute of the
# guest's life. The channel that is supposed to be independent of the fabric would have
# been the one thing waiting on it.
fc_agent_line="$(grep -n 'MC-VSOCK-AGENT LISTENING' "$WORK/fc.console" | head -1 | cut -d: -f1)"
fc_probe_line="$(grep -n 'SLICE3-BEGIN' "$WORK/fc.console" | head -1 | cut -d: -f1)"
if [[ -n "$fc_agent_line" && -n "$fc_probe_line" ]]; then
    (( fc_agent_line < fc_probe_line )) \
        || fail "REGRESSION: the vsock agent came up AFTER mc-probe.sh (console lines $fc_agent_line vs $fc_probe_line). With no NIC, mc-probe.sh takes its slowest path — so vsock would be unreachable for ~60s while waiting on the network stack this channel is supposed to be independent of"
    note "the agent listens before mc-probe.sh even starts (console lines $fc_agent_line < $fc_probe_line)  ✓"
fi

[[ -S "$SHORT/fc.vsock" ]] \
    || fail "Firecracker did not create its vsock unix socket at $SHORT/fc.vsock — its host end IS that file, so there is nothing to connect to"
fc_out="$(probe --engine firecracker --uds "$SHORT/fc.vsock" --port "$PORT" --retries 20)" \
    || { KEEP=1; fail "the Firecracker guest did not answer over vsock: $fc_out"; }
grep -q '^HANDSHAKE OK ' <<<"$fc_out" \
    || fail "Firecracker's host end answered WITHOUT the 'CONNECT <port>' text handshake ($fc_out). That handshake is half the asymmetry §5 is about — if it is gone, the seam finding below is describing an API that no longer exists"
note "firecracker: unix socket + handshake — $(grep '^HANDSHAKE' <<<"$fc_out")  ✓"

# ── 4. QEMU: a real AF_VSOCK address, no path and no handshake ─────────────
Q_CID=43
"$QEMU_BIN" -M microvm,rtc=on -cpu host -enable-kvm -m 256 -smp 1 \
    -no-user-config -nodefaults -no-reboot -display none \
    -bios "$QBOOT" -kernel "$KERNEL" \
    -append "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw mc_name=vs-qemu" \
    -drive "file=$WORK/q.ext4,if=none,id=disk0,format=raw" \
    -device virtio-blk-device,drive=disk0 \
    -device "vhost-vsock-device,guest-cid=$Q_CID" \
    -serial "file:$WORK/q.console" >"$WORK/q.err" 2>&1 &
Q_PID=$!
wait_for "$WORK/q.console" 'MC-VSOCK-AGENT LISTENING' "$BOOT_TIMEOUT" \
    || { KEEP=1; fail "the QEMU guest never reported a listening agent within ${BOOT_TIMEOUT}s — qemu stderr: $(head -2 "$WORK/q.err")"; }

q_out="$(probe --engine qemu --cid "$Q_CID" --port "$PORT" --retries 20)" \
    || { KEEP=1; fail "the QEMU guest did not answer over AF_VSOCK cid=$Q_CID: $q_out"; }
grep -q '^HANDSHAKE' <<<"$q_out" \
    && fail "the QEMU path produced a handshake line ($q_out) — it is a raw AF_VSOCK socket and has no handshake, so this means the probe took the wrong branch and both rows measured the same API"
note "qemu: raw AF_VSOCK, no path and no handshake, addressed by cid=$Q_CID  ✓"

# ── 5. THE FINDING: identical guest, different host ────────────────────────
# The guest halves must match field-for-field with only the name differing. Compare the
# SHAPE, not the values — uptime and the ephemeral peer port cannot be equal and a test
# that demanded it would be asserting a coincidence.
shape() { sed -E 's/=[^ ]*/=X/g' <<<"$1" | tr -d '\n'; }
fc_reply="$(grep '^MC-VSOCK-AGENT name=' <<<"$fc_out")"
q_reply="$(grep  '^MC-VSOCK-AGENT name=' <<<"$q_out")"
[[ -n "$fc_reply" && -n "$q_reply" ]] || fail "one of the guests answered without a parseable record — fc='$fc_reply' qemu='$q_reply'"
[[ "$(shape "$fc_reply")" == "$(shape "$q_reply")" ]] \
    || fail "the two guests' replies do not have the same shape, so the guest-side contract is NOT identical and the seam finding collapses:
  firecracker: $fc_reply
  qemu       : $q_reply"
grep -q 'name=vs-fc '   <<<"$fc_reply" || fail "the firecracker guest answered to the wrong name: $fc_reply"
grep -q 'name=vs-qemu ' <<<"$q_reply"  || fail "the qemu guest answered to the wrong name: $q_reply"
grep -q "cid=$FC_CID "  <<<"$fc_reply" || fail "the firecracker guest reports a CID that is not the $FC_CID it was configured with: $fc_reply"
grep -q "cid=$Q_CID "   <<<"$q_reply"  || fail "the qemu guest reports a CID that is not the $Q_CID it was configured with: $q_reply"
# Both guests see the HOST as cid 2 (VMADDR_CID_HOST) — the one number that IS the same on
# both sides of the seam, which is worth pinning precisely because everything else differs.
grep -q 'peer=2:' <<<"$fc_reply" && grep -q 'peer=2:' <<<"$q_reply" \
    || fail "the guests disagree about the host's CID (expected 2 = VMADDR_CID_HOST on both):
  firecracker: $fc_reply
  qemu       : $q_reply"
note "identical guest record shape from both engines, each naming itself and seeing the host as cid 2  ✓"

# ── 6. the CID matrix — where the two engines genuinely part company ───────
# QEMU's guest-cid is an allocation in the HOST kernel's vhost-vsock namespace.
#
# Its own disk copy, and that is not tidiness. The first draft pointed this guest at the
# LIVE guest's q.ext4; QEMU refused it — `Failed to get "write" lock` — so the process did
# exit non-zero and the collision test "passed" without ever reaching the vsock device.
# The assertion below caught it, which is the entire reason a refusal has to be checked for
# its REASON and not just its exit status.
cp "$WORK/vsock.ext4" "$WORK/q2.ext4"
# FOREGROUND, UNDER `timeout`, and that is the second thing this block got wrong. The first
# draft backgrounded it and called `wait`. A guest that is REFUSED exits immediately, so the
# happy path looked fine — but a guest that successfully takes the cid keeps running, `wait`
# blocks forever, and the assertion written for exactly that case can never fire. Injecting
# a free cid (44) proved it: the run timed out at 300 s with no verdict at all instead of
# failing. An assertion never observed failing is not known to work.
timeout 20 "$QEMU_BIN" -M microvm,rtc=on -cpu host -enable-kvm -m 256 -smp 1 \
    -no-user-config -nodefaults -no-reboot -display none \
    -bios "$QBOOT" -kernel "$KERNEL" \
    -append "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw mc_name=vs-collide" \
    -drive "file=$WORK/q2.ext4,if=none,id=disk0,format=raw" \
    -device virtio-blk-device,drive=disk0 \
    -device "vhost-vsock-device,guest-cid=$Q_CID" \
    -serial "file:$WORK/q2.console" >"$WORK/q2.err" 2>&1
q2_rc=$?
(( q2_rc != 124 )) \
    || fail "REGRESSION: a SECOND QEMU guest took cid=$Q_CID while the first was live — it was still running 20s later. Two guests would then share one address and the host could not tell which it was talking to: the seam-answers-for-the-wrong-instance class, in the one place vsock offers to prevent it"
(( q2_rc != 0 )) \
    || fail "REGRESSION: a SECOND QEMU guest on cid=$Q_CID exited 0 — it neither collided nor kept running, which means this experiment did not run the collision at all"
grep -qi 'unable to set guest cid\|Address already in use' "$WORK/q2.err" \
    || fail "the second QEMU guest exited $q2_rc, but not for the reason under test. It must be refused BECAUSE the cid is taken, not for an unrelated failure that would mask a real collision. stderr: $(head -2 "$WORK/q2.err")"
note "ABSORBED: a duplicate guest-cid is refused by the host kernel at device creation, before the VM starts — $(grep -oi 'unable to set guest cid.*' "$WORK/q2.err" | head -1)  ✓"

# And now the same collision ACROSS engines, which is not the same experiment. Firecracker
# is a userspace vsock device: guest_cid is a number it hands the guest, with no presence in
# the host kernel's namespace at all. "Which guest?" is answered by WHICH UNIX SOCKET you
# opened. So the number that QEMU treats as a host-global resource is, under Firecracker,
# advisory — and nothing anywhere reports that difference.
cat > "$WORK/fc2.json" <<JSON
{
  "boot-source": { "kernel_image_path": "$KERNEL",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off mc_name=fc-same-cid" },
  "drives": [ { "drive_id": "rootfs", "path_on_host": "$WORK/fc.ext4",
                "is_root_device": true, "is_read_only": false } ],
  "vsock": { "guest_cid": $Q_CID, "uds_path": "$SHORT/fc2.vsock" },
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 }
}
JSON
cp "$WORK/vsock.ext4" "$WORK/fc2.ext4"
sed -i "s|$WORK/fc.ext4|$WORK/fc2.ext4|" "$WORK/fc2.json"
"$FC_BIN" --no-api --config-file "$WORK/fc2.json" --api-sock "$SHORT/fc2.api" \
    >"$WORK/fc2.console" 2>&1 &
FC2_PID=$!
wait_for "$WORK/fc2.console" 'MC-VSOCK-AGENT LISTENING' "$BOOT_TIMEOUT" \
    || { KEEP=1; fail "a Firecracker guest configured with the SAME cid=$Q_CID as the live QEMU guest never came up. If Firecracker refused it, that is a finding worth recording — but it must be recorded, not read as a boot failure. console: $WORK/fc2.console"; }

# Three guests now claim cid=43. Each host API must reach the one it addressed — and the
# only reason that is checkable is that the agent reports its own mc_name. Without the
# name, "cid=43 answered" would be indistinguishable between them, which is precisely how
# a wrong-instance answer hides.
fc2_out="$(probe --engine firecracker --uds "$SHORT/fc2.vsock" --port "$PORT" --retries 20)" \
    || { KEEP=1; fail "the same-cid Firecracker guest did not answer on its own uds: $fc2_out"; }
grep -q 'name=fc-same-cid ' <<<"$fc2_out" \
    || fail "REGRESSION: the firecracker uds for the same-cid guest answered as someone else — $fc2_out. Two guests sharing a cid must still be distinguishable by the channel used to reach them, or the host cannot tell which machine it just talked to"
q_again="$(probe --engine qemu --cid "$Q_CID" --port "$PORT" --retries 20)" \
    || { KEEP=1; fail "the QEMU guest stopped answering on cid=$Q_CID once a Firecracker guest claimed the same number: $q_again"; }
grep -q 'name=vs-qemu ' <<<"$q_again" \
    || fail "REGRESSION: AF_VSOCK cid=$Q_CID now reaches the FIRECRACKER guest — $q_again. The host would be addressing one machine and talking to another, which is the exact failure a vbmc port collision produced in this repo before"
note "the SAME cid=$Q_CID under Firecracker does NOT collide: its number lives in no host namespace, and each host API still reaches the guest it addressed  ✓"

pass "vsock works from both engines with no fabric, no tap and no root — and it is a sharper seam row than 'stop': ONE statically-linked agent produces the same record shape under Firecracker and QEMU (each naming itself, each seeing the host as cid 2), while the host APIs differ in kind — a unix socket plus a 'CONNECT <port>' handshake versus a raw AF_VSOCK address. The asymmetry has a consequence nothing reports: QEMU's guest-cid is a host-kernel allocation and a duplicate is ABSORBED at device creation, whereas Firecracker's is advisory, so the same number booted happily beside it and the two were told apart only by which channel was opened"
