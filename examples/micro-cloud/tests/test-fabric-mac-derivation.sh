#!/usr/bin/env bash
# The fabric and the VMM must derive the SAME guest MAC for the same instance name.
#
# WHY THIS EXISTS. `fabric.sh tap <name>` reserves a DHCP lease against a MAC; `lab-fc.sh`
# sets the MAC on the guest. Nothing enforces that these agree, and when they disagree
# NOTHING ERRORS: the guest simply misses its reservation, takes a dynamic lease from the
# pool, and dnsmasq goes on answering `<name>` with the reserved address — which nothing
# holds. A record that outlives its subject, invisible from either tool alone, and only
# observable by booting a guest and asking a third party what its name resolves to.
#
# It was real. Until 2026-08-05 `fabric.sh` derived the MAC from the ORDER taps were created
# (the line count of dhcp-hosts: `api1` -> 06:00:ac:47:00:01) while its own comment claimed
# the name, and `lab-fc.sh` had hashed the name since slice 4 (`api1` -> 06:00:ac:47:f1:f7).
# THE TWO COMMITTED TOOLS COULD NEVER AGREE. It went unnoticed for three slices because every
# run hand-wrote the microVM config with the positional MAC — `lab-fc.sh` had never actually
# been pointed at a `fabric.sh` tap.
#
# HOW THIS TEST IS BUILT, AND WHY IT IS NOT A STRING COMPARISON. Both tools expose a
# read-only `mac <name>` verb that needs no tap and no root, and this drives BOTH of them.
# It does not re-implement the formula and it does not grep the sources: a test that
# transcribes the algorithm passes when both copies are wrong in the same way, and a test
# that greps for `md5sum` passes when someone changes the byte offsets. Ask each tool what it
# would DO, and compare the answers — the outcome, not the mechanism.
#
# The order-independence half matters for exactly the same reason: a name must map to one MAC
# no matter how many instances precede it, or a static spec file cannot name its own MAC.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

FC_TOOL="$REPO_DIR/phase7-firecracker/lab-fc.sh"
[[ -x "$FABRIC"  ]] || skip "fabric.sh not executable at $FABRIC"
[[ -x "$FC_TOOL" ]] || skip "lab-fc.sh not executable at $FC_TOOL"
need md5sum

_on_exit() {
    local rc=$?
    if (( rc != 0 && rc != 77 )) && (( _VERDICT == 0 )); then
        printf 'FAIL: test exited early (rc=%d) — no verdict was printed by the test itself\n' "$rc" >&2
    fi
}
trap _on_exit EXIT

# ── 1. the two tools agree, across a spread of names ────────────────────────
NAMES=(api1 api2 edge db metrics a z9 web-1)
for n in "${NAMES[@]}"; do
    f="$(bash "$FABRIC"  mac "$n")" || fail "fabric.sh mac $n failed"
    c="$(bash "$FC_TOOL" mac "$n")" || fail "lab-fc.sh mac $n failed"
    [[ -n "$f" ]] || fail "fabric.sh mac $n printed nothing"
    [[ "$f" == "$c" ]] \
        || fail "REGRESSION: the fabric and the VMM disagree for '$n' — fabric.sh says '$f', lab-fc.sh says '$c'. A guest booted with one and reserved under the other misses its lease SILENTLY and dnsmasq keeps answering '$n' with an address nothing holds"
    [[ "$f" =~ ^06:00:ac:47:[0-9a-f]{2}:[0-9a-f]{2}$ ]] \
        || fail "'$f' is not a well-formed locally-administered MAC in this lab's 06:00:ac:47 range"
done
note "agreement: ${#NAMES[@]} names, fabric.sh mac == lab-fc.sh mac for every one"

# ── 2. the MAC is a function of the NAME, not of creation order ─────────────
# The defect this replaced: `api1` was 06:00:ac:47:00:01 only because it happened to be
# created first. Asking twice in different contexts must give one answer.
first="$(bash "$FABRIC" mac api1)"
_="$(bash "$FABRIC" mac edge)"; _="$(bash "$FABRIC" mac db)"
again="$(bash "$FABRIC" mac api1)"
[[ "$first" == "$again" ]] \
    || fail "REGRESSION: 'api1' derived '$first' then '$again' — the MAC moved, so it is positional again and a static spec cannot name its own MAC"
note "order-independence: api1 -> $first before and after two other names"

# ── 3. distinct names must not collide ──────────────────────────────────────
# A collision is two guests fighting over one reservation. Not proof against all inputs —
# it is a hash — but a collision inside the set this lab actually uses is a build blocker.
mapfile -t macs < <(for n in "${NAMES[@]}"; do bash "$FABRIC" mac "$n"; done)
uniq_n="$(printf '%s\n' "${macs[@]}" | sort -u | wc -l)"
(( uniq_n == ${#NAMES[@]} )) \
    || fail "MAC collision within this lab's own names: ${#NAMES[@]} names produced only $uniq_n distinct MACs"
note "no collisions across the ${#NAMES[@]} names"

# ── 4. the negative control: the comparison must be capable of failing ──────
# Every assertion above compares two strings that are currently equal. If the harness were
# broken — a helper that always returned empty, a comparison that always held — it would look
# exactly like this. So make the check bite on purpose, right here, and refuse to pass if it
# does not. (Both tools SHOULD disagree with a different name.)
ctl_a="$(bash "$FABRIC" mac api1)"; ctl_b="$(bash "$FC_TOOL" mac api2)"
[[ "$ctl_a" != "$ctl_b" ]] \
    || fail "the control failed: 'api1' and 'api2' derived the same MAC ('$ctl_a'), so the agreement asserted above proves nothing"
note "control: api1 and api2 derive DIFFERENT MACs, so equality above is a real observation"

# ── 5. refusals, so a typo cannot become a silent default ───────────────────
if out="$(bash "$FABRIC" mac 2>&1)"; then
    fail "fabric.sh mac with no name exited 0 (printed '$out') — an empty name would hash to a real-looking MAC"
fi
if out="$(bash "$FABRIC" mac 'Bad Name' 2>&1)"; then
    fail "fabric.sh mac accepted an invalid instance name — dnsmasq and the tap namespace both constrain it"
fi
note "refusals: a missing name and an invalid name are both rejected"

pass "the fabric and the VMM derive the same guest MAC from the instance name — order-independent, collision-free across this lab's names, and the control proves the comparison can fail"
