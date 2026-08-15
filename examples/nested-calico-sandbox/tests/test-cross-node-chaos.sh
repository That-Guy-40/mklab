#!/usr/bin/env bash
# Verdict: the two CNI faults that need a PEER — a tunnel deleted while it is carrying pod
# traffic, and a node's chosen address moved out from under a node that is routing to it —
# graded on CLAUDE.md's ladder against a dataplane that crosses two kernels.
#
# ── WHAT THIS ADDS TO THE ONE-NODE MATRIX, PRECISELY ────────────────────────────────────
#
# `test-cni-chaos.sh` grades eight rows and says, in the open, that two of them are graded on
# a proxy because a single node cannot observe their real consequence:
#
#   vxlan-deleted           "graded on rebuild alone" — with no peers the tunnel carries no
#                           traffic, so the dataplane observable cannot move whatever happens
#   chosen-address-removed  the F.6 mechanism with nobody on the other end to notice
#
# Those are honest UNKNOWNs, and this file is what turns them into measurements. Nothing here
# replaces the one-node matrix: it is the same ladder asked of the same CNI with a witness.
#
# ── THE RUNGS, AND WHY LIED IS DERIVED FROM TWO FIELDS AND NOT ONE ──────────────────────
#
#   ABSORBED  the cross-node dataplane never noticed                        ← the goal
#   DEGRADED  it broke and healed ITSELF
#   HALTED    it broke, needed the verb the system offers, and recovered
#   LIED      it broke, did not heal itself, AND the cluster reported every node Ready for
#             the whole outage — the record and reality disagreeing
#   STRANDED  it broke and nothing brought it back
#
# `LIEWINDOW` is the seconds spent broken while every node reported Ready, sampled by the
# injector. It is what makes LIED a measurement instead of a rhetorical flourish: F.6 was not
# "a node broke", it was an outage that looked like a healthy cluster, and a matrix that
# records only the dataplane can say the traffic stopped but not that nothing admitted it.
#
# A transient that heals itself is NOT the critical rung even though the cluster said Ready
# throughout — hence SELFHEAL is consulted before LIEWINDOW. The lie that matters is the one
# still standing when someone comes looking.
#
# NEEDS THE LIVE TWO-NODE PAIR and takes ~10 minutes. SKIPs otherwise, because an unmet
# precondition is an UNKNOWN and never a pass.
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

host_binding() { ip -d link show vxlan.calico 2>/dev/null | grep -oE 'local [0-9.]+ dev [a-zA-Z0-9._-]+' || true; }

# Same record switch as the one-node grader, for the same two reasons: re-read a failed run's
# evidence without spending the cluster time again, and RUN THE NEGATIVE CONTROLS — every
# branch below is a claim about what this file would do if the CNI misbehaved, and a claim
# nobody has watched fire is not known to work. See test-cross-node-grader.sh.
RECORD="${CNI2_CHAOS_RECORD:-}"
if [[ -n "$RECORD" ]]; then
    [[ -r "$RECORD" ]] || fail "CNI2_CHAOS_RECORD=$RECORD is not readable"
    note "⚠ GRADING A SUPPLIED RECORD ($RECORD) — nothing was injected in this run. These rungs describe whatever cluster wrote this file, whenever that was"
    OUT="$RECORD"
    grep -q '^CNI2-END' "$OUT" || fail "the supplied record does not reach CNI2-END, so it is partial"
else
    [[ -x "$SANDBOX" ]] || skip "sandbox.sh is not executable at $SANDBOX"
    [[ -r "$LAB_DIR/cross-node-chaos.sh" ]] || skip "cross-node-chaos.sh is missing"
    two_node_running \
        || skip "the two-node pair is not running — this test breaks a live CNI and will not invent one. Bring it up with 'examples/nested-calico-sandbox/sandbox.sh up2 && sandbox.sh join2' (~20 min, unprivileged), then re-run"

    HOST_BEFORE="$(host_binding)"
    note "host binding before: ${HOST_BEFORE:-<absent>}  (this lab breaks a CNI; it must not be that one)"

    OUT="$(mktemp)"
    on_exit 'if [[ "${_EXIT_RC:-1}" -eq 0 ]]; then rm -f -- "$OUT"; else printf "  - the cross-node record was kept: re-grade it without re-running with CNI2_CHAOS_RECORD=%s\n" "$OUT" >&2; fi'
    note "injecting the two cross-node faults (~10 min — each row waits out its own recovery)"
    if ! bash "$SANDBOX" cross-chaos >"$OUT" 2>&1; then
        cat "$OUT" >&2
        fail "the cross-node chaos run did not complete — a partial run must never be read as a matrix"
    fi
    grep -q '^CNI2-END' "$OUT" \
        || { cat "$OUT" >&2; fail "the run did not reach CNI2-END, so what is above is partial"; }
fi

rowline() { grep "^CNI2-ROW=$1 " "$OUT" | grep 'AFTER\[' | tail -1; }
rowinfo() { grep "^CNI2-ROW=$1 $2" "$OUT" | tail -1; }
field()   { sed -n "s/.*$2\[\([^]]*\)\].*/\1/p" <<<"$1"; }
kv()      { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<" $1"; }

# ── 1. THE MATRIX MUST ACTUALLY HAVE BEEN CROSS-NODE ────────────────────────────────────
# This is the precondition the whole file rests on, and it is the one that fails INVISIBLY:
# two pods that landed on the same node talk over a veth pair and a bridge, no fault below
# touches them, every row grades ABSORBED, and the result reads as a CNI that shrugged off
# two faults rather than a matrix that never left one kernel.
wl="$(grep '^CNI2-WORKLOAD-READY' "$OUT" | tail -1)"
[[ -n "$wl" ]] \
    || { cat "$OUT" >&2; fail "the two-pod workload never came up, so there was no cross-node dataplane to break and no row below means anything"; }
[[ "$(kv "$wl" different_nodes)" == yes ]] \
    || { cat "$OUT" >&2; fail "the workload was NOT spread across two nodes ($wl). Every row below would grade ABSORBED because no fault to the overlay can touch two pods on one kernel — a matrix reporting resilience it never tested"; }
a_node="$(sed -n 's/.* a=[^@]*@\([^/]*\).*/\1/p' <<<"$wl")"
b_node="$(sed -n 's/.* b=[^@]*@\([^/]*\).*/\1/p' <<<"$wl")"
[[ -n "$a_node" && -n "$b_node" && "$a_node" != "$b_node" ]] \
    || fail "the record claims different_nodes=yes but names '$a_node' and '$b_node' — the claim and the fields disagree, and the claim is the one that would be believed"
note "workload: $wl  ✓  (pods on $a_node and $b_node)"

topo="$(grep '^CNI2-TOPOLOGY' "$OUT" | tail -1)"
note "topology: ${topo#CNI2-}"

# THE OVERLAY MUST HAVE BEEN IN THE PATH. Calico in `CrossSubnet` mode routes directly between
# nodes that share a subnet — which these two do — and then vxlan.calico is decoration.
# Deleting a device nothing routes through is not a fault, and the row would report ABSORBED
# meaning "we broke something that was not in the path".
path_dev="$(kv "$(grep '^CNI2-PATH' "$OUT" | tail -1)" dev)"
note "the leader's route to the peer's pod goes via '$path_dev'"

# ── 2. THE CONTROL — no fault, and traffic crosses ──────────────────────────────────────
ctl="$(rowline control-no-fault)"
[[ "$(kv "$(field "$ctl" AFTER)" xpods)" == OK ]] \
    || { cat "$OUT" >&2; fail "the NO-FAULT control could not ping the peer's pod. Nothing below is measurable: a matrix whose control fails is grading a broken harness, not a CNI"; }
note "control (no fault): $(field "$ctl" AFTER)  ✓"

ABSORBED=0; NOTABSORBED=0; CRITICAL=0; ROWS=0; GRADED=""
grade() {  # grade <row> <expected-rung>
    local name="$1" want="$2" line before after rec selfheal lie mid got
    line="$(rowline "$name")"
    if [[ -z "$line" ]]; then
        if grep -q "^CNI2-ROW=$name SKIPPED" "$OUT"; then
            note "UNCOVERED: $name — $(grep "^CNI2-ROW=$name SKIPPED" "$OUT" | sed 's/.*reason=//')"
            return
        fi
        if grep -q "^CNI2-ROW=$name INJECTOR-FAILED" "$OUT"; then
            fail "the '$name' injector did not land, so there is no fault to grade: $(grep "^CNI2-ROW=$name INJECTOR-FAILED" "$OUT" | sed "s/^CNI2-ROW=$name INJECTOR-FAILED //")
An injector that silently does nothing is the worst outcome available here — the row would
otherwise report ABSORBED, which reads as resilience and means 'nothing was broken'."
        fi
        fail "the '$name' row is missing from the record entirely — a layer with no scenario is a layer nobody has watched fall over, and a silently absent row is worse than a named gap"
    fi
    # BEFORE lives on its OWN line — it is emitted before the fault, when there is nothing yet
    # to print MID or AFTER beside. Reading it off the graded line (which is what the one-node
    # grader does) silently yields an empty string, so its REGRESSION message shows a blank
    # "before:" exactly when a human most wants the contrast.
    before="$(field "$(rowinfo "$name" BEFORE)" BEFORE)"; after="$(field "$line" AFTER)"
    rec="$(kv "$line" RECOVERED)"; selfheal="$(kv "$line" SELFHEAL)"; lie="$(kv "$line" LIEWINDOW)"
    mid="$(kv "$(field "$line" MID)" xpods)"
    local after_x loss lost; after_x="$(kv "$after" xpods)"

    # ── ABSORBED IS DECIDED BY PACKETS LOST, NOT BY THE `MID` SAMPLE ────────────────────
    # MID is one probe racing the CNI's recovery, and it decides the row: the tunnel row's
    # rebuild has been measured at 9s, 9s and 1s, against a probe that takes 3-4s. A rebuild
    # that outran the probe would report MID=OK and hand this row an ABSORBED reading as
    # "the CNI shrugged off having its overlay deleted". So the row carries a 1-per-second
    # ping run for the whole fault window, and one lost packet is one second of dead traffic.
    loss="$(kv "$line" LOSS)"; lost="${loss%%/*}"
    # `0/0` AND "nothing was lost" ARE THE SAME NUMBER AND OPPOSITE FACTS. A witness that
    # never ran must be an UNKNOWN and never the goal rung — silently reading it as zero loss
    # is exactly how an unchecked thing gets retired as fine.
    [[ "$loss" =~ ^[0-9]+/[1-9][0-9]*$ ]] \
        || fail "the '$name' row has no usable packet count (LOSS='${loss:-<absent>}'), so whether the fault touched the dataplane is UNMEASURED. That is not ABSORBED and must not be graded as though it were: the witness ping either never started or never reported, and the fix is to the harness, not to the CNI"

    # The order is the argument. `after != OK` first, because nothing still broken can be
    # anything but STRANDED. Then zero packets lost, the only way to earn ABSORBED. Then
    # SELFHEAL BEFORE LIEWINDOW: a fault that healed itself in ten seconds had the cluster
    # reporting Ready throughout too, and calling that critical would put every transient there.
    if   [[ "$after_x" != OK ]];   then got=STRANDED
    elif (( lost == 0 ));          then got=ABSORBED
    elif [[ "$selfheal" == yes ]]; then got=DEGRADED
    elif [[ -n "$lie" ]] && (( lie > 0 )); then got=LIED
    else                                got=HALTED
    fi

    ROWS=$((ROWS+1)); GRADED="$GRADED $name"
    [[ "$got" == ABSORBED ]] && ABSORBED=$((ABSORBED+1)) || NOTABSORBED=$((NOTABSORBED+1))
    [[ "$got" == STRANDED || "$got" == LIED ]] && CRITICAL=$((CRITICAL+1))

    if [[ "$want" != "$got" ]]; then
        fail "REGRESSION: the '$name' row moved on the ladder — recorded $want, measured $got.
  before: $before
  mid:    $(field "$line" MID)
  after:  $after  (recovered=$rec, selfheal=$selfheal, ${lie:-?}s of it while every node reported Ready)
A rung that changes means the CNI's cross-node failure behaviour changed under this lab, and
that is worth a human look in BOTH directions: a row that silently improved is as interesting
as one that regressed."
    fi
    note "$name — $got  ✓  ($lost packets lost of ${loss##*/}; recovered=$rec in $(kv "$line" SECS)s; selfheal=$selfheal; ${lie:-0}s of it with the cluster reporting every node Ready)"
}

# ── 3. the rows, each at the rung it was measured at ────────────────────────────────────
grade tunnel-deleted-under-peer DEGRADED
grade peer-address-moved        DEGRADED

# ── 3b. THE TWO RECORDS OF THE PEER'S ADDRESS, WHICH THE RUNG CANNOT ASK ABOUT ──────────
#
# A rung says what happened to the traffic. It cannot say what the CLUSTER was claiming while
# that happened, and on this row that is the finding: a node's address is written down TWICE —
# Calico's `projectcalico.org/IPv4Address` annotation and the node's `InternalIP`, which
# kubelet publishes from its `--node-ip` flag — by different components on different
# schedules. Bug class #1 asks whether either of them outlives its subject.
#
# Nothing here is hardcoded to an address: every claim is BEFORE compared with MID and AFTER,
# so the assertions survive the lab being re-addressed and cannot pass by matching a constant.
nodeval() { tr ',' '\n' <<<"$1" | sed -n "s|^$2:||p"; }
pam="$(rowline peer-address-moved)"
if [[ -n "$pam" ]]; then
    pam_before="$(field "$(rowinfo peer-address-moved BEFORE)" BEFORE)"
    pam_mid="$(field "$pam" MID)"; pam_after="$(field "$pam" AFTER)"
    moved_to="$(kv "$pam" MOVED_TO)"
    b4_annot="$(nodeval "$(kv "$pam_before" nodeips)" "$b_node")"
    mid_annot="$(nodeval "$(kv "$pam_mid" nodeips)" "$b_node")"
    after_annot="$(nodeval "$(kv "$pam_after" nodeips)" "$b_node")"
    b4_iip="$(nodeval "$(kv "$pam_before" internalips)" "$b_node")"
    after_iip="$(nodeval "$(kv "$pam_after" internalips)" "$b_node")"

    [[ -n "$b4_annot" && -n "$b4_iip" ]] \
        || fail "the record does not carry $b_node's address annotation and InternalIP before the move (nodeips='$(kv "$pam_before" nodeips)' internalips='$(kv "$pam_before" internalips)'), so neither of the two claims below can be checked against anything. An unmeasurable claim must not be printed as a finding"

    # (a) WAS THE RECORD STALE WHILE THE TRAFFIC WAS DOWN? Reported in both directions rather
    # than asserted: MID is one sample taken as fast as the harness can take it, and a Calico
    # that re-detected inside that window would be a genuinely faster CNI, not a defect.
    if [[ "$mid_annot" == "$b4_annot" ]]; then
        note "the peer's Calico annotation still named '$mid_annot' while its traffic was already down — the record outlived the address it describes  ✓ (bug class #1, measured rather than argued)"
    else
        note "the peer's Calico annotation had ALREADY moved to '$mid_annot' by the first sample after the fault — faster re-detection than this lab has measured before, and worth a look"
    fi

    # (b) …and the SECOND record, the one `kubectl get nodes -o wide` prints. Only checkable
    # on the self-heal path: when the address had to be restored by hand, AFTER is taken with
    # the original address back in place and the comparison is vacuous.
    if [[ "$(kv "$pam" SELFHEAL)" == yes ]]; then
        [[ "$after_annot" == "$moved_to"* ]] \
            || fail "the row recorded SELFHEAL=yes, but the peer's Calico annotation reads '$after_annot' and not '$moved_to'. Then the dataplane came back for some reason OTHER than Calico re-detecting the moved address, and this row is crediting re-detection with a recovery it did not perform"
        if [[ "$after_iip" == "$b4_iip" ]]; then
            note "the peer's InternalIP still reads '$after_iip' — the address it had BEFORE the move, which no longer exists — while Calico's annotation correctly reads '$after_annot'  ✓  The cluster keeps two records of one address, they disagree, and the stale one is the one 'kubectl get nodes -o wide' shows"
        else
            fail "REGRESSION (in the good direction): the peer's InternalIP moved from '$b4_iip' to '$after_iip' by itself. This lab records that kubelet does NOT re-read --node-ip and leaves that field naming an address that has ceased to exist; if it now tracks, the finding in findings-two-node.env is out of date and a human should say so rather than a test quietly accepting either answer"
        fi
    fi
fi

# ── 4. the layers NOT covered, named rather than left implicit ──────────────────────────
note "NOT covered by this file, deliberately:"
note "  · the eight single-node layers — they are test-cni-chaos.sh's, and running them here would measure the same thing twice while making the pair look like sixteen distinct findings"
note "  · the tunnel deleted on the PEER rather than the leader. The overlay is symmetric and this asks the same question from the other side; it is a cheap row to add and has not been run, which is different from having been run and found equivalent"
note "  · a partition of the wire itself (both nodes healthy, no path between them). That is a fault in the fabric rather than in the CNI, and its dataplane consequence is arithmetic; what would be interesting is the CLUSTER's honesty about it, which needs its own row"
note "  · three or more nodes: everything here is one peer watching one peer, so nothing observes a partial outage — the shape where half a fleet is fine and says so"
note "  · an address that moves somewhere the peer can NEVER reach. Measured 2026-08-15: under 'cidr=' autodetection a competing interface does not win while the incumbent address still matches — not in 205s, and not across a calico-node restart — so inducing that would mean changing the CNI's configuration mid-run, which is changing the subject rather than injecting a fault"

# ── 5. THE MATRIX MUST BE OCCUPIED, AND BY NAME ─────────────────────────────────────────
#
# NOT by a count. The one-node grader guards itself with `ROWS >= 5`, and that threshold is
# exactly what rotted: a negative control tuned to skip enough rows to fall below it silently
# stopped biting when an eighth row was added. A count is a proxy for coverage; the names are
# the coverage.
for want_row in tunnel-deleted-under-peer peer-address-moved; do
    [[ " $GRADED " == *" $want_row "* ]] \
        || fail "the '$want_row' row was NOT graded in this run — it was skipped or absent, and the reason is above. This file exists to cover exactly two scenarios; covering one of them and passing would make an UNKNOWN indistinguishable from a result, which is the substitution this repo keeps getting caught by"
done
# AND THERE IS DELIBERATELY NO "at least one row ABSORBED" GUARD, unlike the one-node grader.
# Both rows here exist BECAUSE they break the dataplane: an ABSORBED would be the surprise,
# not the reassurance. The job that guard does over there — telling "the faults landed" from
# "the CNI has no resilience left" — is done here by §2's no-fault control, which is the row
# that must come out clean.
(( NOTABSORBED > 0 )) \
    || fail "BOTH cross-node faults were absorbed. On this topology that is far more likely to mean the faults did not land — a workload that quietly ran on one node, an overlay that was not in the path — than a CNI that shrugs off having its tunnel deleted. A matrix where nothing breaks cannot tell resilience from an injector that missed"
note "ladder occupied: $ROWS rows, $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical  ✓"

# ── 6. and the host's own cluster never moved ───────────────────────────────────────────
if [[ -n "$RECORD" ]]; then
    pass "the supplied record grades clean: $ROWS cross-node rows, $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical. NOTHING WAS INJECTED IN THIS RUN — this says the grader reads that file correctly, and says nothing whatever about any cluster's health today"
fi
HOST_AFTER="$(host_binding)"
[[ "$HOST_AFTER" == "$HOST_BEFORE" ]] \
    || fail "REGRESSION: the HOST's Calico binding moved during this run: '${HOST_BEFORE:-<absent>}' -> '${HOST_AFTER:-<absent>}'. This lab exists so that breaking a CNI costs nothing; if it can reach the host's, it is not a sandbox"
note "host binding unchanged across the whole cross-node break pass: ${HOST_AFTER:-<absent>}  ✓"

pass "the two faults a single node could not ask, asked: a VXLAN tunnel deleted while it carried real pod-to-pod traffic, and F.6 with a witness — a node's chosen address moved out from under a peer that was routing to it. $ROWS rows, $ABSORBED absorbed, $NOTABSORBED not, $CRITICAL critical, graded on a dataplane that crosses two kernels rather than on whether a device came back. The one-node matrix's two proxy rows now have the measurement they were standing in for, and each carries the number that needed a witness: seconds of dead traffic, and how many of them the cluster spent reporting every node Ready"
