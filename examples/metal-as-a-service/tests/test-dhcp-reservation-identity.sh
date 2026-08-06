#!/usr/bin/env bash
# Verdict: a node's DHCP reservation is keyed on its MAC and nothing else — a client
# that sends no hostname, the wrong hostname, or a client-identifier still gets the
# reserved address, and only a MAC the reservation does not name falls to the pool.
#
# WHY THIS EXISTS. DEFERRED.md carried an explanation for a live observation — the
# deployer ramdisk on node2 came up on 192.168.123.31 while node2's reservation is
# .102 — that said dnsmasq "keys the reservation on the DHCP hostname/MAC pair and
# the ramdisk sends no hostname, so it lands in the dynamic range", with a fix shape
# of `udhcpc -x hostname:$node`. That explanation was never measured. It is wrong:
# §2 below sends dnsmasq a DISCOVER with no option 12 at all and gets the reservation.
#
# A wrong diagnosis is worse than an open question, because it retires the question.
# So the mechanism is pinned here, by a real dnsmasq answering real packets, and the
# row that actually reproduces a pool address — §4, a MAC the reservation does not
# name — is the one that says where to look when this recurs.
#
# It all happens inside a throwaway user+network namespace, so it is rootless and
# cannot touch the host's networking, the fleet, or libvirt.
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need python3

DNSMASQ="${DNSMASQ:-dnsmasq}"
have "$DNSMASQ" || DNSMASQ=/usr/sbin/dnsmasq
command -v "$DNSMASQ" >/dev/null || skip "dnsmasq is not installed — the DHCP behaviour cannot be exercised"
command -v unshare >/dev/null || skip "unshare is not available — no rootless network namespace"

SANDBOX="$(mktemp -d)"
# shellcheck disable=SC2154
trap '_rc=$?; rm -rf "$SANDBOX"; [[ $_rc == 0 || $_rc == 77 ]] || printf "FAIL: test exited early (rc=%s)\n" "$_rc" >&2' EXIT

# dnsmasq needs NET_ADMIN and drops privileges on the way up. An unprivileged
# `unshare -rn` gives the first but denies setgroups(), so the drop fails; --map-auto
# maps the /etc/subuid range through newuidmap, which sets setgroups=allow.
unshare -rn --map-auto -- true 2>/dev/null \
    || skip "unprivileged user+network namespaces with subuid mapping are unavailable
  (needs /etc/subuid + newuidmap; dnsmasq cannot start without NET_ADMIN)"

PROBE="$TEST_DIR/dhcp-id-probe.py"
RES_MAC="52:54:00:aa:bb:cc"     # the reserved node
OTH_MAC="52:54:00:de:ad:01"     # a MAC no reservation names
RES_IP="127.0.0.102"
POOL_LO=10 POOL_HI=99           # 127.0.0.10 - 127.0.0.99, mirroring the fleet's .10-.99

# ── 1. the fixture reproduces the reservation create-fleet.sh actually writes ──
# libvirt renders each <host mac name ip> into its generated hostsfile as
# `mac,ip,name` (verified against /var/lib/libvirt/dnsmasq/<net>.hostsfile on a live
# fleet) and points dnsmasq at it with dhcp-hostsfile. If create-fleet.sh ever stops
# writing all three attributes, this test's subject is no longer the real one.
FLEET="$LAB_DIR/create-fleet.sh"
if [[ -f "$FLEET" ]]; then
    HOSTLINE="$(grep -o "<host mac='[^>]*/>" "$FLEET" | head -1)"
    [[ -n "$HOSTLINE" ]] \
        || fail "create-fleet.sh no longer writes a <host mac=.../> reservation — this test reproduces a shape the lab has stopped using"
    for attr in "mac='" "name='" "ip='"; do
        grep -q "$attr" <<<"$HOSTLINE" \
            || fail "create-fleet.sh's reservation no longer carries $attr — the hostsfile line this test builds (mac,ip,name) is no longer what libvirt would render"
    done
    note "create-fleet.sh still reserves with mac+name+ip: $HOSTLINE  ✓"
else
    note "create-fleet.sh not found — testing the dnsmasq mechanism only"
fi

printf '%s,%s,node2\n' "$RES_MAC" "$RES_IP" > "$SANDBOX/hostsfile"
# dnsmasq drops privileges and then reads dhcp-hostsfile as `nobody`, which cannot
# traverse a 0700 mktemp directory. It does not refuse: it logs `cannot read ...:
# Permission denied` and serves the POOL to every client — which looks exactly like
# "the reservation does not work" and cost this test one debugging round. §2 fails by
# name on that log line rather than reporting it as a finding about dnsmasq.
chmod 755 "$SANDBOX"; chmod 644 "$SANDBOX/hostsfile"

cat > "$SANDBOX/conf" <<EOF
port=0
bind-interfaces
interface=lo
dhcp-alternate-port=1067,1068
dhcp-range=127.0.0.$POOL_LO,127.0.0.$POOL_HI,1h
dhcp-hostsfile=$SANDBOX/hostsfile
log-dhcp
EOF

# addresses <tag> <probe...> -> `label=address` lines from a real dnsmasq in a netns.
# One invocation = one server with its own lease file, so rows that must not see each
# other's leases go in separate calls and rows that must, share one.
addresses() {
    local tag="$1"; shift
    local args="" p
    for p in "$@"; do args+=" --probe '$p'"; done   # specs are label,mac,option text — no quoting hazard
    unshare -rn --map-auto -- sh -c "
        ip link set lo up || exit 3
        '$DNSMASQ' --conf-file='$SANDBOX/conf' --pid-file='$SANDBOX/$tag.pid' \
            --dhcp-leasefile='$SANDBOX/$tag.leases' --log-facility='$SANDBOX/$tag.log' \
            --no-hosts --no-resolv || exit 4
        sleep 1
        python3 '$PROBE'$args
    " 2>>"$SANDBOX/$tag.stderr"
}
got() { printf '%s\n' "$1" | sed -nE "s/^$2=(.*)$/\1/p"; }

# in_pool <addr> — is this an address from the dynamic range?
in_pool() {
    local a="$1" last
    [[ "$a" =~ ^127\.0\.0\.([0-9]+)$ ]] || return 1
    last="${BASH_REMATCH[1]}"
    (( last >= POOL_LO && last <= POOL_HI ))
}

# ── 2. identity does not move the reservation ──────────────────────────────
OUT="$(addresses ident \
    "mac-only,$RES_MAC,none,none,discover" \
    "with-hostname,$RES_MAC,none,node2,discover" \
    "wrong-hostname,$RES_MAC,none,somebody-else,discover" \
    "with-clid,$RES_MAC,self,none,discover" \
    "unreserved,$OTH_MAC,none,none,discover")"
[[ -n "$OUT" ]] \
    || fail "no reply from dnsmasq at all — the harness is broken, not the config. stderr: $(tr '\n' ' ' < "$SANDBOX/ident.stderr" | tail -c 300)"
grep -q '=NO-OFFER' <<<"$OUT" \
    && fail "dnsmasq declined to answer one or more probes: $(tr '\n' ' ' <<<"$OUT")"
grep -q 'cannot read .*hostsfile' "$SANDBOX/ident.log" 2>/dev/null \
    && fail "dnsmasq could not read the harness's own hostsfile, started anyway, and served the pool to everything — a broken harness, not a finding about reservations: $(grep -m1 'cannot read' "$SANDBOX/ident.log")"

[[ "$(got "$OUT" mac-only)" == "$RES_IP" ]] \
    || fail "a client sending NO hostname was given $(got "$OUT" mac-only), not its reservation $RES_IP. This is the exact claim DEFERRED.md recorded as the cause of the deployer's pool address; if it now holds, the reservation mechanism has changed and reserve_dhcp needs revisiting"
[[ "$(got "$OUT" with-hostname)" == "$RES_IP" ]] \
    || fail "a client sending its own hostname was given $(got "$OUT" with-hostname), not $RES_IP"
[[ "$(got "$OUT" wrong-hostname)" == "$RES_IP" ]] \
    || fail "a client claiming SOMEBODY ELSE'S hostname was given $(got "$OUT" wrong-hostname), not $RES_IP — the reservation would be steerable by a name the client chooses"
[[ "$(got "$OUT" with-clid)" == "$RES_IP" ]] \
    || fail "a client sending a client-identifier (option 61, what busybox udhcpc sends by default) was given $(got "$OUT" with-clid), not $RES_IP"
note "no hostname / own hostname / wrong hostname / client-id — all get $RES_IP  ✓"

# ── 3. and neither does the order two identities arrive in ─────────────────
# The remaining plausible mechanism: one identity commits the reserved lease and the
# other is then refused it. iPXE and the kernel's ip=dhcp are not the same client.
SEQ1="$(addresses seq1 \
    "first-clid,$RES_MAC,self,none,lease" \
    "then-mac-only,$RES_MAC,none,none,discover")"
SEQ2="$(addresses seq2 \
    "first-mac-only,$RES_MAC,none,none,lease" \
    "then-clid,$RES_MAC,self,none,discover")"
[[ "$(got "$SEQ1" first-clid)" == "$RES_IP" && "$(got "$SEQ1" then-mac-only)" == "$RES_IP" ]] \
    || fail "after a client-id client COMMITTED $RES_IP, the same MAC without a client-id got $(got "$SEQ1" then-mac-only) — a two-identity boot chain (iPXE then the kernel) would change address mid-deploy"
[[ "$(got "$SEQ2" first-mac-only)" == "$RES_IP" && "$(got "$SEQ2" then-clid)" == "$RES_IP" ]] \
    || fail "after a MAC-only client COMMITTED $RES_IP, the same MAC WITH a client-id got $(got "$SEQ2" then-clid) — the deployer would leave the reserved address behind"
note "either identity may hold the lease first; the other still gets $RES_IP  ✓"

# ── 4. THE CONTROL — what a pool address actually means ────────────────────
# Two jobs. It proves the pool is reachable and the assertions above are not simply
# reading a server that answers $RES_IP to everything (an all-$RES_IP matrix would
# pass §2 and §3 while checking nothing). And it names the one input that does
# reproduce the live symptom: a MAC the reservation does not name.
UNRES="$(got "$OUT" unreserved)"
in_pool "$UNRES" \
    || fail "a MAC with NO reservation was given $UNRES, which is not in the dynamic range 127.0.0.$POOL_LO-$POOL_HI. Either the pool is unreachable — in which case sections 2 and 3 proved nothing, since every answer would be $RES_IP regardless — or dnsmasq is reserving for a MAC it was never told about"
[[ "$UNRES" != "$RES_IP" ]] \
    || fail "an unreserved MAC was given the reserved address $RES_IP — the reservation is not MAC-keyed at all and every assertion above is vacuous"
note "a MAC the reservation does not name falls to the pool ($UNRES) — the ONLY input here that reproduces one  ✓"

pass "a node's DHCP reservation is keyed on its MAC alone: no hostname, the wrong hostname, a client-identifier and either lease order all still yield $RES_IP, and only an unnamed MAC falls to the dynamic pool ($UNRES). The deployer's pool address is therefore a MAC that the reservation did not name, not a missing option 12 — measured against $($DNSMASQ --version 2>/dev/null | head -1)"
