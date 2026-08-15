#!/usr/bin/env bash
# Verdict: the cross-node grader's own branches, watched firing.
#
# ── WHY THIS TEST EXISTS ────────────────────────────────────────────────────────────────
#
# `test-cross-node-chaos.sh` needs two VMs and ten minutes, so on any ordinary run — and in
# CI, always — it SKIPs and every assertion inside it goes unexercised. Those assertions are a
# pile of claims about what it WOULD do if the CNI misbehaved: it would fail if a row moved
# rung, if the workload never left one node, if the peer's InternalIP started tracking, if a
# row were silently skipped. **An assertion never observed failing is not known to work.**
#
# So this hands the grader a record with one defect injected, once per branch, and requires
# the matching assertion to bite BY ITS OWN MESSAGE. Matching the specific text is what
# separates "the assertion bit" from "the grader fell over", and those have opposite fixes.
#
# No cluster, no VM, no root. ~2 seconds. Same pairing as
# [`test-cni-chaos-grader.sh`](test-cni-chaos-grader.sh) and for the same reason.
#
# ── THE FIXTURE IS A REAL RECORD, NOT A PLAUSIBLE ONE ───────────────────────────────────
#
# Every line below is verbatim from the run of 2026-08-15 that first measured these two rows,
# with nothing tidied. A hand-invented record is this repo's bug class #1 in waiting — it
# stays readable after the emitter changes, the grader reads empty fields, calls them UNKNOWN,
# and every control here keeps passing while testing a format nothing produces. §1 is the
# partial payment: every key the fixture speaks must still be a key the injector emits.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

need sed grep mktemp
GRADER="$TEST_DIR/test-cross-node-chaos.sh"
INJECTOR="$LAB_DIR/cross-node-chaos.sh"
[[ -r "$GRADER"   ]] || fail "the grader under test is missing at $GRADER"
[[ -r "$INJECTOR" ]] || fail "cross-node-chaos.sh is missing at $INJECTOR — §1 cannot bind the fixture to anything"

WORK="$(mktemp -d)"; TMPDIRS+=("$WORK")
GOOD="$WORK/good.rec"

cat >"$GOOD" <<'EOF'
CNI2-TOPOLOGY nodes=2 leader=calico-n1 peer=calico-n2 autodetect=cidr=10.77.0.0/24 peer_addr=10.77.0.12 moves_to=10.77.0.22
CNI2-WORKLOAD-WAITING
CNI2-WORKLOAD-READY a=pod-xa@calico-n1/10.1.76.5 b=pod-xb@calico-n2/10.1.149.1 different_nodes=yes after=1s
CNI2-PATH dev=vxlan.calico (the leader's route to the peer's pod)
CNI2-ROW=control-no-fault BEFORE[xpods=OK path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True]
CNI2-ROW=control-no-fault AFTER[xpods=OK path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True] RECOVERED=n/a SECS=0 LIEWINDOW=0 SELFHEAL=n/a
CNI2-ROW=tunnel-deleted-under-peer BEFORE[xpods=OK path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True]
CNI2-ROW=tunnel-deleted-under-peer MID[xpods=FAIL path=enp0s3 tunnel=absent nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True] AFTER[xpods=OK path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True] RECOVERED=yes SECS=2 LANDED=gone-at-once LOSS=4/90 LIEWINDOW=0 SELFHEAL=yes
CNI2-ROW=peer-address-moved BEFORE[xpods=OK path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True]
CNI2-ROW=peer-address-moved RESTORED to=10.77.0.12 reconverged=yes after=62s
CNI2-ROW=peer-address-moved MID[xpods=FAIL path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.12/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True] AFTER[xpods=OK path=vxlan.calico tunnel=local_10.77.0.11_dev_enp0s4 nodeips=calico-n1:10.77.0.11/24,calico-n2:10.77.0.22/24 internalips=calico-n1:10.77.0.11,calico-n2:10.77.0.12 ready=calico-n1:True,calico-n2:True] RECOVERED=yes SECS=32 LANDED=addr-moved-10.77.0.12-to-10.77.0.22-on-enp0s4 MOVED_TO=10.77.0.22 LOSS=31/90 LIEWINDOW=30 SELFHEAL=yes
CNI2-END
EOF

_n=0
G_RC=0; G_OUT=""
run_grader() {  # run_grader <record> — sets G_RC and G_OUT
    _n=$((_n+1)); G_OUT="$WORK/out.$_n"
    # NOT PIPED. The exit status IS the gate here, and `bash … | grep` would report grep's.
    CNI2_CHAOS_RECORD="$1" bash "$GRADER" >"$G_OUT" 2>&1
    G_RC=$?
}

# ── 1. THE FIXTURE IS BOUND TO THE THING IT IMITATES ────────────────────────────────────
# It greps the `say` LINES, not the file: the one-node version of this check was fooled once
# by a renamed key surviving in a COMMENT, so the check passed while the property it stands
# for — "the injector still emits this key" — was false. Prose is not an emission.
EMITS="$WORK/emissions"
grep -h 'say "' "$INJECTOR" >"$EMITS"
(( $(wc -l <"$EMITS") > 8 )) \
    || fail "only $(wc -l <"$EMITS") 'say' lines found in cross-node-chaos.sh — the emission seam this section greps has moved, so every key below would report missing (or, worse, present) for reasons unrelated to the record format"

missing=()
for k in 'TOPOLOGY' 'WORKLOAD-READY' 'different_nodes=' 'PATH dev=' \
         'ROW=control-no-fault' 'ROW=tunnel-deleted-under-peer' 'ROW=peer-address-moved' \
         'INJECTOR-FAILED' 'SKIPPED reason=' 'RECOVERED=' 'SECS=' 'LANDED=' \
         'LOSS=' 'LIEWINDOW=' 'SELFHEAL=' 'MOVED_TO=' 'RESTORED to=' 'END'; do
    grep -qF -- "$k" "$EMITS" || missing+=("$k")
done
# The probe's own field names are emitted by a DIFFERENT file — the snapshots are its stdout,
# pasted into the record by the injector — so binding them to cross-node-chaos.sh would find
# nothing. They are bound to the emitter that actually prints them.
PROBE="$LAB_DIR/guest-xprobe.sh"
[[ -r "$PROBE" ]] || fail "guest-xprobe.sh is missing at $PROBE — the snapshot fields below have no emitter to be checked against"
for k in 'xpods=' 'path=' 'tunnel=' 'nodeips=' 'internalips=' 'ready='; do
    grep -qF -- "$k" "$PROBE" || missing+=("$k (guest-xprobe.sh)")
done
(( ${#missing[@]} == 0 )) \
    || fail "the fixture below speaks ${#missing[@]} key(s) that are no longer emitted: ${missing[*]}.
This is exactly the drift this section exists to catch: the grader would read those fields as
empty, render empty as UNKNOWN, and every negative control here would keep passing while
testing a record format nothing produces. Update the fixture in the same commit that renamed
the field."
note "fixture bound: all 24 record keys it uses are still emitted, across cross-node-chaos.sh and guest-xprobe.sh  ✓ (this checks the NAMES; only a live run checks the values)"

# ── 2. THE POSITIVE CASE ────────────────────────────────────────────────────────────────
run_grader "$GOOD"
(( G_RC == 0 )) || { cat "$G_OUT" >&2; fail "the CLEAN record does not grade clean (rc=$G_RC). Every negative control below is an edit of this file, so if it fails for reasons of its own then all of them fire for that reason and none proves anything"; }
for want in 'the supplied record grades clean' '2 cross-node rows' '0 absorbed, 2 not, 0 critical' \
            'NOTHING WAS INJECTED IN THIS RUN' \
            'still reads' ; do
    grep -qF -- "$want" "$G_OUT" \
        || { cat "$G_OUT" >&2; fail "the clean record passed but the verdict never said '$want' — a PASS that does not report what it graded is not evidence anything was read"; }
done
note "clean record: PASS, 2 rows, 0 absorbed / 2 not / 0 critical, both stale-record findings reported  ✓"

# ── 3. THE NEGATIVE CONTROLS ────────────────────────────────────────────────────────────
# ⚠️ EVERY MUTATION BELOW MATCHES A PATTERN, NEVER A MEASURED VALUE — `LIEWINDOW=[0-9]*`, not
# `LIEWINDOW=35`. The fixture is refreshed from whatever the latest live run produced, and a
# control pinned to last run's number does not fail loudly when that number changes: measured
# here on 2026-08-15, `peer-address-halted-honestly` was two edits in one program, the second
# stopped matching when the fixture went from 35 to 30, and the control quietly became a
# DUPLICATE of the one above it. `cmp` could not catch that — the record HAD changed, just not
# in the way the control's name claims. A control that hardcodes its subject's numbers rots
# the moment the subject is re-measured, which is exactly when it is most needed.
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
        fail "REGRESSION: the '$name' defect was injected into the record and the grader PASSED it. That branch of test-cross-node-chaos.sh does not bite, so the property it claims to check is unguarded: a real cluster with this defect would be reported as healthy"
    fi
    if ! grep -qF -- "$want" "$G_OUT"; then
        cat "$G_OUT" >&2
        fail "the '$name' control failed the grader (rc=$G_RC) but NOT with its own message — expected to see '$want'. A wrong-reason failure is indistinguishable from a broken grader, and it would let the intended assertion rot while this test stayed green"
    fi
    FIRED=$((FIRED+1))
    note "$name → refused by name  ✓"
}

# (a) the ladder — each rung this matrix can reach, reached
control tunnel-never-came-back \
    '/^CNI2-ROW=tunnel-deleted-under-peer MID/s/AFTER\[xpods=OK/AFTER[xpods=FAIL/' \
    'recorded DEGRADED, measured STRANDED'
# ⚠️ THIS ONE MOVES `LOSS=`, NOT `MID[xpods=`, AND THE DIFFERENCE IS THE POINT. The rung used
# to be decided by that one MID sample; it is now decided by packets lost, because MID is a
# probe racing the CNI's recovery and the tunnel row's rebuild has been measured as fast as
# 1s against a probe that takes 3-4s. When the grading moved, this control had to move with
# it — a mutation aimed at the field that no longer decides anything would have gone on
# "passing" while testing nothing, which is the exact shape §3 exists to prevent.
control tunnel-fault-did-not-touch-the-dataplane \
    '/^CNI2-ROW=tunnel-deleted-under-peer MID/s|LOSS=[0-9]*/|LOSS=0/|' \
    'recorded DEGRADED, measured ABSORBED'
# The witness that never ran. `0/0` and "no packets were lost" are the same number and
# opposite facts, and reading the first as the second is how an unmeasured thing gets retired
# as fine — with the goal rung, no less.
control witness-never-ran \
    '/^CNI2-ROW=peer-address-moved MID/s|LOSS=[0-9]*/[0-9]*|LOSS=0/0|' \
    'so whether the fault touched the dataplane is UNMEASURED'
control witness-field-absent-entirely \
    '/^CNI2-ROW=peer-address-moved MID/s| LOSS=[0-9]*/[0-9]*||' \
    'no usable packet count'
control peer-address-needed-a-hand \
    '/^CNI2-ROW=peer-address-moved MID/s/SELFHEAL=yes/SELFHEAL=no/' \
    'recorded DEGRADED, measured LIED'
control peer-address-halted-honestly \
    '/^CNI2-ROW=peer-address-moved MID/{s/SELFHEAL=yes/SELFHEAL=no/; s/LIEWINDOW=[0-9]*/LIEWINDOW=0/}' \
    'recorded DEGRADED, measured HALTED'
control peer-address-never-came-back \
    '/^CNI2-ROW=peer-address-moved MID/s/AFTER\[xpods=OK/AFTER[xpods=FAIL/' \
    'recorded DEGRADED, measured STRANDED'

# (b) the two records of one address — the findings the rung cannot carry
control recovery-credited-to-a-redetection-that-did-not-happen \
    '/^CNI2-ROW=peer-address-moved MID/s|AFTER\[\(.*\)calico-n2:10.77.0.22/24|AFTER[\1calico-n2:10.77.0.12/24|' \
    'crediting re-detection with a recovery it did not perform'
# `/2` — the SECOND occurrence on the line, which is AFTER's. MID and AFTER both carry an
# `internalips=` list on this one line, and the first draft of this mutation matched neither:
# it tried to anchor on ` RECOVERED` immediately after the internalips list, forgetting the
# `ready=` field between them. `control` refused it for changing nothing, which is precisely
# what that guard is for — the alternative was a control that "passed" by grading the clean
# record, indistinguishable from a working one.
control kubelet-started-tracking-node-ip \
    '/^CNI2-ROW=peer-address-moved MID/s/calico-n2:10\.77\.0\.12 /calico-n2:10.77.0.22 /2' \
    'REGRESSION (in the good direction)'
control before-snapshot-lost-its-address-fields \
    '/^CNI2-ROW=peer-address-moved BEFORE/s/ internalips=[^ ]*//' \
    'neither of the two claims below can be checked'

# (c) the harness's own honesty — the assertions that are ABOUT the record rather than the CNI
control workload-was-never-cross-node \
    's/different_nodes=yes/different_nodes=no/' \
    'was NOT spread across two nodes'
control workload-claims-two-nodes-but-names-one \
    '/^CNI2-WORKLOAD-READY/s|b=pod-xb@calico-n2/|b=pod-xb@calico-n1/|' \
    'the claim and the fields disagree'
control workload-never-existed \
    '/^CNI2-WORKLOAD-READY/d' \
    'the two-pod workload never came up'
control no-fault-control-failed \
    '/^CNI2-ROW=control-no-fault AFTER/s/xpods=OK/xpods=FAIL/' \
    'the NO-FAULT control could not ping'
control row-absent-entirely \
    '/^CNI2-ROW=tunnel-deleted-under-peer/d' \
    "the 'tunnel-deleted-under-peer' row is missing from the record entirely"
control injector-did-not-land \
    's|^CNI2-ROW=tunnel-deleted-under-peer MID.*|CNI2-ROW=tunnel-deleted-under-peer INJECTOR-FAILED the device was still present immediately after the delete — the fault never happened|' \
    "the 'tunnel-deleted-under-peer' injector did not land"
control record-is-partial \
    '/^CNI2-END/d' \
    'does not reach CNI2-END'

# ⚠️ A SKIPPED ROW IS A FAILURE HERE, AND THAT IS A DELIBERATE DIFFERENCE FROM THE ONE-NODE
# GRADER, where a skip is a legitimate `UNCOVERED` note. That file grades eight rows over
# seven layers and can lose one and still be a matrix. This one exists to cover exactly two
# scenarios; covering one of them and passing would make an UNKNOWN indistinguishable from a
# result. The by-name check in §5 is what enforces it — and, unlike a row COUNT, it cannot
# quietly stop biting when the matrix grows.
control a-skipped-row-is-not-coverage \
    '/^CNI2-ROW=peer-address-moved MID/s/ MID.*/ SKIPPED reason=synthetic-for-the-negative-control/' \
    "the 'peer-address-moved' row was NOT graded in this run"

# ── 4. THE ALTERNATE PASSING BRANCH ─────────────────────────────────────────────────────
# Not a defect — the other side of the ordering claim the grader makes in its own header, and
# the one branch a reader is most likely to doubt: SELFHEAL is consulted BEFORE LIEWINDOW, so
# a fault that healed itself is DEGRADED even though the cluster reported every node Ready
# throughout. Without this, that ordering is an assertion nobody has watched.
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
variant a-long-lie-that-still-healed-itself \
    '/^CNI2-ROW=tunnel-deleted-under-peer MID/s/LIEWINDOW=[0-9]*/LIEWINDOW=85/' \
    'tunnel-deleted-under-peer — DEGRADED'
variant calico-redetected-before-the-first-sample \
    '/^CNI2-ROW=peer-address-moved MID/s|MID\[\(.*\)calico-n2:10.77.0.12/24\(.*\)internalips|MID[\1calico-n2:10.77.0.22/24\2internalips|' \
    'had ALREADY moved'

# ── 5. AND THE RECORD SWITCH ITSELF REFUSES WHAT IT CANNOT READ ─────────────────────────
run_grader "$WORK/there-is-no-such-record"
(( G_RC != 0 )) && grep -qF -- 'is not readable' "$G_OUT" \
    || { cat "$G_OUT" >&2; fail "CNI2_CHAOS_RECORD pointing at a nonexistent file did not produce a readable-file refusal (rc=$G_RC) — a grader that treats a missing record as an empty one grades a matrix of nothing and finds no faults in it"; }
note "an unreadable record is refused rather than graded as empty  ✓"

# ── 6. WHAT THIS FILE DOES *NOT* PROVE ──────────────────────────────────────────────────
note "NOT exercised here, and not claimed to be:"
note "  · §5's 'BOTH faults were absorbed' guard — reaching it needs both rows to grade ABSORBED, which trips each row's own REGRESSION check first. It is reachable only by editing the grader's expectations"
note "  · §6's host-binding comparison — record mode skips it BY DESIGN (nothing was injected, so comparing the host to itself is an assertion that cannot fail). Only a live run exercises it"
note "  · the tunnel row's SKIPPED branch (the overlay not being in the path). The fixture is from a cluster where it was; a record-driven test can synthesise the skip but not the CrossSubnet cluster that would produce it"
note "  · whether the fixture's VALUES resemble a real cluster. §1 binds the field names; only 'sandbox.sh cross-chaos' binds the numbers — and these ones came from the run of 2026-08-15"

pass "the cross-node grader's branches, watched biting: 1 real record graded clean, $FIRED defects each refused BY ITS OWN MESSAGE, 2 healthy-but-unusual records still accepted, and an unreadable record refused rather than graded as empty. No cluster, no root, ~2s — so the assertions guarding a two-VM ten-minute matrix are checked on every run instead of on the day they are needed"
