#!/usr/bin/env bash
# fabric.sh survives a full round trip on a real host, and gives everything back.
#
#   up → tap api1 → tap api2 → status → down
#
# Nothing is booted; this is the fabric alone. It began life as a ONE-SHOT that answered a
# single question on 2026-08-04 — *does the instrument still work now that Calico moved to
# the physical uplink?* (plan I.7). Landed here so the answer is re-derivable instead of
# being a paragraph about a script nobody has, which is precisely how slice 3's `fabric.sh`
# was nearly lost (plan §18.1).
#
# ⚠️ THIS TEST TOUCHES REAL HOST NETWORKING, beside a live microk8s/Calico. That is the
# whole point — the property under test is coexistence — but it changes what the file owes
# a reader. A one-shot could assume the operator knew the host's state. A test in a
# repository cannot, so it gains three guards the one-shot did not have:
#
#   1. not root                      → SKIP, never FAIL (CI runs unprivileged)
#   2. a fabric is ALREADY up        → SKIP, and touch nothing. Otherwise this test's
#                                      teardown would destroy a lab somebody is using.
#   3. the repo is owned by root     → SKIP: taps would be created root-owned and an
#                                      unprivileged Firecracker gets EPERM from TUNSETIFF
#                                      (the 2026-08-02 defect, plan G.4)
#
# TEARDOWN RUNS FROM THE EXIT TRAP, not from the happy path. `fail` is an exit, so a failed
# assertion would otherwise leave a bridge, two taps, an nft table and a dnsmasq behind on
# a live host — and a leaked 10.71.0.1 quietly breaks the next lab (plan §7.2).
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root: the fabric creates a bridge, taps and an nft table (CAP_NET_ADMIN)"
need ip nft dnsmasq
[[ -x "$FABRIC" ]] || skip "fabric.sh not executable at $FABRIC"

# Guard 2 — refuse to adopt or destroy a fabric we did not create.
[[ -e /run/mklab-mc/preflight ]] \
    && skip "a fabric is already up (/run/mklab-mc/preflight exists) — refusing to tear down a lab this test did not create; run 'fabric.sh down' first if it is stale"
ip link show br-mc0 >/dev/null 2>&1 \
    && skip "br-mc0 already exists — refusing to adopt an interface this test did not create"

# Guard 3 — derive the tap owner. `${SUDO_USER}` is 'root' when sudo runs from a root
# shell, which is the defect that produced an unopenable tap; the repo's owner is the user
# the VMM will actually run as.
OWNER="$(stat -c %U "$REPO_DIR")"
[[ -n "$OWNER" && "$OWNER" != root ]] \
    || skip "the repo checkout is owned by '$OWNER' — taps would be root-owned and unusable by an unprivileged VMM"
OWNER_UID="$(id -u "$OWNER")" || skip "cannot resolve uid for '$OWNER'"
export MC_OWNER="$OWNER"

LOG="$(mktemp)"
FABRIC_UP=0
_cleanup() {
    # Teardown ALWAYS, and before the verdict net, so a failed assertion cannot leak a
    # bridge onto a live host. Best-effort: its own assertions already ran if we got here
    # through the happy path.
    if (( FABRIC_UP )); then bash "$FABRIC" down >>"$LOG" 2>&1 || true; fi
    rm -f "$LOG"
}
on_exit '_cleanup'

# Run a fabric verb without letting a pipe decide the exit status (house rule).
fab() { local v="$1"; shift; bash "$FABRIC" "$v" "$@" >>"$LOG" 2>&1; }

# ── record THEIRS independently, before we touch anything ───────────────────
# fabric.sh's own `down` compares these too. Capturing them here as well is deliberate:
# if that comparison ever regresses, a test that only trusted it would go on passing.
CAL_BEFORE="$(calico_binding)"; VETH_BEFORE="$(calico_veths)"
FWD_BEFORE="$(cat /proc/sys/net/ipv4/ip_forward)"
note "before: calico=${CAL_BEFORE:-<absent>} veths=$VETH_BEFORE ip_forward=$FWD_BEFORE"

# ── up ──────────────────────────────────────────────────────────────────────
fab up || { cat "$LOG" >&2; fail "fabric up failed: $(tail -1 "$LOG")"; }
FABRIC_UP=1

ip link show br-mc0 >/dev/null 2>&1 || fail "up reported success but br-mc0 does not exist"
[[ "$(ip -4 -o addr show br-mc0)" == *10.71.0.1/24* ]] \
    || fail "br-mc0 does not carry the gateway address 10.71.0.1/24"
nft list table ip mklab-mc >/dev/null 2>&1 || fail "up reported success but the nft table mklab-mc is absent"
DPID="$(sed -n 's/^dnsmasq_pid=//p' /run/mklab-mc/preflight)"
[[ -n "$DPID" && -d "/proc/$DPID" ]] || fail "dnsmasq is not running after up (recorded pid '${DPID:-<none>}')"
note "up: br-mc0 + 10.71.0.1/24 + nft mklab-mc + dnsmasq $DPID"

# ── taps ────────────────────────────────────────────────────────────────────
for n in api1 api2; do
    fab tap "$n" || { cat "$LOG" >&2; fail "fabric tap $n failed: $(tail -1 "$LOG")"; }
done

# The property slice 3 exists to protect, asserted while the fabric is UP rather than only
# inferred from a clean teardown: a tap with an IPv4 is a Calico first-found candidate,
# and that is the F.6 outage mechanism.
found=0
for p in /sys/class/net/mc-*; do
    [[ -e "$p" ]] || continue
    t="$(basename "$p")"; found=$((found+1))
    a="$(ip -4 -o addr show "$t" 2>/dev/null)"
    [[ "$a" != *inet* ]] \
        || fail "REGRESSION: $t carries an IPv4 ($a) — that makes it a Calico first-found candidate, the F.6 mechanism"
    got="$(cat "/sys/class/net/$t/owner" 2>/dev/null)"
    [[ "$got" == "$OWNER_UID" ]] \
        || fail "REGRESSION: $t owner uid is '${got:-<unset>}', expected $OWNER_UID ($OWNER) — an unprivileged VMM would get EPERM from TUNSETIFF"
done
(( found == 2 )) || fail "expected 2 mc-* taps after two 'tap' calls, found $found"
[[ "$(ip -o link show master br-mc0 2>/dev/null | grep -c 'mc-')" == 2 ]] \
    || fail "the taps exist but are not enslaved to br-mc0"
note "taps: 2 created, both addressless, both owned by uid $OWNER_UID, both on br-mc0"

# status must succeed unprivileged-safe and mention what we built
fab status || fail "fabric status failed while the fabric was up"

# ── down, and the assertion that caught F.6 ─────────────────────────────────
fab down || { cat "$LOG" >&2; fail "fabric down failed: $(tail -1 "$LOG")"; }
FABRIC_UP=0

ip link show br-mc0 >/dev/null 2>&1 && fail "REGRESSION: br-mc0 survived teardown — a leaked 10.71.0.1 breaks the next lab"
leftover="$(ip -o link show 2>/dev/null | grep -oE 'mc-[a-z0-9-]+' | sort -u | tr '\n' ' ')"
[[ -z "$leftover" ]] || fail "REGRESSION: mc-* taps survived teardown: $leftover"
nft list table ip mklab-mc >/dev/null 2>&1 && fail "REGRESSION: the nft table mklab-mc survived teardown"
# CAPTURED, then tested. `producer | grep -q X && fail` is the SILENT variant of this
# repo's pipefail inversion: grep -q exits on first match, the producer can die on SIGPIPE,
# `pipefail` makes the pipeline non-zero — and `&& fail` then does NOT fire, so a route that
# HAD survived teardown would be reported as clean. Demonstrated on 2026-08-07 (rc=141, the
# assertion silently skipped). `ip route`'s output is small enough that it was unlikely to
# bite here, but "unlikely" is not the standard for a teardown assertion.
_routes="$(ip -4 route show 2>/dev/null)" || true
grep -q '10\.71\.0\.' <<<"$_routes" && fail "REGRESSION: a 10.71.0.0/24 route survived teardown"
[[ -d "/proc/$DPID" ]] && fail "REGRESSION: our dnsmasq ($DPID) is still running after teardown"
note "down: bridge, taps, nft table, route and dnsmasq all absent"

# ── and THEIRS, compared independently of fabric.sh's own comparison ────────
CAL_AFTER="$(calico_binding)"; VETH_AFTER="$(calico_veths)"
FWD_AFTER="$(cat /proc/sys/net/ipv4/ip_forward)"
[[ "${CAL_AFTER:-<absent>}" == "${CAL_BEFORE:-<absent>}" ]] \
    || fail "REGRESSION: Calico's tunnel MOVED across the run: '${CAL_BEFORE:-<absent>}' -> '${CAL_AFTER:-<absent>}' — the fabric disturbed a live CNI (plan F.6)"
[[ "$VETH_AFTER" == "$VETH_BEFORE" ]] \
    || fail "REGRESSION: cali* veth count moved $VETH_BEFORE -> $VETH_AFTER — pods were recreated"
[[ "$FWD_AFTER" == "$FWD_BEFORE" ]] \
    || fail "REGRESSION: ip_forward moved $FWD_BEFORE -> $FWD_AFTER — teardown reverted a global it did not set"
note "calico binding, pod veth count and ip_forward all unchanged across the round trip"

pass "fabric round trip: up/tap/status/down green, and the live cluster was untouched"
