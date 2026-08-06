#!/usr/bin/env bash
# Slice 5b: the FIDELITY case joins the fabric, and gets its RESERVED lease.
#
# A stock Debian cloud image on QEMU `-M q35` — real firmware, cloud-init, systemd, a full
# network stack — boots on a `fabric.sh` tap beside a Firecracker microVM, takes the lease
# the fabric RESERVED for it, and reaches `api1` by name. Then teardown, with the Calico
# comparison.
#
# ── WHAT THIS PROVES THAT SLICE 5a DID NOT ─────────────────────────────────────────────
#
# 5a compared two engines that were deliberately alike: same ELF kernel, same raw ext4, no
# firmware, no init system. It could not tell whether the fabric works for a REAL guest or
# only for a stripped one. Here the guest shares nothing with the microVMs except the
# bridge — different image format, different firmware, different init, 4x the memory — and
# the attachment is still `-netdev tap,ifname=…,script=no`: a pre-made tap, by name, made by
# the same fabric verb. That is the network-attachment row of §18.4's seam table holding at
# the far end of the fidelity axis.
#
# ── AND IT IS THE FIRST RUN THAT EXERCISES APPENDIX L ───────────────────────────────────
#
# `api1` here is booted by `lab-fc.sh` — the slice-4 TOOL — not by a hand-written
# config.json. Every previous slice hand-wrote the MAC, which is exactly why nobody noticed
# that `fabric.sh` and `lab-fc.sh` derived DIFFERENT MACs for the same name for three
# slices (plan L.2). A hand-written config would dodge the seam again. Booting through the
# tool, and then checking that BOTH guests hold their RESERVED addresses, is what turns L's
# fix from "two tools agree in a unit test" into "a guest actually got the lease".
#
# The reserved-lease assertion is the load-bearing one and it is easy to get wrong: a guest
# that misses its reservation still gets AN address from the same /24, so "it has an IP" and
# "it has the right IP" look identical unless you compare against what the fabric recorded.
#
# ⚠️ REAL HOST NETWORKING beside a live microk8s/Calico; same three guards as its siblings.
# A cloud image boots in tens of seconds rather than tens of milliseconds, so the fabric is
# up for MINUTES here — and Calico's autodetection re-runs every 60 s (plan I.4). The
# addressless-tap and `br-` name rules are asserted while the guests are running, not merely
# inferred from a clean teardown.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

WORKDIR="${MC_WORKDIR:-$(mc_workdir)}"
KERNEL="${MC_KERNEL:-$WORKDIR/vmlinux}"
ROOTFS="${MC_ROOTFS:-$WORKDIR/api1.ext4}"
FC_TOOL="$REPO_DIR/phase7-firecracker/lab-fc.sh"
VM_TOOL="$REPO_DIR/phase2-qemu-vm/lab-vm.sh"
SPEC="$LAB_DIR/edge.toml"
EDGE_TIMEOUT="${MC_EDGE_TIMEOUT:-240}"   # a cloud image + cloud-init, not a microVM
FC_BIN="${MC_FIRECRACKER:-$WORKDIR/firecracker}"

[[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root: the fabric creates a bridge, taps and an nft table (CAP_NET_ADMIN)"
need ip nft dnsmasq runuser socat jq
[[ -x "$FABRIC"  ]] || skip "fabric.sh not executable at $FABRIC"
[[ -x "$FC_TOOL" ]] || skip "lab-fc.sh not executable at $FC_TOOL"
[[ -x "$VM_TOOL" ]] || skip "lab-vm.sh not executable at $VM_TOOL"
[[ -r "$SPEC"    ]] || skip "edge.toml not readable at $SPEC"
[[ -r "$KERNEL" && -r "$ROOTFS" ]] || skip "slice 3's kernel/rootfs are not in $WORKDIR"
[[ -x "$FC_BIN" ]] || skip "no firecracker binary at $FC_BIN (set \$MC_FIRECRACKER)"
command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "no qemu-system-x86_64"
[[ -r /dev/kvm && -w /dev/kvm ]] || skip "/dev/kvm not read-write — a cloud image under TCG would take many minutes"

[[ -e /run/mklab-mc/preflight ]] \
    && skip "a fabric is already up — refusing to tear down a lab this test did not create"
ip link show br-mc0 >/dev/null 2>&1 \
    && skip "br-mc0 already exists — refusing to adopt an interface this test did not create"

OWNER="$(stat -c %U "$REPO_DIR")"
[[ -n "$OWNER" && "$OWNER" != root ]] \
    || skip "the repo checkout is owned by '$OWNER' — taps would be root-owned and unusable by an unprivileged VMM"
OWNER_UID="$(id -u "$OWNER")" || skip "cannot resolve uid for '$OWNER'"
export MC_OWNER="$OWNER"

WORK="$(mktemp -d)" || fail "could not create a scratch dir"
chmod 0755 "$WORK"
LOG="$WORK/fabric.log"
FABRIC_UP=0 FC_PID="" CAT_PID="" EDGE_CREATED=0 KEEP=0

_on_exit() {
    local rc=$?
    # Everything BY PID. `pkill -f` on any of these command lines would match the others —
    # they all carry the same workdir path — and once killed a live QEMU and the agent's
    # own shell (exit 144).
    [[ -n "$CAT_PID" ]] && kill "$CAT_PID" 2>/dev/null
    [[ -n "$FC_PID"  ]] && { kill "$FC_PID" 2>/dev/null; wait "$FC_PID" 2>/dev/null; }
    # The VM gets its own lifecycle verb, not a signal — it has a monitor socket, a pidfile
    # and state the tool owns (repo rule: prefer the tool's verb over a raw kill).
    if (( EDGE_CREATED )); then
        runuser -u "$OWNER" -- "$VM_TOOL" stop    edge --force >/dev/null 2>&1
        runuser -u "$OWNER" -- "$VM_TOOL" destroy edge --force >/dev/null 2>&1
    fi
    if (( FABRIC_UP )); then bash "$FABRIC" down >>"$LOG" 2>&1 || true; fi
    if (( KEEP )); then
        printf '\nconsoles and the fabric log kept in: %s\n' "$WORK" >&2
    else
        [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
    fi
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

fab() { local v="$1"; shift; bash "$FABRIC" "$v" "$@" >>"$LOG" 2>&1; }
wait_for() {
    local f="$1" pat="$2" secs="$3" i=0
    while (( i < secs * 10 )); do
        [[ -s "$f" ]] && grep -q -- "$pat" "$f" 2>/dev/null && return 0
        sleep 0.1; i=$((i+1))
    done
    return 1
}

# ── the cached MAC is checked against its subject, BEFORE anything boots ────
# edge.toml carries a MAC copied out of the fabric. That is a cached value, so it gets a
# gate bound to its subject rather than trust: a stale one does not error, it silently
# demotes the guest to a dynamic lease while dnsmasq keeps answering `edge` with the
# reserved address. Refuse before the irreversible step, not after.
SPEC_MAC="$(jq -r '.vm[0].mac // empty' < <(python3 -c '
import tomllib,json,sys; json.dump(tomllib.load(open(sys.argv[1],"rb")),sys.stdout)' "$SPEC"))" \
    || fail "could not read a mac out of $SPEC"
FAB_MAC="$(bash "$FABRIC" mac edge)" || fail "fabric.sh mac edge failed"
[[ -n "$SPEC_MAC" ]] || fail "$SPEC has no mac — the fabric reserves edge's lease against one"
[[ "$SPEC_MAC" == "$FAB_MAC" ]] \
    || fail "REGRESSION: edge.toml's cached MAC is stale — the file says '$SPEC_MAC', the fabric derives '$FAB_MAC'. Booting anyway would take a DYNAMIC lease while dnsmasq answers 'edge' with the reserved address (plan Appendix L)"
note "cached MAC checked against its subject: edge.toml == fabric.sh mac edge == $SPEC_MAC"

# ── THEIRS, recorded independently ─────────────────────────────────────────
CAL_BEFORE="$(calico_binding)"; VETH_BEFORE="$(calico_veths)"
FWD_BEFORE="$(cat /proc/sys/net/ipv4/ip_forward)"
note "before: calico=${CAL_BEFORE:-<absent>} veths=$VETH_BEFORE ip_forward=$FWD_BEFORE"

# ── one fabric, two taps, two very different guests ────────────────────────
fab up || { KEEP=1; cat "$LOG" >&2; fail "fabric up failed: $(tail -1 "$LOG")"; }
FABRIC_UP=1
for n in api1 edge; do
    fab tap "$n" || { KEEP=1; cat "$LOG" >&2; fail "fabric tap $n failed: $(tail -1 "$LOG")"; }
done
# What the fabric RESERVED. Compared against later — this is the difference between
# "the guest has an address" and "the guest has ITS address".
RES_API1="$(sed -n "s/^.*,\\(10\\.71\\.0\\.[0-9]*\\),api1$/\\1/p" /run/mklab-mc/dhcp-hosts)"
RES_EDGE="$(sed -n "s/^.*,\\(10\\.71\\.0\\.[0-9]*\\),edge$/\\1/p" /run/mklab-mc/dhcp-hosts)"
[[ -n "$RES_API1" && -n "$RES_EDGE" ]] \
    || fail "the fabric recorded no reservation for api1 ('$RES_API1') and/or edge ('$RES_EDGE')"
note "fabric reserved: api1=$RES_API1  edge=$RES_EDGE  (both from ONE verb)"

# ── api1, booted BY THE TOOL — the seam Appendix L fixed ───────────────────
# `lab-fc.sh` locates the binary with `command -v firecracker` and offers no flag and no env
# override — deliberately, because its gate is "the PINNED version is installed", and a path
# you can point anywhere is not that gate. The lab's pinned v1.16.1 lives in slice 3's state
# dir, never on PATH, so the tool is run with that dir PREPENDED rather than worked around.
# (First run of this harness failed exactly here: "FAIL firecracker not on PATH" — the tool
# refusing correctly, and the harness never having told it where to look.)
FC_PATH="$(dirname -- "$FC_BIN"):$PATH"
runuser -u "$OWNER" -- env "PATH=$FC_PATH" "$FC_TOOL" create --name api1 \
        --kernel "$KERNEL" --rootfs "$ROOTFS" --tap mc-api1 --lab micro-cloud \
        >"$WORK/fc-create.log" 2>&1 \
    || { KEEP=1; cat "$WORK/fc-create.log" >&2; fail "lab-fc.sh create failed — see above"; }
runuser -u "$OWNER" -- env "PATH=$FC_PATH" "$FC_TOOL" start api1 >"$WORK/fc-start.log" 2>&1 &
FC_PID=$!
note "api1: created and started through lab-fc.sh, not a hand-written config"

# ── edge: the cloud image, through its spec ────────────────────────────────
runuser -u "$OWNER" -- "$VM_TOOL" create --config "$SPEC" >"$WORK/vm-create.log" 2>&1 \
    || { KEEP=1; cat "$WORK/vm-create.log" >&2; fail "lab-vm.sh create --config edge.toml failed — see above"; }
EDGE_CREATED=1
# Read the serial socket with exactly ONE client. A second reader silently steals bytes
# (repo gotcha), so nothing else may attach while this runs — including `lab-vm.sh console`.
runuser -u "$OWNER" -- "$VM_TOOL" start edge >"$WORK/vm-start.log" 2>&1 \
    || { KEEP=1; cat "$WORK/vm-start.log" >&2; fail "lab-vm.sh start edge failed — see above"; }
# ASK the tool where its socket is; do not reconstruct the path. `LAB_STATE_DIR` is
# overridable and the layout is the phase tool's business, not this test's — a path built
# here is a second source of truth that goes stale silently the day the layout moves.
SER="$(runuser -u "$OWNER" -- "$VM_TOOL" inspect edge --json 2>/dev/null | jq -r '.sockets.serial.path // empty')"
[[ -n "$SER" ]] || { KEEP=1; fail "lab-vm.sh inspect did not report a serial socket path for edge"; }
for _ in $(seq 1 100); do [[ -S "$SER" ]] && break; sleep 0.1; done
[[ -S "$SER" ]] || { KEEP=1; fail "edge's serial socket never appeared at $SER"; }
runuser -u "$OWNER" -- socat -u "UNIX-CONNECT:$SER" "CREATE:$WORK/edge.console" &
CAT_PID=$!
note "edge: created from edge.toml and started; one serial reader attached"

# ── the safety property, while a full VM and a microVM are both running ────
for t in mc-api1 mc-edge; do
    a="$(ip -4 -o addr show "$t" 2>/dev/null)"
    [[ "$a" != *inet* ]] \
        || fail "REGRESSION: $t carries an IPv4 ($a) — a Calico first-found candidate, the F.6 mechanism, with two guests live on it"
    got="$(cat "/sys/class/net/$t/owner" 2>/dev/null)"
    [[ "$got" == "$OWNER_UID" ]] || fail "REGRESSION: $t owner uid is '${got:-<unset>}', expected $OWNER_UID"
done
note "taps: addressless and uid-$OWNER_UID owned, with a q35 cloud VM and a microVM attached"

# ── the guest's own report ─────────────────────────────────────────────────
wait_for "$WORK/edge.console" 'EDGE-BEGIN' "$EDGE_TIMEOUT" \
    || { KEEP=1; fail "edge never reached cloud-init's runcmd within ${EDGE_TIMEOUT}s — console: $WORK/edge.console"; }
wait_for "$WORK/edge.console" 'EDGE-END' 120 \
    || { KEEP=1; fail "edge printed EDGE-BEGIN but never EDGE-END — cloud-init stalled mid-runcmd; console: $WORK/edge.console"; }

# THE assertion: it holds the address the fabric RESERVED, not merely an address from the
# pool. A guest that missed its reservation still gets a 10.71.0.x, so a regex for the
# subnet would pass while the whole point had failed.
grep -Fq "$RES_EDGE" "$WORK/edge.console" \
    || { KEEP=1; fail "REGRESSION: edge did not take its RESERVED address $RES_EDGE — it is on the fabric but holding a dynamic lease, so dnsmasq now answers 'edge' with an address nothing holds (plan Appendix L). Console: $WORK/edge.console"; }
note "edge holds its RESERVED lease $RES_EDGE — the MAC in edge.toml reached the guest"

grep -Fq "$RES_API1" "$WORK/edge.console" \
    || { KEEP=1; fail "edge could not resolve api1 to its reserved address $RES_API1 — console: $WORK/edge.console"; }
grep -Fq 'EDGE-PING-BY-NAME OK peer=api1' "$WORK/edge.console" \
    || { KEEP=1; fail "edge resolved api1 but could not reach it — a full-stack q35 guest and a microVM are on one bridge and cannot talk; console: $WORK/edge.console"; }
note "edge resolved api1 -> $RES_API1 and reached it BY NAME, across the fidelity gap"

# ── teardown, and the assertion that caught F.6 ────────────────────────────
[[ -n "$CAT_PID" ]] && { kill "$CAT_PID" 2>/dev/null; CAT_PID=""; }
runuser -u "$OWNER" -- "$VM_TOOL" stop edge --force >/dev/null 2>&1
runuser -u "$OWNER" -- "$VM_TOOL" destroy edge --force >/dev/null 2>&1; EDGE_CREATED=0
[[ -n "$FC_PID" ]] && { kill "$FC_PID" 2>/dev/null; wait "$FC_PID" 2>/dev/null; FC_PID=""; }
runuser -u "$OWNER" -- env "PATH=$FC_PATH" "$FC_TOOL" destroy api1 --force >/dev/null 2>&1

fab down || { KEEP=1; cat "$LOG" >&2; fail "fabric down failed: $(tail -1 "$LOG")"; }
FABRIC_UP=0

ip link show br-mc0 >/dev/null 2>&1 && fail "REGRESSION: br-mc0 survived teardown"
leftover="$(ip -o link show 2>/dev/null | grep -oE 'mc-[a-z0-9-]+' | sort -u | tr '\n' ' ')"
[[ -z "$leftover" ]] || fail "REGRESSION: mc-* taps survived teardown: $leftover"

CAL_AFTER="$(calico_binding)"; VETH_AFTER="$(calico_veths)"
FWD_AFTER="$(cat /proc/sys/net/ipv4/ip_forward)"
[[ "${CAL_AFTER:-<absent>}" == "${CAL_BEFORE:-<absent>}" ]] \
    || fail "REGRESSION: Calico's tunnel MOVED across the run: '${CAL_BEFORE:-<absent>}' -> '${CAL_AFTER:-<absent>}' (plan F.6) — and this run held the fabric up for minutes, across several 60s autodetection polls"
[[ "$VETH_AFTER" == "$VETH_BEFORE" ]] || fail "REGRESSION: cali* veth count moved $VETH_BEFORE -> $VETH_AFTER"
[[ "$FWD_AFTER" == "$FWD_BEFORE" ]]   || fail "REGRESSION: ip_forward moved $FWD_BEFORE -> $FWD_AFTER"
note "teardown: ours all gone; calico binding, pod veth count and ip_forward unchanged"

pass "the fidelity case joins the fabric: a stock cloud image on -M q35 took the lease the fabric RESERVED for it, resolved and reached a Firecracker microVM by name, and the live cluster was untouched"
