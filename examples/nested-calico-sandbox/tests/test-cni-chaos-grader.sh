#!/usr/bin/env bash
# Verdict: the chaos grader's own branches, watched firing.
#
# ── WHY THIS TEST EXISTS ────────────────────────────────────────────────────────────────
#
# `test-cni-chaos.sh` is a pile of claims about what it WOULD do if the CNI misbehaved: it
# would fail if a refused pod claimed to be Running, if the allocator stopped returning
# addresses, if an injector silently landed nothing, if the run left the cluster's IP pools
# disabled. Every one of those branches has, in practice, run exactly zero times — because
# the only cluster it has ever graded behaved well. **An assertion never observed failing is
# not known to work.** It may be matching a string that is always present, or checking a
# field that is always empty, and either way it reads as coverage.
#
# So this test hands the grader a **hand-written record with one defect injected**, once per
# branch, and requires the matching assertion to bite — by its own specific message, not
# merely by a non-zero exit. That distinction is the whole point: a syntax error in the
# grader would fail all sixteen of these and look like sixteen working negative controls.
#
# It also runs the POSITIVE case first. A negative-control suite where the clean record does
# not pass is grading a broken fixture, not a grader.
#
# **No cluster, no VM, no root.** ~2 seconds. This is the check that runs in CI, while the
# matrix it guards runs on a live Calico for twenty minutes.
#
# ── WHAT A FIXTURE COSTS, AND HOW THAT IS PAID ──────────────────────────────────────────
#
# The record below is a hand-written copy of a shape `cni-chaos.sh` emits — which makes it
# this repo's bug class #1 in waiting: a record that keeps being readable after its subject
# changes. Rename `allocations_left=` in the injector and this fixture does not break; the
# grader simply starts reading an empty field, which it renders as UNKNOWN, and the leak
# branch quietly stops being exercised while this test still passes.
#
# §1 is the payment: every key the fixture speaks is checked to still be a key the injector
# emits. It cannot prove the VALUES are realistic — only a live run does that — and it says
# so rather than implying otherwise.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need sed grep mktemp
GRADER="$TEST_DIR/test-cni-chaos.sh"
INJECTOR="$LAB_DIR/cni-chaos.sh"
[[ -r "$GRADER"   ]] || fail "the grader under test is missing at $GRADER"
[[ -r "$INJECTOR" ]] || fail "cni-chaos.sh is missing at $INJECTOR — §1 cannot bind the fixture to anything"

WORK="$(mktemp -d)"; TMPDIRS+=("$WORK")
GOOD="$WORK/good.rec"

# ── THE CLEAN RECORD ────────────────────────────────────────────────────────────────────
# The matrix as it was measured on 2026-08-08: 7 rows, 3 absorbed, 4 not, 0 critical. Kept
# verbatim in shape — same field names, same ordering, the real refusal text — because every
# mutation below is a one-field edit of it, and a fixture that is already unlike the thing it
# imitates makes each of those edits mean something different.
cat >"$GOOD" <<'EOF'
CNI-NAMESPACE-READY after=9s
CNI-WORKLOAD-WAITING
CNI-WORKLOAD-READY after=26s a=10.1.243.2 b=10.1.243.3
CNI-ROW=control-no-fault BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=control-no-fault AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=n/a SECS=0
CNI-ROW=calico-node-killed BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=calico-node-killed MID[ready=0 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=yes SECS=0 LANDED=uid-3f9a12bc->7c4e01de
CNI-ROW=netfilter-flushed BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=netfilter-flushed MID[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=61] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=yes SECS=0 LANDED=200->0
CNI-ROW=pod-veth-deleted BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=pod-veth-deleted MID[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=FAIL rules=196] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=via-pod-recreate SECS=244+18
CNI-ROW=vxlan-deleted BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=vxlan-deleted MID[ready=1 nodeip=10.0.2.15 tunnel=absent pods=OK rules=200] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=yes SECS=5 LANDED=yes NOTE=single-node-dataplane-unaffected-by-design
CNI-ROW=chosen-address-removed BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=chosen-address-removed DECOY-TAKEN after=20s nodeip=10.88.0.1
CNI-ROW=chosen-address-removed MID[ready=1 nodeip=10.88.0.1 tunnel=local_10.88.0.1_dev_mc-cnidecoy pods=OK rules=200] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=yes SECS=15
CNI-ROW=ipam-exhausted BEFORE[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200]
CNI-ROW=ipam-exhausted FILL filled=7 denied=5 after=63s
CNI-ROW=ipam-exhausted DENIAL-TEXT Failed to create pod sandbox: plugin type="calico" failed (add): failed to request IPv4 addresses: Assigned 0 out of 1 requested IPv4 addresses; No IPs available in pools: [10.99.9.0/29]
CNI-ROW=ipam-exhausted DENIAL stuck=fill-8 reason=named-the-exhausted-pool lied=no
CNI-ROW=ipam-exhausted-incumbent MID[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=n/a SECS=0 LANDED=filled-7-denied-5
CNI-ROW=ipam-exhausted MID[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] AFTER[ready=1 nodeip=10.0.2.15 tunnel=local_10.0.2.15_dev_enp0s3 pods=OK rules=200] RECOVERED=yes SECS=7 LANDED=filled-7-denied-5 REASON=named-the-exhausted-pool LIED=no REFILLED=7/7
CNI-ROW=ipam-exhausted LEAK of_filled=7 first=1 allocations_left=1 released_after=245s pods_left=0
CNI-ROW=ipam-exhausted RESTORED disabled_pools_remaining=0 tiny_pool_present=no
CNI-END
EOF

_n=0
G_RC=0; G_OUT=""
run_grader() {  # run_grader <record> — sets G_RC and G_OUT
    _n=$((_n+1)); G_OUT="$WORK/out.$_n"
    # NOT PIPED. The exit status IS the gate here, and `bash … | grep` would report grep's.
    CNI_CHAOS_RECORD="$1" bash "$GRADER" >"$G_OUT" 2>&1
    G_RC=$?
}

# ── 1. THE FIXTURE IS BOUND TO THE THING IT IMITATES ────────────────────────────────────
# Not "does it look plausible" — does every key it speaks still exist in the emitter. This is
# the only defence available against the fixture rotting into a record of a format nothing
# produces any more, at which point the grader reads empty fields, calls them UNKNOWN, and
# this whole file passes while exercising nothing.
#
# ⚠️ IT GREPS THE `say` LINES, NOT THE FILE, and that distinction was found by breaking it.
# The first version grepped cni-chaos.sh whole; renaming the emitted `allocations_left=` to
# something else left this section green, because the old name still appeared in a COMMENT
# three lines above describing a past measurement. The check passed while the property it
# stands for — "the injector still emits this key" — was false. Prose is not an emission; the
# `say` calls are the seam.
EMITS="$WORK/emissions"
grep -h 'say "' "$INJECTOR" >"$EMITS"
(( $(wc -l <"$EMITS") > 10 )) \
    || fail "only $(wc -l <"$EMITS") 'say' lines found in cni-chaos.sh — the emission seam this section greps has moved, so every key below would report missing (or, worse, present) for reasons unrelated to the record format"

missing=()
for k in 'WORKLOAD-READY' 'ROW=control-no-fault' 'ROW=calico-node-killed' \
         'ROW=netfilter-flushed' 'ROW=pod-veth-deleted' 'ROW=vxlan-deleted' \
         'ROW=chosen-address-removed' 'ROW=ipam-exhausted ' 'ROW=ipam-exhausted-incumbent' \
         'INJECTOR-FAILED' 'SKIPPED reason=' 'DENIAL-TEXT' 'RECOVERED=' 'SECS=' 'LANDED=' \
         'REASON=' 'LIED=' 'of_filled=' 'first=' 'allocations_left=' 'released_after=' \
         'disabled_pools_remaining=' 'tiny_pool_present='; do
    grep -qF -- "$k" "$EMITS" || missing+=("$k")
done
(( ${#missing[@]} == 0 )) \
    || fail "the fixture below speaks ${#missing[@]} key(s) that cni-chaos.sh no longer emits: ${missing[*]}.
This is exactly the drift this section exists to catch: the grader would read those fields as
empty, render empty as UNKNOWN, and every negative control here would keep passing while
testing a record format nothing produces. Update the fixture in the same commit that renamed
the field."
note "fixture bound: all 23 record keys it uses are still emitted by cni-chaos.sh  ✓ (this checks the NAMES; only a live run checks the values)"

# ── 2. THE POSITIVE CASE ────────────────────────────────────────────────────────────────
run_grader "$GOOD"
(( G_RC == 0 )) || { cat "$G_OUT" >&2; fail "the CLEAN record does not grade clean (rc=$G_RC). Every negative control below is an edit of this file, so if it fails for reasons of its own then all sixteen of them fire for that reason and none of them proves anything"; }
for want in 'the supplied record grades clean' '7 rows' '3 absorbed, 4 not, 0 critical' \
            'NOTHING WAS INJECTED IN THIS RUN'; do
    grep -qF -- "$want" "$G_OUT" \
        || { cat "$G_OUT" >&2; fail "the clean record passed but the verdict never said '$want' — a PASS that does not report the matrix it graded is not evidence the matrix was read"; }
done
note "clean record: PASS, 7 rows, 3 absorbed / 4 not / 0 critical, and it announced that nothing was injected  ✓"

# ── 3. THE NEGATIVE CONTROLS ────────────────────────────────────────────────────────────
# One defect each, and each must be refused BY ITS OWN MESSAGE. Matching the specific text is
# what separates "the assertion bit" from "the grader fell over", and those have opposite
# fixes.
FIRED=0
control() {  # control <name> <sed-program> <expected-fragment>
    # Assigned on its own line, not folded into the `local` above: bash expands every word of
    # a command before running it, so `local n="$1" rec="…$n…"` reads the OUTER `n`.
    local name="$1" prog="$2" want="$3"
    local rec="$WORK/neg.$name.rec"
    sed "$prog" "$GOOD" >"$rec"
    if cmp -s "$GOOD" "$rec"; then
        fail "the '$name' negative control did not change the record — its sed matched nothing, so it was about to 'pass' by grading the CLEAN file. A mutation that does not mutate is the silent version of this whole test doing nothing"
    fi
    run_grader "$rec"
    if (( G_RC == 0 )); then
        cat "$G_OUT" >&2
        fail "REGRESSION: the '$name' defect was injected into the record and the grader PASSED it. That branch of test-cni-chaos.sh does not bite, so the property it claims to check is unguarded: a real cluster with this defect would be reported as healthy"
    fi
    if ! grep -qF -- "$want" "$G_OUT"; then
        cat "$G_OUT" >&2
        fail "the '$name' control failed the grader (rc=$G_RC) but NOT with its own message — expected to see '$want'. A wrong-reason failure is indistinguishable from a broken grader, and it would let the intended assertion rot while this test stayed green"
    fi
    FIRED=$((FIRED+1))
    note "$name → refused by name  ✓"
}

# (a) the ladder itself — a row that moved rung
control refused-pod-claims-running \
    '/^CNI-ROW=ipam-exhausted MID/s/LIED=no/LIED=yes/' \
    'recorded HALTED, measured LIED'
control refused-pod-never-recovers \
    '/^CNI-ROW=ipam-exhausted MID/s/RECOVERED=yes/RECOVERED=no/' \
    'recorded HALTED, measured STRANDED'
control incumbent-dataplane-died \
    '/^CNI-ROW=ipam-exhausted-incumbent /s/pods=OK/pods=FAIL/2' \
    'recorded ABSORBED, measured STRANDED'
control vxlan-never-rebuilt \
    '/^CNI-ROW=vxlan-deleted MID/s/RECOVERED=yes/RECOVERED=no/' \
    'recorded DEGRADED, measured STRANDED'
control node-address-never-redetected \
    '/^CNI-ROW=chosen-address-removed MID/s/RECOVERED=yes/RECOVERED=no/' \
    'recorded DEGRADED, measured LIED'
control absorbed-row-stopped-absorbing \
    '/^CNI-ROW=calico-node-killed MID/s/pods=OK/pods=FAIL/2' \
    'recorded ABSORBED, measured STRANDED'

# (b) the allocator row's own three questions
control refusal-does-not-name-the-pool \
    '/^CNI-ROW=ipam-exhausted MID/s/REASON=named-the-exhausted-pool/REASON=named-an-address-failure-but-not-which-pool/' \
    'did NOT name which pool ran out'
control refusal-is-silent \
    '/^CNI-ROW=ipam-exhausted MID/s/REASON=named-the-exhausted-pool/REASON=silent/' \
    'did NOT say why'
control prompt-release-path-is-dead \
    '/^CNI-ROW=ipam-exhausted LEAK/s/first=1/first=7/' \
    'NONE of the 7 addresses were returned'
control pools-left-disabled \
    '/^CNI-ROW=ipam-exhausted RESTORED/s/disabled_pools_remaining=0/disabled_pools_remaining=2/' \
    'did not put the cluster back'
control tiny-pool-left-behind \
    '/^CNI-ROW=ipam-exhausted RESTORED/s/tiny_pool_present=no/tiny_pool_present=yes/' \
    'did not put the cluster back'

# (c) the harness's own honesty — the rows that are ABOUT the record rather than the CNI
control injector-did-not-land \
    's/^CNI-ROW=netfilter-flushed MID.*/CNI-ROW=netfilter-flushed INJECTOR-FAILED before=200 after=200 — the rules were NOT removed, so this row would grade a fault that never happened/' \
    "the 'netfilter-flushed' injector did not land"
control row-absent-entirely \
    '/^CNI-ROW=vxlan-deleted/d' \
    "the 'vxlan-deleted' row is missing from the record entirely"
control no-fault-control-failed \
    '/^CNI-ROW=control-no-fault AFTER/s/pods=OK/pods=FAIL/' \
    'the NO-FAULT control could not ping pod-b from pod-a'
control workload-never-existed \
    '/^CNI-WORKLOAD-READY/d' \
    'the two-pod workload never came up'
control record-is-partial \
    '/^CNI-END/d' \
    'does not reach CNI-END'
control too-few-rows-to-be-a-matrix \
    '/^CNI-ROW=\(vxlan-deleted\|chosen-address-removed\|pod-veth-deleted\) MID/s/ MID.*/ SKIPPED reason=synthetic-for-the-negative-control/' \
    'too few to call this a matrix'

# ── 4. THE ALTERNATE PASSING BRANCHES ───────────────────────────────────────────────────
# Not defects — the other side of three branches whose usual side is the one the live run
# takes. A branch reached only when the cluster behaves unusually is as unexercised as a
# failure branch, and it is the one that will be read on the day something is unusual.
variant() {  # variant <name> <sed-program> <expected-fragment>
    local name="$1" prog="$2" want="$3"
    local rec="$WORK/var.$name.rec"
    sed "$prog" "$GOOD" >"$rec"
    cmp -s "$GOOD" "$rec" && fail "the '$name' variant did not change the record — its sed matched nothing"
    run_grader "$rec"
    (( G_RC == 0 )) || { cat "$G_OUT" >&2; fail "the '$name' variant is a LEGITIMATE record and the grader rejected it (rc=$G_RC). A grader that fails on healthy-but-unusual input trains its reader to stop believing it"; }
    grep -qF -- "$want" "$G_OUT" || { cat "$G_OUT" >&2; fail "the '$name' variant passed but never said '$want', so the branch it exists to reach was not the branch taken"; }
    note "$name → passes, and reports it  ✓"
}
variant allocator-returned-everything \
    '/^CNI-ROW=ipam-exhausted LEAK/s/allocations_left=1/allocations_left=0/' \
    'the allocator gave everything back'
variant a-row-reports-uncovered \
    '/^CNI-ROW=vxlan-deleted MID/s/ MID.*/ SKIPPED reason=no-vxlan-device-on-this-cluster/' \
    'UNCOVERED: vxlan-deleted'
variant row-recovered-but-left-collateral \
    '/^CNI-ROW=chosen-address-removed MID/s/pods=OK/pods=FAIL/2' \
    'collateral: the dataplane was'

# ── 5. AND THE RECORD SWITCH ITSELF REFUSES WHAT IT CANNOT READ ─────────────────────────
run_grader "$WORK/there-is-no-such-record"
(( G_RC != 0 )) && grep -qF -- 'is not readable' "$G_OUT" \
    || { cat "$G_OUT" >&2; fail "CNI_CHAOS_RECORD pointing at a nonexistent file did not produce a readable-file refusal (rc=$G_RC) — a grader that treats a missing record as an empty one grades a matrix of nothing and finds no faults in it"; }
note "an unreadable record is refused rather than graded as empty  ✓"

# ── 6. WHAT THIS FILE DOES *NOT* PROVE ──────────────────────────────────────────────────
# UNKNOWN is a verdict, and these are the branches a record-driven test cannot reach. Saying
# so is the difference between "16 controls fired" and "the grader is fully exercised".
note "NOT exercised here, and not claimed to be:"
note "  · §5's 'no row ABSORBED' / 'EVERY row absorbed' guards — reaching either needs a row to grade at a rung other than its recorded one, which trips the per-row REGRESSION check first. They are reachable only by editing the grader's own expectations"
note "  · §6's host-binding comparison — record mode skips it BY DESIGN (nothing was injected, so comparing the host to itself is an assertion that cannot fail). It is exercised only by a live run"
note "  · whether the fixture's VALUES resemble a real cluster. §1 binds the field names; only 'sandbox.sh cni-chaos' binds the numbers"

pass "the chaos grader's branches, watched biting: 1 clean record graded clean, $FIRED defects each refused BY ITS OWN MESSAGE, 3 healthy-but-unusual records still accepted, and an unreadable record refused rather than graded as empty. No cluster, no root, ~2s — so the assertions guarding a 20-minute live matrix are now checked on every run instead of on the day they are needed"
