#!/usr/bin/env bash
# Exhaust the DHCP pool on purpose, at BOTH layers, and grade how the fabric falls.
#
# §14's break pass for slice 3 lists "exhaust the DHCP pool". It was deferred in
# [G.9] because `.100–.200` is 101 leases — nobody was going to fill that by hand — and
# the deferral was then restated four times as "needs a host without a live cluster",
# which was never true of THIS scenario (plan M.7). Exhausting our own dnsmasq's pool on
# our own bridge reaches nothing Calico owns. The only obstacle was that DHCP_LO/DHCP_HI
# were bare assignments; they are now MC_DHCP_LO/MC_DHCP_HI, and a four-address pool
# fills in seconds.
#
# ── THE POINT IS NOT "IT RUNS OUT". IT IS *HOW* IT RUNS OUT ────────────────────────────
#
# Running out of addresses is not a bug; it is arithmetic. The question CLAUDE.md's chaos
# ladder asks is whether the fabric, on running out, ABSORBS (refuses before doing harm),
# HALTS honestly (says so, by name, recoverably), or LIES (reports success while the
# guest holds nothing, or hands out an address the server will not answer for). This
# fabric can run out at TWO independent layers, and they fail differently:
#
#   layer 1 — RESERVATION time, our code. `fabric.sh tap <name>` derives the next address
#             from the pool. Before this slice it computed `10.71.0.$((100 + IDX))` with
#             the base hard-coded, so a shrunken pool would march reservations straight
#             out of the range — dnsmasq would then never answer for them, and the tap
#             would be created anyway. Silent, and exactly bug class #1.
#
#   layer 2 — LEASE time, dnsmasq. A guest with no reservation asks and there is nothing
#             left to give.
#
# ── THE ASSERTION THAT ACTUALLY MATTERS, AND ITS BUILT-IN CONTROL ──────────────────────
#
# Slice 5b established that a guest holding *an* address in the right subnet proves
# nothing — the load-bearing property is that it holds the address the fabric RESERVED.
# So the question here is the inverse: with the dynamic pool completely full, does a
# reserved instance still get ITS address?
#
#   - a client with a RESERVED MAC must get exactly its reserved address   → ABSORBED
#   - a client with an UNRESERVED MAC, at the same instant, must get nothing → HALTED
#
# The second is the negative control for the first, and it is taken from the *same*
# exhausted state. Without it, "the reserved client got an address" is indistinguishable
# from "the pool was never actually full", and this test would be the all-PASS matrix
# that checks nothing.
#
# ── HOW THE CLIENTS ARE MADE, AND WHY IT IS SAFE BESIDE A LIVE CLUSTER ─────────────────
#
# No VMs. Each fake guest is a veth pair: the host end is enslaved to br-mc0 and stays
# ADDRESSLESS; the far end is moved into its own network namespace, given a MAC, and runs
# a real `busybox udhcpc`. Two properties follow, and both are the reason this can run
# here at all:
#
#   - the leased IPv4 lands on an interface INSIDE a namespace, so the host never sees an
#     addressed interface appear. Calico's first-found autodetection — which runs on a
#     60-second poll (plan I.4), not only at restart — cannot consider what it cannot see.
#     This is F.7.1 rule 2 satisfied by construction rather than by naming discipline.
#   - a real DHCP client speaks the real protocol. A hand-rolled DISCOVER would test the
#     harness's idea of DHCP; udhcpc is what a busybox guest actually runs.
#
# G.9 said as much: "dummy interfaces and the guest's own DHCP clients suffice, so the
# experiment does not depend on nested virt being enabled."
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

BR=br-mc0   # matches fabric.sh rule 1; the round-trip test names it the same way

[[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root: the fabric creates a bridge, taps and an nft table, and this test adds veths and netns (CAP_NET_ADMIN)"
need ip nft dnsmasq busybox
busybox udhcpc --help 2>&1 | grep -qi 'udhcpc' || skip "this busybox has no udhcpc applet — the DHCP client is the instrument, not an implementation detail"
[[ -x "$FABRIC" ]] || skip "fabric.sh not executable at $FABRIC"

# Refuse to adopt or destroy a fabric this test did not create (round-trip's guard 2).
[[ -e /run/mklab-mc/preflight ]] \
    && skip "a fabric is already up (/run/mklab-mc/preflight exists) — refusing to tear down a lab this test did not create; run 'fabric.sh down' first if it is stale"
ip link show "$BR" >/dev/null 2>&1 \
    && skip "$BR already exists — refusing to adopt an interface this test did not create"

OWNER="$(stat -c %U "$REPO_DIR")"
[[ -n "$OWNER" && "$OWNER" != root ]] \
    || skip "the repo checkout is owned by '$OWNER' — taps would be root-owned and unusable by an unprivileged VMM"
export MC_OWNER="$OWNER"

# ── the pool, deliberately tiny ────────────────────────────────────────────
# .100–.104 is five addresses. `tap` reserves from DHCP_LO+1 upward, so four are
# reservable (.101–.104) and exactly ONE (.100) is left for dynamic clients. That single
# dynamic address is what makes lease-time exhaustion cost two client runs instead of a
# hundred.
export MC_DHCP_LO=10.71.0.100
export MC_DHCP_HI=10.71.0.104
POOL_LO_OCT=100
RESERVABLE=4          # .101 .102 .103 .104
DYNAMIC_ADDR=10.71.0.100

WORK="$(mktemp -d)"; LOG="$WORK/log"
FABRIC_UP=0
CLIENTS=()

# reap_clients — remove every veth/netns this test made.
#
# CALLED FROM THE BODY BEFORE `down`, NOT ONLY FROM THE TRAP. The first root run
# (2026-08-06) failed here, and the fabric was right: `down` asserts that no `mc-*`
# interface survives, the fake clients are named `mc-cli1..3`, and the trap that reaped
# them ran AFTER the explicit `down`. So `down` correctly reported three leftovers this
# test had leaked onto the bridge.
#
# The naming stays. Calling them `mc-cli*` is what put them inside the namespace `down`
# polices, and the alternative — a name teardown ignores — would have leaked them silently
# on every run. §7.2's "teardown is a test, not a cleanup" caught its author on the first
# real exercise, which is the strongest argument for the assertion existing.
reap_clients() {
    local c ns hv
    for c in "${CLIENTS[@]}"; do
        ns="mcns$c"; hv="mc-cli$c"
        ip netns del "$ns" >/dev/null 2>&1 || true
        ip link del "$hv" >/dev/null 2>&1 || true
    done
    CLIENTS=()
    # Then DERIVE, and reap anything the bookkeeping missed. The in-memory list is a
    # cached fact about what we made; the kernel is the fact. This second pass is what
    # would have caught the subshell bug above on its own, and it also cleans up after a
    # run that died before it could record anything.
    while read -r hv; do
        [[ -n "$hv" ]] && ip link del "$hv" >/dev/null 2>&1 || true
    done < <(ip -o link show 2>/dev/null | grep -oE 'mc-cli[0-9]+' | sort -u)
    while read -r ns; do
        [[ -n "$ns" ]] && ip netns del "$ns" >/dev/null 2>&1 || true
    done < <(ip netns list 2>/dev/null | grep -oE '^mcns[0-9]+' | sort -u)
}

_cleanup() {
    reap_clients
    if (( FABRIC_UP )); then bash "$FABRIC" down >>"$LOG" 2>&1 || true; fi
    # KEEP the scratch dir on ANY failure, not only a verdict-less one. The first run
    # printed `FAIL: ... see /tmp/tmp.XXXX/log` and then deleted that very directory on
    # the way out — a failure message naming a file the trap had just removed. The reader
    # is sent to diagnose a run whose evidence the harness destroyed.
    if (( _EXIT_RC != 0 && _EXIT_RC != 77 )); then
        printf '  (evidence kept: %s)\n' "$LOG" >&2
        return
    fi
    rm -rf "$WORK"
}
on_exit '_cleanup'

fab() { local v="$1"; shift; bash "$FABRIC" "$v" "$@" >>"$LOG" 2>&1; }

# udhcpc hands the lease to a script; the script is how a lease becomes observable.
cat > "$WORK/udhcpc.script" <<'SCRIPT'
#!/bin/sh
# $1 is deconfig|bound|renew|nak; $ip is set by udhcpc on bound/renew.
case "$1" in
    bound|renew) printf '%s\n' "$ip" > "$LEASEOUT" ;;
esac
exit 0
SCRIPT
chmod +x "$WORK/udhcpc.script"

# dhcp_ask <id> <mac> — run one real DHCP client. Sets $LEASE to the address it got, or "".
#
# IT SETS A GLOBAL RATHER THAN PRINTING, AND THAT IS THE WHOLE POINT.
#
# The first version printed the lease and was called as `got1="$(dhcp_ask 1 …)"`. A command
# substitution is a SUBSHELL, so its `CLIENTS+=("$id")` appended to a copy that died with
# it: the parent's array stayed EMPTY, the EXIT trap iterated over nothing, and three live
# veths were left on br-mc0. Found on the first root run (2026-08-06) — `fabric.sh down`
# reported the leftovers and was right to.
#
# So the bookkeeping cannot live behind a subshell. `reap_clients` also DERIVES the list
# from the kernel for the same reason: an in-memory list of what we made is a cached fact,
# and a crashed run leaves no bookkeeping at all.
LEASE=""
dhcp_ask() {
    local id="$1" mac="$2"
    # Separate `local`s: within ONE `local`, the names being declared are not reliably
    # visible to the expansions beside them, so `ns="mcns$id"` could read an outer `id`.
    local ns="mcns$id" hv="mc-cli$id" gv="cli$id" out="$WORK/lease.$id"
    LEASE=""
    CLIENTS+=("$id")
    : > "$out"
    ip link add "$hv" type veth peer name "$gv" >>"$LOG" 2>&1 || { LEASE="VETH-FAIL"; return; }
    ip link set "$hv" master "$BR" up          >>"$LOG" 2>&1 || { LEASE="ENSLAVE-FAIL"; return; }
    ip netns add "$ns"                          >>"$LOG" 2>&1 || { LEASE="NETNS-FAIL"; return; }
    ip link set "$gv" netns "$ns"               >>"$LOG" 2>&1 || { LEASE="MOVE-FAIL"; return; }
    ip netns exec "$ns" ip link set lo up       >>"$LOG" 2>&1
    ip netns exec "$ns" ip link set "$gv" address "$mac" >>"$LOG" 2>&1 || { LEASE="MAC-FAIL"; return; }
    ip netns exec "$ns" ip link set "$gv" up    >>"$LOG" 2>&1 || { LEASE="UP-FAIL"; return; }
    # -n: exit rather than fork into the background when no lease arrives. -t/-T bound the
    # wait so a refusal costs seconds, not a timeout the reader mistakes for a hang.
    ip netns exec "$ns" env LEASEOUT="$out" \
        busybox udhcpc -i "$gv" -f -q -n -t 3 -T 2 -s "$WORK/udhcpc.script" >>"$LOG" 2>&1 || true
    LEASE="$(tr -d '[:space:]' < "$out")"
}

# ── record THEIRS before touching anything ─────────────────────────────────
CAL_BEFORE="$(calico_binding)"; VETH_BEFORE="$(calico_veths)"

fab up || fail "fabric.sh up failed with the shrunken pool $MC_DHCP_LO-$MC_DHCP_HI — see $LOG"
FABRIC_UP=1
# Confirm the override REACHED dnsmasq, from dnsmasq's own cmdline. Without this the whole
# test could run against the default 101-address pool: nothing would exhaust, every
# assertion below would be measuring something else, and the run would still look busy.
# (`-a` because /proc/<pid>/cmdline is NUL-separated and grep otherwise treats it as binary.)
DPID="$(sed -n 's/^dnsmasq_pid=//p' /run/mklab-mc/preflight 2>/dev/null)"
[[ -n "$DPID" && -d "/proc/$DPID" ]] \
    || fail "fabric.sh up recorded no live dnsmasq pid — cannot confirm which pool is actually being served"
grep -qa -- "--dhcp-range=$MC_DHCP_LO,$MC_DHCP_HI" "/proc/$DPID/cmdline" \
    || fail "dnsmasq (pid $DPID) is not serving the pool this test asked for — MC_DHCP_LO/MC_DHCP_HI did not reach the --dhcp-range flag, so every assertion below would be measuring the DEFAULT 101-address pool"
note "fabric up with a deliberately tiny pool: $MC_DHCP_LO-$MC_DHCP_HI (dnsmasq's own cmdline confirms it)"

# ── 1. LAYER 1: reservation-time exhaustion is refused, by name, before the tap ────
RESERVED_IPS=()
for i in $(seq 1 "$RESERVABLE"); do
    fab tap "r$i" || fail "fabric.sh tap r$i failed while the pool still had room — see $LOG"
    ip="$(sed -n "s/^.*,\(.*\),r$i\$/\1/p" /run/mklab-mc/dhcp-hosts)"
    [[ -n "$ip" ]] || fail "tap r$i wrote no dhcp-hosts entry"
    RESERVED_IPS+=("$ip")
done
note "reservations: ${RESERVED_IPS[*]} — $RESERVABLE of them, filling .$((POOL_LO_OCT+1))-.${MC_DHCP_HI##*.}"

# Every reserved address must be INSIDE the pool. This is the assertion that would have
# caught the hard-coded `100 + IDX`: with a pool starting anywhere but .100, that formula
# produced addresses dnsmasq was never told to serve, and the tap was created anyway.
for ip in "${RESERVED_IPS[@]}"; do
    o="${ip##*.}"
    (( o > POOL_LO_OCT && o <= ${MC_DHCP_HI##*.} )) \
        || fail "REGRESSION: reservation $ip falls OUTSIDE the pool $MC_DHCP_LO-$MC_DHCP_HI — dnsmasq will never answer for it, and the tap was created anyway. The reservation base must derive from DHCP_LO, not from a hard-coded 100"
done
note "every reservation lands inside the pool — the base is derived from DHCP_LO, not assumed"

# `die` is an exit, so the refusal goes in a subshell or it takes this test with it.
if ( bash "$FABRIC" tap "r$((RESERVABLE+1))" >"$WORK/overflow.out" 2>&1 ); then
    fail "REGRESSION: 'tap r$((RESERVABLE+1))' SUCCEEDED with the pool full — it must refuse. Either it handed out an address outside $MC_DHCP_LO-$MC_DHCP_HI (which dnsmasq will not answer for) or it reused one. Output: $(head -c 300 "$WORK/overflow.out")"
fi
grep -qi 'DHCP pool exhausted' "$WORK/overflow.out" \
    || fail "'tap' refused the $((RESERVABLE+1))th reservation, but not by naming pool exhaustion — an operator cannot act on an unexplained refusal. Got: $(head -c 300 "$WORK/overflow.out")"
ip link show "mc-r$((RESERVABLE+1))" >/dev/null 2>&1 \
    && fail "REGRESSION: 'tap' refused but LEFT THE TAP mc-r$((RESERVABLE+1)) behind — a gate after the act is a post-mortem; a half-made instance nobody refuses is worse than none"
note "layer 1 ABSORBED: the $((RESERVABLE+1))th reservation is refused by name, before the tap exists"

# ── 2. LAYER 2: the one dynamic address is handed out ──────────────────────
# MACs for the unreserved clients use 06:00:ac:48:.. — fabric.sh derives 06:00:ac:47:..
# from md5(name), so a collision with a real reservation is impossible by construction
# rather than by luck.
dhcp_ask 1 06:00:ac:48:00:01; got1="$LEASE"
[[ "$got1" == "$DYNAMIC_ADDR" ]] \
    || fail "the first unreserved client got '${got1:-<nothing>}', expected the pool's one free address $DYNAMIC_ADDR — if it got a RESERVED address instead, dnsmasq is handing out addresses promised to named instances (the silent failure slice 5b's reserved-lease assertion exists to catch)"
note "layer 2: the single dynamic address $DYNAMIC_ADDR went to the first unreserved client"

# ── 3. the pool is now empty, and the next client is refused HONESTLY ──────
dhcp_ask 2 06:00:ac:48:00:02; got2="$LEASE"
[[ -z "$got2" ]] \
    || fail "REGRESSION: a second unreserved client got '$got2' from an exhausted pool. Either dnsmasq reused a live lease, or it handed out a RESERVED address — both mean an instance that boots later finds its address already taken, with nothing reporting a conflict"
note "layer 2 HALTED (honest): the second unreserved client got no lease at all — no address, no half-configured interface"

# ── 4. THE ONE THAT MATTERS: a reserved instance still gets ITS address ────
# Assertion 3 is this one's control: it proves the pool really is exhausted, taken from
# the same state, moments earlier. Without it a success here means nothing.
RESV_MAC="$(bash "$FABRIC" mac r1)" || fail "could not ask the fabric for r1's MAC"
dhcp_ask 3 "$RESV_MAC"; got3="$LEASE"
[[ -n "$got3" ]] \
    || fail "REGRESSION: the reserved instance r1 ($RESV_MAC) got NO lease from a pool whose dynamic half is exhausted — a reservation that does not survive exhaustion is not a reservation, and an instance that boots into a busy fabric would silently never come up"
[[ "$got3" == "${RESERVED_IPS[0]}" ]] \
    || fail "REGRESSION: r1 got '$got3' but the fabric RESERVED ${RESERVED_IPS[0]} — it holds an address dnsmasq is not answering for, while the name r1 still resolves to ${RESERVED_IPS[0]}. This is the plan's bug class #1: a record that outlives its subject, and it is invisible from either side alone"
note "layer 2 ABSORBED: with the dynamic pool empty, r1 still received its RESERVED ${RESERVED_IPS[0]}"

# ── 5. and none of this made the host grow a Calico candidate ──────────────
# The leases live inside network namespaces. If any host-side veth has an IPv4 the
# construction has failed and this test has been re-arming F.6 while claiming to be safe.
for c in "${CLIENTS[@]}"; do
    a="$(ip -4 -o addr show "mc-cli$c" 2>/dev/null || true)"
    [[ "$a" == *inet* ]] \
        && fail "REGRESSION: host-side veth mc-cli$c carries an IPv4 ($a) — an addressed host interface is a Calico first-found candidate (F.7.1 rule 2). The lease must land inside the namespace, never on the host"
done
note "safety: every leased address stayed inside its namespace — no host interface gained an IPv4"

# ── 6. teardown compares THEIRS, independently of fabric.sh's own comparison ──
# Reap the clients FIRST. They are real interfaces on br-mc0 in the `mc-*` namespace that
# `down` polices, so leaving them up makes `down` fail — correctly. (It did, on the first
# root run.) An assertion about the fabric must not be run through artifacts the test
# itself leaked.
reap_clients
leftover="$(ip -o link show | grep -oE 'mc-cli[0-9]+' | sort -u | tr '\n' ' ')"
[[ -z "$leftover" ]] \
    || fail "this test's own fake clients survived reap_clients: $leftover — 'down' would blame the fabric for the harness"
note "clients reaped before teardown — nothing of this test's left in the mc-* namespace"

fab down || fail "fabric.sh down reported failure — evidence kept at $LOG"
FABRIC_UP=0
CAL_AFTER="$(calico_binding)"; VETH_AFTER="$(calico_veths)"
[[ "$CAL_AFTER" == "$CAL_BEFORE" ]] \
    || fail "calico tunnel MOVED across this test: '$CAL_BEFORE' -> '$CAL_AFTER'"
[[ "$VETH_AFTER" == "$VETH_BEFORE" ]] \
    || fail "cali* veth count moved $VETH_BEFORE -> $VETH_AFTER — pods were recreated"
note "teardown: calico binding and pod veth count unchanged"

pass "the DHCP pool exhausts honestly at both layers — reservations are refused by name before a tap exists, an unreserved client gets nothing rather than a bad address, and a RESERVED instance still receives its own address from an exhausted pool"
