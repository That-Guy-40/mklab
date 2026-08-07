#!/usr/bin/env bash
# Verdict: `fabric.sh retap` recovers a tap that exists but cannot be opened by the user
# the VMM runs as — and it does so WITHOUT disturbing the DHCP reservation, which is the
# whole reason it is a separate verb from `tap`.
#
# WHY THIS EXISTS. `retap` was added because of a real defect (plan G.4, 2026-08-02): a
# tap created root-owned looks perfect — it exists, it is enslaved to the bridge, it
# shows `carrier 1` — and an unprivileged Firecracker gets EPERM from TUNSETIFF. The verb
# has been in `fabric.sh` since slice 3 and **had never been called by anything**, which
# the plan, the README and DEFERRED.md each said in their own words. A verb no test
# exercises is a verb nobody knows works.
#
# THE ASSERTION IS THE IOCTL, NOT THE OWNER FILE. `/sys/class/net/<tap>/owner` is the
# mechanism; whether the VMM can attach is the outcome, and this repo has been caught by
# that gap before (`ip tuntap add` exiting 0 read as "the tap is usable"). So the tap is
# opened for real, as the unprivileged owner, via `tests/tun-open.py` — before the break,
# after the break, and after the repair. **The run that must SUCCEED is what gives the
# run that must FAIL its meaning**: if the ioctl failed in both states the harness would
# have proven nothing, and §3 says so by name.
#
# THAT GUARD EARNED ITS KEEP ON THE FIRST PRIVILEGED RUN (2026-08-07). §3 staged the broken
# tap with a bare `ip tuntap add` — and uid 1000 attached to it without trouble, so the test
# FAILED rather than "proving" a repair of something that was never broken. An owner-LESS
# tap and a root-OWNED one look identical in `ip link show` and behave in opposite
# directions; only the second is G.4. See §3.
#
# ⚠️ TOUCHES REAL HOST NETWORKING beside a live microk8s/Calico, so it carries the same
# three guards as test-fabric-round-trip.sh, and tears down from the EXIT trap.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

[[ ${EUID:-$(id -u)} -eq 0 ]] || skip "needs root: the fabric creates a bridge, taps and an nft table, and this test must create a deliberately root-owned tap (CAP_NET_ADMIN)"
need ip nft dnsmasq runuser python3
[[ -x "$FABRIC" ]] || skip "fabric.sh not executable at $FABRIC"
TUNOPEN="$TEST_DIR/tun-open.py"
[[ -f "$TUNOPEN" ]] || skip "tun-open.py is missing — the outcome under test cannot be asked"

# Guard 2 — refuse to adopt or destroy a fabric this test did not create.
[[ -e /run/mklab-mc/preflight ]] \
    && skip "a fabric is already up (/run/mklab-mc/preflight exists) — refusing to tear down a lab this test did not create; run 'fabric.sh down' first if it is stale"
ip link show br-mc0 >/dev/null 2>&1 \
    && skip "br-mc0 already exists — refusing to adopt an interface this test did not create"

# Guard 3 — the tap owner is the repo's owner, not $SUDO_USER (which is 'root' when sudo
# runs from a root shell — the very mistake that produces an unopenable tap).
OWNER="$(stat -c %U "$REPO_DIR")"
[[ -n "$OWNER" && "$OWNER" != root ]] \
    || skip "the repo checkout is owned by '$OWNER' — every tap would be root-owned, so the broken state and the repaired state would be indistinguishable"
OWNER_UID="$(id -u "$OWNER")" || skip "cannot resolve uid for '$OWNER'"
export MC_OWNER="$OWNER"

NAME=rt1
TAP="mc-$NAME"
LOG="$(mktemp)"
FABRIC_UP=0
_cleanup() {
    ip link del "$TAP" >/dev/null 2>&1 || true      # in case a break step left it behind
    if (( FABRIC_UP )); then bash "$FABRIC" down >>"$LOG" 2>&1 || true; fi
    if (( _EXIT_RC != 0 && _EXIT_RC != 77 )); then
        printf '  (evidence kept: %s)\n' "$LOG" >&2
        return
    fi
    rm -f "$LOG"
}
on_exit '_cleanup'

fab() { local v="$1"; shift; bash "$FABRIC" "$v" "$@" >>"$LOG" 2>&1; }

# can_open — attempt TUNSETIFF as the unprivileged owner. Echoes the tool's own message.
can_open() { runuser -u "$OWNER" -- python3 "$TUNOPEN" "$TAP" 2>&1; }

CAL_BEFORE="$(calico_binding)"; VETH_BEFORE="$(calico_veths)"
note "before: calico=${CAL_BEFORE:-<absent>} veths=$VETH_BEFORE"

# ── 1. a healthy tap, made by the fabric ──────────────────────────────────
fab up || { cat "$LOG" >&2; fail "fabric up failed: $(tail -1 "$LOG")"; }
FABRIC_UP=1
fab tap "$NAME" || { cat "$LOG" >&2; fail "fabric tap $NAME failed: $(tail -1 "$LOG")"; }
ip link show "$TAP" >/dev/null 2>&1 || fail "fabric tap reported success but $TAP does not exist"

RES_BEFORE="$(grep ",$NAME\$" /run/mklab-mc/dhcp-hosts 2>/dev/null)"
HOSTS_BEFORE="$(grep " $NAME\$" /run/mklab-mc/hosts 2>/dev/null)"
[[ -n "$RES_BEFORE" ]] || fail "fabric tap $NAME recorded no dhcp-hosts reservation — §4's 'the reservation survived' assertion would be vacuous"
note "reservation: $RES_BEFORE"

# ── 2. the BASELINE that gives §3 its meaning ─────────────────────────────
out="$(can_open)" \
    || fail "the harness cannot attach to a HEALTHY fabric tap as '$OWNER' ($out). Nothing below is testable: a failure in §3 would prove the harness broken, not the tap. If this says NO-TUN-DEVICE, /dev/net/tun is missing"
note "baseline: '$OWNER' can attach to the fabric's own tap — $out  ✓"

# ── 3. break it exactly the way the defect did: owner uid 0 ───────────────
# `user root`, NOT a bare `ip tuntap add`. The first draft of this test used the bare form
# on the theory that "no owner" is what a root shell produces, and the first privileged run
# (2026-08-07) refused it: uid 1000 attached to that tap perfectly well. The kernel is
# explicit about why — drivers/net/tun.c, tun_not_capable():
#
#     return ((uid_valid(tun->owner) && !uid_eq(cred->euid, tun->owner)) ||
#             (gid_valid(tun->group) && !in_egroup_p(tun->group))) &&
#            !ns_capable(net->user_ns, CAP_NET_ADMIN);
#
# With NO owner and NO group both halves of the first clause are false, so the tap is
# attachable by ANYONE. "Root-owned" and "owner-less" look identical in `ip link show` and
# behave in OPPOSITE directions, and only one of them is G.4.
#
# G.4's tap came from `fabric.sh tap` with MC_OWNER/SUDO_USER resolving to `root` — i.e.
# `ip tuntap add … user root`, owner uid 0, a VALID uid that is not the caller's. That is
# what fabric.sh:246 refuses to create, and it is what gets staged here.
ip link del "$TAP" || fail "the harness could not delete $TAP to stage the broken state"
ip tuntap add dev "$TAP" mode tap user root \
    || fail "the harness could not create a root-owned $TAP (ip tuntap add … user root)"
ip link set "$TAP" master br-mc0 || fail "the harness could not enslave the broken $TAP"
ip link set "$TAP" up || fail "the harness could not bring the broken $TAP up"

# CHECK THE FIXTURE BEFORE ASKING THE QUESTION. The ioctl below is the outcome, but if the
# staging silently produced some other state the refusal would be about the wrong thing —
# which is exactly how the first run went wrong. So read the owner back first.
staged="$(cat "/sys/class/net/$TAP/owner" 2>/dev/null)"
[[ "$staged" == 0 ]] \
    || fail "the harness meant to stage owner uid 0 and got '${staged:-<unset>}'. An UNSET owner is not a weaker version of a root-owned one — with neither owner nor group set the kernel lets ANY user attach, so §4 would then be repairing a tap that was never broken"

# It LOOKS fine. This is the point of the defect.
[[ "$(cat "/sys/class/net/$TAP/operstate" 2>/dev/null)" != down ]] \
    || note "(the broken tap is operstate=down, which at least hints at trouble)"
out="$(can_open)" \
    && fail "REGRESSION: '$OWNER' could attach to a tap owned by uid 0 ($out) — the defect retap exists to repair cannot be staged on this kernel, so §4 would pass without proving anything"
note "broken: the tap exists, is enslaved, is up, owner uid is 0, and '$OWNER' still cannot attach — ${out##*$'\n'}  ✓"

# ── 4. retap repairs it, and the reservation survives ─────────────────────
fab retap "$NAME" || { cat "$LOG" >&2; fail "fabric retap $NAME failed on a tap it is meant to repair: $(tail -1 "$LOG")"; }

out="$(can_open)" \
    || fail "REGRESSION: after 'retap', '$OWNER' STILL cannot attach to $TAP ($out). The verb reported success without restoring the one property it exists to restore — an unprivileged VMM would still get EPERM"
note "repaired: '$OWNER' can attach again — $out  ✓"

got_uid="$(cat "/sys/class/net/$TAP/owner" 2>/dev/null)"
[[ "$got_uid" == "$OWNER_UID" ]] \
    || fail "after retap the tap's owner uid is '${got_uid:-<unset>}', not $OWNER_UID ($OWNER)"

# THE REASON retap IS A SEPARATE VERB. The guest's MAC comes from the VMM's config, so
# the reservation stays valid across a tap recreate; re-appending would hand the guest a
# second address and break the name it answers to. Byte-identical, not merely present.
RES_AFTER="$(grep ",$NAME\$" /run/mklab-mc/dhcp-hosts 2>/dev/null)"
[[ "$RES_AFTER" == "$RES_BEFORE" ]] \
    || fail "REGRESSION: retap changed the DHCP reservation.
  before: ${RES_BEFORE:-<none>}
  after:  ${RES_AFTER:-<none>}
retap must not touch dhcp-hosts: the guest's MAC is set by the VMM, so the reservation survives a recreate. A second entry gives the guest a different address and breaks the name it is meant to answer to"
[[ "$(grep " $NAME\$" /run/mklab-mc/hosts 2>/dev/null)" == "$HOSTS_BEFORE" ]] \
    || fail "REGRESSION: retap changed the addn-hosts entry for $NAME — the name-to-address contract moved under a repair that is supposed to be invisible to it"
n_res="$(grep -c ",$NAME\$" /run/mklab-mc/dhcp-hosts 2>/dev/null || true)"
[[ "$n_res" == 1 ]] \
    || fail "REGRESSION: $NAME now has $n_res reservations, not 1 — retap appended instead of leaving the record alone"
note "the reservation is byte-identical and still single: $RES_AFTER  ✓"

addrs="$(ip -4 -o addr show "$TAP" 2>/dev/null)"
[[ "$addrs" != *inet* ]] \
    || fail "REGRESSION: the repaired $TAP carries an IPv4 address ($addrs) — rule 2 says a fabric tap is addressless, and an addressed interface is exactly what Calico's autodetection would consider"
[[ "$(cat "/sys/class/net/$TAP/master" 2>/dev/null || readlink -f "/sys/class/net/$TAP/master" 2>/dev/null | xargs -r basename)" == *br-mc0* ]] \
    || [[ "$(ip -o link show "$TAP")" == *"master br-mc0"* ]] \
    || fail "the repaired $TAP is not enslaved to br-mc0 — it exists and is openable but is attached to nothing"
note "the repaired tap is addressless and on br-mc0  ✓"

# ── 5. the two refusals that keep the verbs distinct ──────────────────────
if ( fab retap nosuchname ); then
    fail "REGRESSION: 'retap' accepted a name with no reservation. It only recreates a tap and deliberately does not write dhcp-hosts, so the result would be a tap no DHCP server answers for — silently"
fi
grep -qi "no dhcp-hosts entry" "$LOG" \
    || fail "'retap' refused an unknown name without naming the reason or pointing at 'tap': $(tail -2 "$LOG")"
if ( fab tap "$NAME" ); then
    fail "REGRESSION: 'tap' accepted a name that already holds a reservation — it would append a SECOND entry and the guest would get a different address under the same name"
fi
grep -qi "already has a reservation" "$LOG" \
    || fail "'tap' refused a duplicate without naming the reservation or pointing at 'retap': $(tail -2 "$LOG")"
note "retap refuses an unreserved name, and tap refuses a reserved one — each pointing at the other  ✓"

# ── 6. and the live cluster is where we found it ──────────────────────────
CAL_AFTER="$(calico_binding)"; VETH_AFTER="$(calico_veths)"
[[ "$CAL_AFTER" == "$CAL_BEFORE" ]] \
    || fail "REGRESSION: Calico's VXLAN binding MOVED across this run: '${CAL_BEFORE:-<absent>}' -> '${CAL_AFTER:-<absent>}'. Deleting and recreating a tap on a shared host disturbed the live cluster"
[[ "$VETH_AFTER" == "$VETH_BEFORE" ]] \
    || fail "REGRESSION: Calico's pod veth count changed ($VETH_BEFORE -> $VETH_AFTER) across this run"
note "calico binding and pod veth count unchanged across break and repair  ✓"

fab down || { cat "$LOG" >&2; fail "fabric down failed after the repair: $(tail -1 "$LOG")"; }
FABRIC_UP=0
ip link show "$TAP" >/dev/null 2>&1 \
    && fail "'down' left the repaired tap behind — teardown is a test, not a cleanup"

pass "retap recovers the defect it exists for: a root-owned tap that looks healthy and that '$OWNER' cannot attach to becomes one it can — proven by the TUNSETIFF ioctl in all three states, not by the owner file — while the DHCP reservation stays byte-identical, the tap stays addressless on br-mc0, each verb refuses the other's case by name, and the live Calico binding never moves"
