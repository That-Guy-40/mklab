#!/usr/bin/env bash
# Slice 5a (b): TWO VMMs on ONE fabric, and the live cluster untouched.
#
# Firecracker and QEMU `-M microvm` boot the same kernel and the same rootfs bytes on two
# `fabric.sh`-made taps on `br-mc0`, take DHCP leases from the fabric's dnsmasq, and resolve
# EACH OTHER BY NAME across the engine boundary. Then teardown, with the Calico comparison.
#
# THIS IS THE EVIDENCE FOR §18.4's network-attachment row, and it is the row the seam table
# claims is "common". A claim about a common seam is worth exactly one demonstration that
# one fabric verb serves both engines — which is what `tap api1` / `tap api2` do here.
#
# AND BOTH VMMs ARE DROPPED TO THE UNPRIVILEGED OWNER (`runuser -u $OWNER`), which is not
# decoration. The test itself must be root — the fabric needs CAP_NET_ADMIN — and it would
# have been a line shorter to leave the guests running as root too. But then "neither VMM
# needs privilege" would be a claim the test asserts in a comment and never exercises: a
# root VMM can open ANY tap, so the uid-1000 tap ownership that plan G.4 exists to protect
# would go untested, and the run would pass just as happily with it broken. Dropping
# privilege is what makes the `owner` assertion below mean something.
#
# ⚠️ REAL HOST NETWORKING, BESIDE A LIVE microk8s/Calico. Same three guards as
# test-fabric-round-trip.sh, for the same reasons — not root → SKIP; a fabric already up →
# SKIP and touch nothing; a root-owned checkout → SKIP (root-owned taps are unopenable by an
# unprivileged VMM, the 2026-08-02 defect, plan G.4). Teardown runs from the EXIT trap
# because `fail` is an exit, and a leaked 10.71.0.1 quietly breaks the next lab.
#
# AND ONE HAZARD THIS TEST HAS THAT THE ROUND TRIP DOES NOT: it holds the fabric up for the
# whole of two guest boots rather than a few seconds. Calico's first-found autodetection
# re-runs EVERY 60 SECONDS (plan I.4) and its tunnel now sits on the physical uplink
# (I.3), so this run is exposed for its entire duration. That is precisely why rule 1 (the
# `br-` name, excluded by Calico at any operstate) and rule 2 (addressless taps) are both
# asserted below while the guests are RUNNING — not merely inferred from a clean teardown.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

WORKDIR="${MC_WORKDIR:-$(mc_workdir)}"
KERNEL="${MC_KERNEL:-$WORKDIR/vmlinux}"
ROOTFS="${MC_ROOTFS:-$WORKDIR/api1.ext4}"
FC_BIN="${MC_FIRECRACKER:-$WORKDIR/firecracker}"
QEMU_BIN="${MC_QEMU:-qemu-system-x86_64}"
QBOOT="${MC_QBOOT:-/usr/share/qemu/qboot.rom}"
BOOT_TIMEOUT=45

[[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root: the fabric creates a bridge, taps and an nft table (CAP_NET_ADMIN)"
need ip nft dnsmasq runuser install   # runuser: the VMMs are dropped to $OWNER, see the header
[[ -x "$FABRIC" ]] || skip "fabric.sh not executable at $FABRIC"
[[ -r "$KERNEL" && -r "$ROOTFS" ]] || skip "slice 3's kernel/rootfs are not in $WORKDIR"
[[ -x "$FC_BIN" ]] || skip "no firecracker binary at $FC_BIN"
command -v "$QEMU_BIN" >/dev/null 2>&1 || skip "no $QEMU_BIN on PATH"
"$QEMU_BIN" -machine help 2>/dev/null | grep -q '^microvm ' || skip "this QEMU has no microvm machine type"
[[ -r "$QBOOT" ]] || skip "qboot ROM not readable at $QBOOT"
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm not read-write — this would compare TCG, not two VMMs"

[[ -e /run/mklab-mc/preflight ]] \
    && skip "a fabric is already up (/run/mklab-mc/preflight exists) — refusing to tear down a lab this test did not create"
ip link show br-mc0 >/dev/null 2>&1 \
    && skip "br-mc0 already exists — refusing to adopt an interface this test did not create"

OWNER="$(stat -c %U "$REPO_DIR")"
[[ -n "$OWNER" && "$OWNER" != root ]] \
    || skip "the repo checkout is owned by '$OWNER' — taps would be root-owned and unusable by an unprivileged VMM"
OWNER_UID="$(id -u "$OWNER")" || skip "cannot resolve uid for '$OWNER'"
export MC_OWNER="$OWNER"

WORK="$(mktemp -d)" || fail "could not create a scratch dir"
# The VMMs run as $OWNER (see the header), so the scratch dir and everything in it
# must be theirs: mktemp -d is 0700 root, which an unprivileged Firecracker cannot
# even traverse — it would fail on the config file, long before the tap.
chmod 0755 "$WORK" || fail "could not open the scratch dir for $OWNER"
LOG="$WORK/fabric.log"
FABRIC_UP=0
FC_PID="" QEMU_PID=""
KEEP=0

_on_exit() {
    local rc=$?
    # Guests first, BY PID. Never by pattern: both command lines carry the shared workdir
    # path and `pkill -f` on it has, in this repo, killed a live QEMU and the agent's own
    # shell (exit 144). $FC_PID/$QEMU_PID were recorded from $! — there is no guessing.
    [[ -n "$FC_PID"   ]] && kill "$FC_PID"   2>/dev/null
    [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null
    [[ -n "$FC_PID"   ]] && wait "$FC_PID"   2>/dev/null
    [[ -n "$QEMU_PID" ]] && wait "$QEMU_PID" 2>/dev/null
    if (( FABRIC_UP )); then bash "$FABRIC" down >>"$LOG" 2>&1 || true; fi
    if (( KEEP )); then
        printf '\nguest consoles and the fabric log kept in: %s\n' "$WORK" >&2
    else
        [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
    fi
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

fab() { local v="$1"; shift; bash "$FABRIC" "$v" "$@" >>"$LOG" 2>&1; }
die_with_log() { KEEP=1; cat "$LOG" >&2; fail "$1"; }

# Wait for a marker in a guest console. Returns non-zero on timeout — a guest that never
# came up must never be read as one that came up silently.
wait_for() {
    local f="$1" pat="$2" secs="$3" i=0
    while (( i < secs * 10 )); do
        [[ -s "$f" ]] && grep -q -- "$pat" "$f" 2>/dev/null && return 0
        sleep 0.1; i=$((i+1))
    done
    return 1
}

# ── record THEIRS, independently, before touching anything ──────────────────
CAL_BEFORE="$(calico_binding)"; VETH_BEFORE="$(calico_veths)"
FWD_BEFORE="$(cat /proc/sys/net/ipv4/ip_forward)"
note "before: calico=${CAL_BEFORE:-<absent>} veths=$VETH_BEFORE ip_forward=$FWD_BEFORE"

# ── one fabric, two taps, one verb ──────────────────────────────────────────
fab up || die_with_log "fabric up failed: $(tail -1 "$LOG")"
FABRIC_UP=1
for n in api1 api2; do
    fab tap "$n" || die_with_log "fabric tap $n failed: $(tail -1 "$LOG")"
done
note "fabric: br-mc0 + two taps from ONE verb, for two different VMMs"

# ── two engines, same kernel, same rootfs bytes ─────────────────────────────
# ASK THE FABRIC for each guest's MAC; never write one down. The fabric reserves the DHCP
# lease against this value, so a hand-written MAC that drifts from the reservation does not
# error — the guest just takes a dynamic lease while dnsmasq keeps answering the name with
# the reserved address. This test used to carry 06:00:ac:47:00:01 and :02 literally, which
# were the fabric's OLD positional MACs; they stopped being right the moment the derivation
# became name-based, and nothing but this line would have noticed.
MAC1="$(bash "$FABRIC" mac api1)" || fail "could not ask the fabric for api1's MAC"
MAC2="$(bash "$FABRIC" mac api2)" || fail "could not ask the fabric for api2's MAC"
[[ "$MAC1" =~ ^06:00: && "$MAC2" =~ ^06:00: && "$MAC1" != "$MAC2" ]] \
    || fail "the fabric returned unusable MACs for api1/api2: '$MAC1' / '$MAC2'"
note "MACs asked of the fabric, not hard-coded: api1=$MAC1 api2=$MAC2"

cp -- "$ROOTFS" "$WORK/api1.ext4" || fail "could not copy the rootfs for api1"
cp -- "$ROOTFS" "$WORK/api2.ext4" || fail "could not copy the rootfs for api2"
chown "$OWNER" "$WORK/api1.ext4" "$WORK/api2.ext4" || fail "could not hand the rootfs copies to $OWNER"

# api1 = Firecracker. It APPENDS `root=/dev/vda rw` itself (plan E.4), so it is absent here;
# `ip=` is absent too — the guest takes DHCP from the fabric's dnsmasq, which is the thing
# under test (F.4: an `ip=` without a tap is a 23x silent regression).
cat > "$WORK/api1.json" <<JSON
{
  "boot-source": { "kernel_image_path": "$KERNEL",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off mc_name=api1 mc_peer=api2" },
  "drives": [ { "drive_id": "rootfs", "path_on_host": "$WORK/api1.ext4",
                "is_root_device": true, "is_read_only": false } ],
  "network-interfaces": [ { "iface_id": "eth0", "host_dev_name": "mc-api1",
                            "guest_mac": "$MAC1" } ],
  "machine-config": { "vcpu_count": 1, "mem_size_mib": 256 }
}
JSON
chown "$OWNER" "$WORK/api1.json" || fail "could not hand api1.json to $OWNER"
install -o "$OWNER" -m 0644 /dev/null "$WORK/api1.console" || fail "could not create api1.console"
runuser -u "$OWNER" -- "$FC_BIN" --no-api --config-file "$WORK/api1.json" \
        --api-sock "$WORK/api1.sock" >"$WORK/api1.console" 2>&1 &
FC_PID=$!

# api2 = QEMU -M microvm. The SAME pre-made tap contract — `-netdev tap,ifname=…,script=no`
# consumes a tap by name and neither creates nor destroys it (plan H.5), which is exactly
# what Firecracker does above. That symmetry IS the network-attachment row's evidence.
# `root=` must be supplied here: QEMU appends nothing (E.4's asymmetry).
install -o "$OWNER" -m 0644 /dev/null "$WORK/api2.console" || fail "could not create api2.console"
runuser -u "$OWNER" -- "$QEMU_BIN" \
    -M microvm,rtc=on -cpu host -enable-kvm -m 256 -smp 1 \
    -no-user-config -nodefaults -no-reboot -display none \
    -bios "$QBOOT" \
    -kernel "$KERNEL" \
    -append "console=ttyS0 reboot=k panic=1 pci=off root=/dev/vda rw mc_name=api2 mc_peer=api1" \
    -drive "file=$WORK/api2.ext4,if=none,id=disk0,format=raw" \
    -device "virtio-blk-device,drive=disk0" \
    -netdev "tap,id=net0,ifname=mc-api2,script=no,downscript=no" \
    -device "virtio-net-device,netdev=net0,mac=$MAC2" \
    -serial "file:$WORK/api2.console" >"$WORK/api2.qemu.err" 2>&1 &
QEMU_PID=$!

for g in api1 api2; do
    wait_for "$WORK/$g.console" 'Run /sbin/init as init process' "$BOOT_TIMEOUT" \
        || { KEEP=1; fail "$g never reached userspace within ${BOOT_TIMEOUT}s — console: $WORK/$g.console"; }
done
note "both guests reached userspace: api1 under Firecracker, api2 under QEMU -M microvm"

# ── the safety property, asserted while BOTH guests are RUNNING ─────────────
# Not inferred from a clean teardown: a tap with an IPv4 is a Calico first-found candidate,
# and autodetection is polling every 60 s for the whole of this run.
for t in mc-api1 mc-api2; do
    a="$(ip -4 -o addr show "$t" 2>/dev/null)"
    [[ "$a" != *inet* ]] \
        || fail "REGRESSION: $t carries an IPv4 ($a) — that makes it a Calico first-found candidate, the F.6 mechanism, and two VMMs are running on it right now"
    got="$(cat "/sys/class/net/$t/owner" 2>/dev/null)"
    [[ "$got" == "$OWNER_UID" ]] \
        || fail "REGRESSION: $t owner uid is '${got:-<unset>}', expected $OWNER_UID ($OWNER)"
done
CAL_MID="$(calico_binding)"
[[ "${CAL_MID:-<absent>}" == "${CAL_BEFORE:-<absent>}" ]] \
    || fail "REGRESSION: Calico's tunnel moved WHILE both guests were running: '${CAL_BEFORE:-<absent>}' -> '${CAL_MID:-<absent>}'"
note "with both engines up: taps addressless, uid-$OWNER_UID owned, Calico's binding unmoved"

# ── DHCP from one dnsmasq, to two different VMMs ────────────────────────────
# WAIT for the line, do not sample for it. The first version grepped the console the instant
# the tap assertions finished and failed with "api1 took no DHCP lease" — which was FALSE:
# api1 was still inside udhcpc. The two engines do not arrive together and never will, and
# this run says why in one line each:
#
#     SLICE3-BEGIN name=api2 peer=api1 uptime=0.04s      ← QEMU -M microvm
#     SLICE3-BEGIN name=api1 peer=api2 uptime=0.55s      ← Firecracker, 0.51 s behind
#
# That is Appendix J's i8042 probe, re-derived by the guests themselves on a fabric with
# network devices attached — J measured no-network boots, so this is an independent
# confirmation rather than a repeat. It also means ANY instant-sampled assertion here is a
# stopwatch race against a 0.5 s device probe, and it will fail on whichever engine is
# behind. Assert the state the system must reach, with a timeout that reports honestly.
for g in api1 api2; do
    wait_for "$WORK/$g.console" 'dhcp rc=0' 30 \
        || { KEEP=1; fail "$g took no DHCP lease from the fabric's dnsmasq within 30s — console: $WORK/$g.console"; }
    grep -q 'addr *: .*10\.71\.0\.' "$WORK/$g.console" \
        || { KEEP=1; fail "$g reported dhcp rc=0 but no 10.71.0.x address — console: $WORK/$g.console"; }
done
IP1="$(grep -o '10\.71\.0\.[0-9]*' "$WORK/api1.console" | head -1)"
IP2="$(grep -o '10\.71\.0\.[0-9]*' "$WORK/api2.console" | head -1)"
[[ -n "$IP1" && -n "$IP2" && "$IP1" != "$IP2" ]] \
    || fail "the two guests did not get distinct leases (api1='$IP1' api2='$IP2')"
note "DHCP: api1=$IP1 (Firecracker) api2=$IP2 (QEMU) — one dnsmasq, two engines, distinct leases"

# ── the point of the whole slice: name resolution ACROSS the engine boundary ─
# The assertion is the guest init script's OWN outcome marker, not a string scraped out of
# ping's report. `SLICE3-PING-BY-NAME OK` is printed only after the peer's NAME resolved and
# the ping to the resolved address succeeded — it is the state the system must end in, and
# it survives busybox changing ping's output format. (Slice 3's log is instructive here:
# nslookup prints `** server can't find api2: SERVFAIL` on the very line above a successful
# resolution, so any grep for failure text in that console would report a false negative.)
for g in api1 api2; do
    wait_for "$WORK/$g.console" 'SLICE3-PING-BY-NAME OK' 25 \
        || { KEEP=1; fail "$g never printed SLICE3-PING-BY-NAME OK — it did not reach its peer BY NAME across the engine boundary; console: $WORK/$g.console"; }
done
peer1="$(sed -n 's/.*SLICE3-PING-BY-NAME OK name=\([a-z0-9]*\) peer=\([a-z0-9]*\).*/\1->\2/p' "$WORK/api1.console" | head -1)"
peer2="$(sed -n 's/.*SLICE3-PING-BY-NAME OK name=\([a-z0-9]*\) peer=\([a-z0-9]*\).*/\1->\2/p' "$WORK/api2.console" | head -1)"
[[ "$peer1" == "api1->api2" && "$peer2" == "api2->api1" ]] \
    || fail "the two guests did not reach EACH OTHER (api1 saw '$peer1', api2 saw '$peer2') — a guest pinging itself would also print the marker"
note "name resolution: $peer1 (Firecracker→QEMU) and $peer2 (QEMU→Firecracker), both by name"

# ── teardown, and the assertion that caught F.6 ─────────────────────────────
kill "$FC_PID" 2>/dev/null; kill "$QEMU_PID" 2>/dev/null
wait "$FC_PID" 2>/dev/null; wait "$QEMU_PID" 2>/dev/null
FC_PID="" QEMU_PID=""

fab down || die_with_log "fabric down failed: $(tail -1 "$LOG")"
FABRIC_UP=0

ip link show br-mc0 >/dev/null 2>&1 && fail "REGRESSION: br-mc0 survived teardown"
leftover="$(ip -o link show 2>/dev/null | grep -oE 'mc-[a-z0-9-]+' | sort -u | tr '\n' ' ')"
[[ -z "$leftover" ]] || fail "REGRESSION: mc-* taps survived teardown: $leftover"
nft list table ip mklab-mc >/dev/null 2>&1 && fail "REGRESSION: the nft table mklab-mc survived teardown"

CAL_AFTER="$(calico_binding)"; VETH_AFTER="$(calico_veths)"
FWD_AFTER="$(cat /proc/sys/net/ipv4/ip_forward)"
[[ "${CAL_AFTER:-<absent>}" == "${CAL_BEFORE:-<absent>}" ]] \
    || fail "REGRESSION: Calico's tunnel MOVED across the run: '${CAL_BEFORE:-<absent>}' -> '${CAL_AFTER:-<absent>}' (plan F.6)"
[[ "$VETH_AFTER" == "$VETH_BEFORE" ]] \
    || fail "REGRESSION: cali* veth count moved $VETH_BEFORE -> $VETH_AFTER — pods were recreated"
[[ "$FWD_AFTER" == "$FWD_BEFORE" ]] \
    || fail "REGRESSION: ip_forward moved $FWD_BEFORE -> $FWD_AFTER"
note "teardown: ours all gone; calico binding, pod veth count and ip_forward unchanged"

pass "two engines on one fabric: Firecracker and QEMU -M microvm booted the same kernel and rootfs on taps from one verb, leased from one dnsmasq, resolved each other by name, and the live cluster was untouched"
